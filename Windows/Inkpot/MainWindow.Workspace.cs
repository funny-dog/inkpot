using System.Globalization;
using Inkpot.Workspace;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Windows.Storage.Pickers;
using Windows.System;

namespace Inkpot;

public sealed partial class MainWindow
{
    private AppPreferences preferences = new();
    private string? preferencesPath;
    private Exception? preferencesError;
    private bool showingOutline;
    private string? folderPath;
    private readonly Dictionary<int, ListViewItem> outlineItems = [];
    private IReadOnlyList<Bridge.OutlineHeading>? renderedHeadings;
    private readonly Dictionary<string, ToggleMenuFlyoutItem> viewMenus = [];

    private void InitializeWorkspace(string[] arguments)
    {
        // CI 使用独立临时目录，不能读取或改写桌面用户的偏好。
        int reportIndex = Array.IndexOf(arguments, "--smoke-report");
        preferencesPath = reportIndex >= 0 && reportIndex + 1 < arguments.Length
            ? Path.Combine(Path.GetDirectoryName(Path.GetFullPath(arguments[reportIndex + 1]))!, "preferences.json")
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Inkpot", "preferences.json");
        try { preferences = AppPreferences.Load(preferencesPath); }
        catch (IOException error) { preferencesError = error; }
        FilesButton.Content = L10n.Text("Files");
        OutlineButton.Content = L10n.Text("Outline");
        EmptyOpenFolderButton.Content = L10n.Text("OpenFolder");
        EmptyFilesTitle.Text = L10n.Text("NoFolder");
        EmptyFilesMessage.Text = L10n.Text("NoFolderMessage");
        EmptyOutlineTitle.Text = L10n.Text("NoHeadings");
        EmptyOutlineMessage.Text = L10n.Text("NoHeadingsMessage");
        AutomationProperties.SetName(SidebarSwitcher, L10n.Text("SidebarContent"));
        AutomationProperties.SetName(FilesTree, L10n.Text("Files"));
        AutomationProperties.SetName(OutlineList, L10n.Text("Outline"));
        AutomationProperties.SetName(SidebarDivider, L10n.Text("ResizeSidebar"));
        AutomationProperties.SetName(ModeLabel, L10n.Text("EditingMode"));
        AutomationProperties.SetName(SaveLabel, L10n.Text("SaveStatus"));
        AutomationProperties.SetName(StatisticsLabel, L10n.Text("WordCount"));
        // 顶栏图标按钮没有文字，名称供读屏使用，提示说明用途与快捷键。
        foreach (var (button, name, tip) in new (FrameworkElement, string, string)[] {
            (OpenFolderButton, "OpenFolder", "ChangeFolderTip"),
            (SidebarToggle, "Sidebar", "SidebarTip"),
            (FocusToggle, "FocusMode", "FocusTip"),
            (SourceToggle, "SourceMode", "SourceTip") })
        {
            AutomationProperties.SetName(button, L10n.Text(name));
            ToolTipService.SetToolTip(button, L10n.Text(tip));
        }
        ApplyWorkspaceAppearance();
        RefreshSidebar();
    }

    private void ApplyWorkspaceAppearance() => Root.RequestedTheme = preferences.Appearance switch
    {
        "light" => ElementTheme.Light,
        "dark" => ElementTheme.Dark,
        _ => ElementTheme.Default,
    };

    private void RefreshSidebar()
    {
        SidebarColumn.Width = new GridLength(preferences.SidebarVisible ? preferences.SidebarWidth : 0);
        DividerColumn.Width = new GridLength(preferences.SidebarVisible ? 6 : 0);
        SidebarPanel.Visibility = SidebarDivider.Visibility = preferences.SidebarVisible ? Visibility.Visible : Visibility.Collapsed;
        FilesPanel.Visibility = showingOutline ? Visibility.Collapsed : Visibility.Visible;
        OutlinePanel.Visibility = showingOutline ? Visibility.Visible : Visibility.Collapsed;
        FilesButton.IsChecked = !showingOutline;
        OutlineButton.IsChecked = showingOutline;
        FilesButton.FontWeight = showingOutline ? FontWeights.Normal : FontWeights.SemiBold;
        OutlineButton.FontWeight = showingOutline ? FontWeights.SemiBold : FontWeights.Normal;
        bool hasFolder = folderPath is not null;
        FolderHeader.Visibility = FilesTree.Visibility = hasFolder ? Visibility.Visible : Visibility.Collapsed;
        EmptyFiles.Visibility = hasFolder ? Visibility.Collapsed : Visibility.Visible;
        SidebarToggle.IsChecked = preferences.SidebarVisible;
        FocusToggle.IsChecked = preferences.FocusMode;
        foreach (var (key, item) in viewMenus)
            item.IsChecked = key switch
            {
                "Sidebar" => preferences.SidebarVisible,
                "Outline" => preferences.SidebarVisible && showingOutline,
                "FocusMode" => preferences.FocusMode,
                "TypewriterMode" => preferences.TypewriterMode,
                _ => false,
            };
        RefreshOutline();
    }

