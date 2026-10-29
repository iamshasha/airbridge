using AirBridge.Engine;
using AirBridge.App.Pages;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;

namespace AirBridge.App;

public sealed partial class MainWindow : Window
{
    readonly DispatcherTimer _bannerTimer = new() { Interval = TimeSpan.FromSeconds(3) };
    readonly DispatcherTimer _badgeTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    readonly TrayIcon _tray;
    int _seenInbox;
    bool _quitting;
    bool _toldAboutTray;

    public bool IsForeground { get; private set; } = true;
    public nint Hwnd => WinRT.Interop.WindowNative.GetWindowHandle(this);

    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1100, 720));
        if (AppWindow.Presenter is OverlappedPresenter p) { p.PreferredMinimumWidth = 760; p.PreferredMinimumHeight = 520; }
        Activated += (_, e) =>
        {
            IsForeground = e.WindowActivationState != WindowActivationState.Deactivated;
            if (IsForeground) AppState.Current.OnWindowForeground();
        };

        // Closing keeps AirBridge running in the notification area so it can still receive.
        _tray = new TrayIcon(Hwnd, Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"), ShowAndActivate, Quit);
        AppWindow.Closing += (_, e) =>
        {
            if (_quitting || !AppState.Current.AppSettings.KeepRunningInBackground) { _tray.Dispose(); return; }
            e.Cancel = true;
            AppWindow.Hide();
            IsForeground = false;
            if (!_toldAboutTray)
            {
                _toldAboutTray = true;
                Notifications.Simple("AirBridge is still running", "It keeps receiving in the background. Find it in the notification area, or quit from its menu.");
            }
        };
        _badgeTimer.Tick += (_, _) => UpdateBadges();
        _badgeTimer.Start();

        _bannerTimer.Tick += (_, _) => { Banner.IsOpen = false; _bannerTimer.Stop(); };
        var state = AppState.Current;
        state.Toast += ShowBanner;
        state.ShowPrompt = ShowPromptAsync;
        state.Transfers.CollectionChanged += (_, _) => UpdateBadges();
        state.Inbox.CollectionChanged += (_, _) => UpdateBadges();
        state.ShowWindowRequested += page =>
        {
            ShowAndActivate();
            if (page is "transfers" or "received")
                Nav.SelectedItem = Nav.MenuItems.OfType<NavigationViewItem>().First(i => (string)i.Tag == page);
        };
        ContentFrame.Navigate(typeof(DevicesPage));
    }

    public void StartHidden()
    {
        IsForeground = false;
        AppWindow.Hide();
    }

    public void ShowAndActivate()
    {
        AppWindow.Show();
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter) presenter.Restore();
        AppWindow.MoveInZOrderAtTop();
        Activate();
        IsForeground = true;
        AppState.Current.OnWindowForeground();
    }

    /// <summary>Quits so the updater script can replace the files.</summary>
    public void QuitForUpdate() => Quit();

    /// <summary>At launch, once a day: offer a newer release (a dialog when visible, a notification otherwise).</summary>
    public async Task CheckForUpdatesInBackgroundAsync()
    {
        var settings = AppState.Current.AppSettings;
        // Test hook (used by CI): AIRBRIDGE_UPDATE_TEST=1 installs whatever is newer, without any clicks.
        if (Environment.GetEnvironmentVariable("AIRBRIDGE_UPDATE_TEST") == "1")
        {
            if (await UpdateChecker.CheckAsync(UpdateChecker.CurrentVersion, Pages.UpdateDialog.Asset) is { DownloadUrl: not null } found)
                await Pages.UpdateDialog.DownloadAndRelaunchAsync(found, null);
            return;
        }
        if (!settings.CheckForUpdates || !UpdateChecker.IsDue(settings.LastUpdateCheck)) return;
        AppUpdate? update;
        try { update = await UpdateChecker.CheckAsync(UpdateChecker.CurrentVersion, Pages.UpdateDialog.Asset); }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or Protocol.AirBridgeException) { return; }
        settings.LastUpdateCheck = DateTimeOffset.Now;
        AppState.Current.SaveAppSettings();
        if (update is null) return;
        if (IsForeground && AppWindow.IsVisible)
        {
            try { await new Pages.UpdateDialog(update) { XamlRoot = Content.XamlRoot }.ShowAsync(); }
            catch (System.Runtime.InteropServices.COMException) { /* another dialog is open; Settings still offers it */ }
        }
        else Notifications.Simple($"AirBridge {update.Version} is available", "Open AirBridge and choose Settings › Check for updates to install it.");
    }

    void Quit()
    {
        _quitting = true;
        _tray.Dispose();
        Close();
        Application.Current.Exit();
    }

    void OnNavigate(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        var page = args.IsSettingsSelected ? typeof(SettingsPage) : (args.SelectedItem as NavigationViewItem)?.Tag switch
        {
            "transfers" => typeof(TransfersPage),
            "received" => typeof(ReceivedPage),
            _ => typeof(DevicesPage),
        };
        if (page == typeof(ReceivedPage)) _seenInbox = AppState.Current.Inbox.Count;
        ContentFrame.Navigate(page, null, new EntranceNavigationTransitionInfo());
        UpdateBadges();
    }

    void UpdateBadges()
    {
        var state = AppState.Current;
        var active = state.Transfers.Count(t => !t.Info.IsFinished);
        ActiveBadge.Value = active;
        ActiveBadge.Visibility = active > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (ContentFrame.CurrentSourcePageType == typeof(ReceivedPage)) _seenInbox = state.Inbox.Count;
        _seenInbox = Math.Min(_seenInbox, state.Inbox.Count);
        var unread = state.Inbox.Count - _seenInbox;
        InboxBadge.Value = unread;
        InboxBadge.Visibility = unread > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    void ShowBanner(string title, InfoBarSeverity severity)
    {
        Banner.Title = title;
        Banner.Severity = severity;
        Banner.IsOpen = true;
        _bannerTimer.Stop();
        _bannerTimer.Start();
    }

    /// <summary>Incoming file offers and pairing requests.</summary>
    async Task<bool> ShowPromptAsync(PromptRequest request)
    {
        var body = new StackPanel { Spacing = 12, MaxWidth = 420 };
        if (request.Kind == PromptKind.Pairing)
        {
            body.Children.Add(new TextBlock { Text = $"Check that {request.PeerName} shows the same code.", TextWrapping = TextWrapping.Wrap });
            body.Children.Add(new TextBlock
            {
                Text = $"{request.Code![..3]} {request.Code[3..]}",
                FontSize = 40,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                CharacterSpacing = 200,
                HorizontalAlignment = HorizontalAlignment.Center,
            });
            body.Children.Add(new TextBlock
            {
                Text = "Only pair if the codes match. Paired devices can send without asking.",
                TextWrapping = TextWrapping.Wrap,
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            });
        }
        else
        {
            var files = (request.Items ?? []).Where(i => !i.IsDirectory).ToList();
            var list = new StackPanel { Spacing = 4 };
            foreach (var f in files.Take(6))
            {
                var row = new Grid { ColumnSpacing = 12 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(new TextBlock { Text = f.Path, TextTrimming = TextTrimming.CharacterEllipsis });
                var size = new TextBlock { Text = Format.Bytes(f.Size), Opacity = 0.7 };
                Grid.SetColumn(size, 1);
                row.Children.Add(size);
                list.Children.Add(row);
            }
            if (files.Count > 6) list.Children.Add(new TextBlock { Text = $"and {files.Count - 6} more", Opacity = 0.7 });
            body.Children.Add(list);
            body.Children.Add(new TextBlock
            {
                Text = $"End-to-end encrypted. Unknown device, fingerprint {request.Fingerprint[..12]}…",
                TextWrapping = TextWrapping.Wrap,
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            });
        }

        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = request.Summary,
            Content = body,
            PrimaryButtonText = request.Kind == PromptKind.Pairing ? "Pair" : "Accept",
            CloseButtonText = request.Kind == PromptKind.Pairing ? "Don't pair" : "Decline",
            DefaultButton = ContentDialogButton.Primary,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }
}
