using Microsoft.UI.Xaml;
using Inkpot.Storage;

namespace Inkpot;

public partial class App : Application
{
    internal static readonly List<MainWindow> Windows = [];
    internal static bool IsSmoke => Environment.GetCommandLineArgs().Contains("--smoke-report");
    internal static readonly AppState Data = new(Environment.GetEnvironmentVariable("INKPOT_DATA_DIRECTORY")
        ?? (IsSmoke ? Path.Combine(Path.GetTempPath(), "InkpotSmoke", Guid.NewGuid().ToString("N"))
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Inkpot")));
    internal static readonly Preferences Preferences = Data.LoadPreferences();
    internal static string Version => typeof(App).Assembly.GetName().Version is { } version ? $"{version.Major}.{version.Minor}.{version.Build}" : "0.1.0";
    private static SettingsWindow? settings;
    public static readonly System.Diagnostics.Stopwatch StartupClock = System.Diagnostics.Stopwatch.StartNew();

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, args) => RecordFailure(args.Exception, args.Message);
        AppDomain.CurrentDomain.UnhandledException += (_, args) => RecordFailure(args.ExceptionObject as Exception, "AppDomain.UnhandledException");
    }

    internal static void RecordFailure(Exception? error, string context)
    {
        try
        {
            string folder = Path.Combine(Data.DirectoryPath, "Logs");
            Directory.CreateDirectory(folder);
            File.AppendAllText(Path.Combine(folder, "crash.log"), $"{DateTimeOffset.Now:O} {context}\n{error}\n\n");
        }
        catch { /* Logging must not replace the original failure. */ }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        string[] arguments = Environment.GetCommandLineArgs().Skip(1).ToArray();
        var saved = !IsSmoke && arguments.Length == 0 && Preferences.RestoreSession ? Data.LoadSession() : [];
        if (saved.Count == 0) OpenWindow(arguments);
        else foreach (var window in saved) OpenWindow([], window);
    }

    internal static MainWindow OpenWindow(string[]? arguments = null, SavedWindow? saved = null)
    {
        var window = new MainWindow(arguments ?? [], saved);
        Windows.Add(window);
        window.Closed += (_, _) =>
        {
            Windows.Remove(window);
            if (Windows.Count == 0) { settings?.Close(); settings = null; }
        };
        window.Activate();
        return window;
    }
    internal static void SaveSession(MainWindow closing, SavedWindow state)
    {
        if (IsSmoke) return;
        Data.SaveSession(Windows.Select(window => window == closing ? state : window.CaptureSession()).ToList());
    }
    internal static void ShowSettings(bool about = false, int? pane = null)
    {
        if (settings is null) { settings = new SettingsWindow(); settings.Closed += (_, _) => settings = null; }
        settings.SelectPane(pane ?? (about ? 3 : 0)); settings.Activate();
    }
    internal static void CloseSettings() { settings?.Close(); settings = null; }
    internal static void ValidateSettingsLayout() => settings?.ValidateVisiblePage();
    internal static async Task PreferencesChangedAsync()
    {
        Data.SavePreferences(Preferences);
        foreach (var window in Windows.ToArray()) await window.ApplyPreferencesAsync();
    }
}