    private void SetSidebarEnabled(bool enabled)
    {
        FilesTree.IsEnabled = OutlineList.IsEnabled = OpenFolderButton.IsEnabled = EmptyOpenFolderButton.IsEnabled = SidebarDivider.IsEnabled = enabled;
        FilesButton.IsEnabled = OutlineButton.IsEnabled = enabled;
        SidebarToggle.IsEnabled = FocusToggle.IsEnabled = SourceToggle.IsEnabled = enabled;
    }

    private async Task ChangePreferencesAsync(AppPreferences next)
    {
        next = next.Normalize();
        next.Save(preferencesPath!);
        preferences = next;
        ApplyWorkspaceAppearance();
        RefreshSidebar();
        foreach (var document in documents)
            if (document.Editor is { } editor)
            {
                await editor.SetAppearanceAsync(Dark);
                await editor.ApplyPreferencesAsync(preferences);
            }
    }

    private async Task ShowSettingsAsync()
    {
        var next = await PreferencesDialog.ShowAsync(Root.XamlRoot, preferences);
        if (next is not null) await ChangePreferencesAsync(next);
    }

    private Task SaveSidebarAsync(AppPreferences next)
    {
        next = next.Normalize();
        next.Save(preferencesPath!);
        preferences = next;
        RefreshSidebar();
        return Task.CompletedTask;
    }

    private Task ToggleSidebarAsync() => SaveSidebarAsync(preferences with { SidebarVisible = !preferences.SidebarVisible });
    private Task ToggleFocusAsync() => ChangePreferencesAsync(preferences with { FocusMode = !preferences.FocusMode });
    private Task ToggleTypewriterAsync() => ChangePreferencesAsync(preferences with { TypewriterMode = !preferences.TypewriterMode });

    private async Task ShowOutlineAsync()
    {
        showingOutline = true;
        await SaveSidebarAsync(preferences with { SidebarVisible = true });
    }

    private Task ToggleOutlineAsync() => showingOutline && preferences.SidebarVisible ? ToggleSidebarAsync() : ShowOutlineAsync();

    private async void ShowFiles(object sender, RoutedEventArgs args)
    {
        await RunAsync(async () =>
        {
            showingOutline = false;
            await SaveSidebarAsync(preferences with { SidebarVisible = true });
        });
        RefreshSidebar();
    }

    // 切换按钮点击时会先自行翻转选中状态；无论操作是否执行，结束后都按实际状态复位。
    private async void ShowOutline(object sender, RoutedEventArgs args) { await RunAsync(ShowOutlineAsync); RefreshSidebar(); }
    private async void ToggleSidebarFromToolbar(object sender, RoutedEventArgs args) { await RunAsync(ToggleSidebarAsync); RefreshSidebar(); }
    private async void ToggleFocusFromToolbar(object sender, RoutedEventArgs args) { await RunAsync(ToggleFocusAsync); RefreshSidebar(); }

    private async void ToggleSourceFromToolbar(object sender, RoutedEventArgs args)
    {
        await RunAsync(async () => { if (Current?.Editor is { } editor) await editor.CommandAsync("toggleSourceMode"); });
        RefreshStatus();
    }
    private async void OpenFolder(object sender, RoutedEventArgs args) => await RunAsync(OpenFolderPickerAsync);

    private async Task OpenFolderPickerAsync()
    {
        var picker = new FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var folder = await picker.PickSingleFolderAsync();
        if (folder is not null) await OpenFolderAsync(folder.Path);
    }

    private async Task OpenFolderAsync(string path)
    {
        var entries = await Task.Run(() => FileTree.ReadDirectory(path));
        // 全部读取成功后才替换旧树；打开文件夹不关闭现有文档。
        FilesTree.RootNodes.Clear();
        foreach (var entry in entries) FilesTree.RootNodes.Add(MakeFileNode(entry));
        folderPath = Path.GetFullPath(path);
        FolderLabel.Text = Path.GetFileName(Path.TrimEndingDirectorySeparator(folderPath));
        ToolTipService.SetToolTip(FolderLabel, folderPath);
        showingOutline = false;
        await SaveSidebarAsync(preferences with { SidebarVisible = true });
    }

