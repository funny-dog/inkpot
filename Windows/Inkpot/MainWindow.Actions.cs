using System.Text.Json.Nodes;
using Inkpot.Bridge;
using Inkpot.Storage;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.Storage.Streams;
using Windows.System;
using static Inkpot.L10n;

namespace Inkpot;

public sealed partial class MainWindow
{
    private MenuFlyoutSubItem? recentFilesMenu, recentFoldersMenu;
    private bool tabBarVisible = true;
    private void AddTableMenu(MenuBarItem format)
    {
        var menu = new MenuFlyoutSubItem { Text = T("表格", "Table") };
        foreach (var (label, command) in TableActions)
        {
            var item = new MenuFlyoutItem { Text = label };
            item.Click += async (_, _) => await RunAsync(async () => { if (Current?.Editor is { } editor) await editor.CommandAsync(command); });
            menu.Items.Add(item); commandMenus[command] = item;
        }
        format.Items.Add(menu);
    }
    private static (string Label, string Command)[] TableActions =>
    [
        (T("插入表格", "Insert table"), "insertTable"), (T("在上方插入行", "Insert row above"), "tableRowAbove"),
        (T("在下方插入行", "Insert row below"), "tableRowBelow"), (T("在左侧插入列", "Insert column before"), "tableColumnBefore"),
        (T("在右侧插入列", "Insert column after"), "tableColumnAfter"), (T("删除当前行", "Delete row"), "tableDeleteRow"),
        (T("删除当前列", "Delete column"), "tableDeleteColumn"), (T("当前列左对齐", "Align column left"), "tableAlignLeft"),
        (T("当前列居中", "Center column"), "tableAlignCenter"), (T("当前列右对齐", "Align column right"), "tableAlignRight"),
    ];
    private static void PutClipboard(string text)
    { var data = new DataPackage(); data.SetText(text); Clipboard.SetContent(data); }
    private Task CopyPathAsync(string? path) { if (path is not null) PutClipboard(path); return Task.CompletedTask; }
    private async Task CopyMarkdownAsync()
    { if (Current?.Editor is { } editor) PutClipboard(await editor.TextAsync("selectedMarkdown")); }
    private async Task PasteClipboardAsync(bool plain)
    {
        if (Current?.Editor is not { } editor) return;
        var clipboard = Clipboard.GetContent();
        if (!plain && clipboard.Contains(StandardDataFormats.Bitmap))
        {
            using var stream = await (await clipboard.GetBitmapAsync()).OpenReadAsync();
            if (stream.Size > ImageStorage.MaximumBytes) throw new IOException(T("图片不能超过 20 MB。", "Images must be smaller than 20 MB."));
            using var reader = new DataReader(stream.GetInputStreamAt(0)); await reader.LoadAsync((uint)stream.Size);
            byte[] bytes = new byte[stream.Size]; reader.ReadBytes(bytes); await InsertImageBytesAsync(bytes); return;
        }
        if (!plain && clipboard.Contains(StandardDataFormats.StorageItems))
        {
            foreach (var item in await clipboard.GetStorageItemsAsync()) if (FolderIndex.IsImage(item.Path)) await InsertImageFileAsync(item.Path);
            return;
        }
        string text = clipboard.Contains(StandardDataFormats.Text) ? await clipboard.GetTextAsync() : "";
        if (!plain && clipboard.Contains(StandardDataFormats.Html))
            await editor.RequestAsync("pasteHTML", new JsonObject { ["html"] = HtmlFormatHelper.GetStaticFragment(await clipboard.GetHtmlFormatAsync()), ["plain"] = text });
        else await editor.PasteAsync(text);
    }
    private async Task InsertImagePickerAsync()
    {
        var picker = new FileOpenPicker();
        foreach (var extension in new[] { ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tif", ".tiff" }) picker.FileTypeFilter.Add(extension);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSingleFileAsync() is { } file) await InsertImageFileAsync(file.Path);
    }
    private async Task InsertImageFileAsync(string path)
    {
        var image = await ImageStorage.ReadAsync(path, null, false); await InsertImageBytesAsync(image.Bytes);
    }
    private async Task InsertImageBytesAsync(byte[] bytes)
    {
        if (Current is not { Editor: { } editor } document || editor.State?.Composing != false) return;
        if (document.Path is null && !await SaveAsync(document)) return;
        bytes = (await EditorSession.NormalizeBitmapAsync(bytes)).Bytes;
        string relative = await ImageStorage.ImportAsync(bytes, document.Path!, App.Preferences);
        await editor.RequestAsync("insertImage", new JsonObject { ["path"] = relative });
    }
    private async Task OpenLinkAsync(string destination)
    {
        if (Current?.Editor is not { } editor) return;
        if (destination.StartsWith('#')) { await editor.RequestAsync("navigateFragment", new JsonObject { ["fragment"] = Uri.UnescapeDataString(destination[1..]) }); return; }
        if (Uri.TryCreate(destination, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https" or "mailto")
        { await Launcher.LaunchUriAsync(uri); return; }
        string fragment = "";
        int hash = destination.IndexOf('#');
        if (hash >= 0) { fragment = Uri.UnescapeDataString(destination[(hash + 1)..]); destination = destination[..hash]; }
        string path = ImageStorage.ResolveLocal(destination, Current.Path);
        if (!FolderIndex.IsText(path)) throw new IOException(T("仅支持网页、邮件、Markdown 和文本文件链接。", "Only web, mail, Markdown and text links are supported."));
        await OpenPathAsync(path);
        if (fragment != "" && Current?.Editor is { } target) await target.RequestAsync("navigateFragment", new JsonObject { ["fragment"] = fragment });
    }
    private Task ToggleModeAsync(bool typewriter)
    {
        if (typewriter) App.Preferences.Typewriter = !App.Preferences.Typewriter; else App.Preferences.Focus = !App.Preferences.Focus;
        return App.PreferencesChangedAsync();
    }
    private Task ZoomAsync(int direction)
    {
        App.Preferences.Zoom = direction == 0 ? 1 : Math.Clamp(Math.Round(App.Preferences.Zoom + direction * .1, 2), .5, 2);
        return App.PreferencesChangedAsync();
    }
    private Task ToggleFullscreenAsync()
    {
        AppWindow.SetPresenter(AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen ? AppWindowPresenterKind.Overlapped : AppWindowPresenterKind.FullScreen);
        return Task.CompletedTask;
    }
    private async Task SelectRelativeTabAsync(int delta)
    {
        if (Tabs.TabItems.Count == 0) return;
        int index = Tabs.TabItems.IndexOf(Tabs.SelectedItem);
        Tabs.SelectedItem = Tabs.TabItems[(index + delta + Tabs.TabItems.Count) % Tabs.TabItems.Count]; await ActivateCurrentAsync();
    }
    private async Task ShowAllTabsAsync()
    {
        var list = new ListView { MaxHeight = 400, SelectionMode = ListViewSelectionMode.Single };
        foreach (var item in Tabs.TabItems.OfType<TabViewItem>()) list.Items.Add(new TextBlock { Text = item.Header?.ToString(), Tag = item });
        list.SelectedIndex = Tabs.TabItems.IndexOf(Tabs.SelectedItem);
        if (await new ContentDialog { XamlRoot = Root.XamlRoot, Title = T("所有标签页", "All tabs"), Content = list, PrimaryButtonText = T("切换", "Switch"), CloseButtonText = Text("Cancel") }.ShowAsync() == ContentDialogResult.Primary
            && list.SelectedItem is TextBlock { Tag: TabViewItem selected }) { Tabs.SelectedItem = selected; await ActivateCurrentAsync(); }
    }
    private Task ToggleTabBarAsync()
    {
        tabBarVisible = !tabBarVisible;
        // Hide only the TabView's header row; the document presenter remains stretched.
        var header = FindVisual<FrameworkElement>(Tabs, element => element.Name == "TabContainerGrid");
        if (header is not null) header.Visibility = tabBarVisible ? Visibility.Visible : Visibility.Collapsed;
        return Task.CompletedTask;
    }
    private static TElement? FindVisual<TElement>(DependencyObject root, Func<TElement, bool> match) where TElement : DependencyObject
    {
        for (int index = 0; index < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(root, index);
            if (child is TElement element && match(element)) return element;
            if (FindVisual(child, match) is { } found) return found;
        }
        return null;
    }
    private async Task HandleShortcutAsync(string action)
    {
        switch (action)
        {
            case "new": App.OpenWindow(); break;
            case "newTab": CreateDocument(); await ActivateCurrentAsync(); break;
            case "open": await OpenPickerAsync(); break;
            case "openFolder": await OpenFolderPickerAsync(); break;
            case "save": if (Current is { } save) await SaveAsync(save); break;
            case "saveAs": if (Current is { } saveAs) await SaveAsync(saveAs, true); break;
            case "close": if (Current is { } close && await CloseDocumentAsync(close)) { if (documents.Count == 0) CreateDocument(); await ActivateCurrentAsync(); } break;
            case "settings": App.ShowSettings(); break;
            case "focus": case "focusMode": await ToggleModeAsync(false); break;
            case "typewriter": case "typewriterMode": await ToggleModeAsync(true); break;
            case "fullscreen": await ToggleFullscreenAsync(); break;
            case "files": await ToggleSidebarAsync("files"); break;
            case "sidebar": await ToggleSidebarAsync(Current?.SidebarPage ?? "files"); break;
            case "outline": await ToggleSidebarAsync("outline"); break;
            case "folderSearch": await ShowSidebarAsync("search"); break;
            case "source": if (Current?.Editor is { } editor) await editor.CommandAsync("toggleSourceMode"); break;
            case "nextTab": await SelectRelativeTabAsync(1); break;
            case "previousTab": await SelectRelativeTabAsync(-1); break;
            case "zoomIn": await ZoomAsync(1); break;
            case "zoomOut": await ZoomAsync(-1); break;
            case "resetZoom": await ZoomAsync(0); break;
            case "print": await PrintAsync(); break;
            case "pageSetup": await PageSetupAsync(); break;
            case "pastePlain": await PasteClipboardAsync(true); break;
            case "findNext": case "findPrevious": if (Current?.Editor is { } search) await search.CommandAsync(action); break;
        }
    }
    private void AddRecentMenus(MenuBarItem file)
    {
        recentFilesMenu = new MenuFlyoutSubItem { Text = T("打开最近使用", "Open recent") };
        recentFoldersMenu = new MenuFlyoutSubItem { Text = T("打开最近的文件夹", "Open recent folder") };
        file.Items.Add(recentFilesMenu); file.Items.Add(recentFoldersMenu); RebuildRecentMenus();
    }
    private void RebuildRecentMenus()
    {
        void Populate(MenuFlyoutSubItem? menu, List<string> paths, bool folders)
        {
            if (menu is null) return;
            menu.Items.Clear();
            foreach (string path in paths.ToArray())
            {
                var item = new MenuFlyoutItem { Text = Path.GetFileName(path) + " — " + Path.GetDirectoryName(path) };
                item.Click += async (_, _) => await RunAsync(async () =>
                {
                    if (folders ? Directory.Exists(path) : File.Exists(path)) { if (folders) await OpenFolderAsync(path); else await OpenPathAsync(path); }
                    else { paths.Remove(path); App.Data.SavePreferences(App.Preferences); RebuildRecentMenus(); await DialogAsync(T("找不到文件或文件夹", "File or folder not found"), path); }
                });
                menu.Items.Add(item);
            }
            var clear = new MenuFlyoutItem { Text = T("清除菜单", "Clear menu"), IsEnabled = paths.Count > 0 };
            clear.Click += (_, _) => { paths.Clear(); App.Data.SavePreferences(App.Preferences); RebuildRecentMenus(); };
            menu.Items.Add(clear);
        }
        Populate(recentFilesMenu, App.Preferences.RecentFiles, false); Populate(recentFoldersMenu, App.Preferences.RecentFolders, true);
    }
    private void MenuAction(MenuFlyout menu, string text, Func<Task> action)
    {
        var item = new MenuFlyoutItem { Text = text };
        item.Click += async (_, _) => await RunAsync(action); menu.Items.Add(item);
    }
    private MenuFlyout EntryMenu(FolderEntry entry)
    {
        var menu = new MenuFlyout();
        if (!entry.IsDirectory)
        {
            MenuAction(menu, T("打开", "Open"), () => SwitchFileAsync(entry.Path));
            MenuAction(menu, T("在新标签页中打开", "Open in new tab"), () => OpenPathAsync(entry.Path));
            MenuAction(menu, T("在新窗口中打开", "Open in new window"), () => { App.OpenWindow([entry.Path]); return Task.CompletedTask; });
            MenuAction(menu, T("创建副本", "Duplicate"), () => DuplicateAsync(entry.Path));
        }
        string folder = entry.IsDirectory ? entry.Path : Path.GetDirectoryName(entry.Path)!;
        MenuAction(menu, T("新建文件…", "New file…"), () => CreateEntryAsync(folder, false));
        MenuAction(menu, T("新建文件夹…", "New folder…"), () => CreateEntryAsync(folder, true));
        MenuAction(menu, T("重命名…", "Rename…"), () => RenameEntryAsync(entry.Path));
        MenuAction(menu, T("移到回收站…", "Move to Recycle Bin…"), () => TrashEntryAsync(entry.Path));
        MenuAction(menu, T("复制路径", "Copy path"), () => CopyPathAsync(entry.Path));
        MenuAction(menu, T("在资源管理器中显示", "Show in Explorer"), async () =>
        {
            if (entry.IsDirectory) await Launcher.LaunchFolderPathAsync(entry.Path);
            else if (await StorageFile.GetFileFromPathAsync(entry.Path) is { } file)
            { var options = new FolderLauncherOptions(); options.ItemsToSelect.Add(file); await Launcher.LaunchFolderPathAsync(Path.GetDirectoryName(entry.Path)!, options); }
        });
        return menu;
    }
    private async Task<string?> NameDialogAsync(string title, string initial)
    {
        var input = new TextBox { Text = initial, MinWidth = 300 }; input.SelectAll();
        var answer = await new ContentDialog { XamlRoot = Root.XamlRoot, Title = title, Content = input, PrimaryButtonText = Text("OK"), CloseButtonText = Text("Cancel"), DefaultButton = ContentDialogButton.Primary }.ShowAsync();
        return answer == ContentDialogResult.Primary ? input.Text : null;
    }
    private async Task CreateEntryAsync(string? folder, bool directory)
    {
        if (folder is null) { await OpenFolderPickerAsync(); folder = Current?.Folder; }
        if (folder is null || await NameDialogAsync(directory ? T("新建文件夹", "New folder") : T("新建文件", "New file"), directory ? T("新文件夹", "New folder") : "Untitled.md") is not { } name) return;
        string path = FolderIndex.ChildPath(folder, name);
        if (File.Exists(path) || Directory.Exists(path)) throw new IOException(T("同名文件或文件夹已存在。", "A file or folder with that name already exists."));
        if (directory) Directory.CreateDirectory(path);
        else { using (File.Open(path, FileMode.CreateNew, FileAccess.Write)) { } await OpenPathAsync(path); }
        RefreshFileTrees();
    }
    private async Task DuplicateAsync(string path)
    {
        string folder = Path.GetDirectoryName(path)!;
        for (int index = 1; ; index++)
        {
            string target = Path.Combine(folder, Path.GetFileNameWithoutExtension(path) + T(" 副本", " copy") + (index == 1 ? "" : $" {index}") + Path.GetExtension(path));
            if (File.Exists(target)) continue;
            File.Copy(path, target, false); RefreshFileTrees(); await OpenPathAsync(target); return;
        }
    }
    private Task RenameCurrentAsync() => Current?.Path is { } path ? RenameEntryAsync(path) : Task.CompletedTask;
    private async Task RenameEntryAsync(string path)
    {
        if (!FolderIndex.IsSafeEntry(path)) throw new IOException("Cannot rename a link.");
        if (await NameDialogAsync(T("重命名", "Rename"), Path.GetFileName(path)) is not { } name) return;
        string target = FolderIndex.ChildPath(Path.GetDirectoryName(path)!, name);
        if (path == target) return;
        if (Directory.Exists(path)) Directory.Move(path, target); else File.Move(path, target, false);
        foreach (var window in App.Windows)
            foreach (var document in window.documents)
            {
                if (document.Path is { } original && InPath(original, path))
                {
                    document.Path = Relocate(original, path, target);
                    if (document.Editor is { } editor) { editor.DocumentPath = document.Path; await editor.RequestAsync("refreshImages"); }
                    document.RefreshHeader();
                }
                if (document.Folder is { } folder && InPath(folder, path)) document.Folder = Relocate(folder, path, target);
            }
        foreach (var paths in new[] { App.Preferences.RecentFiles, App.Preferences.RecentFolders })
            for (int index = 0; index < paths.Count; index++) if (InPath(paths[index], path)) paths[index] = Relocate(paths[index], path, target);
        App.Preferences.DocumentFolders = App.Preferences.DocumentFolders.ToDictionary(pair => InPath(pair.Key, path) ? Relocate(pair.Key, path, target) : pair.Key,
            pair => InPath(pair.Value, path) ? Relocate(pair.Value, path, target) : pair.Value, StringComparer.OrdinalIgnoreCase);
        if (App.Preferences.ImageFolder is { } images && InPath(images, path)) App.Preferences.ImageFolder = Relocate(images, path, target);
        App.Data.SavePreferences(App.Preferences); RefreshFileTrees(); RefreshStatus();
    }
    private static bool InPath(string candidate, string parent) => string.Equals(candidate, parent, StringComparison.OrdinalIgnoreCase) || candidate.StartsWith(parent.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    private static string Relocate(string candidate, string parent, string destination) => string.Equals(candidate, parent, StringComparison.OrdinalIgnoreCase) ? destination : Path.Combine(destination, Path.GetRelativePath(parent, candidate));
    private async Task TrashEntryAsync(string path)
    {
        if (!FolderIndex.IsSafeEntry(path)) throw new IOException("Cannot delete a link.");
        if (await DialogAsync(T("移到回收站？", "Move to Recycle Bin?"), path, T("移到回收站", "Move to Recycle Bin"), close: Text("Cancel")) != ContentDialogResult.Primary) return;
        foreach (var window in App.Windows.ToArray())
            foreach (var document in window.documents.Where(document => document.Path is { } file && InPath(file, path)).ToArray())
                if (!await window.CloseDocumentAsync(document)) return;
        if (Directory.Exists(path)) Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(path, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
        else Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(path, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
        foreach (var window in App.Windows) { if (window.documents.Count == 0) window.CreateDocument(); await window.ActivateCurrentAsync(); }
        RefreshFileTrees();
    }
    private static void RefreshFileTrees()
    { foreach (var window in App.Windows) { window.displayedFolder = null; window.RefreshSidebar(); window.RebuildRecentMenus(); } }
    private async Task ReloadCurrentAsync()
    {
        if (Current is not { Path: { } path, Editor: { } editor } document) return;
        if (await DialogAsync(T("重新载入磁盘版本？", "Reload from disk?"), T("当前编辑内容将被磁盘内容替换。", "The disk version will replace the current editor contents."), T("重新载入", "Reload"), close: Text("Cancel")) != ContentDialogResult.Primary) return;
        var loaded = await DocumentStorage.ReadAsync(path);
        bool source = editor.State?.SourceMode == true;
        await editor.OpenAsync(loaded.Text, Dark, Language); await editor.ApplyPreferencesAsync(App.Preferences);
        if (source) await editor.CommandAsync("toggleSourceMode");
        document.Baseline = loaded.Baseline; document.HasBom = loaded.HasBom; document.SavedRevision = 0; document.Recovered = false; document.DraftRevision = -1;
        App.Data.RemoveDraft(document.RecoveryId); document.RefreshHeader(); RefreshStatus();
    }
    private async Task DetachTabAsync()
    {
        if (Current is not { } document) return;
        var target = App.OpenWindow();
        if (!target.Root.IsLoaded)
        { var loaded = new TaskCompletionSource(); target.Root.Loaded += (_, _) => loaded.TrySetResult(); await loaded.Task.WaitAsync(TimeSpan.FromSeconds(10)); }
        await target.RunAsync(async () =>
        {
            if (target.documents.Count == 1 && target.Current is { Path: null, Folder: null, Dirty: false } empty) await target.CloseDocumentAsync(empty);
            await MoveTabAsync(document, target);
        });
        if (documents.Count == 0) CreateDocument(); await ActivateCurrentAsync();
    }
    private async Task MoveTabAsync(DocumentTab document, MainWindow target)
    {
        // Do not detach a composition session before the user confirms the candidate text.
        if (document.Editor is { } currentEditor) await currentEditor.SnapshotAsync();
        var originalItem = document.Item;
        int originalIndex = Tabs.TabItems.IndexOf(originalItem);
        // Move the existing WebView, preserving selection and undo history.
        document.Item.Content = null; Tabs.TabItems.Remove(document.Item); documents.Remove(document);
        Root.UpdateLayout();
        await Task.Delay(50);
        // TabViewItem retains a template/presenter bound to its original XamlRoot. Give the destination
        // a fresh container while retaining the editor itself and its history.
        try
        {
            document.Item = new TabViewItem { IsClosable = true };
            if (document.Editor is { } editor) document.Item.Content = editor.Control;
            document.RefreshHeader();
            target.documents.Add(document); target.Tabs.TabItems.Add(document.Item); target.Tabs.SelectedItem = document.Item;
            await target.ActivateCurrentAsync();
            await target.AssertEditorVisibleAsync(document, T("移动标签页", "Move tab"));
        }
        catch
        {
            document.Item.Content = null; target.Tabs.TabItems.Remove(document.Item); target.documents.Remove(document); target.Root.UpdateLayout();
            await Task.Delay(50);
            document.Item = originalItem; document.Item.Content = document.Editor?.Control;
            documents.Add(document); Tabs.TabItems.Insert(Math.Clamp(originalIndex, 0, Tabs.TabItems.Count), originalItem); Tabs.SelectedItem = originalItem;
            await ActivateCurrentAsync();
            throw;
        }
    }
    private async Task MergeWindowsAsync()
    {
        foreach (var window in App.Windows.Where(window => window != this).ToArray())
        {
            foreach (var document in window.documents.ToArray()) await window.MoveTabAsync(document, this);
            window.allowClose = true; window.Close();
        }
    }
    private async Task CheckAutomaticUpdatesAsync()
    {
        if (App.IsSmoke || !App.Preferences.AutomaticUpdates || DateTime.UtcNow - App.Preferences.LastUpdateCheck < TimeSpan.FromDays(1)) return;
        App.Preferences.LastUpdateCheck = DateTime.UtcNow; App.Data.SavePreferences(App.Preferences);
        try { await CheckUpdatesAsync(true); } catch { /* Manual check presents actionable errors; background checks stay quiet. */ }
    }
    private async Task CheckUpdatesAsync(bool automatic)
    {
        var update = await UpdateService.CheckAsync(App.Version, Path.Combine(App.Data.DirectoryPath, "Updates"), App.Preferences.AutomaticUpdates);
        if (automatic)
        { if (update is not null) SaveLabel.Text = T("新版本可用：", "Update available: ") + update.Tag + (update.DownloadedPath is null ? "" : T("（已下载）", " (downloaded)")); return; }
        var answer = await DialogAsync(update is null ? T("已是最新版本", "You're up to date") : T("发现新版本 ", "New version ") + update.Tag,
            update?.DownloadedPath ?? T("如有新版本，可前往发布页下载安装。", "Visit the releases page to download a new version."),
            update?.DownloadedPath is null ? T("前往下载页", "Open downloads") : T("显示下载包", "Show download"), close: Text("Close"));
        if (answer == ContentDialogResult.Primary)
        { if (update?.DownloadedPath is { } path) await Launcher.LaunchFolderPathAsync(Path.GetDirectoryName(path)!); else await Launcher.LaunchUriAsync(new Uri(UpdateService.DownloadPage)); }
    }
    private void HookEditorContext(EditorSession editor)
    {
        editor.Control.CoreWebView2.ContextMenuRequested += (sender, args) =>
        {
            var owner = App.Windows.FirstOrDefault(window => window.Current?.Editor == editor);
            if (owner is null) return;
            var environment = editor.Control.CoreWebView2.Environment;
            var state = editor.State;
            // Keep native spelling suggestions, but replace browser navigation/reload with document commands.
            var spelling = args.MenuItems.Where(item => item.Name.Contains("spell", StringComparison.OrdinalIgnoreCase)
                || item.Name.Contains("dictionary", StringComparison.OrdinalIgnoreCase)).ToArray();
            args.MenuItems.Clear(); foreach (var item in spelling) args.MenuItems.Add(item);
            CoreWebView2ContextMenuItem Action(string label, Func<Task> action, bool enabled = true)
            {
                var item = environment.CreateContextMenuItem(label, null, CoreWebView2ContextMenuItemKind.Command);
                item.IsEnabled = enabled && state?.Composing == false;
                item.CustomItemSelected += (itemSender, eventArgs) => _ = owner.RunAsync(action);
                return item;
            }
            CoreWebView2ContextMenuItem Command(string label, string command) => Action(label, () => editor.CommandAsync(command),
                command.StartsWith("table", StringComparison.Ordinal) ? state?.TableActions.Contains(command) == true : state?.EditorFocused == true);
            CoreWebView2ContextMenuItem Submenu(string title, IEnumerable<(string Label, string Command)> commands)
            {
                var item = environment.CreateContextMenuItem(title, null, CoreWebView2ContextMenuItemKind.Submenu);
                foreach (var (label, command) in commands) item.Children.Add(Command(label, command));
                return item;
            }
            args.MenuItems.Add(Action(Text("Undo"), () => editor.CommandAsync("undo"), state?.CanUndo == true));
            args.MenuItems.Add(Action(Text("Redo"), () => editor.CommandAsync("redo"), state?.CanRedo == true));
            args.MenuItems.Add(Action(Text("Cut"), async () => { await editor.Control.CoreWebView2.ExecuteScriptAsync("document.execCommand('cut')"); }));
            args.MenuItems.Add(Action(Text("Copy"), async () => { await editor.Control.CoreWebView2.ExecuteScriptAsync("document.execCommand('copy')"); }));
            args.MenuItems.Add(Action(Text("Paste"), () => owner.PasteClipboardAsync(false)));
            var clipboard = environment.CreateContextMenuItem(T("复制／粘贴为…", "Copy / paste as…"), null, CoreWebView2ContextMenuItemKind.Submenu);
            clipboard.Children.Add(Action(T("复制 Markdown", "Copy Markdown"), owner.CopyMarkdownAsync));
            clipboard.Children.Add(Action(T("粘贴为纯文本", "Paste as plain text"), () => owner.PasteClipboardAsync(true)));
            args.MenuItems.Add(clipboard);
            var paragraph = Enumerable.Range(1, 6).Select(level => (Text($"Heading{level}"), $"heading{level}")).ToList();
            paragraph.AddRange([(Text("OrderedList"), "orderedList"), (Text("BulletList"), "bulletList"), (Text("TaskList"), "taskList"),
                (Text("Quote"), "blockquote"), (Text("CodeBlock"), "codeBlock"), (T("公式块", "Math block"), "insertMathBlock")]);
            args.MenuItems.Add(Submenu(T("段落", "Paragraph"), paragraph));
            args.MenuItems.Add(Submenu(Text("Format"), [(Text("Bold"), "bold"), (Text("Italic"), "italic"), (Text("Strike"), "strikethrough"), (Text("InlineCode"), "inlineCode"), (Text("Link"), "link")]));
            var insert = Submenu(T("插入", "Insert"), [(T("表格", "Table"), "insertTable"), (Text("Rule"), "horizontalRule")]);
            insert.Children.Insert(0, Action(T("本地图片…", "Local image…"), owner.InsertImagePickerAsync, state?.EditorFocused == true)); args.MenuItems.Add(insert);
            if (state?.TableActions.Length > 0) args.MenuItems.Add(Submenu(T("表格", "Table"), TableActions.Where(action => state.TableActions.Contains(action.Command))));
        };
    }
}
