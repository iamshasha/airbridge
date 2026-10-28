using System.Runtime.InteropServices;

namespace AirBridge.App;

/// <summary>
/// Turns a startup crash into a message box and a log file instead of a window that never appears.
/// Log: %LOCALAPPDATA%\AirBridge\crash.log
/// </summary>
internal static class CrashReporter
{
    public static string LogPath { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AirBridge", "crash.log");

    static int _shown;

    public static void Install()
    {
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Report(e.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, e) => { Log(e.Exception); e.SetObserved(); };
    }

    public static void Log(Exception? error)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
            File.AppendAllText(LogPath, $"[{DateTime.Now:O}] {error}\n\n");
        }
        catch (Exception) { }
    }

    public static void Report(Exception? error)
    {
        Log(error);
        if (Interlocked.Exchange(ref _shown, 1) == 1) return;
        MessageBoxW(0, $"AirBridge ran into a problem and has to close.\n\n{error?.Message}\n\nDetails were saved to {LogPath}",
            "AirBridge", 0x10 /* MB_ICONERROR */);
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int MessageBoxW(nint hwnd, string text, string caption, uint type);
}
