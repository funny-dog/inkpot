using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Windows.UI;
using Inkpot.Storage;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Inkpot.Bridge;

internal sealed class EditorSession : IDisposable
{
    internal const string Page = "https://editor.inkpot.local/index.html";
    private readonly TaskCompletionSource pageReady = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Dictionary<int, TaskCompletionSource<ResponseMessage>> pending = [];
    private int requestID;
    private int generation;
    private Exception? failure;
    private bool disposed;
    internal WebView2 Control { get; } = new();
    internal PublishMessage? State { get; private set; }
    internal event Action<PublishMessage>? Published;
    internal event Action<string>? ShortcutRequested;
    internal event Action? PasteImageRequested;
    internal event Action<string>? LinkRequested;
    internal event Action<OutlineMessage>? OutlineChanged;
    internal string? DocumentPath { get; set; }
    internal bool RemoteImages { get; set; }
    internal Heading[] Headings { get; private set; } = [];
    internal int? ActiveHeading { get; private set; }
    private int outlineRevision;
    internal double ReadyMilliseconds { get; private set; }
    internal long ReadyUnixMilliseconds { get; private set; }

    internal static Task<CoreWebView2Environment> CreateEnvironmentAsync()
    {
        try { CoreWebView2Environment.GetAvailableBrowserVersionString(); }
        catch (Exception error) { throw new WebView2RuntimeMissingException(error); }
        return CoreWebView2Environment.CreateWithOptionsAsync(
            browserExecutableFolder: null,
            userDataFolder: Path.Combine(
                App.Data.DirectoryPath, "WebView2"),
            options: null).AsTask();
    }

