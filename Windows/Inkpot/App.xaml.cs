using Microsoft.UI.Xaml;

namespace Inkpot;

public partial class App : Application
{
    private MainWindow? window;
    public static readonly System.Diagnostics.Stopwatch StartupClock = System.Diagnostics.Stopwatch.StartNew();

    public App() => InitializeComponent();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new MainWindow(Environment.GetCommandLineArgs().Skip(1).ToArray());
        window.Activate();
    }
}
