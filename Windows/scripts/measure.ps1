param(
    [Parameter(Mandatory=$true)][string]$AppDirectory,
    [Parameter(Mandatory=$true)][string]$ResultsDirectory
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $ResultsDirectory | Out-Null
$report = Join-Path (Resolve-Path $ResultsDirectory) 'smoke-raw.json'
$executable = Join-Path (Resolve-Path $AppDirectory) 'Inkpot.exe'
$started = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$process = Start-Process $executable -ArgumentList "--smoke-report `"$report`"" -PassThru
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    while (!(Test-Path $report)) {
        if ($process.HasExited) { throw "应用在生成报告前退出，退出码：$($process.ExitCode)" }
        if ([DateTime]::UtcNow -gt $deadline) { throw '应用冒烟检查超过 120 秒。' }
        Start-Sleep -Milliseconds 100
    }
    $raw = Get-Content -Raw $report | ConvertFrom-Json
    # 成败都先截图：编辑器逻辑通过但组合层未渲染时，截图直接暴露空白窗口。
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = New-Object System.Drawing.Bitmap $screen.Width, $screen.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($screen.Location, [System.Drawing.Point]::Empty, $screen.Size)
        $bitmap.Save((Join-Path (Resolve-Path $ResultsDirectory) 'window-screenshot.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
    if (!$raw.success) { throw $raw.error }
    $ids = @($process.Id) + @($raw.webView2ProcessIds) | Sort-Object -Unique
    $samples = @()
    foreach ($iteration in 1..3) {
        $entries = @($ids | ForEach-Object {
            $running = Get-Process -Id $_ -ErrorAction SilentlyContinue
            if ($running) { [ordered]@{ pid = $running.Id; name = $running.ProcessName; workingSetBytes = $running.WorkingSet64; privateBytes = $running.PrivateMemorySize64 } }
        })
        $samples += [ordered]@{ processes = $entries; totalWorkingSetBytes = ($entries | Measure-Object workingSetBytes -Sum).Sum; totalPrivateBytes = ($entries | Measure-Object privateBytes -Sum).Sum }
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
        memorySamples = $samples; publishedBytes = $bytes
        method = '一次新进程启动到 ready；打开 1 MiB UTF-8 Markdown 后取得完整快照；激活10标签后对应用及本环境全部WebView2进程采样3次。runner磁盘缓存未清理，启动数据不是硬件冷启动验收。'
    }
    $measurements | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $ResultsDirectory 'measurements.json') -Encoding utf8
    $measurements | ConvertTo-Json -Depth 8
    if ($env:GITHUB_STEP_SUMMARY) {
        @"
## Windows MVP 验证

- 实际启动、编辑/撤销、混合行尾往返、1 MiB 大文本消息：通过
- 标签按需创建：激活前 $($raw.webViewsBeforeActivation) 个，全部激活后 $($raw.activatedTabs) 个；编辑器可视尺寸 $($raw.editorVisualSize)
- 新进程到 ready：$($measurements.startupProcessToReadyMilliseconds) ms
- 1 MiB 文档打开及完整快照：$($raw.open1MiBMilliseconds) ms
- 发布目录：$([Math]::Round($bytes / 1MB, 2)) MiB（包含 .NET，依赖共享 Windows App Runtime 和 WebView2）
- 原始机器信息与逐进程内存见 measurements.json；这些数据不能替代 Windows 11 桌面验收。
"@ | Add-Content $env:GITHUB_STEP_SUMMARY
    }
}
finally {
    if (!$process.HasExited) {
        [void]$process.CloseMainWindow()
        if (!$process.WaitForExit(10000)) { throw '测试应用未能正常退出，保留现场。' }
    }
}