    private static TreeViewNode MakeFileNode(FileTreeEntry entry) => new() { Content = entry, HasUnrealizedChildren = entry.IsDirectory };

    private async void ExpandDirectory(TreeView sender, TreeViewExpandingEventArgs args)
    {
        if (!args.Node.HasUnrealizedChildren || args.Node.Content is not FileTreeEntry entry) return;
        await RunAsync(() => ExpandDirectoryAsync(args.Node, entry));
    }

    private static async Task ExpandDirectoryAsync(TreeViewNode node, FileTreeEntry entry)
    {
        try
        {
            var entries = await Task.Run(() => FileTree.ReadDirectory(entry.Path));
            node.Children.Clear();
            foreach (var child in entries) node.Children.Add(MakeFileNode(child));
            node.HasUnrealizedChildren = false;
        }
        catch { node.IsExpanded = false; throw; }
    }

    private async void InvokeFile(TreeView sender, TreeViewItemInvokedEventArgs args)
    {
        if (args.InvokedItem is TreeViewNode { Content: FileTreeEntry { IsDirectory: false } entry })
            await RunAsync(() => OpenPathAsync(entry.Path));
    }

    private void RefreshOutline()
    {
        var editor = Current?.Editor;
        var headings = editor?.Headings;
        if (!ReferenceEquals(renderedHeadings, headings))
        {
            renderedHeadings = headings;
            OutlineList.Items.Clear();
            outlineItems.Clear();
            if (headings is not null)
                foreach (var heading in headings)
                {
                    // 与 macOS 大纲一致：一级标题加粗，三级及以下用次要层次显示。
                    var item = new ListViewItem { Tag = heading.Id, Content = new TextBlock {
                        Text = heading.Title, Margin = new Thickness((heading.Level - 1) * 14, 4, 0, 4), TextTrimming = TextTrimming.CharacterEllipsis,
                        FontWeight = heading.Level == 1 ? FontWeights.SemiBold : FontWeights.Normal, Opacity = heading.Level >= 3 ? 0.72 : 1 } };
                    ToolTipService.SetToolTip(item, $"H{heading.Level} · {heading.Title}");
                    AutomationProperties.SetName(item, heading.Title);
                    OutlineList.Items.Add(item);
                    outlineItems.Add(heading.Id, item);
                }
        }
        EmptyOutline.Visibility = headings is null || headings.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        OutlineList.SelectedItem = editor?.ActiveHeading is int active ? outlineItems.GetValueOrDefault(active) : null;
    }

    private async void InvokeHeading(object sender, ItemClickEventArgs args)
    {
        if (args.ClickedItem is ListViewItem { Tag: int id } && Current?.Editor is { } editor)
            await RunAsync(() => editor.NavigateHeadingAsync(id));
    }

    private void RefreshStatus()
    {
        var state = Current?.Editor?.State;
        ModeLabel.Text = L10n.Text(state?.SourceMode == true ? "SourceLabel" : "LiveMode");
        SourceToggle.IsChecked = state?.SourceMode == true;
        // 保存状态：有未保存修改或已保存；从未保存过的空白文档不显示。
        var document = Current;
        SaveLabel.Text = document is null ? "" : document.Dirty ? L10n.Text("UnsavedState") : document.Path is not null ? L10n.Text("SavedState") : "";
        SaveDivider.Visibility = SaveLabel.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        StatisticsLabel.Text = string.Format(CultureInfo.CurrentCulture, L10n.Text("StatsFormat"), state?.Stats.Words ?? 0,
            state?.Stats.Characters ?? 0, state?.Stats.Lines ?? 0);
    }

    private void ResizeSidebar(object sender, DragDeltaEventArgs args)
    {
        preferences = preferences with { SidebarWidth = Math.Clamp(preferences.SidebarWidth + args.HorizontalChange, 180, 480) };
        SidebarColumn.Width = new GridLength(preferences.SidebarWidth);
    }

    private async void FinishResizeSidebar(object sender, DragCompletedEventArgs args)
        => await RunAsync(() => { preferences.Save(preferencesPath!); return Task.CompletedTask; });

    private async void ResizeSidebarWithKeyboard(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key is not (VirtualKey.Left or VirtualKey.Right)) return;
        args.Handled = true;
        await RunAsync(() => SaveSidebarAsync(preferences with { SidebarWidth = Math.Clamp(preferences.SidebarWidth + (args.Key == VirtualKey.Left ? -16 : 16), 180, 480) }));
    }
}
