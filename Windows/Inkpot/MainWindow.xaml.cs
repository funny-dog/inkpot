using System.Diagnostics;
using System.Text.Json.Nodes;
using Inkpot.Bridge;
using Inkpot.Storage;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.Web.WebView2.Core;
using Windows.Storage.Pickers;
using Windows.System;
using Windows.ApplicationModel.DataTransfer;
using static Inkpot.L10n;

namespace Inkpot;

public sealed partial class MainWindow : Window
{
    private readonly Task<CoreWebView2Environment> environment;
    private readonly List<DocumentTab> documents = [];
    private readonly Dictionary<string, MenuFlyoutItem> commandMenus = [];
    private bool busy;
    private bool allowClose;
    private readonly DispatcherTimer recoveryTimer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private readonly SavedWindow? restoredWindow;
    private new DocumentTab? Current => documents.FirstOrDefault(document => ReferenceEquals(document.Item, Tabs.SelectedItem));
    private bool Dark => Root.ActualTheme == ElementTheme.Dark;

    internal MainWindow(string[] arguments, SavedWindow? saved = null)
    {
        restoredWindow = saved;
        InitializeComponent();
        Title = "Inkpot";
        SystemBackdrop = new MicaBackdrop();
        WindowMetrics.Resize(this, 1100, 780);
        try { environment = EditorSession.CreateEnvironmentAsync(); }
        catch (Exception error) { environment = Task.FromException<CoreWebView2Environment>(error); }
        BuildMenus();
        InitializeWorkspace();
        Root.RequestedTheme = App.Preferences.Appearance switch { "light" => ElementTheme.Light, "dark" => ElementTheme.Dark, _ => ElementTheme.Default };
        recoveryTimer.Tick += async (_, _) => await PersistEditsAsync();
        Closed += (_, _) => { recoveryTimer.Stop(); searchCancellation?.Cancel(); printView?.Close(); };
        AppWindow.Closing += WindowClosing;
        Root.ActualThemeChanged += (_, _) => _ = RunAsync(async () =>
        {
            foreach (var document in documents)
                if (document.Editor is { } editor) await editor.SetAppearanceAsync(Dark);
        });
        Root.Loaded += async (_, _) => await RunAsync(async () =>
        {
            int reportIndex = Array.IndexOf(arguments, "--smoke-report");
            if (reportIndex >= 0 && reportIndex + 1 < arguments.Length)
            {
                await RunSmokeAsync(arguments[reportIndex + 1]);
                return;
            }
            var missing = new List<string>();
            if (restoredWindow is { } session)
            {
                RestoreWindowBounds(session);
                foreach (var tab in session.Tabs)
                {
                    if (tab.Path is { } path)
                    {
                        try { await OpenPathAsync(path, false); }
                        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { missing.Add(path); continue; }
                    }
                    else CreateDocument();
                    if (Current is { } document)
                    {
                        document.Folder = tab.Folder is { } folder && Directory.Exists(folder) ? folder : null;
                        document.Sidebar = tab.Sidebar; document.SidebarPage = tab.SidebarPage; document.SidebarWidth = tab.SidebarWidth;
                    }
                }
                if (documents.Count > 0) Tabs.SelectedItem = documents[Math.Clamp(session.Selected, 0, documents.Count - 1)].Item;
            }
            else foreach (string path in arguments.Where(argument => !argument.StartsWith('-'))) await OpenPathAsync(path, false);
            if (documents.Count == 0) CreateDocument();
            await ActivateCurrentAsync();
            if (!App.IsSmoke) recoveryTimer.Start();
            if (missing.Count > 0) await DialogAsync(T("部分会话文件无法恢复", "Some session files could not be restored"), string.Join("\n", missing));
            if (App.Windows.FirstOrDefault() == this && App.Data.LoadDrafts().Count > 0)
            {
                var answer = await DialogAsync(T("发现未保存草稿", "Unsaved drafts found"), T("可以恢复上次未保存的内容。", "You can recover unsaved work from the previous session."), T("恢复草稿…", "Recover drafts…"), close: T("稍后", "Later"));
                if (answer == ContentDialogResult.Primary) await RestoreDraftsAsync();
            }
            if (App.Windows.FirstOrDefault() == this) _ = CheckAutomaticUpdatesAsync();
        });
    }