    internal async Task InitializeAsync(Task<CoreWebView2Environment> environment, bool dark)
    {
        SetBackground(dark);
        if (Control.XamlRoot is null)
        {
            var loaded = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            RoutedEventHandler? handler = null;
            handler = (_, _) => { Control.Loaded -= handler; loaded.TrySetResult(); };
            Control.Loaded += handler;
            try { await loaded.Task.WaitAsync(TimeSpan.FromSeconds(20)); }
            catch (TimeoutException error) { throw new IOException("编辑器控件未能进入可视树。", error); }
        }
        await Control.EnsureCoreWebView2Async(await environment);
        var core = Control.CoreWebView2;
        core.SetVirtualHostNameToFolderMapping("editor.inkpot.local", Path.Combine(AppContext.BaseDirectory, "Editor"), CoreWebView2HostResourceAccessKind.DenyCors);
        core.AddWebResourceRequestedFilter("https://images.inkpot.local/*", CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += ServeImage;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.AreBrowserAcceleratorKeysEnabled = false;
        core.WebMessageReceived += (_, args) =>
        {
            if (args.Source != Page) return;
            switch (HostMessage.Parse(args.WebMessageAsJson))
            {
                case ReadyMessage:
                    ReadyMilliseconds = App.StartupClock.Elapsed.TotalMilliseconds;
                    ReadyUnixMilliseconds = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                    pageReady.TrySetResult();
                    break;
                case ResponseMessage response when pending.Remove(response.RequestId, out var completion):
                    if (response.Error is not null) completion.TrySetException(new IOException(response.Error));
                    else completion.TrySetResult(response);
                    break;
                case PublishMessage state when state.Generation == generation && state.Revision >= (State?.Revision ?? 0):
                    State = state;
                    Published?.Invoke(state);
                    break;
                case ShortcutMessage shortcut when shortcut.Generation == generation:
                    ShortcutRequested?.Invoke(shortcut.Shortcut);
                    break;
                case PasteImageMessage paste when paste.Generation == generation:
                    PasteImageRequested?.Invoke();
                    break;
                case LinkMessage link when link.Generation == generation:
                    LinkRequested?.Invoke(link.OpenLink);
                    break;
                case OutlineMessage outline when outline.Generation == generation && outline.Revision >= Math.Max(outlineRevision, State?.Revision ?? 0):
                    if (outline.Headings is not null) Headings = outline.Headings;
                    ActiveHeading = outline.Active;
                    outlineRevision = outline.Revision;
                    OutlineChanged?.Invoke(outline);
                    break;
            }
        };
        core.NavigationStarting += (_, args) => { if (args.Uri != Page) args.Cancel = true; };
        core.NewWindowRequested += (_, args) => args.Handled = true;
        core.PermissionRequested += (_, args) => args.State = CoreWebView2PermissionState.Deny;
        core.ProcessFailed += (_, args) => Fail(new IOException($"WebView2: {args.ProcessFailedKind}"));
        core.NavigationCompleted += (_, args) =>
        {
            if (!args.IsSuccess) Fail(new IOException($"WebView2: {args.WebErrorStatus}"));
        };
        core.Navigate(Page);
        await pageReady.Task.WaitAsync(TimeSpan.FromSeconds(20));
    }

    internal Task OpenAsync(string text, bool dark, string language)
    {
        State = null;
        generation++;
        Headings = [];
        ActiveHeading = null;
        outlineRevision = 0;
        return SendAsync(new JsonObject
        {
            ["method"] = "open", ["text"] = text, ["generation"] = generation,
            ["dark"] = dark, ["language"] = language,
            ["resources"] = new JsonObject { ["assetBase"] = "https://editor.inkpot.local/math/", ["imageBase"] = "https://images.inkpot.local/local/" },
        });
    }

    internal Task CommandAsync(string name) => SendAsync(new JsonObject { ["method"] = "command", ["name"] = name });
    internal Task PasteAsync(string text) => SendAsync(new JsonObject { ["method"] = "pastePlainText", ["text"] = text });
    internal Task NavigateHeadingAsync(int id) => RequestAsync("navigateHeading", new JsonObject { ["id"] = id });
    internal Task RequestAsync(string method, JsonObject? arguments = null)
    {
        arguments ??= new();
        arguments["method"] = method;
        return SendAsync(arguments);
    }
    internal async Task<string> TextAsync(string method, JsonObject? arguments = null)
    {
        arguments ??= new();
        arguments["method"] = method;
        return (await SendAsync(arguments)).Value ?? throw new IOException("Missing editor response.");
    }
    internal async Task ApplyPreferencesAsync(Preferences preferences)
    {
        RemoteImages = preferences.RemoteImages;
        await RequestAsync("preferences", new JsonObject
        {
            ["fonts"] = new JsonObject { ["bodyFamily"] = preferences.BodyFont, ["bodySize"] = preferences.BodySize, ["codeFamily"] = preferences.CodeFont, ["codeSize"] = preferences.CodeSize },
            ["editing"] = new JsonObject { ["brackets"] = preferences.PairBrackets, ["markdown"] = preferences.PairMarkdown, ["remoteImages"] = preferences.RemoteImages, ["indent"] = preferences.Indent },
            ["modes"] = new JsonObject { ["focus"] = preferences.Focus, ["typewriter"] = preferences.Typewriter },
            ["spellcheck"] = preferences.Spellcheck,
            ["zoom"] = preferences.Zoom,
            ["zoomWithControlScroll"] = preferences.ZoomWithControlScroll,
        });
    }

    private async void ServeImage(object? sender, CoreWebView2WebResourceRequestedEventArgs args)
    {
        var deferral = args.GetDeferral();
        int requestedGeneration = generation;
        try
        {
            var uri = new Uri(args.Request.Uri);
            var query = new global::Windows.Foundation.WwwFormUrlDecoder(uri.Query);
            if (!uri.AbsolutePath.StartsWith("/local/", StringComparison.Ordinal) || query.GetFirstValueByName("document") != generation.ToString(System.Globalization.CultureInfo.InvariantCulture)) throw new IOException("Stale document image.");
            string path = Uri.UnescapeDataString(uri.AbsolutePath[7..]);
            var image = await NormalizeBitmapAsync((await ImageStorage.ReadAsync(path, DocumentPath, RemoteImages)).Bytes);
            if (disposed || generation != requestedGeneration) throw new IOException("Document changed.");
            args.Response = Control.CoreWebView2.Environment.CreateWebResourceResponse(new MemoryStream(image.Bytes).AsRandomAccessStream(), 200, "OK",
                $"Content-Type: {image.Mime}\r\nAccess-Control-Allow-Origin: https://editor.inkpot.local\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or HttpRequestException or OperationCanceledException or System.Runtime.InteropServices.COMException)
        {
            if (!disposed) args.Response = Control.CoreWebView2.Environment.CreateWebResourceResponse(null, 404, "Not Found", "Content-Type: text/plain\r\nAccess-Control-Allow-Origin: https://editor.inkpot.local");
        }
        finally { deferral.Complete(); }
    }

    internal static async Task ValidateImageAsync(byte[] bytes)
    {
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream.GetOutputStreamAt(0))) { writer.WriteBytes(bytes); await writer.StoreAsync(); }
        var decoder = await BitmapDecoder.CreateAsync(stream);
        if ((ulong)decoder.PixelWidth * decoder.PixelHeight > 40_000_000) throw new IOException("Image exceeds 40 million pixels.");
    }
    internal static async Task<ImageBytes> NormalizeBitmapAsync(byte[] bytes)
    {
        await ValidateImageAsync(bytes);
        string mime = ImageStorage.Mime(bytes);
        if (mime is not ("image/bmp" or "image/tiff")) return new(bytes, mime);
        using var input = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(input.GetOutputStreamAt(0))) { writer.WriteBytes(bytes); await writer.StoreAsync(); }
        var decoder = await BitmapDecoder.CreateAsync(input);
        using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        using var output = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
        encoder.SetSoftwareBitmap(bitmap); await encoder.FlushAsync();
        if (output.Size > ImageStorage.MaximumBytes) throw new IOException("Converted image exceeds 20 MB.");
        using var reader = new DataReader(output.GetInputStreamAt(0)); await reader.LoadAsync((uint)output.Size);
        byte[] png = new byte[output.Size]; reader.ReadBytes(png); return new(png, "image/png");
    }

