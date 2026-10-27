using Microsoft.UI.Xaml;

namespace AirBridge.App;

public partial class App : Application
{
    public static MainWindow? Window { get; private set; }

    public App()
    {
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
    }
}
