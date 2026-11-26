param(
    [Parameter(Mandatory=$true)][string]$AppDirectory,
    [Parameter(Mandatory=$true)][string]$ResultsDirectory
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $ResultsDirectory | Out-Null
$resultsPath = (Resolve-Path $ResultsDirectory).Path
$report = Join-Path $resultsPath 'smoke-raw.json'
$traceLog = Join-Path $resultsPath 'smoke-trace.log'
$screenshot = Join-Path $resultsPath 'window-screenshot.png'
$executable = Join-Path (Resolve-Path $AppDirectory).Path 'Inkpot.exe'
$smokeData = Join-Path ([IO.Path]::GetTempPath()) ("InkpotSmoke-" + [Guid]::NewGuid().ToString('N'))

function Save-ScreenCapture([string]$Path) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bitmap = New-Object System.Drawing.Bitmap $screen.Width, $screen.Height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen($screen.Location, [System.Drawing.Point]::Empty, $screen.Size)
            $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
    } catch {
        Write-Warning "保存现场截图失败：$($_.Exception.Message)"
    }
}

function Stop-ProcessTree([System.Diagnostics.Process]$Target) {
    if ($null -eq $Target -or $Target.HasExited) { return }
    try { $Target.Kill($true) } catch { try { $Target.Kill() } catch { } }
    try { [void]$Target.WaitForExit(5000) } catch { }
}

function Write-FailureDiagnostics([System.Diagnostics.Process]$Target) {
    if (!(Test-Path $screenshot)) { Save-ScreenCapture $screenshot }
    if ($null -ne $Target) {
        if ($Target.HasExited) {
            Write-Host "冒烟进程已退出（PID=$($Target.Id)，ExitCode=$($Target.ExitCode)）。"
        } else {
            Write-Host "冒烟进程仍在运行（PID=$($Target.Id)）。"
        }
    }
    if (Test-Path $traceLog) {
        Write-Host '=== smoke-trace.log ==='
        Get-Content $traceLog | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host 'smoke-trace.log 尚未生成（应用可能在 Root.Loaded 前失败或阻塞）。'
    }
    $crashLog = Join-Path $smokeData 'Logs\crash.log'
    if (Test-Path $crashLog) {
        Copy-Item $crashLog (Join-Path $resultsPath 'crash.log') -Force
        Write-Host '=== crash.log ==='
        Get-Content $crashLog | ForEach-Object { Write-Host $_ }
    }
}

