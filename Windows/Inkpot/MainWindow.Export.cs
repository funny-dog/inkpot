using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Windows.Storage.Pickers;
using static Inkpot.L10n;

namespace Inkpot;

public sealed partial class MainWindow
{
    private WebView2? printView;
    private async Task<WebView2> RenderExportAsync()
    {
        if (Current?.Editor is not { } editor) throw new IOException(Text("EditorFailed"));
        // Validate composition before entering export; source content and undo history stay in the editor.
        await editor.SnapshotAsync();
        string html = await editor.TextAsync("exportHTML", new JsonObject { ["mode"] = "pdf" });
        if (printView is not null) { Root.Children.Remove(printView); printView.Close(); }
        var renderer = new WebView2 { Width = Math.Max(320, (App.Preferences.Landscape ? App.Preferences.PageHeight : App.Preferences.PageWidth) * 96), Height = 800, Opacity = 0, IsHitTestVisible = false };
        printView = renderer; Grid.SetRow(renderer, 1); Root.Children.Add(renderer); Root.UpdateLayout();
        if (!renderer.IsLoaded)
        { var loaded = new TaskCompletionSource(); renderer.Loaded += (_, _) => loaded.TrySetResult(); await loaded.Task.WaitAsync(TimeSpan.FromSeconds(10)); }
        await renderer.EnsureCoreWebView2Async(await environment);
        var core = renderer.CoreWebView2;
        core.SetVirtualHostNameToFolderMapping("editor.inkpot.local", Path.Combine(AppContext.BaseDirectory, "Editor"), CoreWebView2HostResourceAccessKind.Allow);
        core.Settings.AreDevToolsEnabled = false; core.Settings.IsStatusBarEnabled = false;
        core.PermissionRequested += (_, args) => args.State = CoreWebView2PermissionState.Deny;
        core.NewWindowRequested += (_, args) => args.Handled = true;
        var completed = new TaskCompletionSource();
        core.NavigationCompleted += (_, args) => { if (args.IsSuccess) completed.TrySetResult(); else completed.TrySetException(new IOException(args.WebErrorStatus.ToString())); };
        const string exportPage = "https://export.inkpot.local/document";
        core.AddWebResourceRequestedFilter(exportPage, CoreWebView2WebResourceContext.Document);
        core.WebResourceRequested += (_, args) => args.Response = core.Environment.CreateWebResourceResponse(
            new MemoryStream(System.Text.Encoding.UTF8.GetBytes(html)).AsRandomAccessStream(), 200, "OK", "Content-Type: text/html; charset=utf-8\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline' https://editor.inkpot.local; font-src https://editor.inkpot.local; img-src data:");
        core.NavigationStarting += (_, args) => { if (args.Uri != exportPage) args.Cancel = true; };
        core.Navigate(exportPage);
        await completed.Task.WaitAsync(TimeSpan.FromSeconds(15));
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (await core.ExecuteScriptAsync("document.readyState==='complete' && document.fonts.status==='loaded' && Array.from(document.images).every(i=>i.complete && i.naturalWidth>0)") != "true")
        { if (DateTime.UtcNow > deadline) throw new IOException(T("导出资源未能加载，已取消。", "Export resources did not load; export cancelled.")); await Task.Delay(50); }
        await Task.Delay(100);
        string width = (App.Preferences.Landscape ? App.Preferences.PageHeight : App.Preferences.PageWidth).ToString(System.Globalization.CultureInfo.InvariantCulture);
        string height = (App.Preferences.Landscape ? App.Preferences.PageWidth : App.Preferences.PageHeight).ToString(System.Globalization.CultureInfo.InvariantCulture);
        string margin = App.Preferences.PageMargin.ToString(System.Globalization.CultureInfo.InvariantCulture);
        // The system print dialog uses the same page geometry as PDF export.
        await core.ExecuteScriptAsync($"document.head.appendChild(document.createElement('style')).textContent='@page {{ size: {width}in {height}in; margin: {margin}in; }}'");
        return renderer;
    }
    private CoreWebView2PrintSettings PrintSettings(CoreWebView2 core)
    {
        var preferences = App.Preferences;
        var settings = core.Environment.CreatePrintSettings();
        settings.PageWidth = preferences.PageWidth; settings.PageHeight = preferences.PageHeight;
        settings.Orientation = preferences.Landscape ? CoreWebView2PrintOrientation.Landscape : CoreWebView2PrintOrientation.Portrait;
        settings.MarginTop = settings.MarginBottom = settings.MarginLeft = settings.MarginRight = preferences.PageMargin;
        settings.ShouldPrintBackgrounds = true; settings.ShouldPrintHeaderAndFooter = false;
        return settings;
    }
    private async Task ExportAsync(bool pdf)
    {
        if (Current is not { Editor: { } editor } document) return;
        var picker = new FileSavePicker { SuggestedFileName = Path.GetFileNameWithoutExtension(document.Name) };
        picker.FileTypeChoices.Add(pdf ? "PDF" : "HTML", new List<string> { pdf ? ".pdf" : ".html" });
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSaveFileAsync() is not { } file) return;
        if (document.Path is { } source && string.Equals(Path.GetFullPath(source), Path.GetFullPath(file.Path), StringComparison.OrdinalIgnoreCase))
            throw new IOException(T("导出目标不能是当前源文件。", "Cannot export over the source document."));
        string temporary = Path.Combine(Path.GetDirectoryName(file.Path)!, ".inkpot-export-" + Guid.NewGuid().ToString("N") + (pdf ? ".pdf" : ".html"));
        try
        {
            if (pdf)
            {
                var renderer = await RenderExportAsync();
                var settings = PrintSettings(renderer.CoreWebView2);
                if (!App.Preferences.PaginatedPdf)
                {
                    double height = double.Parse(await renderer.CoreWebView2.ExecuteScriptAsync("Math.ceil(Math.max(document.body.scrollHeight,document.documentElement.scrollHeight))"), System.Globalization.CultureInfo.InvariantCulture) / 96 + 2 * App.Preferences.PageMargin;
                    if (height > 200) throw new IOException(T("连续长页超过 PDF 200 英寸限制，请使用分页导出。", "The continuous page exceeds the PDF 200-inch limit. Use paginated export."));
                    settings.Orientation = CoreWebView2PrintOrientation.Portrait;
                    settings.PageWidth = App.Preferences.Landscape ? App.Preferences.PageHeight : App.Preferences.PageWidth;
                    settings.PageHeight = Math.Max(1, height);
                }
                if (!await renderer.CoreWebView2.PrintToPdfAsync(temporary, settings)) throw new IOException(T("PDF 导出失败。", "PDF export failed."));
            }
            else
            {
                await editor.SnapshotAsync();
                string html = await editor.TextAsync("exportHTML", new JsonObject { ["mode"] = "html" });
                await File.WriteAllTextAsync(temporary, html, new System.Text.UTF8Encoding(false));
            }
            File.Move(temporary, file.Path, true);
            SaveLabel.Text = T("已导出：", "Exported: ") + file.Name;
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private async Task PrintAsync()
    {
        var renderer = await RenderExportAsync();
        renderer.CoreWebView2.ShowPrintUI(CoreWebView2PrintDialogKind.System);
    }
    private async Task PageSetupAsync()
    {
        var preferences = App.Preferences;
        var panel = new StackPanel { Spacing = 12, MinWidth = 320 };
        var paginated = new CheckBox { Content = T("PDF 分页导出", "Paginated PDF"), IsChecked = preferences.PaginatedPdf };
        var landscape = new CheckBox { Content = T("横向", "Landscape"), IsChecked = preferences.Landscape };
        var width = new NumberBox { Header = T("纸张宽度（英寸）", "Paper width (inches)"), Value = preferences.PageWidth, Minimum = 1, Maximum = 100 };
        var height = new NumberBox { Header = T("纸张高度（英寸）", "Paper height (inches)"), Value = preferences.PageHeight, Minimum = 1, Maximum = 100 };
        var margin = new NumberBox { Header = T("页边距（英寸）", "Margins (inches)"), Value = preferences.PageMargin, Minimum = 0, Maximum = 10 };
        var paper = new ComboBox { Header = T("纸张", "Paper"), ItemsSource = new[] { "A4", "A5", "Letter", T("自定义", "Custom") }, SelectedIndex = 3 };
        paper.SelectionChanged += (_, _) =>
        {
            var sizes = new[] { (8.2677, 11.6929), (5.8268, 8.2677), (8.5, 11.0) };
            if (paper.SelectedIndex < 3) { width.Value = sizes[paper.SelectedIndex].Item1; height.Value = sizes[paper.SelectedIndex].Item2; }
        };
        foreach (var child in new UIElement[] { paper, width, height, margin, landscape, paginated }) panel.Children.Add(child);
        if (await new ContentDialog { XamlRoot = Root.XamlRoot, Title = T("页面设置", "Page setup"), Content = panel, PrimaryButtonText = Text("OK"), CloseButtonText = Text("Cancel") }.ShowAsync() != ContentDialogResult.Primary) return;
        preferences.PageWidth = width.Value; preferences.PageHeight = height.Value; preferences.PageMargin = margin.Value;
        preferences.Landscape = landscape.IsChecked == true; preferences.PaginatedPdf = paginated.IsChecked == true;
        App.Data.SavePreferences(preferences);
    }
}
