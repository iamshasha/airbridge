using Microsoft.UI.Xaml;

namespace AirBridge.App;

public partial class App : Application
{
    public static MainWindow? Window { get; private set; }

    // Runs before InitializeComponent, so even a failure to load XAML gets reported.
    static App() => CrashReporter.Install();

    public App()
    {
        UnhandledException += (_, e) => CrashReporter.Report(e.Exception);
        InitializeComponent();
        // Windows UI sounds for invokes, focus moves and dialogs: the desktop counterpart of haptics.
        ElementSoundPlayer.State = ElementSoundPlayerState.On;
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        Notifications.Register();
        Window = new MainWindow();
        // Started at sign-in: stay in the notification area until opened.
        if (Environment.GetCommandLineArgs().Contains("--background")) Window.StartHidden();
        else Window.Activate();
        await AppState.Current.StartAsync(Window.DispatcherQueue);
        await Window.CheckForUpdatesInBackgroundAsync();
    }
}
