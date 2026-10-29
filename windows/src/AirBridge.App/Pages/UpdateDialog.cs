using System.Diagnostics;
using System.IO.Compression;
using System.Runtime.InteropServices;
using AirBridge.Engine;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AirBridge.App.Pages;

/// <summary>
/// Check for updates, show what's new, and install: download the zip for this PC's architecture, then a small
/// PowerShell script waits for AirBridge to quit, copies the new files over this folder and starts it again.
/// </summary>
public sealed class UpdateDialog : ContentDialog
{
    public static string Asset => RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "AirBridge-win-arm64.zip" : "AirBridge-win-x64.zip";

    readonly TextBlock _message = new() { TextWrapping = TextWrapping.Wrap };
    readonly TextBlock _notes = new() { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, Opacity = 0.85 };
    readonly ProgressBar _progress = new() { Maximum = 1, Visibility = Visibility.Collapsed };
    readonly ProgressRing _ring = new() { IsActive = true, Width = 32, Height = 32, HorizontalAlignment = HorizontalAlignment.Left };
    AppUpdate? _update;
    bool _busy;

    /// <param name="found">An update an automatic check already found; null checks now.</param>
    public UpdateDialog(AppUpdate? found = null)
    {
        Title = "Checking for updates";
        CloseButtonText = "Close";
        DefaultButton = ContentDialogButton.Primary;
        Content = new StackPanel
        {
            Spacing = 12,
            Width = 420,
            Children =
            {
                _ring,
                _message,
                _progress,
                new ScrollViewer { MaxHeight = 260, Content = _notes },
            },
        };
        PrimaryButtonClick += async (sender, args) =>
        {
            args.Cancel = true; // stay open to show progress
            if (_update is { } update) await InstallAsync(update);
        };
        Closing += (sender, args) => { if (_busy) args.Cancel = true; };
        Opened += async (sender, args) =>
        {
            if (found is not null) Show(found);
            else await CheckAsync();
        };
    }

    async Task CheckAsync()
    {
        try
        {
            var update = await UpdateChecker.CheckAsync(UpdateChecker.CurrentVersion, Asset);
            var state = AppState.Current;
            state.AppSettings.LastUpdateCheck = DateTimeOffset.Now;
            state.SaveAppSettings();
            if (update is null)
            {
                _ring.Visibility = Visibility.Collapsed;
                Title = "You're up to date";
                _message.Text = $"AirBridge {UpdateChecker.CurrentVersion} is the latest version.";
                ElementSoundPlayer.Play(ElementSoundKind.Show);
            }
            else Show(update);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or Protocol.AirBridgeException)
        {
            Fail($"Couldn't check for updates: {e.Message}");
        }
    }

    void Show(AppUpdate update)
    {
        _update = update;
        _ring.Visibility = Visibility.Collapsed;
        Title = $"AirBridge {update.Version} is available";
        _message.Text = $"You have {UpdateChecker.CurrentVersion}.";
        _notes.Text = PlainNotes(update.Notes);
        PrimaryButtonText = update.DownloadUrl is null ? "View release" : "Update and restart";
        CloseButtonText = "Later";
        ElementSoundPlayer.Play(ElementSoundKind.Show);
    }

    void Fail(string message)
    {
        _busy = false;
        _ring.Visibility = Visibility.Collapsed;
        _progress.Visibility = Visibility.Collapsed;
        Title = "Update didn't work";
        _message.Text = message;
        IsPrimaryButtonEnabled = _update is not null;
        PrimaryButtonText = "Try again";
        CloseButtonText = "Close";
    }

    async Task InstallAsync(AppUpdate update)
    {
        if (update.DownloadUrl is not { } url)
        {
            Process.Start(new ProcessStartInfo(update.PageUrl.ToString()) { UseShellExecute = true });
            Hide();
            return;
        }
        var target = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        if (!CanWrite(target))
        {
            Fail($"AirBridge can't write to {target}. Download the new version from the release page instead.");
            Process.Start(new ProcessStartInfo(update.PageUrl.ToString()) { UseShellExecute = true });
            return;
        }
        _busy = true;
        IsPrimaryButtonEnabled = false;
        CloseButtonText = "";
        Title = $"Downloading AirBridge {update.Version}";
        _notes.Text = "";
        _progress.Visibility = Visibility.Visible;
        try
        {
            await DownloadAndRelaunchAsync(update, new Progress<double>(f =>
            {
                _progress.Value = f;
                _message.Text = f < 1 ? $"{f:P0}" : "Installing. AirBridge restarts in a moment.";
                if (f >= 1) { Title = "Installing"; _progress.IsIndeterminate = true; }
            }));
        }
        catch (Exception e) when (e is HttpRequestException or IOException or InvalidDataException or UnauthorizedAccessException)
        {
            Fail($"Couldn't install the update: {e.Message}");
        }
    }

    /// <summary>Downloads and unpacks the update, then quits so the script can swap the files and restart.</summary>
    public static async Task DownloadAndRelaunchAsync(AppUpdate update, IProgress<double>? progress)
    {
        var target = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        var work = Path.Combine(Path.GetTempPath(), $"AirBridge-update-{Guid.NewGuid():N}");
        var zip = Path.Combine(work, "update.zip");
        var files = Path.Combine(work, "files");
        await UpdateChecker.DownloadAsync(update.DownloadUrl!, zip, progress);
        progress?.Report(1);
        await Task.Run(() => ZipFile.ExtractToDirectory(zip, files));
        if (!File.Exists(Path.Combine(files, "AirBridge.exe"))) throw new InvalidDataException("The download isn't an AirBridge build.");
        Relaunch(work, files, target);
    }

    static bool CanWrite(string folder)
    {
        try
        {
            var probe = Path.Combine(folder, $".write-test-{Guid.NewGuid():N}");
            File.WriteAllText(probe, "");
            File.Delete(probe);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
    }

    /// <summary>The script copies (never deletes), so other files someone keeps in this folder stay put.</summary>
    static void Relaunch(string work, string files, string target)
    {
        static string Q(string s) => "'" + s.Replace("'", "''", StringComparison.Ordinal) + "'";
        var script = Path.Combine(work, "update.ps1");
        File.WriteAllText(script, $"""
            Wait-Process -Id {Environment.ProcessId} -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 300
            robocopy {Q(files)} {Q(target)} /E /R:10 /W:1 /NFL /NDL /NJH /NJS | Out-Null
            $env:AIRBRIDGE_UPDATE_TEST = $null
            Start-Process {Q(Path.Combine(target, "AirBridge.exe"))}
            Start-Sleep -Seconds 2
            Remove-Item -Recurse -Force {Q(work)} -ErrorAction SilentlyContinue
            """);
        Process.Start(new ProcessStartInfo("powershell.exe", $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{script}\"")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
        });
        App.Window?.QuitForUpdate();
    }

    /// <summary>Release notes are Markdown; show them as plain text.</summary>
    static string PlainNotes(string markdown) => string.Join('\n', markdown.Split('\n').Select(line =>
        System.Text.RegularExpressions.Regex.Replace(line.TrimEnd('\r'), @"^#+\s*", "")
            .Replace("**", "", StringComparison.Ordinal).Replace("`", "", StringComparison.Ordinal))).Trim();
}