    private void BuildMenus()
    {
        MenuBarItem Menu(string key)
        {
            var menu = new MenuBarItem { Title = L10n.Text(key) };
            Menus.Items.Add(menu);
            return menu;
        }
        void Item(MenuBarItem menu, string key, Func<Task> action, VirtualKey shortcut = VirtualKey.None,
            VirtualKeyModifiers modifiers = VirtualKeyModifiers.Control, string? command = null)
        {
            var item = new MenuFlyoutItem { Text = L10n.Text(key) };
            item.Click += async (_, _) => await RunAsync(action);
            if (shortcut != VirtualKey.None)
            {
                var accelerator = new KeyboardAccelerator { Key = shortcut, Modifiers = modifiers };
                accelerator.Invoked += async (_, args) => { args.Handled = true; if (item.IsEnabled) await RunAsync(action); };
                item.KeyboardAccelerators.Add(accelerator);
            }
            menu.Items.Add(item);
            if (command is not null) commandMenus[command] = item;
        }
        var file = Menu("File");
        Item(file, "New", () => { App.OpenWindow(); return Task.CompletedTask; }, VirtualKey.N);
        Item(file, T("新建标签页", "New tab"), async () => { CreateDocument(); await ActivateCurrentAsync(); }, VirtualKey.N, VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu);
        Item(file, "Open", OpenPickerAsync, VirtualKey.O);
        Item(file, T("打开文件夹…", "Open folder…"), OpenFolderPickerAsync, VirtualKey.O, VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu);
        AddRecentMenus(file);
        Item(file, "Save", async () => { if (Current is { } document) await SaveAsync(document); }, VirtualKey.S);
        Item(file, "SaveAs", async () => { if (Current is { } document) await SaveAsync(document, saveAs: true); }, VirtualKey.S, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift);
        Item(file, "Close", async () => { if (Current is { } document && await CloseDocumentAsync(document))
            { if (documents.Count == 0) CreateDocument(); await ActivateCurrentAsync(); } }, VirtualKey.W);
        Item(file, T("重命名…", "Rename…"), RenameCurrentAsync);
        Item(file, T("重新载入磁盘版本…", "Reload from disk…"), ReloadCurrentAsync);
        Item(file, T("恢复未保存草稿…", "Recover unsaved drafts…"), RestoreDraftsAsync);
        Item(file, T("导出为 PDF…", "Export PDF…"), () => ExportAsync(true));
        Item(file, T("导出为 HTML…", "Export HTML…"), () => ExportAsync(false));
        Item(file, T("页面设置…", "Page setup…"), PageSetupAsync, VirtualKey.P, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift);
        Item(file, T("打印…", "Print…"), PrintAsync, VirtualKey.P);
        Item(file, T("设置…", "Settings…"), () => { App.ShowSettings(); return Task.CompletedTask; }, (VirtualKey)188);
        Item(file, "Exit", ExitAsync);
        var edit = Menu("Edit");
        void Command(MenuBarItem menu, string key, string command, VirtualKey shortcut = VirtualKey.None,
            VirtualKeyModifiers modifiers = VirtualKeyModifiers.Control) => Item(menu, key, async () =>
            {
                if (Current?.Editor is { } editor) await editor.CommandAsync(command);
            }, shortcut, modifiers, command);
        Command(edit, "Undo", "undo", VirtualKey.Z);
        Command(edit, "Redo", "redo", VirtualKey.Y);
        foreach (var (key, command) in new[] { ("Cut", "cut"), ("Copy", "copy"), ("Paste", "paste") })
            Item(edit, key, async () =>
            {
                if (Current?.Editor is not { } editor) return;
                if (command == "paste")
                {
                    await PasteClipboardAsync(false);
                    return;
                }
                // 浏览器原生命令作用于当前输入焦点，不把剪贴板文本拼进脚本。
                await editor.Control.CoreWebView2.ExecuteScriptAsync($"document.execCommand('{command}')");
            });
        Command(edit, "SelectAll", "selectAll", VirtualKey.A);
        Command(edit, "Find", "find", VirtualKey.F);
        Command(edit, "FindNext", "findNext", VirtualKey.F3, VirtualKeyModifiers.None);
        Command(edit, "FindPrevious", "findPrevious", VirtualKey.F3, VirtualKeyModifiers.Shift);
        Item(edit, T("复制 Markdown", "Copy Markdown"), CopyMarkdownAsync);
        Item(edit, T("粘贴为纯文本", "Paste as plain text"), () => PasteClipboardAsync(true), VirtualKey.V, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift);
        Item(edit, T("在文件夹中查找…", "Find in folder…"), () => ShowSidebarAsync("search"), VirtualKey.F, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift);
        Item(edit, T("输入时检查拼写", "Check spelling while typing"), async () => { App.Preferences.Spellcheck = !App.Preferences.Spellcheck; await App.PreferencesChangedAsync(); });
        var format = Menu("Format");
        Command(format, "Bold", "bold", VirtualKey.B);
        Command(format, "Italic", "italic", VirtualKey.I);
        Command(format, "Strike", "strikethrough", VirtualKey.X, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift);
        Command(format, "InlineCode", "inlineCode", VirtualKey.E);
        Command(format, "Link", "link", VirtualKey.K);
        for (int level = 1; level <= 6; level++) Command(format, $"Heading{level}", $"heading{level}", (VirtualKey)((int)VirtualKey.Number0 + level));
        Command(format, "OrderedList", "orderedList", VirtualKey.Number7);
        Command(format, "BulletList", "bulletList", VirtualKey.Number8);
        Command(format, "TaskList", "taskList", VirtualKey.Number9, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift);
        // WinRT 的 VirtualKey 枚举没有句点成员，190 是主键盘句点键的虚拟键值。
        Command(format, "Quote", "blockquote", (VirtualKey)190, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift);
        Command(format, "CodeBlock", "codeBlock", VirtualKey.C, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift);
        Command(format, "Rule", "horizontalRule", VirtualKey.H, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift);
        Item(format, T("插入本地图片…", "Insert local image…"), InsertImagePickerAsync);
        Command(format, T("插入公式块", "Insert math block"), "insertMathBlock");
        AddTableMenu(format);
        var view = Menu(T("显示", "View"));
        Command(view, "SourceMode", "toggleSourceMode", VirtualKey.M, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift);
        Item(view, T("文件树", "File tree"), () => ToggleSidebarAsync("files"), VirtualKey.E, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift);
        Item(view, T("标题大纲", "Outline"), () => ToggleSidebarAsync("outline"), VirtualKey.O, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift);
        Item(view, T("专注模式", "Focus mode"), () => ToggleModeAsync(false), VirtualKey.F8, VirtualKeyModifiers.None);
        Item(view, T("打字机模式", "Typewriter mode"), () => ToggleModeAsync(true), VirtualKey.F9, VirtualKeyModifiers.None);
        Item(view, T("字体与字号…", "Fonts and sizes…"), () => { App.ShowSettings(pane: 2); return Task.CompletedTask; });
        Item(view, T("恢复默认字体", "Reset fonts"), async () => { App.Preferences.BodyFont = App.Preferences.CodeFont = ""; App.Preferences.BodySize = App.Preferences.CodeSize = 15; await App.PreferencesChangedAsync(); });
        Item(view, T("实际大小", "Actual size"), () => ZoomAsync(0), VirtualKey.Number0);
        Item(view, T("放大", "Zoom in"), () => ZoomAsync(1), VirtualKey.Add);
        Item(view, T("缩小", "Zoom out"), () => ZoomAsync(-1), VirtualKey.Subtract);
        Item(view, T("全屏", "Full screen"), ToggleFullscreenAsync, VirtualKey.F11, VirtualKeyModifiers.None);
        var window = Menu(T("窗口", "Window"));
        Item(window, T("下一个标签页", "Next tab"), () => SelectRelativeTabAsync(1), VirtualKey.Tab);
        Item(window, T("上一个标签页", "Previous tab"), () => SelectRelativeTabAsync(-1), VirtualKey.Tab, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift);
        Item(window, T("将标签页移到新窗口", "Move tab to new window"), DetachTabAsync);
        Item(window, T("合并所有窗口", "Merge all windows"), MergeWindowsAsync);
        Item(window, T("显示／隐藏标签栏", "Show / hide tab bar"), ToggleTabBarAsync);
        Item(window, T("显示所有标签页…", "Show all tabs…"), ShowAllTabsAsync);
        var help = Menu(T("帮助", "Help"));
        Item(help, T("关于 Inkpot", "About Inkpot"), () => { App.ShowSettings(true); return Task.CompletedTask; });
        Item(help, T("检查更新…", "Check for updates…"), () => CheckUpdatesAsync(false));
        Item(help, T("官方网站", "Website"), async () => { await Launcher.LaunchUriAsync(new Uri("https://github.com/funny-dog/inkpot")); });
        Item(help, T("反馈", "Feedback"), async () => { await Launcher.LaunchUriAsync(new Uri("https://github.com/funny-dog/inkpot/issues")); });
        RefreshMenus();
    }

