using System.Text.Json.Nodes;
using Inkpot.Bridge;
using Inkpot.Storage;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Text;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.System;
using static Inkpot.L10n;

namespace Inkpot;

public sealed partial class MainWindow
{
    private string? displayedFolder;
    private (bool All, bool Hidden) displayedFilter;
    private CancellationTokenSource? searchCancellation;
    private EditorSession? outlineOwner;
    private Heading[]? displayedHeadings;
    private readonly Dictionary<int, ListViewItem> headingItems = [];
    private bool persistenceBusy;
    private readonly SemaphoreSlim commandGate = new(1, 1);
    private static bool quitting;

    private void InitializeWorkspace()
    {
        FilesButton.Content = T("文件", "Files"); OutlineButton.Content = T("大纲", "Outline"); SearchButton.Content = T("搜索", "Search");
        EmptyOpenFolderButton.Content = Text("OpenFolder");
        EmptyFilesTitle.Text = Text("NoFolder"); EmptyFilesMessage.Text = Text("NoFolderMessage");
        EmptyOutlineTitle.Text = Text("NoHeadings"); EmptyOutlineMessage.Text = Text("NoHeadingsMessage");
        foreach (var (control, name) in new (FrameworkElement, string)[] {
            (FilesTree, "Files"), (OutlineList, "Outline"), (SearchButton, "Search"),
            (SidebarSwitcher, "SidebarContent"), (SidebarDivider, "ResizeSidebar"),
            (ModeLabel, "EditingMode"), (SaveLabel, "SaveStatus"), (StatisticsLabel, "WordCount") })
            AutomationProperties.SetName(control, Text(name));
        foreach (var (button, name, tip) in new (FrameworkElement, string, string)[] {
            (OpenFolderButton, "OpenFolder", "ChangeFolderTip"), (SidebarToggle, "Sidebar", "SidebarTip"),
            (FocusToggle, "FocusMode", "FocusTip"), (SourceToggle, "SourceMode", "SourceTip") })
        { AutomationProperties.SetName(button, Text(name)); ToolTipService.SetToolTip(button, Text(tip)); }
        RefreshSidebar();
        FolderQuery.PlaceholderText = T("在文件夹中查找", "Find in folder");
        Root.AllowDrop = true;
        Root.DragOver += (_, args) => { if (args.DataView.Contains(StandardDataFormats.StorageItems)) { args.AcceptedOperation = DataPackageOperation.Copy; args.Handled = true; } };
        Root.Drop += async (_, args) =>
        {
            args.Handled = true;
            await RunAsync(async () =>
            {
                foreach (var item in await args.DataView.GetStorageItemsAsync())
                {
                    if (!FolderIndex.IsSafeEntry(item.Path)) continue;
                    if (item is StorageFolder) await OpenFolderAsync(item.Path);
                    else if (FolderIndex.IsImage(item.Path)) await InsertImageFileAsync(item.Path);
                    else if (FolderIndex.IsText(item.Path) || App.Preferences.AllFiles) await OpenPathAsync(item.Path);
                }
            });
        };
        var rootMenu = new MenuFlyout();
        MenuAction(rootMenu, T("打开文件夹…", "Open folder…"), OpenFolderPickerAsync);
        MenuAction(rootMenu, T("新建文件…", "New file…"), () => CreateEntryAsync(Current?.Folder, false));
        MenuAction(rootMenu, T("新建文件夹…", "New folder…"), () => CreateEntryAsync(Current?.Folder, true));
        MenuAction(rootMenu, T("复制文件夹路径", "Copy folder path"), () => CopyPathAsync(Current?.Folder));
        MenuAction(rootMenu, T("在资源管理器中显示", "Show in Explorer"), async () => { if (Current?.Folder is { } folder) await Launcher.LaunchFolderPathAsync(folder); });
        FilesTree.ContextFlyout = rootMenu;
    }