    internal async Task<EditorSnapshot> SnapshotAsync()
    {
        var response = await SendAsync(new JsonObject { ["method"] = "snapshot" });
        return response.Snapshot is { Text: not null, Revision: >= 0 } snapshot ? snapshot : throw new IOException(L10n.Text("SnapshotFailed"));
    }

    internal Task SetAppearanceAsync(bool dark)
    {
        SetBackground(dark);
        return SendAsync(new JsonObject { ["method"] = "setAppearance", ["dark"] = dark });
    }

    private void SetBackground(bool dark) => Control.DefaultBackgroundColor = dark
        ? Color.FromArgb(255, 30, 30, 30) : Color.FromArgb(255, 255, 255, 255);

    private async Task<ResponseMessage> SendAsync(JsonObject request)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (failure is not null) throw new IOException(L10n.Text("EditorFailed"), failure);
        int id = ++requestID;
        var completion = new TaskCompletionSource<ResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending.Add(id, completion);
        request["requestId"] = id;
        try
        {
            Control.CoreWebView2.PostWebMessageAsJson(request.ToJsonString());
            return await completion.Task.WaitAsync(TimeSpan.FromSeconds(request["method"]?.GetValue<string>() == "exportHTML" ? 90 : 20));
        }
        finally { pending.Remove(id); }
    }

    private void Fail(Exception error)
    {
        failure = error;
        pageReady.TrySetException(error);
        foreach (var completion in pending.Values) completion.TrySetException(error);
        pending.Clear();
    }

    public void Dispose()
    {
        disposed = true;
        Fail(new ObjectDisposedException(nameof(EditorSession)));
        Control.Close();
    }
}