    private DocumentTab CreateDocument(string? path = null, LoadedDocument? loaded = null)
    {
        var document = new DocumentTab(path, loaded?.Text ?? "", loaded?.HasBom ?? false, loaded?.Baseline);
        document.Folder = path is not null && App.Preferences.DocumentFolders.TryGetValue(path, out var folder) && Directory.Exists(folder) ? folder : Current?.Folder;
        document.Sidebar = Current?.Sidebar ?? true;
        document.SidebarPage = Current?.SidebarPage ?? "files";
        document.SidebarWidth = Current?.SidebarWidth ?? 260;
        document.RefreshHeader();
        documents.Add(document);
        Tabs.TabItems.Add(document.Item);
        Tabs.SelectedItem = document.Item;
        return document;
    }

    private async Task OpenPathAsync(string path, bool activate = true)
    {
        path = Path.GetFullPath(path);
        if (!FolderIndex.IsText(path) && !App.Preferences.AllFiles)
            throw new IOException(L10n.Text("UnsupportedFile"));
        var existing = documents.FirstOrDefault(document => string.Equals(document.Path, path, StringComparison.OrdinalIgnoreCase));
        if (existing is not null) Tabs.SelectedItem = existing.Item;
        else CreateDocument(path, await DocumentStorage.ReadAsync(path));
        RememberFile(path);
        if (activate) await ActivateCurrentAsync();
    }