    internal async Task ApplyPreferencesAsync()
    {
        Root.RequestedTheme = App.Preferences.Appearance switch { "light" => ElementTheme.Light, "dark" => ElementTheme.Dark, _ => ElementTheme.Default };
        foreach (var document in documents)
            if (document.Editor is { } editor)
            { await editor.SetAppearanceAsync(Dark); await editor.ApplyPreferencesAsync(App.Preferences); }
        RefreshSidebar(); RefreshStatus();
    }
    private void RememberFile(string path)
    {
        if (App.IsSmoke) return;
        Preferences.Remember(App.Preferences.RecentFiles, path);
        if (Current?.Folder is { } folder) App.Preferences.DocumentFolders[path] = folder;
        App.Data.SavePreferences(App.Preferences);
        foreach (var window in App.Windows) window.RebuildRecentMenus();
    }

    private async Task OpenFolderPickerAsync()
    {
        var picker = new FolderPicker(); picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSingleFolderAsync() is { } folder) await OpenFolderAsync(folder.Path);
    }
    private Task OpenFolderAsync(string path)
    {
        if (!Directory.Exists(path) || !FolderIndex.IsSafeEntry(path)) throw new IOException(T("文件夹无法打开。", "Cannot open this folder."));
        if (Current is null) CreateDocument();
        Current!.Folder = Path.GetFullPath(path); Current.Sidebar = true; Current.SidebarPage = "files";
        Preferences.Remember(App.Preferences.RecentFolders, path);
        if (Current.Path is { } file) App.Preferences.DocumentFolders[file] = path;
        App.Data.SavePreferences(App.Preferences); displayedFolder = null; RefreshSidebar();
        foreach (var window in App.Windows) window.RebuildRecentMenus();
        return Task.CompletedTask;
    }
    private Task ShowSidebarAsync(string page)
    {
        if (Current is { } document) { document.Sidebar = true; document.SidebarPage = page; RefreshSidebar(); if (page == "search") FolderQuery.Focus(FocusState.Programmatic); }
        return Task.CompletedTask;
    }
    private Task ToggleSidebarAsync(string page)
    {
        if (Current is { } document) { document.Sidebar = !document.Sidebar || document.SidebarPage != page; document.SidebarPage = page; RefreshSidebar(); }
        return Task.CompletedTask;
    }
    // Switching panes only changes view state. Do not disable the clicked button or the search
    // input via RunAsync: doing so cancels pointer capture and prevents focus from being set.
    private void ShowFiles(object sender, RoutedEventArgs args) => _ = ShowSidebarAsync("files");
    private void ShowOutline(object sender, RoutedEventArgs args) => _ = ShowSidebarAsync("outline");
    private void ShowSearch(object sender, RoutedEventArgs args) => _ = ShowSidebarAsync("search");
    private void ResizeSidebar(object sender, DragDeltaEventArgs args)
    {
        if (Current is not { } document || !document.Sidebar) return;
        document.SidebarWidth = Math.Clamp(document.SidebarWidth + args.HorizontalChange, 200, Math.Max(200, Root.ActualWidth - 300));
        SidebarColumn.Width = new GridLength(document.SidebarWidth);
    }
    private void RefreshSidebar()
    {
        var document = Current;
        bool visible = document?.Sidebar == true;
        SidebarColumn.Width = new GridLength(visible ? Math.Clamp(document!.SidebarWidth, 200, Math.Max(200, Root.ActualWidth - 300)) : 0);
        SidebarPanel.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        SidebarDivider.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        DividerColumn.Width = new GridLength(visible ? 4 : 0);
        SidebarToggle.IsChecked = visible;
        FilesButton.IsChecked = document?.SidebarPage == "files";
        OutlineButton.IsChecked = document?.SidebarPage == "outline";
        SearchButton.IsChecked = document?.SidebarPage == "search";
        bool hasFolder = document?.Folder is not null;
        FolderHeader.Visibility = FilesTree.Visibility = hasFolder ? Visibility.Visible : Visibility.Collapsed;
        EmptyFiles.Visibility = hasFolder ? Visibility.Collapsed : Visibility.Visible;
        FilesPanel.Visibility = document?.SidebarPage == "files" ? Visibility.Visible : Visibility.Collapsed;
        OutlinePanel.Visibility = document?.SidebarPage == "outline" ? Visibility.Visible : Visibility.Collapsed;
        SearchPanel.Visibility = document?.SidebarPage == "search" ? Visibility.Visible : Visibility.Collapsed;
        if (displayedFolder != document?.Folder || displayedFilter != (App.Preferences.AllFiles, App.Preferences.HiddenFiles))
        {
            searchCancellation?.Cancel(); SearchResults.Items.Clear();
            displayedFolder = document?.Folder; displayedFilter = (App.Preferences.AllFiles, App.Preferences.HiddenFiles);
            FilesTree.RootNodes.Clear();
            FolderLabel.Text = displayedFolder is null ? T("请打开文件夹", "Open a folder to browse files") : Path.GetFileName(displayedFolder);
            ToolTipService.SetToolTip(FolderLabel, displayedFolder);
            if (displayedFolder is { } folder) _ = LoadFolderAsync(folder, FilesTree.RootNodes);
            if (document?.SidebarPage == "search") StartFolderSearch();
        }
        SelectCurrentFile();
        RefreshOutline();
        if (visible && document?.SidebarPage == "search") SearchStatus.Text = document.Folder is null ? T("请先打开文件夹。", "Open a folder first.") : SearchStatus.Text;
    }
    private async Task LoadFolderAsync(string folder, IList<TreeViewNode> nodes)
    {
        string? root = displayedFolder;
        var filter = displayedFilter;
        try
        {
            var entries = await Task.Run(() => FolderIndex.Children(folder, filter.All, filter.Hidden));
            if (root != displayedFolder || filter != displayedFilter) return;
            nodes.Clear();
            foreach (var entry in entries)
            {
                // TreeView recycles containers while expanding/collapsing. Store data here;
                // a UIElement reused as node content can still belong to the old container.
                nodes.Add(new TreeViewNode { Content = entry, HasUnrealizedChildren = entry.IsDirectory });
            }
            SelectCurrentFile();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { FolderLabel.Text = error.Message; }
    }
    // Recycled containers are rebound without raising Loaded again, so refresh the per-entry
    // menu on every data change; otherwise a context action could target the previous file.
    private void InitializeFileItem(FrameworkElement sender, DataContextChangedEventArgs args)
    {
        if (sender is not TreeViewItem item) return;
        if (args.NewValue is not TreeViewNode { Content: FolderEntry entry })
        {
            item.ContextFlyout = null;
            ToolTipService.SetToolTip(item, null);
            return;
        }
        item.ContextFlyout = EntryMenu(entry);
        ToolTipService.SetToolTip(item, entry.Path);
        AutomationProperties.SetName(item, entry.Name);
    }
    private async void ExpandFolder(TreeView sender, TreeViewExpandingEventArgs args)
    {
        if (!args.Node.HasUnrealizedChildren || args.Node.Content is not FolderEntry entry) return;
        await LoadFolderAsync(entry.Path, args.Node.Children); args.Node.HasUnrealizedChildren = false;
    }
    private async void InvokeFile(TreeView sender, TreeViewItemInvokedEventArgs args)
    {
        if (args.InvokedItem is not TreeViewNode { Content: FolderEntry entry } node) return;
        if (entry.IsDirectory) { node.IsExpanded = !node.IsExpanded; return; }
        await RunAsync(() => SwitchFileAsync(entry.Path));
    }
    private async Task SwitchFileAsync(string path)
    {
        var previous = Current;
        await OpenPathAsync(path, activate: false);
        // Navigation from the sidebar keeps the pane the user clicked in, including when
        // the destination already has a tab with a different saved workspace.
        if (previous is not null && Current is { } document)
        {
            document.Folder = previous.Folder; document.Sidebar = previous.Sidebar;
            document.SidebarPage = previous.SidebarPage; document.SidebarWidth = previous.SidebarWidth;
        }
        await ActivateCurrentAsync();
    }
    private void SelectCurrentFile()
    {
        TreeViewNode? Find(IEnumerable<TreeViewNode> nodes)
        {
            foreach (var node in nodes)
            {
                if (node.Content is FolderEntry { IsDirectory: false } entry
                    && string.Equals(entry.Path, Current?.Path, StringComparison.OrdinalIgnoreCase)) return node;
                if (Find(node.Children) is { } child) return child;
            }
            return null;
        }
        FilesTree.SelectedNode = Find(FilesTree.RootNodes);
    }
    private void RefreshOutline()
    {
        var editor = Current?.Editor;
        if (outlineOwner != editor || !ReferenceEquals(displayedHeadings, editor?.Headings))
        {
            outlineOwner = editor; displayedHeadings = editor?.Headings; OutlineList.Items.Clear(); headingItems.Clear();
            foreach (var heading in editor?.Headings ?? [])
            {
                var item = new ListViewItem { Tag = heading.Id, Content = new TextBlock {
                    Text = heading.Title, Margin = new Thickness((heading.Level - 1) * 14, 4, 0, 4), TextTrimming = TextTrimming.CharacterEllipsis,
                    FontWeight = heading.Level == 1 ? FontWeights.SemiBold : FontWeights.Normal, Opacity = heading.Level >= 3 ? .72 : 1 } };
                ToolTipService.SetToolTip(item, $"H{heading.Level} · {heading.Title}");
                AutomationProperties.SetName(item, heading.Title);
                OutlineList.Items.Add(item); headingItems[heading.Id] = item;
            }
        }
        EmptyOutline.Visibility = editor?.Headings.Length > 0 ? Visibility.Collapsed : Visibility.Visible;
        OutlineList.SelectedItem = editor?.ActiveHeading is int id ? headingItems.GetValueOrDefault(id) : null;
    }
    private async void InvokeHeading(object sender, ItemClickEventArgs args)
    {
        if (args.ClickedItem is ListViewItem { Tag: int id } && Current?.Editor is { } editor)
            await RunAsync(() => editor.RequestAsync("navigateHeading", new JsonObject { ["id"] = id }));
    }

    private void FolderQueryChanged(object sender, TextChangedEventArgs args) => StartFolderSearch();
    private void StartFolderSearch()
    {
        searchCancellation?.Cancel(); searchCancellation?.Dispose(); searchCancellation = new();
        SearchResults.Items.Clear(); SearchStatus.Text = "";
        if (Current?.Folder is not { } folder || string.IsNullOrWhiteSpace(FolderQuery.Text)) return;
        string query = FolderQuery.Text; var token = searchCancellation.Token;
        _ = SearchFolderAsync(folder, query, token);
    }
    private async Task SearchFolderAsync(string folder, string query, CancellationToken token)
    {
        try
        {
            await Task.Delay(250, token); SearchStatus.Text = T("正在搜索…", "Searching…");
            await Task.Run(() => FolderIndex.SearchAsync(folder, query, App.Preferences.HiddenFiles, match => DispatcherQueue.TryEnqueue(() =>
            {
                if (token.IsCancellationRequested) return;
                var item = new TextBlock { Text = $"{Path.GetRelativePath(folder, match.Path)}:{match.Line}\n{match.Preview}", TextWrapping = TextWrapping.Wrap, Tag = match, MaxWidth = 400 };
                SearchResults.Items.Add(item);
            }), token), token);
            if (!token.IsCancellationRequested) SearchStatus.Text = T("搜索完成，最多显示 1000 处匹配。", "Search complete. Showing up to 1,000 matches.");
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!token.IsCancellationRequested) SearchStatus.Text = error.Message; }
    }
    private async void InvokeSearchResult(object sender, ItemClickEventArgs args)
    {
        if (args.ClickedItem is not TextBlock { Tag: FolderMatch match }) return;
        await RunAsync(async () =>
        {
            await SwitchFileAsync(match.Path);
            if (Current?.Path == match.Path && Current.Editor is { } editor)
                await editor.RequestAsync("selectMatch", new JsonObject { ["line"] = match.Line, ["column"] = match.Column, ["length"] = match.Length });
        });
    }

    private void RefreshStatus()
    {
        var document = Current; var state = document?.Editor?.State;
        ModeLabel.Text = state?.SourceMode == true ? T("源码模式", "Source mode") : T("实时模式", "Live mode");
        SaveLabel.Text = document?.AutosaveBlocked == true ? T("自动保存已暂停，请手动保存处理冲突。", "Autosave paused. Save manually to resolve the conflict.")
            : document?.Dirty == true ? T("未保存", "Unsaved") : document?.Path is not null ? T("已保存", "Saved") : "";
        StatisticsLabel.Text = state is null ? "" : T($"{state.Stats.Words:N0} 字 · {state.Stats.Characters:N0} 字符 · {state.Stats.Lines:N0} 行", $"{state.Stats.Words:N0} words · {state.Stats.Characters:N0} characters · {state.Stats.Lines:N0} lines");
        SourceToggle.IsChecked = state?.SourceMode == true;
        FocusToggle.IsChecked = App.Preferences.Focus;
        SaveDivider.Visibility = SaveLabel.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        Title = document is null ? "Inkpot" : document.Name + (document.Dirty ? " •" : "") + " — Inkpot";
    }
    private async Task PersistEditsAsync()
    {
        if (busy || persistenceBusy || allowClose || !documents.Any(NeedsPersistence)) return;
        // Share the document gate with foreground commands without changing control enabled
        // states. A timer tick must never interrupt a pointer press or steal keyboard focus.
        if (!await commandGate.WaitAsync(0)) return;
        persistenceBusy = true;
        try
        {
            foreach (var document in documents.ToArray())
                if (NeedsPersistence(document)) await PersistDocumentAsync(document);
        }
        catch (Exception error) { SaveLabel.Text = T("草稿恢复保存失败：", "Recovery draft could not be saved: ") + error.Message; }
        finally { persistenceBusy = false; commandGate.Release(); }
    }
    private static bool NeedsPersistence(DocumentTab document) => document.Dirty
        && document.Editor is { State.Composing: false } editor
        && DateTime.UtcNow - document.LastEdit >= TimeSpan.FromSeconds(2)
        && (editor.State.Revision != document.DraftRevision
            || App.Preferences.Autosave && document.Path is not null && !document.AutosaveBlocked);
    private async Task PersistDocumentAsync(DocumentTab document)
    {
        if (document.Editor is not { } editor) return;
        var snapshot = await editor.SnapshotAsync();
        if (snapshot.Revision != document.DraftRevision)
        {
            var draft = new RecoveryDraft(document.RecoveryId, document.Path, snapshot.Text, document.HasBom, document.Baseline, DateTime.UtcNow);
            await Task.Run(() => App.Data.SaveDraft(draft)); document.DraftRevision = snapshot.Revision;
        }
        if (App.Preferences.Autosave && document.Path is not null && !document.AutosaveBlocked)
        {
            try { await SaveAsync(document, automatic: true); }
            catch (Exception error) { document.AutosaveBlocked = true; SaveLabel.Text = error.Message; }
        }
    }
    private async Task RestoreDraftsAsync()
    {
        var drafts = App.Data.LoadDrafts();
        if (drafts.Count == 0) { await DialogAsync(T("恢复草稿", "Recover drafts"), T("没有可恢复的草稿。", "No recovery drafts found.")); return; }
        var list = new ListView { SelectionMode = ListViewSelectionMode.Multiple, MaxHeight = 380 };
        foreach (var draft in drafts)
            list.Items.Add(new TextBlock { Text = $"{draft.Path ?? Text("Untitled")}\n{draft.Updated.ToLocalTime():g} · {draft.Text.Length:N0}", Tag = draft, TextWrapping = TextWrapping.Wrap });
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = T("恢复未保存草稿", "Recover unsaved drafts"), Content = list,
            PrimaryButtonText = T("恢复选中草稿", "Recover selected"), SecondaryButtonText = T("删除选中草稿", "Delete selected"), CloseButtonText = Text("Cancel") };
        var answer = await dialog.ShowAsync();
        if (answer == ContentDialogResult.None) return;
        var selected = list.SelectedItems.Cast<TextBlock>().Select(item => (RecoveryDraft)item.Tag).ToArray();
        if (answer == ContentDialogResult.Secondary)
        {
            if (selected.Length > 0 && await DialogAsync(T("删除恢复草稿？", "Delete recovery drafts?"), T("所选草稿将被删除。", "The selected recovery drafts will be deleted."), T("删除", "Delete"), close: Text("Cancel")) == ContentDialogResult.Primary)
                foreach (var draft in selected) App.Data.RemoveDraft(draft.Id);
            return;
        }
        foreach (var draft in selected)
        {
            if (App.Windows.SelectMany(window => window.documents).Any(document => document.RecoveryId == draft.Id)) continue;
            // Recover as a separate dirty tab; never replace a document already open in a window.
            var document = CreateDocument(null, new LoadedDocument(draft.Text, draft.HasBom, draft.Baseline ?? new(0, DateTime.MinValue, "")));
            document.RecoveryId = draft.Id; document.Recovered = true; document.SavedRevision = -1;
            if (draft.Path is not null && !App.Windows.SelectMany(window => window.documents).Any(tab => tab != document && string.Equals(tab.Path, draft.Path, StringComparison.OrdinalIgnoreCase)))
            { document.Path = draft.Path; document.Baseline = draft.Baseline; }
            document.RefreshHeader(); await ActivateCurrentAsync();
        }
    }
    internal SavedWindow CaptureSession()
    {
        var ordered = Tabs.TabItems.OfType<TabViewItem>().Select(item => documents.First(document => document.Item == item)).ToList();
        var retained = ordered.Where(document => document.Path is not null || document.Folder is not null).ToList();
        return new(retained.Select(document => new SavedTab(document.Path, document.Folder, document.Sidebar, document.SidebarPage, document.SidebarWidth)).ToList(),
            Math.Max(0, retained.IndexOf(Current!)), AppWindow.Position.X, AppWindow.Position.Y, AppWindow.Size.Width, AppWindow.Size.Height);
    }
    private void RestoreWindowBounds(SavedWindow state)
    {
        var area = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
        int width = Math.Clamp(state.Width, 640, Math.Max(640, area.Width)), height = Math.Clamp(state.Height, 400, Math.Max(400, area.Height));
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(Math.Clamp(state.X, area.X, Math.Max(area.X, area.X + area.Width - width)), Math.Clamp(state.Y, area.Y, Math.Max(area.Y, area.Y + area.Height - height)), width, height));
    }
    private async Task ExitAsync()
    {
        App.Data.SaveSession(App.Windows.Select(window => window.CaptureSession()).ToList());
        quitting = true;
        try
        {
            foreach (var window in App.Windows.ToArray()) { await window.CloseAllAsync(); if (!window.allowClose) return; }
        }
        finally { quitting = false; }
    }

    private async void OpenFolder(object sender, RoutedEventArgs args) => await RunAsync(OpenFolderPickerAsync);
    private async void ToggleSidebarFromToolbar(object sender, RoutedEventArgs args)
    {
        await RunAsync(() => ToggleSidebarAsync(Current?.SidebarPage ?? "files")); RefreshSidebar();
    }
    private async void ToggleFocusFromToolbar(object sender, RoutedEventArgs args)
    {
        await RunAsync(() => ToggleModeAsync(false)); RefreshStatus();
    }
    private async void ToggleSourceFromToolbar(object sender, RoutedEventArgs args)
    {
        await RunAsync(async () => { if (Current?.Editor is { } editor) await editor.CommandAsync("toggleSourceMode"); }); RefreshStatus();
    }
    private async void ResizeSidebarWithKeyboard(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key is not (VirtualKey.Left or VirtualKey.Right)) return;
        args.Handled = true;
        await RunAsync(() => {
            if (Current is { Sidebar: true } document)
            {
                document.SidebarWidth = Math.Clamp(document.SidebarWidth + (args.Key == VirtualKey.Left ? -16 : 16), 200, Math.Max(200, Root.ActualWidth - 300));
                RefreshSidebar();
            }
            return Task.CompletedTask;
        });
    }
}
