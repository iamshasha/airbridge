using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace AirBridge.App;

/// <summary>
/// Single instance: opening AirBridge again while it runs in the notification area brings the existing
/// window back instead of starting a second copy (which would also fight over the listening port).
/// </summary>
public static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        var main = AppInstance.FindOrRegisterForKey("AirBridge.Main");
        if (!main.IsCurrent)
        {
            // Hand this launch to the running copy, then exit.
            var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
            Task.Run(() => main.RedirectActivationToAsync(activation).AsTask()).Wait();
            return 0;
        }
        main.Activated += (_, _) =>
            App.Window?.DispatcherQueue.TryEnqueue(() => App.Window.ShowAndActivate());

        Application.Start(_ =>
        {
            SynchronizationContext.SetSynchronizationContext(
                new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App();
        });
        return 0;
    }
}