    private async Task OpenPickerAsync()
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        foreach (string extension in new[] { ".md", ".markdown", ".txt" }) picker.FileTypeFilter.Add(extension);
        var files = await picker.PickMultipleFilesAsync();
        foreach (var file in files) await OpenPathAsync(file.Path, activate: false);
        await ActivateCurrentAsync();
    }

    private async Task ActivateCurrentAsync()
    {
        if (Current is not { } document) return;
        if (document.Editor is null)
        {
            var editor = new EditorSession();
            document.Editor = editor;
            document.Item.Content = editor.Control;
            editor.DocumentPath = document.Path;
            editor.Published += state =>
            {
                var owner = App.Windows.FirstOrDefault(window => window.documents.Contains(document));
                document.RefreshHeader(); owner?.RefreshMenus();
                if (state.Changed) { document.LastEdit = DateTime.UtcNow; document.AutosaveBlocked = false; }
                if (owner?.Current == document) owner.RefreshStatus();
            };
            editor.OutlineChanged += _ => { App.Windows.FirstOrDefault(window => window.Current == document)?.RefreshOutline(); };
            editor.LinkRequested += destination => { var owner = App.Windows.FirstOrDefault(window => window.Current == document); if (owner is not null) _ = owner.RunAsync(() => owner.OpenLinkAsync(destination)); };
            editor.PasteImageRequested += () => { var owner = App.Windows.FirstOrDefault(window => window.Current == document); if (owner is not null) _ = owner.RunAsync(() => owner.PasteClipboardAsync(false)); };
            editor.ShortcutRequested += action =>
            {
                var owner = App.Windows.FirstOrDefault(window => window.Current == document);
                if (owner is not null) _ = owner.RunAsync(() => owner.HandleShortcutAsync(action));
            };
            try
            {
                EnsureTabContentVisible(document);
                await editor.InitializeAsync(environment, Dark);
                HookEditorContext(editor);
                await editor.OpenAsync(document.InitialText, Dark, L10n.Language);
                await editor.ApplyPreferencesAsync(App.Preferences);
                if (App.Preferences.DefaultSource) await editor.CommandAsync("toggleSourceMode");
                document.InitialText = "";
            }
            catch
            {
                document.Item.Content = null;
                document.Editor = null;
                editor.Dispose();
                throw;
            }
        }
        else EnsureTabContentVisible(document);
        document.Editor.Control.Focus(FocusState.Programmatic);
        RefreshSidebar(); RefreshStatus();
        RefreshMenus();
        RefreshOutline();
    }

    // WinUI TabView 对程序化选择可能不生成容器内容（microsoft-ui-xaml#3907）：
    // 先强制布局，仍未挂载时按“先取消选择再重选”重新触发，编辑器初始化才能等到 Loaded。
    private void EnsureTabContentVisible(DocumentTab document)
    {
        if (!ReferenceEquals(Tabs.SelectedItem, document.Item)) Tabs.SelectedItem = document.Item;
        Root.UpdateLayout();
        if (document.Editor is { } editor && editor.Control.XamlRoot is null)
        {
            Tabs.SelectedItem = null;
            Tabs.SelectedItem = document.Item;
            Root.UpdateLayout();
        }
    }

    private void RefreshMenus()
    {
        RefreshStatus();
        var state = Current?.Editor?.State;
        foreach (var (name, item) in commandMenus)
            item.IsEnabled = state is not null && !state.Composing && (name switch
            {
                "undo" => state.CanUndo || state.SearchInputFocused,
                "redo" => state.CanRedo || state.SearchInputFocused,
                "find" or "findNext" or "findPrevious" or "toggleSourceMode" => true,
                _ when name.StartsWith("table", StringComparison.Ordinal) => state.TableActions.Contains(name),
                _ => state.EditorFocused,
            });
    }

    private async Task<bool> SaveAsync(DocumentTab document, bool saveAs = false, bool automatic = false)
    {
        var snapshot = document.Editor is { } editor ? await editor.SnapshotAsync() : new EditorSnapshot(document.InitialText, 0);
        string? path = document.Path;
        if (saveAs || path is null)
        {
            var picker = new FileSavePicker { SuggestedFileName = document.Name };
            picker.FileTypeChoices.Add("Markdown", new List<string> { ".md", ".markdown" });
            picker.FileTypeChoices.Add(L10n.Text("TextFile"), new List<string> { ".txt" });
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            var target = await picker.PickSaveFileAsync();
            if (target is null) return false;
            path = target.Path;
        }
        if (App.Windows.SelectMany(window => window.documents).Any(other => other != document && string.Equals(other.Path, path, StringComparison.OrdinalIgnoreCase)))
            throw new IOException(T("该文件已在另一个标签页中打开，请先关闭对应标签页。", "This file is already open in another tab. Close that tab first."));
        var expected = string.Equals(path, document.Path, StringComparison.OrdinalIgnoreCase) ? document.Baseline : null;
        FileBaseline baseline;
        try { baseline = await DocumentStorage.SaveAsync(path, snapshot.Text, document.HasBom, expected); }
        catch (ExternalChangeException)
        {
            if (automatic) { document.AutosaveBlocked = true; RefreshStatus(); return false; }
            var answer = await DialogAsync(L10n.Text("ExternalChange"), path, L10n.Text("Overwrite"), null, L10n.Text("Cancel"));
            if (answer != ContentDialogResult.Primary) return false;
            baseline = await DocumentStorage.SaveAsync(path, snapshot.Text, document.HasBom, expected, overwriteExternal: true);
        }
        document.Path = path;
        document.Baseline = baseline;
        document.SavedRevision = snapshot.Revision;
        document.Recovered = false; document.AutosaveBlocked = false;
        App.Data.RemoveDraft(document.RecoveryId);
        RememberFile(path);
        document.RefreshHeader();
        RefreshStatus();
        if (document.Editor is { } currentEditor)
        {
            currentEditor.DocumentPath = path;
            try { await currentEditor.RequestAsync("refreshImages"); }
            catch (IOException) { SaveLabel.Text = T("文件已保存，图片刷新失败。", "File saved; image refresh failed."); }
        }
        return true;
    }

    private async Task<bool> CloseDocumentAsync(DocumentTab document)
    {
        // 即使状态通知尚未送达，也先取快照；输入法候选或编辑器故障时阻止关闭。
        if (document.Editor is { } editor)
        {
            var snapshot = await editor.SnapshotAsync();
            if (document.Dirty || snapshot.Revision != document.SavedRevision)
            {
                var answer = await DialogAsync(L10n.Text("Unsaved"), document.Name, L10n.Text("Save"), L10n.Text("Discard"), L10n.Text("Cancel"));
                if (answer == ContentDialogResult.None || (answer == ContentDialogResult.Primary && !await SaveAsync(document))) return false;
            }
        }
        else if (document.Recovered)
        {
            var answer = await DialogAsync(L10n.Text("Unsaved"), document.Name, L10n.Text("Save"), L10n.Text("Discard"), L10n.Text("Cancel"));
            if (answer == ContentDialogResult.None || (answer == ContentDialogResult.Primary && !await SaveAsync(document))) return false;
        }
        App.Data.RemoveDraft(document.RecoveryId);
        document.Editor?.Dispose();
        documents.Remove(document);
        Tabs.TabItems.Remove(document.Item);
        return true;
    }

    private Task<ContentDialogResult> DialogAsync(string title, string content, string? primary = null, string? secondary = null, string? close = null)
        => new ContentDialog { XamlRoot = Root.XamlRoot, Style = PreferencesDialog.DialogStyle, RequestedTheme = Root.ActualTheme,
            Title = title, Content = content, PrimaryButtonText = primary ?? "",
            SecondaryButtonText = secondary ?? "", CloseButtonText = close ?? L10n.Text("OK"), DefaultButton = ContentDialogButton.Close }.ShowAsync().AsTask();

    private async Task RunAsync(Func<Task> action)
    {
        await commandGate.WaitAsync();
        if (allowClose) { commandGate.Release(); return; }
        busy = true;
        Menus.IsEnabled = false;
        Tabs.IsEnabled = false;
        try { await action(); }
        catch (Exception error)
        {
            if (error is WebView2RuntimeMissingException)
            {
                var answer = await DialogAsync(L10n.Text("RuntimeMissing"), L10n.Text("RuntimeHelp"), L10n.Text("Download"));
                if (answer == ContentDialogResult.Primary) await Launcher.LaunchUriAsync(new Uri("https://developer.microsoft.com/microsoft-edge/webview2/"));
            }
            else await DialogAsync(L10n.Text("Error"), error.Message);
        }
        finally { busy = false; Menus.IsEnabled = true; Tabs.IsEnabled = true; RefreshMenus(); commandGate.Release(); }
    }

    private async void AddTab(TabView sender, object args) => await RunAsync(async () => { CreateDocument(); await ActivateCurrentAsync(); });
    private async void SelectTab(object sender, SelectionChangedEventArgs args)
    {
        // Commands that select a tab activate it themselves. Re-enqueuing their selection
        // events would activate it again later and steal focus back from the sidebar.
        if (!busy && !allowClose) await RunAsync(ActivateCurrentAsync);
    }
    private async void CloseTab(TabView sender, TabViewTabCloseRequestedEventArgs args) => await RunAsync(async () =>
    {
        var document = documents.FirstOrDefault(document => document.Item == args.Tab);
        if (document is not null && await CloseDocumentAsync(document))
        {
            if (documents.Count == 0) CreateDocument();
            await ActivateCurrentAsync();
        }
    });
    private void WindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (allowClose) return;
        args.Cancel = true;
        _ = RunAsync(CloseAllAsync);
    }

    private async Task CloseAllAsync()
    {
        var session = CaptureSession();
        if (!quitting) App.SaveSession(this, session);
        foreach (var document in documents.ToArray()) if (!await CloseDocumentAsync(document)) return;
        allowClose = true;
        Close();
    }
}