$started = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$previousSmoke = $env:INKPOT_ALLOW_SMOKE
$previousData = $env:INKPOT_DATA_DIRECTORY
$env:INKPOT_ALLOW_SMOKE = '1'
$env:INKPOT_DATA_DIRECTORY = $smokeData
$failed = $false
$process = $null
try {
    $process = Start-Process $executable -ArgumentList "--smoke-report `"$report`"" -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(180)
    while (!(Test-Path $report)) {
        if ($process.HasExited) { throw "应用在生成报告前退出，退出码：$($process.ExitCode)" }
        if ([DateTime]::UtcNow -gt $deadline) { throw '应用冒烟检查超过 180 秒。' }
        Start-Sleep -Milliseconds 100
    }
    $raw = Get-Content -Raw $report | ConvertFrom-Json
    # 成败都先截图：编辑器逻辑通过但组合层未渲染时，截图直接暴露空白窗口。
    Save-ScreenCapture $screenshot
    if (!$raw.success) { throw $raw.error }
    $ids = @($process.Id) + @($raw.webView2ProcessIds) | Sort-Object -Unique
    $samples = @()
    foreach ($iteration in 1..3) {
        $entries = @($ids | ForEach-Object {
            $running = Get-Process -Id $_ -ErrorAction SilentlyContinue
            if ($running) { [pscustomobject][ordered]@{ pid = $running.Id; name = $running.ProcessName; workingSetBytes = $running.WorkingSet64; privateBytes = $running.PrivateMemorySize64 } }
        })
        $wsSum = ($entries | Measure-Object workingSetBytes -Sum).Sum
        $privSum = ($entries | Measure-Object privateBytes -Sum).Sum
        $samples += [ordered]@{
            processes = $entries
            totalWorkingSetBytes = if ($null -ne $wsSum) { [long]$wsSum } else { [long]0 }
            totalPrivateBytes = if ($null -ne $privSum) { [long]$privSum } else { [long]0 }
        }
        Start-Sleep -Seconds 1
    }
    $bytes = (Get-ChildItem $AppDirectory -File -Recurse | Measure-Object Length -Sum).Sum
    $machine = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $measurements = [ordered]@{
        runnerImage = $env:ImageOS; runnerImageVersion = $env:ImageVersion
        os = (Get-CimInstance Win32_OperatingSystem).Caption
        cpu = $cpu.Name; logicalProcessors = $machine.NumberOfLogicalProcessors; memoryBytes = $machine.TotalPhysicalMemory
        startupProcessToReadyMilliseconds = $raw.readyUnixMilliseconds - $started
        open1MiBMilliseconds = $raw.open1MiBMilliseconds
        documentCharacters = $raw.documentCharacters; documentUtf8Bytes = $raw.documentUtf8Bytes
        activatedTabs = $raw.activatedTabs; webViewsBeforeActivation = $raw.webViewsBeforeActivation
        editorVisualSize = $raw.editorVisualSize
        sidebarFilesOutlineSettingsAndStatus = $raw.sidebarFilesOutlineSettingsAndStatus
        memorySamples = $samples; publishedBytes = $bytes
        method = '一次新进程启动到 ready；打开 1 MiB UTF-8 Markdown 后取得完整快照；激活10标签后对应用及本环境全部WebView2进程采样3次。runner磁盘缓存未清理，启动数据不是硬件冷启动验收。'
    }
    $measurements | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $resultsPath 'measurements.json') -Encoding utf8
    $measurements | ConvertTo-Json -Depth 8
    if ($env:GITHUB_STEP_SUMMARY) {
        @"
## Windows 应用验证

- 实际启动、编辑/撤销、混合行尾往返、1 MiB 大文本消息：通过
- 文件树按需展开、设置对话框显示与取消、偏好持久化与同步、大纲跳转、标签切换、侧栏显隐与状态栏：$($raw.sidebarFilesOutlineSettingsAndStatus)
- 标签按需创建：激活前 $($raw.webViewsBeforeActivation) 个，全部激活后 $($raw.activatedTabs) 个；编辑器可视尺寸 $($raw.editorVisualSize)
- 新进程到 ready：$($measurements.startupProcessToReadyMilliseconds) ms
- 1 MiB 文档打开及完整快照：$($raw.open1MiBMilliseconds) ms
- 发布目录：$([Math]::Round($bytes / 1MB, 2)) MiB（包含 .NET，依赖共享 Windows App Runtime 和 WebView2）
- 原始机器信息与逐进程内存见 measurements.json；这些数据不能替代 Windows 11 桌面验收。
"@ | Add-Content $env:GITHUB_STEP_SUMMARY
    }
}
catch {
    $failed = $true
    Write-FailureDiagnostics $process
    throw
}
finally {
    if ($null -eq $previousSmoke) { Remove-Item Env:INKPOT_ALLOW_SMOKE -ErrorAction SilentlyContinue } else { $env:INKPOT_ALLOW_SMOKE = $previousSmoke }
    if ($null -eq $previousData) { Remove-Item Env:INKPOT_DATA_DIRECTORY -ErrorAction SilentlyContinue } else { $env:INKPOT_DATA_DIRECTORY = $previousData }
    if ($null -ne $process -and !$process.HasExited) {
        [void]$process.CloseMainWindow()
        if ($failed) {
            if (!$process.WaitForExit(3000)) { Stop-ProcessTree $process }
        } elseif (!$process.WaitForExit(25000)) {
            Save-ScreenCapture (Join-Path $resultsPath 'exit-timeout-screenshot.png')
            Write-FailureDiagnostics $process
            Stop-ProcessTree $process
            throw '测试应用在冒烟通过后未能于 25 秒内正常退出，已截屏并终止进程。'
        }
    }
    if (Test-Path $smokeData) {
        Remove-Item $smokeData -Recurse -Force -ErrorAction SilentlyContinue
    }
}
