using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Storage.Pickers;
using Windows.System;
using static Inkpot.L10n;

namespace Inkpot;

internal sealed class SettingsWindow : Window
{
    private readonly TabView tabs = new() { IsAddTabButtonVisible = false, CanReorderTabs = false };
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly Storage.Preferences preferences = App.Preferences;
    private readonly List<ScrollViewer> viewports = [];

    internal SettingsWindow()
    {
        Title = T("Inkpot 设置", "Inkpot Settings"); SystemBackdrop = new MicaBackdrop();
        WindowMetrics.Resize(this, 760, 740);
        var root = new Grid(); root.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) }); root.RowDefinitions.Add(new() { Height = GridLength.Auto });
        root.Children.Add(tabs); Grid.SetRow(status, 1); status.Margin = new Thickness(16, 4, 16, 8); root.Children.Add(status); Content = root;
        tabs.SizeChanged += (_, args) => { foreach (var viewport in viewports) SizePage(viewport, args.NewSize.Width); };
        General(); Editing(); Appearance(); About();
        ApplyTheme();
        Activated += (_, args) =>
        {
            if (args.WindowActivationState == WindowActivationState.Deactivated) return;
            int pane = Math.Max(0, tabs.SelectedIndex);
            viewports.Clear(); tabs.TabItems.Clear(); General(); Editing(); Appearance(); About();
            tabs.SelectedIndex = pane; ApplyTheme();
        };
    }
    internal void SelectPane(int index) => tabs.SelectedIndex = index;
    internal void ValidateVisiblePage()
    {
        ((FrameworkElement)Content).UpdateLayout();
        if (tabs.SelectedItem is not TabViewItem { Content: ScrollViewer { Content: StackPanel panel } scroll }
            || scroll.ActualWidth < 200 || panel.ActualWidth < 200) throw new IOException("Settings page is not visible.");
        var position = panel.TransformToVisual(tabs).TransformPoint(new Windows.Foundation.Point(0, 0));
        if (position.X < -1 || position.X + panel.ActualWidth > tabs.ActualWidth + 1) throw new IOException($"Settings page exceeds the window width: x={position.X}, panel={panel.ActualWidth}, viewport={scroll.ActualWidth}, tabs={tabs.ActualWidth}.");
    }
    private void ApplyTheme() => ((FrameworkElement)Content).RequestedTheme = preferences.Appearance switch { "light" => ElementTheme.Light, "dark" => ElementTheme.Dark, _ => ElementTheme.Default };
    private StackPanel Page(string title)
    {
        var panel = new StackPanel { Spacing = 18, Padding = new Thickness(24), MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Left };
        var scroll = new ScrollViewer { Content = panel, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Disabled, HorizontalAlignment = HorizontalAlignment.Left, HorizontalContentAlignment = HorizontalAlignment.Left };
        // Bound the viewport before measuring controls such as ComboBox, whose unconstrained desired
        // width can otherwise push the General page outside the window.
        SizePage(scroll, tabs.ActualWidth);
        scroll.Loaded += (_, _) => SizePage(scroll, tabs.ActualWidth);
        viewports.Add(scroll);
        tabs.TabItems.Add(new TabViewItem { Header = title, IsClosable = false, Content = scroll });
        return panel;
    }
    private static void SizePage(ScrollViewer viewport, double width)
    {
        viewport.Width = Math.Max(1, width);
        ((FrameworkElement)viewport.Content).Width = Math.Min(640, viewport.Width);
    }
    private async Task ChangedAsync()
    {
        try { await App.PreferencesChangedAsync(); ApplyTheme(); status.Text = ""; }
        catch (Exception error) { status.Text = error.Message; }
    }
    private void Toggle(StackPanel panel, string label, bool value, Action<bool> set)
    {
        var toggle = new ToggleSwitch { Header = label, IsOn = value, OnContent = T("开启", "On"), OffContent = T("关闭", "Off") };
        toggle.Toggled += async (_, _) => { set(toggle.IsOn); await ChangedAsync(); };
        panel.Children.Add(toggle);
    }
    private void Choice(StackPanel panel, string label, string[] labels, int selected, Action<int> set)
    {
        var combo = new ComboBox { Header = label, ItemsSource = labels, SelectedIndex = selected, HorizontalAlignment = HorizontalAlignment.Stretch };
        combo.SelectionChanged += async (_, _) => { if (combo.SelectedIndex >= 0) { set(combo.SelectedIndex); await ChangedAsync(); } };
        panel.Children.Add(combo);
    }
    private void Number(StackPanel panel, string label, double value, double min, double max, Action<double> set)
    {
        var input = new NumberBox { Header = label, Value = value, Minimum = min, Maximum = max, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline };
        input.ValueChanged += async (_, _) => { if (double.IsFinite(input.Value)) { set(input.Value); await ChangedAsync(); } };
        panel.Children.Add(input);
    }
    private void General()
    {
        var page = Page(T("通用", "General"));
        Choice(page, T("启动时", "On launch"), [T("恢复上次会话", "Restore previous session"), T("新建文档", "Create a new document")], preferences.RestoreSession ? 0 : 1, index => preferences.RestoreSession = index == 0);
        Choice(page, T("文件树", "File tree"), [T("Markdown 和文本文件", "Markdown and text files"), T("所有文件", "All files")], preferences.AllFiles ? 1 : 0, index => preferences.AllFiles = index == 1);
        Toggle(page, T("显示隐藏文件和文件夹", "Show hidden files and folders"), preferences.HiddenFiles, value => preferences.HiddenFiles = value);
        Toggle(page, T("自动保存已有文件（停止输入约 2 秒）", "Autosave existing files after 2 seconds of inactivity"), preferences.Autosave, value => preferences.Autosave = value);
        Choice(page, T("图片素材目录", "Image assets folder"), [T("自定义目录／默认 assets", "Custom folder / assets by default"), T("文档名.assets", "Document name.assets")], preferences.DocumentImageFolder ? 1 : 0, index => preferences.DocumentImageFolder = index == 1);
        var folder = new TextBlock { Text = preferences.ImageFolder ?? T("文档同级 assets 文件夹", "assets folder beside the document"), TextWrapping = TextWrapping.Wrap };
        page.Children.Add(folder);
        var choose = new Button { Content = T("选择图片目录…", "Choose image folder…") };
        choose.Click += async (_, _) =>
        {
            try
            {
                var picker = new FolderPicker(); picker.FileTypeFilter.Add("*");
                WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
                if (await picker.PickSingleFolderAsync() is { } selected) { preferences.ImageFolder = selected.Path; folder.Text = selected.Path; await ChangedAsync(); }
            }
            catch (Exception error) { status.Text = error.Message; }
        };
        page.Children.Add(choose);
        var reset = new Button { Content = T("恢复默认图片目录", "Reset image folder") };
        reset.Click += async (_, _) => { preferences.ImageFolder = null; folder.Text = T("文档同级 assets 文件夹", "assets folder beside the document"); await ChangedAsync(); };
        page.Children.Add(reset);
        page.Children.Add(new TextBlock { Text = T("仅影响新插入图片，不移动已有素材。", "Applies to new images; existing assets stay in place."), TextWrapping = TextWrapping.Wrap });
        Toggle(page, T("加载远程图片（HTTPS）", "Load remote images (HTTPS)"), preferences.RemoteImages, value => preferences.RemoteImages = value);
    }
    private void Editing()
    {
        var page = Page(T("编辑", "Editing"));
        Choice(page, T("默认打开模式", "Default editing mode"), [T("实时模式", "Live mode"), T("源码模式", "Source mode")], preferences.DefaultSource ? 1 : 0, index => preferences.DefaultSource = index == 1);
        Choice(page, T("缩进宽度", "Indent width"), [T("2 个空格", "2 spaces"), T("4 个空格", "4 spaces")], preferences.Indent == 4 ? 1 : 0, index => preferences.Indent = index == 1 ? 4 : 2);
        Toggle(page, T("自动配对括号与引号", "Pair brackets and quotes"), preferences.PairBrackets, value => preferences.PairBrackets = value);
        Toggle(page, T("自动配对 Markdown 字符", "Pair Markdown characters"), preferences.PairMarkdown, value => preferences.PairMarkdown = value);
        Toggle(page, T("输入时检查拼写", "Check spelling while typing"), preferences.Spellcheck, value => preferences.Spellcheck = value);
        Toggle(page, T("专注模式", "Focus mode"), preferences.Focus, value => preferences.Focus = value);
        Toggle(page, T("打字机模式", "Typewriter mode"), preferences.Typewriter, value => preferences.Typewriter = value);
    }
    private void Appearance()
    {
        var page = Page(T("外观", "Appearance"));
        Choice(page, T("外观", "Appearance"), [T("跟随系统", "System"), T("浅色", "Light"), T("深色", "Dark")], preferences.Appearance == "light" ? 1 : preferences.Appearance == "dark" ? 2 : 0, index => preferences.Appearance = new[] { "system", "light", "dark" }[index]);
        Number(page, T("缩放比例（0.5–2）", "Zoom (0.5–2)"), preferences.Zoom, .5, 2, value => preferences.Zoom = value);
        Toggle(page, T("按住 Ctrl 时使用滚轮缩放", "Zoom with Ctrl + mouse wheel"), preferences.ZoomWithControlScroll, value => preferences.ZoomWithControlScroll = value);
        Font(page, T("正文字体", "Body font"), false);
        Number(page, T("正文字号", "Body font size"), preferences.BodySize, 8, 72, value => preferences.BodySize = value);
        Font(page, T("代码字体（等宽）", "Code font (monospaced)"), true);
        Number(page, T("代码字号", "Code font size"), preferences.CodeSize, 8, 72, value => preferences.CodeSize = value);
        var reset = new Button { Content = T("恢复默认字体与缩放", "Reset fonts and zoom") };
        reset.Click += async (_, _) => { preferences.BodyFont = ""; preferences.CodeFont = ""; preferences.BodySize = preferences.CodeSize = 15; preferences.Zoom = 1; await ChangedAsync(); tabs.TabItems.RemoveAt(2); Appearance(); var last = tabs.TabItems[^1]; tabs.TabItems.RemoveAt(tabs.TabItems.Count - 1); tabs.TabItems.Insert(2, last); tabs.SelectedIndex = 2; };
        page.Children.Add(reset);
    }
    private void Font(StackPanel page, string label, bool code)
    {
        var families = FontCatalog.Families(code);
        string current = code ? preferences.CodeFont : preferences.BodyFont;
        string[] names = [T("系统默认", "System default"), .. families];
        int index = Math.Max(0, Array.IndexOf(names, current));
        Choice(page, label, names, index, selected => { if (code) preferences.CodeFont = selected == 0 ? "" : names[selected]; else preferences.BodyFont = selected == 0 ? "" : names[selected]; });
    }
    private void About()
    {
        var page = Page(T("关于", "About"));
        page.Children.Add(new TextBlock { Text = "Inkpot", FontSize = 30 });
        page.Children.Add(new TextBlock { Text = T("版本 ", "Version ") + App.Version });
        Toggle(page, T("自动检查更新并下载", "Automatically check and download updates"), preferences.AutomaticUpdates, value => preferences.AutomaticUpdates = value);
        page.Children.Add(new TextBlock { Text = T("每天最多检查一次。下载包校验通过后保存到缓存；处理未保存文档并退出后手动覆盖安装。", "Checks at most once a day. Verified downloads are cached; save your work and exit before installing manually."), TextWrapping = TextWrapping.Wrap });
        var update = new Button { Content = T("检查更新…", "Check for updates…") };
        update.Click += async (_, _) =>
        {
            update.IsEnabled = false;
            try
            {
                var result = await Storage.UpdateService.CheckAsync(App.Version, Path.Combine(App.Data.DirectoryPath, "Updates"), preferences.AutomaticUpdates);
                status.Text = result is null ? T("已是最新版本。", "You're up to date.") : T("发现新版本：", "New version: ") + result.Tag;
                if (result?.DownloadedPath is { } path) { status.Text += "\n" + path; await Launcher.LaunchFolderPathAsync(Path.GetDirectoryName(path)!); }
                else if (result is not null) await Launcher.LaunchUriAsync(new Uri(Storage.UpdateService.DownloadPage));
            }
            catch (Exception error) { status.Text = error.Message; }
            finally { update.IsEnabled = true; }
        };
        page.Children.Add(update);
        foreach (var (label, url) in new[] { (T("官方网站", "Website"), "https://github.com/funny-dog/inkpot"), (T("反馈", "Feedback"), "https://github.com/funny-dog/inkpot/issues") })
            page.Children.Add(new HyperlinkButton { Content = label, NavigateUri = new Uri(url) });
        var notices = new Button { Content = T("第三方许可…", "Third-party licenses…") };
        notices.Click += async (_, _) =>
        {
            try
            {
                var text = new TextBlock { Text = await File.ReadAllTextAsync(Path.Combine(AppContext.BaseDirectory, "ThirdPartyNotices.md")), IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap };
                await new ContentDialog { XamlRoot = tabs.XamlRoot, Title = T("第三方许可", "Third-party licenses"), Content = new ScrollViewer { Content = text, MaxHeight = 450 }, CloseButtonText = Text("Close") }.ShowAsync();
            }
            catch (Exception error) { status.Text = error.Message; }
        };
        page.Children.Add(notices);
    }
}
