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

namespace Inkpot;

public sealed partial class MainWindow : Window
{
    private readonly Task<CoreWebView2Environment> environment;
    private readonly List<DocumentTab> documents = [];
    private readonly Dictionary<string, MenuFlyoutItem> commandMenus = [];
    private bool busy;
    private bool allowClose;
    private DocumentTab? Current => documents.FirstOrDefault(document => document.Item == Tabs.SelectedItem);
    private bool Dark => Root.ActualTheme == ElementTheme.Dark;

    public MainWindow(string[] arguments)
    {
        InitializeComponent();
        Title = "Inkpot";
        SystemBackdrop = new MicaBackdrop();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1100, 780));
        InitializeWorkspace(arguments);
        try { environment = EditorSession.CreateEnvironmentAsync(); }
        catch (Exception error) { environment = Task.FromException<CoreWebView2Environment>(error); }
        BuildMenus();
        AppWindow.Closing += WindowClosing;
        Root.ActualThemeChanged += (_, _) => _ = RunAsync(async () =>
        {
            foreach (var document in documents)
                if (document.Editor is { } editor) await editor.SetAppearanceAsync(Dark);
        });
        Root.Loaded += async (_, _) => await RunAsync(async () =>
        {
            if (preferencesError is not null) await DialogAsync(L10n.Text("Error"), preferencesError.Message);
            int reportIndex = Array.IndexOf(arguments, "--smoke-report");
            if (reportIndex >= 0 && reportIndex + 1 < arguments.Length)
            {
                await RunSmokeAsync(arguments[reportIndex + 1]);
                return;
            }
            foreach (string path in arguments.Where(argument => !argument.StartsWith('-')))
                await OpenPathAsync(path, activate: false);
            if (documents.Count == 0) CreateDocument();
            Tabs.SelectedItem = documents[0].Item;
            await ActivateCurrentAsync();
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
        Item(file, "New", async () => { CreateDocument(); await ActivateCurrentAsync(); }, VirtualKey.N);
        Item(file, "Open", OpenPickerAsync, VirtualKey.O);
        Item(file, "OpenFolder", OpenFolderPickerAsync, VirtualKey.O, VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu);
        Item(file, "Save", async () => { if (Current is { } document) await SaveAsync(document); }, VirtualKey.S);
        Item(file, "SaveAs", async () => { if (Current is { } document) await SaveAsync(document, saveAs: true); }, VirtualKey.S, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift);
        Item(file, "Close", async () => { if (Current is { } document && await CloseDocumentAsync(document))
            { if (documents.Count == 0) CreateDocument(); await ActivateCurrentAsync(); } }, VirtualKey.W);
        Item(file, "Exit", CloseAllAsync);
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
                    var clipboard = Clipboard.GetContent();
                    if (clipboard.Contains(StandardDataFormats.Text)) await editor.PasteAsync(await clipboard.GetTextAsync());
                    return;
                }
                // 浏览器原生命令作用于当前输入焦点，不把剪贴板文本拼进脚本。
                await editor.Control.CoreWebView2.ExecuteScriptAsync($"document.execCommand('{command}')");
            });
        Command(edit, "SelectAll", "selectAll", VirtualKey.A);
        Command(edit, "Find", "find", VirtualKey.F);
        Command(edit, "FindNext", "findNext", VirtualKey.F3, VirtualKeyModifiers.None);
        Command(edit, "FindPrevious", "findPrevious", VirtualKey.F3, VirtualKeyModifiers.Shift);
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
        var view = Menu("View");
        Command(view, "SourceMode", "toggleSourceMode", VirtualKey.M, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift);
        void Toggle(string key, Func<Task> action, VirtualKey shortcut, VirtualKeyModifiers modifiers)
        {
            var item = new ToggleMenuFlyoutItem { Text = L10n.Text(key) };
            item.Click += async (_, _) => { await RunAsync(action); RefreshSidebar(); };
            var accelerator = new KeyboardAccelerator { Key = shortcut, Modifiers = modifiers };
            accelerator.Invoked += async (_, args) => { args.Handled = true; await RunAsync(action); };
            item.KeyboardAccelerators.Add(accelerator);
            view.Items.Add(item);
            viewMenus.Add(key, item);
        }
        Toggle("Sidebar", ToggleSidebarAsync, VirtualKey.E, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift);
        Toggle("Outline", ToggleOutlineAsync, VirtualKey.O, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift);
        Toggle("FocusMode", ToggleFocusAsync, VirtualKey.F8, VirtualKeyModifiers.None);
        Toggle("TypewriterMode", ToggleTypewriterAsync, VirtualKey.F9, VirtualKeyModifiers.None);
        Item(view, "Settings", ShowSettingsAsync, (VirtualKey)188);
        RefreshSidebar();
        RefreshMenus();
    }

    private DocumentTab CreateDocument(string? path = null, LoadedDocument? loaded = null)
    {
        var document = new DocumentTab(path, loaded?.Text ?? "", loaded?.HasBom ?? false, loaded?.Baseline);
        document.RefreshHeader();
        documents.Add(document);
        Tabs.TabItems.Add(document.Item);
        Tabs.SelectedItem = document.Item;
        return document;
    }

    private async Task OpenPathAsync(string path, bool activate = true)
    {
        path = Path.GetFullPath(path);
        if (!new[] { ".md", ".markdown", ".txt" }.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase))
            throw new IOException(L10n.Text("UnsupportedFile"));
        var existing = documents.FirstOrDefault(document => string.Equals(document.Path, path, StringComparison.OrdinalIgnoreCase));
        if (existing is not null) Tabs.SelectedItem = existing.Item;
        else CreateDocument(path, await DocumentStorage.ReadAsync(path));
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
            editor.Published += _ => { document.RefreshHeader(); RefreshMenus(); };
            editor.OutlineChanged += () => { if (Current == document) RefreshOutline(); };
            editor.ShortcutRequested += action =>
            {
                if (Current != document) return;
                _ = RunAsync(async () =>
                {
                    switch (action)
                    {
                        case "new": CreateDocument(); await ActivateCurrentAsync(); break;
                        case "open": await OpenPickerAsync(); break;
                        case "save": await SaveAsync(document); break;
                        case "saveAs": await SaveAsync(document, saveAs: true); break;
                        case "openFolder": await OpenFolderPickerAsync(); break;
                        case "settings": await ShowSettingsAsync(); break;
                        case "sidebar": await ToggleSidebarAsync(); break;
                        case "outline": await ToggleOutlineAsync(); break;
                        case "focusMode": await ToggleFocusAsync(); break;
                        case "typewriterMode": await ToggleTypewriterAsync(); break;
                        case "close":
                            if (await CloseDocumentAsync(document))
                            { if (documents.Count == 0) CreateDocument(); await ActivateCurrentAsync(); }
                            break;
                    }
                });
            };
            try
            {
                EnsureTabContentVisible(document);
                await editor.InitializeAsync(environment, Dark);
                await editor.OpenAsync(document.InitialText, Dark, L10n.Language);
                await editor.ApplyPreferencesAsync(preferences, initial: true);
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
                _ => state.EditorFocused,
            });
    }

    private async Task<bool> SaveAsync(DocumentTab document, bool saveAs = false)
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
        var expected = string.Equals(path, document.Path, StringComparison.OrdinalIgnoreCase) ? document.Baseline : null;
        FileBaseline baseline;
        try { baseline = await DocumentStorage.SaveAsync(path, snapshot.Text, document.HasBom, expected); }
        catch (ExternalChangeException)
        {
            var answer = await DialogAsync(L10n.Text("ExternalChange"), path, L10n.Text("Overwrite"), null, L10n.Text("Cancel"));
            if (answer != ContentDialogResult.Primary) return false;
            baseline = await DocumentStorage.SaveAsync(path, snapshot.Text, document.HasBom, expected, overwriteExternal: true);
        }
        document.Path = path;
        document.Baseline = baseline;
        document.SavedRevision = snapshot.Revision;
        document.RefreshHeader();
        return true;
    }

    private async Task<bool> CloseDocumentAsync(DocumentTab document)
    {
        // 即使状态通知尚未送达，也先取快照；输入法候选或编辑器故障时阻止关闭。
        if (document.Editor is { } editor)
        {
            var snapshot = await editor.SnapshotAsync();
            if (snapshot.Revision != document.SavedRevision)
            {
                var answer = await DialogAsync(L10n.Text("Unsaved"), document.Name, L10n.Text("Save"), L10n.Text("Discard"), L10n.Text("Cancel"));
                if (answer == ContentDialogResult.None || (answer == ContentDialogResult.Primary && !await SaveAsync(document))) return false;
            }
        }
        document.Editor?.Dispose();
        documents.Remove(document);
        Tabs.TabItems.Remove(document.Item);
        return true;
    }

    private Task<ContentDialogResult> DialogAsync(string title, string content, string? primary = null, string? secondary = null, string? close = null)
        => new ContentDialog { XamlRoot = Root.XamlRoot, Title = title, Content = content, PrimaryButtonText = primary ?? "",
            SecondaryButtonText = secondary ?? "", CloseButtonText = close ?? L10n.Text("OK"), DefaultButton = ContentDialogButton.Close }.ShowAsync().AsTask();

    private async Task RunAsync(Func<Task> action)
    {
        if (busy) return;
        busy = true;
        Menus.IsEnabled = false;
        Tabs.IsEnabled = false;
        SidebarPanel.IsEnabled = false;
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
        finally { busy = false; Menus.IsEnabled = true; Tabs.IsEnabled = true; SidebarPanel.IsEnabled = true; RefreshMenus(); }
    }

    private async void AddTab(TabView sender, object args) => await RunAsync(async () => { CreateDocument(); await ActivateCurrentAsync(); });
    private async void SelectTab(object sender, SelectionChangedEventArgs args) => await RunAsync(ActivateCurrentAsync);
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
        foreach (var document in documents.ToArray()) if (!await CloseDocumentAsync(document)) return;
        allowClose = true;
        Close();
    }
}
