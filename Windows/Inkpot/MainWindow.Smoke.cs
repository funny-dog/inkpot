using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using Inkpot.Bridge;
using Inkpot.Storage;
using Inkpot.Workspace;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Inkpot;

public sealed partial class MainWindow
{
    // 仅由 CI 显式参数触发；使用临时文档，不读取或覆盖用户文件。
    private async Task RunSmokeAsync(string reportPath)
    {
        var report = new JsonObject { ["success"] = false, ["os"] = Environment.OSVersion.ToString(),
            ["cpuCount"] = Environment.ProcessorCount, ["runtime"] = Environment.Version.ToString() };
        try
        {
            var initial = CreateDocument();
            await ActivateCurrentAsync();
            await AssertEditorVisibleAsync(initial, "首个文档");
            report["readyMilliseconds"] = initial.Editor!.ReadyMilliseconds;
            report["readyUnixMilliseconds"] = initial.Editor.ReadyUnixMilliseconds;
            report["editorVisualSize"] = $"{initial.Editor.Control.ActualWidth:0}x{initial.Editor.Control.ActualHeight:0}";
            const string original = "# 标题\r\n中文\n尾";
            await initial.Editor.OpenAsync(original, Dark, L10n.Language);
            await initial.Editor.CommandAsync("heading2");
            var changed = await initial.Editor.SnapshotAsync();
            if (changed.Text != "## 标题\r\n中文\n尾" || initial.Editor.State?.CanUndo != true)
                throw new IOException("编辑命令或撤销状态不正确。");
            await initial.Editor.CommandAsync("undo");
            if ((await initial.Editor.SnapshotAsync()).Text != original) throw new IOException("撤销未恢复原文。");
            report["editUndoAndLineEndings"] = true;
            await AssertWorkspaceAsync(initial, reportPath);
            report["sidebarFilesOutlineSettingsAndStatus"] = true;
            var text = new StringBuilder();
            const string paragraph = "Markdown paragraph 中文测试 with **bold** and a link.\n\n";
            int paragraphBytes = Encoding.UTF8.GetByteCount(paragraph);
            int totalBytes = 0;
            while (totalBytes + paragraphBytes <= 1024 * 1024) { text.Append(paragraph); totalBytes += paragraphBytes; }
            text.Append('x', 1024 * 1024 - totalBytes);
            string large = text.ToString();
            var timer = Stopwatch.StartNew();
            await initial.Editor.OpenAsync(large, Dark, L10n.Language);
            await initial.Editor.CommandAsync("focus");
            if ((await initial.Editor.SnapshotAsync()).Text != large) throw new IOException("大文档内容不一致。");
            report["open1MiBMilliseconds"] = timer.Elapsed.TotalMilliseconds;
            report["documentCharacters"] = large.Length;
            report["documentUtf8Bytes"] = Encoding.UTF8.GetByteCount(large);
            for (int index = 1; index < 10; index++) CreateDocument();
            report["webViewsBeforeActivation"] = documents.Count(document => document.Editor is not null);
            if (documents.Count(document => document.Editor is not null) != 1) throw new IOException("后台标签提前创建了 WebView2。");
            foreach (var document in documents)
            {
                Tabs.SelectedItem = document.Item;
                await ActivateCurrentAsync();
                await document.Editor!.CommandAsync("focus");
                await AssertEditorVisibleAsync(document, $"标签{documents.IndexOf(document) + 1}");
            }
            report["activatedTabs"] = documents.Count(document => document.Editor is not null);
            report["appWorkingSetBytes"] = Process.GetCurrentProcess().WorkingSet64;
            report["webView2ProcessIds"] = new JsonArray((await environment).GetProcessInfos()
                .Select(info => JsonValue.Create(info.ProcessId)).Cast<JsonNode?>().ToArray());
            report["success"] = true;
            foreach (var document in documents) document.SavedRevision = document.Editor?.State?.Revision ?? 0;
        }
        catch (Exception error)
        {
            report["error"] = error.ToString();
            Environment.ExitCode = 1;
        }
        finally
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(reportPath))!);
            await File.WriteAllTextAsync(reportPath, report.ToJsonString(new() { WriteIndented = true }));
            // 失败时保留窗口数秒：measure.ps1 读到报告会先截图留现场再关闭应用。
            if (report["success"]?.GetValue<bool>() != true)
            {
                allowClose = true;
                await Task.Delay(TimeSpan.FromSeconds(8));
                Close();
            }
        }
    }

    private async Task AssertWorkspaceAsync(DocumentTab initial, string reportPath)
    {
        string directory = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(reportPath))!, "workspace-fixture");
        Directory.CreateDirectory(Path.Combine(directory, "子目录"));
        string path = Path.Combine(directory, "文档2.md");
        const string markdown = "# 第一章\r\n中文正文\n\n## 第二章\n更多文字\n";
        await File.WriteAllTextAsync(path, markdown);
        await File.WriteAllTextAsync(Path.Combine(directory, "子目录", "子文档.txt"), "子目录内容");
        await OpenFolderAsync(directory);
        Root.UpdateLayout();
        if (SidebarPanel.ActualWidth < 180 || SidebarPanel.ActualHeight < 100 || FilesTree.RootNodes.Count != 2)
            throw new IOException("文件树侧栏未显示或未列出测试文件。");
        var directoryNode = FilesTree.RootNodes.First(node => node.Content is FileTreeEntry { IsDirectory: true });
        if (!directoryNode.HasUnrealizedChildren || directoryNode.Children.Count != 0) throw new IOException("文件树未按需加载。");
        await ExpandDirectoryAsync(directoryNode, (FileTreeEntry)directoryNode.Content);
        directoryNode.IsExpanded = true;
        if (directoryNode.HasUnrealizedChildren || directoryNode.Children.Count != 1) throw new IOException("子目录展开失败。");

        var before = await initial.Editor!.SnapshotAsync();
        var originalPreferences = preferences;
        var changed = preferences with { BodySize = 18, CodeSize = 16, IndentWidth = 4, PairBrackets = false,
            PairMarkdown = false, FocusMode = true, TypewriterMode = true, Appearance = "dark", DefaultSourceMode = true };
        await ChangePreferencesAsync(changed);
        if (AppPreferences.Load(preferencesPath!) != changed.Normalize()) throw new IOException("设置没有完整持久化。");
        var font = await initial.Editor.Control.CoreWebView2.ExecuteScriptAsync("document.querySelector('.cm-editor').style.getPropertyValue('--inkpot-body-size')");
        if (font != "\"18px\"" || Root.ActualTheme != ElementTheme.Dark || (await initial.Editor.SnapshotAsync()) != before)
            throw new IOException("设置未同步，或改变了文档文本／撤销版本。");

        AppPreferences? accepted = null;
        var dialog = PreferencesDialog.Create(Root.XamlRoot, preferences, next => accepted = next);
        var showing = dialog.ShowAsync();
        try
        {
            var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(5);
            while (!dialog.IsLoaded || dialog.ActualWidth < 100)
            {
                if (DateTime.UtcNow > deadline) throw new IOException("设置对话框没有进入可视区域。");
                await Task.Delay(50);
            }
        }
        finally { dialog.Hide(); await showing; }
        if (accepted is not null || preferences != changed) throw new IOException("取消设置修改了偏好。");

        await OpenPathAsync(path);
        var fixture = Current!;
        if (fixture == initial || fixture.Editor?.State?.SourceMode != true || (await fixture.Editor!.SnapshotAsync()).Text != markdown)
            throw new IOException("文件树打开流程或默认源码模式没有生效。");
        await ShowOutlineAsync();
        var outlineDeadline = DateTime.UtcNow + TimeSpan.FromSeconds(5);
        while (fixture.Editor.Headings.Count != 2)
        {
            if (DateTime.UtcNow > outlineDeadline) throw new IOException("大纲消息没有传入 Windows 侧栏。");
            await Task.Delay(50);
        }
        RefreshOutline();
        if (OutlineList.Items.Count != 2 || EmptyOutline.Visibility != Visibility.Collapsed)
            throw new IOException("大纲未显示标题。");
        await fixture.Editor.NavigateHeadingAsync(fixture.Editor.Headings[1].Id);
        // 通过编辑操作验证光标已到第二个标题；撤销后正文必须完全一致。
        await fixture.Editor.PasteAsync("跳转");
        if (!(await fixture.Editor.SnapshotAsync()).Text.Contains("## 跳转第二章"))
            throw new IOException("大纲跳转没有定位第二章。");
        await fixture.Editor.CommandAsync("undo");
        if ((await fixture.Editor.SnapshotAsync()).Text != markdown || StatisticsLabel.Text.Length == 0 || ModeLabel.Text != L10n.Text("SourceLabel"))
            throw new IOException("大纲导航或状态栏不正确。");
        fixture.SavedRevision = fixture.Editor.State!.Revision;
        await CloseDocumentAsync(fixture);
        Tabs.SelectedItem = initial.Item;
        await ActivateCurrentAsync();
        if ((await initial.Editor.SnapshotAsync()) != before || outlineItems.Keys.Except(initial.Editor.Headings.Select(item => item.Id)).Any())
            throw new IOException("切换标签丢失原文或保留了其他文档的大纲。");
        await ToggleSidebarAsync();
        if (SidebarPanel.Visibility != Visibility.Collapsed || SidebarColumn.Width.Value != 0) throw new IOException("侧栏不能隐藏。");
        await ChangePreferencesAsync(originalPreferences);
        showingOutline = false;
        RefreshSidebar();
    }

    // 冒烟必须确认编辑器真的显示出来：逻辑通过但组合层不可见时，用户看到的就是空白窗口。
    // 布局尺寸、XamlRoot 与 Loaded 事件就位时机有先后，统一短等；超时仍缺项时输出布局链关键尺寸供定位。
    private async Task AssertEditorVisibleAsync(DocumentTab document, string label)
    {
        var control = document.Editor?.Control ?? throw new IOException($"{label}没有编辑器。");
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(5);
        while (control.ActualHeight < 100 || control.ActualWidth < 100 || control.XamlRoot is null || !control.IsLoaded)
        {
            if (DateTime.UtcNow > deadline)
                throw new IOException(
                    $"{label}的编辑器未进入可视区域：尺寸={control.ActualWidth:0}x{control.ActualHeight:0} " +
                    $"XamlRoot={control.XamlRoot is not null} IsLoaded={control.IsLoaded} " +
                    $"TabView={Tabs.ActualWidth:0}x{Tabs.ActualHeight:0} Root={Root.ActualHeight:0} " +
                    $"父级={control.Parent?.GetType().Name ?? "null"} 选中={ReferenceEquals(Tabs.SelectedItem, document.Item)}");
            await Task.Delay(100);
        }
    }
}
