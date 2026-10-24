using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Windows.UI;

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
    internal double ReadyMilliseconds { get; private set; }
    internal long ReadyUnixMilliseconds { get; private set; }

    internal static Task<CoreWebView2Environment> CreateEnvironmentAsync()
    {
        try { CoreWebView2Environment.GetAvailableBrowserVersionString(); }
        catch (Exception error) { throw new WebView2RuntimeMissingException(error); }
        return CoreWebView2Environment.CreateWithOptionsAsync(
            browserExecutableFolder: null,
            userDataFolder: Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Inkpot", "WebView2"),
            options: null);
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
            await loaded.Task.WaitAsync(TimeSpan.FromSeconds(20));
        }
        await Control.EnsureCoreWebView2Async(await environment);
        var core = Control.CoreWebView2;
        core.SetVirtualHostNameToFolderMapping("editor.inkpot.local", Path.Combine(AppContext.BaseDirectory, "Editor"), CoreWebView2HostResourceAccessKind.DenyCors);
        // 第一期不读取图片，在本机返回失败，避免把文档路径发到网络。
        core.AddWebResourceRequestedFilter("https://images.inkpot.local/*", CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += (_, args) => args.Response = core.Environment.CreateWebResourceResponse(null, 404, "Not Found", "Content-Type: text/plain");
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
        return SendAsync(new JsonObject
        {
            ["method"] = "open", ["text"] = text, ["generation"] = generation,
            ["dark"] = dark, ["language"] = language,
            ["resources"] = new JsonObject { ["assetBase"] = "https://editor.inkpot.local/math/", ["imageBase"] = "https://images.inkpot.local/local/" },
        });
    }

    internal Task CommandAsync(string name) => SendAsync(new JsonObject { ["method"] = "command", ["name"] = name });
    internal Task PasteAsync(string text) => SendAsync(new JsonObject { ["method"] = "pastePlainText", ["text"] = text });

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
            return await completion.Task.WaitAsync(TimeSpan.FromSeconds(20));
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
