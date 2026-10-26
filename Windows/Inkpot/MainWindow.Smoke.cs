using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using Inkpot.Bridge;
using Inkpot.Storage;
using Inkpot.Workspace;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using static Inkpot.L10n;

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
            if (SidebarToggle.IsChecked != true || EmptyFiles.Visibility != Visibility.Visible || FilesTree.Visibility != Visibility.Collapsed)
                throw new IOException("初始文件侧栏或空状态未显示。");
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
            await RunParitySmokeAsync(initial, report);
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
                foreach (var window in App.Windows.ToArray()) { window.allowClose = true; window.Close(); }
            }
        }
    }

    private async Task RunParitySmokeAsync(DocumentTab document, JsonObject report)
    {
        var editor = document.Editor!;
        string folder = Path.Combine(App.Data.DirectoryPath, "parity"); Directory.CreateDirectory(folder);
        document.Path = Path.Combine(folder, "中文 文档.md"); editor.DocumentPath = document.Path;
        const string markdown = "# Windows parity\n\n## 子标题\n\n正文 **bold**\n\n$$\nx^2\n$$\n\n```mermaid\nflowchart LR\nA-->B\n```\n\n";
        await editor.OpenAsync(markdown, Dark, L10n.Language);
        App.Preferences.Focus = App.Preferences.Typewriter = true; App.Preferences.Zoom = 1.2; App.Preferences.Indent = 4;
        await editor.ApplyPreferencesAsync(App.Preferences);
        if (await editor.Control.CoreWebView2.ExecuteScriptAsync("document.body.style.zoom==='1.2'") != "true") throw new IOException("缩放偏好未应用。");
        App.Preferences.Focus = App.Preferences.Typewriter = false; App.Preferences.Zoom = 1; App.Preferences.Indent = 2;
        await editor.ApplyPreferencesAsync(App.Preferences);
        await WaitSmokeAsync(() => editor.Headings.Length == 2, "标题大纲未传回宿主。");
        await editor.RequestAsync("navigateHeading", new JsonObject { ["id"] = editor.Headings[1].Id });
        await OpenFolderAsync(folder);
        await File.WriteAllTextAsync(document.Path, markdown);
        document.Baseline = (await DocumentStorage.ReadAsync(document.Path)).Baseline;
        string siblingPath = Path.Combine(folder, "另一份文档.md");
        await File.WriteAllTextAsync(siblingPath, "# 另一份文档\n");
        int originalTabCount = documents.Count;
        await SwitchFileAsync(siblingPath);
        var sibling = Current!;
        if (!documents.Contains(document) || sibling == document || sibling.Folder != folder || documents.Count != originalTabCount + 1)
            throw new IOException("文件树打开文档替换了原标签，或丢失文件夹上下文。");
        await SwitchFileAsync(siblingPath);
        if (Current != sibling || documents.Count != originalTabCount + 1) throw new IOException("文件树重复打开了相同文档。");
        document.SidebarPage = "outline";
        await SwitchFileAsync(document.Path);
        if (Current != document || Current.SidebarPage != "files") throw new IOException("从文件树切换到已有标签时侧栏跳回了大纲。");
        await WaitSmokeAsync(() => FilesTree.SelectedNode?.Content is FolderEntry selected
            && selected.Path == document.Path, "文件树没有高亮当前文档。");
        await SwitchFileAsync(siblingPath);
        await CloseDocumentAsync(sibling);
        Tabs.SelectedItem = document.Item; await ActivateCurrentAsync();
        report["fileTreePreservesOpenTabs"] = true;
        await editor.PasteAsync("待恢复正文");
        await PersistDocumentAsync(document);
        if (App.Data.LoadDrafts().Single().Text != (await editor.SnapshotAsync()).Text) throw new IOException("恢复草稿未保存最新编辑器内容。");
        await File.AppendAllTextAsync(document.Path, "external");
        App.Preferences.Autosave = true;
        await PersistDocumentAsync(document);
        if (!document.AutosaveBlocked || !(await File.ReadAllTextAsync(document.Path)).EndsWith("external")) throw new IOException("自动保存覆盖了外部修改。");
        App.Preferences.Autosave = false; document.AutosaveBlocked = false; App.Data.RemoveDraft(document.RecoveryId);
        report["recoveryDraftAndAutosaveConflict"] = true;
        displayedFolder = null; RefreshSidebar();
        await WaitSmokeAsync(() => FilesTree.RootNodes.Count > 0, "文件树未显示文档。");
        await ShowSidebarAsync("outline");
        if (OutlineList.Items.Count == 0 || StatisticsLabel.Text.Length == 0) throw new IOException("大纲或状态栏为空。");
        Root.UpdateLayout();
        if (EmptyOutline.Visibility != Visibility.Collapsed || OutlineButton.IsChecked != true || FilesButton.IsChecked == true || SidebarPanel.ActualWidth < 180)
            throw new IOException("大纲分段按钮、空状态或侧栏布局不正确。");
        await editor.CommandAsync("toggleSourceMode"); RefreshStatus();
        if (SourceToggle.IsChecked != true || ModeLabel.Text != T("源码模式", "Source mode"))
            throw new IOException("源码工具栏按钮或状态栏未同步。");
        await editor.CommandAsync("toggleSourceMode"); RefreshStatus();
        await ToggleModeAsync(false);
        if (FocusToggle.IsChecked != true) throw new IOException("专注工具栏按钮未同步。");
        await ToggleModeAsync(false);
        await ToggleSidebarAsync("outline");
        if (SidebarPanel.Visibility != Visibility.Collapsed || DividerColumn.Width.Value != 0 || SidebarToggle.IsChecked != false)
            throw new IOException("隐藏侧栏后布局或工具栏状态不正确。");
        await ShowSidebarAsync("outline");
        report["alignedSidebarToolbarAndStatus"] = true;
        report["preferencesOutlineAndStatus"] = true;
        App.Data.SaveSession([CaptureSession()]);
        var restored = App.OpenWindow([], App.Data.LoadSession().Single());
        await WaitSmokeAsync(() => restored.Current?.Editor?.State is not null && !restored.busy, "会话恢复窗口未就绪。");
        await restored.AssertSidebarInteractionAsync();
        report["sidebarFocusAndBackgroundSave"] = true;
        await restored.AssertFileTreeRecyclingAsync();
        report["fileTreeContainerRecycling"] = true;
        await restored.commandGate.WaitAsync();
        try
        {
            if (restored.Current?.Path != document.Path || restored.Current.SidebarPage != "outline") throw new IOException("会话恢复未还原文件或侧栏。");
            await restored.CloseDocumentAsync(restored.Current); restored.allowClose = true; restored.Close();
        }
        finally { restored.commandGate.Release(); }
        report["sessionRestore"] = true;

        byte[] png = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=");
        await EditorSession.ValidateImageAsync(png);
        byte[] bmp = Convert.FromHexString("424D3A0000000000000036000000280000000100000001000000010018000000000004000000130B0000130B00000000000000000000FF000000");
        if ((await EditorSession.NormalizeBitmapAsync(bmp)).Mime != "image/png") throw new IOException("位图未转成可携带的 PNG。");
        string imagePath = await ImageStorage.ImportAsync(png, document.Path, App.Preferences);
        await editor.OpenAsync(markdown + $"![local]({imagePath})\n", Dark, L10n.Language);
        await editor.ApplyPreferencesAsync(App.Preferences);
        string html = await editor.TextAsync("exportHTML", new JsonObject { ["mode"] = "html" });
        if (!html.Contains("data:image/png;base64,") || !html.Contains("<math") || !html.Contains("<svg")) throw new IOException("HTML 导出缺少内嵌图片、公式或图表。");
        report["localImagesMathMermaidAndHtml"] = true;
        var renderer = await RenderExportAsync();
        string pdf = Path.Combine(folder, "smoke.pdf");
        if (!await renderer.CoreWebView2.PrintToPdfAsync(pdf, PrintSettings(renderer.CoreWebView2)) || new FileInfo(pdf).Length < 1000) throw new IOException("真实 PDF 导出失败。");
        Root.Children.Remove(renderer); renderer.Close(); printView = null;
        report["pdfExport"] = true;

        await editor.OpenAsync("", Dark, L10n.Language);
        await editor.CommandAsync("insertTable");
        if (!(await editor.SnapshotAsync()).Text.Contains('|')) throw new IOException("插入表格失败。");
        await editor.CommandAsync("undo"); await editor.CommandAsync("insertMathBlock");
        if (!(await editor.SnapshotAsync()).Text.Contains("$$")) throw new IOException("插入公式块失败。");
        report["tableAndMathCommands"] = true;
        var beforeTransfer = await editor.SnapshotAsync();
        var target = App.OpenWindow();
        if (!target.Root.IsLoaded)
        { var loaded = new TaskCompletionSource(); target.Root.Loaded += (_, _) => loaded.TrySetResult(); await loaded.Task.WaitAsync(TimeSpan.FromSeconds(10)); }
        await target.commandGate.WaitAsync();
        try
        {
            if (target.Current is { } empty) await target.CloseDocumentAsync(empty);
            await MoveTabAsync(document, target);
            await target.AssertEditorVisibleAsync(document, "拆分窗口");
            if (!ReferenceEquals(editor, document.Editor) || (await editor.SnapshotAsync()).Text != beforeTransfer.Text) throw new IOException("拆分窗口丢失了编辑器状态。");
            await editor.CommandAsync("undo");
            if ((await editor.SnapshotAsync()).Text != "") throw new IOException("拆分窗口丢失了撤销历史。");
            await editor.CommandAsync("redo");
            await target.MoveTabAsync(document, this);
            target.allowClose = true; target.Close();
        }
        finally { target.commandGate.Release(); }
        report["windowTransferPreservesUndo"] = true;
        App.ShowSettings(); await Task.Delay(250); App.ValidateSettingsLayout();
        App.ShowSettings(true); await Task.Delay(100); App.ValidateSettingsLayout(); App.CloseSettings(); Activate();
        report["settingsAndAbout"] = true;
        document.Path = null; editor.DocumentPath = null; document.Folder = null; document.Sidebar = false;
        RefreshSidebar();
    }

    private static async Task WaitSmokeAsync(Func<bool> ready, string failure)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!ready()) { if (DateTime.UtcNow > deadline) throw new IOException(failure); await Task.Delay(50); }
    }

    private async Task AssertSidebarInteractionAsync()
    {
        var document = Current!;
        var editor = document.Editor!;
        int disabled = 0;
        var controls = new Control[] { FilesButton, OutlineButton, SearchButton, FolderQuery, FilesTree };
        var callbacks = controls.Select(control => control.RegisterPropertyChangedCallback(Control.IsEnabledProperty,
            (sender, _) => { if (sender is Control { IsEnabled: false }) disabled++; })).ToArray();
        try
        {
            // Exercise the actual click handlers and background-save path, rather than only
            // calling view-state setters while the smoke runner holds the document gate.
            await RunAsync(() =>
            {
                ShowFiles(FilesButton, new RoutedEventArgs());
                ShowSearch(SearchButton, new RoutedEventArgs());
                return Task.CompletedTask;
            });
            if (disabled != 0) throw new IOException("前台文档操作禁用了侧栏，导致后续点击丢失。");
            if (SearchButton.IsChecked != true || SearchPanel.Visibility != Visibility.Visible
                || !ReferenceEquals(FocusManager.GetFocusedElement(Root.XamlRoot), FolderQuery))
                throw new IOException("单击搜索没有立即显示并聚焦输入框。");
            FolderQuery.Text = "Windows";
            for (int index = 0; index < 3; index++) await PersistEditsAsync();
            if (disabled != 0 || !ReferenceEquals(FocusManager.GetFocusedElement(Root.XamlRoot), FolderQuery))
                throw new IOException("空闲草稿检查打断了侧栏输入。");

            await editor.PasteAsync(" 后台草稿测试");
            document.LastEdit = DateTime.UtcNow.AddSeconds(-3);
            FolderQuery.Focus(FocusState.Programmatic);
            await PersistEditsAsync();
            if (document.DraftRevision != editor.State!.Revision || disabled != 0
                || !ReferenceEquals(FocusManager.GetFocusedElement(Root.XamlRoot), FolderQuery))
                throw new IOException("后台草稿保存禁用了侧栏、打断焦点或未保存内容。");
            document.SavedRevision = (await editor.SnapshotAsync()).Revision;
        }
        finally
        {
            for (int index = 0; index < controls.Length; index++)
                controls[index].UnregisterPropertyChangedCallback(Control.IsEnabledProperty, callbacks[index]);
            await ShowSidebarAsync("outline");
        }
    }

    private async Task AssertFileTreeRecyclingAsync()
    {
        var document = Current!;
        string originalFolder = document.Folder!;
        string originalPage = document.SidebarPage;
        string fixture = Path.Combine(App.Data.DirectoryPath, "tree-recycling");
        string nested = Path.Combine(fixture, "子目录");
        Directory.CreateDirectory(nested);
        await File.WriteAllTextAsync(Path.Combine(nested, "子文档.md"), "# 子文档\n");
        for (int index = 0; index < 8; index++)
            await File.WriteAllTextAsync(Path.Combine(fixture, $"文档{index}.md"), $"# 文档{index}\n");
        var mirror = new TreeView { ItemTemplate = FilesTree.ItemTemplate, Width = 220,
            HorizontalAlignment = HorizontalAlignment.Right, CanDragItems = false, CanReorderItems = false };
        try
        {
            await OpenFolderAsync(fixture);
            await WaitSmokeAsync(() => FilesTree.RootNodes.Count == 9, "文件树回收测试目录未加载。");
            if (FilesTree.RootNodes.Any(node => node.Content is not FolderEntry))
                throw new IOException("文件树节点必须存储文件数据，不能存储会被多个容器复用的 UI 控件。");
            var directory = FilesTree.RootNodes.First(node => node.Content is FolderEntry { IsDirectory: true });
            await LoadFolderAsync(nested, directory.Children);
            directory.HasUnrealizedChildren = false;
            Grid.SetRow(mirror, 1); Root.Children.Add(mirror);
            for (int iteration = 0; iteration < 40; iteration++)
            {
                // Render the same entries in fresh containers, including a second tree at
                // the same time. Sharing TextBlock node content fails this scenario.
                mirror.RootNodes.Clear();
                foreach (var node in FilesTree.RootNodes)
                    mirror.RootNodes.Add(new TreeViewNode { Content = node.Content });
                directory.IsExpanded = iteration % 2 == 0;
                await ShowSidebarAsync(iteration % 3 == 0 ? "search" : "outline");
                await ShowSidebarAsync("files");
                Root.UpdateLayout();
                await Task.Delay(20);
                var first = FindVisual<TextBlock>(FilesTree, item => item.Text == "文档0.md");
                var second = FindVisual<TextBlock>(mirror, item => item.Text == "文档0.md");
                if (first is null || second is null || ReferenceEquals(first, second))
                    throw new IOException("文件树容器重建后没有生成独立且可见的文件名控件。");
                // 回收后的容器必须重新绑定右键菜单与提示，否则删除等操作会作用到上一个文件。
                if (FindVisual<TreeViewItem>(FilesTree, item => item.Content is FolderEntry entry
                        && (item.ContextFlyout is null || ToolTipService.GetToolTip(item) as string != entry.Path)) is not null)
                    throw new IOException("文件树容器回收后右键菜单或提示仍指向旧文件。");
            }
        }
        finally
        {
            Root.Children.Remove(mirror);
            await OpenFolderAsync(originalFolder);
            await ShowSidebarAsync(originalPage);
        }
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
