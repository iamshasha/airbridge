using System.Collections.Concurrent;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using AirBridge.Engine;
using AirBridge.Net;
using AirBridge.Protocol;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Controls;

namespace AirBridge.App;

/// <summary>App preferences that only concern the Windows shell (not the protocol).</summary>
public sealed class AppSettings
{
    /// <summary>Closing the window keeps AirBridge in the notification area, still receiving.</summary>
    public bool KeepRunningInBackground { get; set; } = true;
    public bool OpenAtSignIn { get; set; }
    public bool AirDrop { get; set; }
    public string AirDropInterface { get; set; } = "wlan1";
    /// <summary>Check GitHub Releases once a day at launch.</summary>
    public bool CheckForUpdates { get; set; } = true;
    public DateTimeOffset? LastUpdateCheck { get; set; }
}

/// <summary>
/// App-wide state: owns the engine and discovery, and mirrors engine state into UI-thread collections.
/// Collections are updated in place by id so list rows keep their identity (no flashing on refresh).
/// </summary>
public sealed class AppState
{
    public static AppState Current { get; } = new();

    public Node Node { get; }
    public AppSettings AppSettings { get; }
    public ObservableCollection<PeerItem> Peers { get; } = [];
    public ObservableCollection<TransferItem> Transfers { get; } = [];
    public ObservableCollection<ReceivedText> Inbox { get; } = [];
    public AdapterCapabilities Capabilities { get; private set; } = new();
    public AirDropBridge? AirDrop { get; private set; }

    /// <summary>Banner shown inside the window (title, severity).</summary>
    public event Action<string, InfoBarSeverity>? Toast;
    /// <summary>Shows a prompt dialog on the UI thread; set by MainWindow.</summary>
    public Func<PromptRequest, Task<bool>>? ShowPrompt { get; set; }
    public event Action? CapabilitiesChanged;
    /// <summary>A notification asked to bring the window forward (optionally to a page).</summary>
    public event Action<string?>? ShowWindowRequested;

    readonly Store _store;
    DispatcherQueue? _ui;
    Mdns? _mdns;
    BluetoothService? _bluetooth;
    readonly SemaphoreSlim _promptGate = new(1, 1);
    readonly ConcurrentDictionary<string, (PromptRequest Request, TaskCompletionSource<bool> Answer)> _pending = new();

    AppState()
    {
        _store = new Store(Store.DefaultDirectory);
        Node = new Node(_store, Environment.MachineName);
        AppSettings = _store.Load<AppSettings>("app-settings.json") ?? new AppSettings();
    }

    public void SaveAppSettings() => _store.Save(AppSettings, "app-settings.json");

    bool Foreground => App.Window?.IsForeground == true;

    public async Task StartAsync(DispatcherQueue ui)
    {
        _ui = ui;
        Notifications.Invoked += args => OnUi(() => OnNotificationInvoked(args));
        Node.PromptHandler = async request =>
        {
            // Answerable from the in-app dialog or from the notification, whichever comes first.
            var id = Guid.NewGuid().ToString("N");
            var answer = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            _pending[id] = (request, answer);
            OnUi(() =>
            {
                if (Foreground) _ = ShowPendingAsync(id);
                else Notifications.Prompt(id, request);
            });
            try { return await answer.Task.ConfigureAwait(false); }
            finally
            {
                _pending.TryRemove(id, out _);
                Notifications.Remove(id);
            }
        };
        Node.PeersChanged += () => OnUi(SyncPeers);
        Node.TrustChanged += () => OnUi(SyncPeers);
        Node.TransferAdded += t => OnUi(() => Transfers.Insert(0, new TransferItem(t, ui)));
        Node.TransferFinished += t => OnUi(() => OnTransferFinished(t));
        Node.TextReceived += (text, toClipboard) => OnUi(() =>
        {
            Inbox.Insert(0, text);
            if (toClipboard) CopyText(text.Text);
            if (Foreground)
            {
                Microsoft.UI.Xaml.ElementSoundPlayer.Play(Microsoft.UI.Xaml.ElementSoundKind.Show);
                Toast?.Invoke($"Text from {text.From}", InfoBarSeverity.Informational);
            }
            else Notifications.Text(text, toClipboard);
        });
        Node.UnpairedByPeer += name => OnUi(() => Announce($"{name} unpaired this PC", "Pair again to send automatically.", InfoBarSeverity.Warning));

        Node.Start();
        _mdns = new Mdns(Node);
        _mdns.Start();
        if (Node.Settings.BluetoothDiscovery) _bluetooth = await BluetoothService.StartAsync(Node);
        SyncPeers();
        await RefreshCapabilitiesAsync();
        if (AppSettings.AirDrop) await SetAirDropAsync(true);
    }

    void OnUi(Action action) => _ui?.TryEnqueue(() => action());

    // MARK: prompts

    async Task ShowPendingAsync(string id)
    {
        await _promptGate.WaitAsync();
        try
        {
            if (!_pending.TryGetValue(id, out var pending) || pending.Answer.Task.IsCompleted || ShowPrompt is null) return;
            Notifications.Remove(id);
            pending.Answer.TrySetResult(await ShowPrompt(pending.Request));
        }
        finally { _promptGate.Release(); }
    }

    /// <summary>When the window comes forward, requests that were only notified get their dialog.</summary>
    public void OnWindowForeground()
    {
        foreach (var id in _pending.Keys) _ = ShowPendingAsync(id);
    }

    void OnNotificationInvoked(IDictionary<string, string> args)
    {
        var action = args.TryGetValue("action", out var a) ? a : "show";
        var id = args.TryGetValue("id", out var i) ? i : null;
        var path = args.TryGetValue("path", out var p) ? p : null;
        switch (action)
        {
            case "accept" or "decline" when id is not null && _pending.TryGetValue(id, out var pending):
                pending.Answer.TrySetResult(action == "accept");
                break;
            case "prompt":
                ShowWindowRequested?.Invoke(null);
                if (id is not null) _ = ShowPendingAsync(id);
                break;
            case "open" when path is not null && (File.Exists(path) || Directory.Exists(path)):
                Preview.Open(path);
                break;
            case "reveal" when path is not null:
                Preview.Reveal(path);
                break;
            case "copy" when id is not null && Inbox.FirstOrDefault(t => t.Id.ToString() == id) is { } text:
                CopyText(text.Text);
                break;
            case "transfers" or "received":
                ShowWindowRequested?.Invoke(action);
                break;
            default:
                ShowWindowRequested?.Invoke(null);
                break;
        }
    }

    static void CopyText(string text)
    {
        var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
        package.SetText(text);
        Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
    }

    // MARK: peers

    void SyncPeers()
    {
        var latest = Node.Peers;
        // Remove gone, update existing in place, insert new at their sorted position.
        for (var i = Peers.Count - 1; i >= 0; i--)
            if (latest.All(p => p.Id != Peers[i].Id)) Peers.RemoveAt(i);
        for (var i = 0; i < latest.Count; i++)
        {
            var peer = latest[i];
            var existing = Peers.FirstOrDefault(p => p.Id == peer.Id);
            if (existing is null) Peers.Insert(Math.Min(i, Peers.Count), new PeerItem(peer, Node.IsTrusted(peer)));
            else
            {
                existing.Update(peer, Node.IsTrusted(peer));
                var at = Peers.IndexOf(existing);
                if (at != i && i < Peers.Count) Peers.Move(at, i);
            }
        }
    }

    // MARK: feedback

    void OnTransferFinished(TransferInfo t)
    {
        if (t.State == TransferState.Done && t.Direction == TransferDirection.Incoming && !Foreground)
        {
            _ = Notifications.ReceivedAsync(t);
            return;
        }
        switch (t.State)
        {
            case TransferState.Done when t.Direction == TransferDirection.Incoming:
                Announce($"Received {t.Title}", $"From {t.PeerName}", InfoBarSeverity.Success);
                break;
            case TransferState.Done:
                Announce($"Sent to {t.PeerName}", t.Title, InfoBarSeverity.Success);
                break;
            case TransferState.Declined:
                Announce($"{t.PeerName} declined", t.Title, InfoBarSeverity.Warning);
                break;
            case TransferState.Failed:
                Announce("Transfer failed", $"{t.Title}: {t.Error}", InfoBarSeverity.Error);
                break;
        }
    }

    /// <summary>Banner when the window is in front, a Windows notification (with sound) when it isn't.</summary>
    public void Announce(string title, string body, InfoBarSeverity severity)
    {
        if (Foreground)
        {
            Microsoft.UI.Xaml.ElementSoundPlayer.Play(severity == InfoBarSeverity.Error ? Microsoft.UI.Xaml.ElementSoundKind.Hide : Microsoft.UI.Xaml.ElementSoundKind.Show);
            Toast?.Invoke(title, severity);
        }
        else Notifications.Simple(title, body);
    }

    public void ReportError(string context, Exception e) =>
        Announce(context, e is AirBridgeException { Kind: AirBridgeError.Declined } ? "The other device declined." : e.Message,
            e is AirBridgeException { Kind: AirBridgeError.Declined } ? InfoBarSeverity.Warning : InfoBarSeverity.Error);

    // MARK: settings that need side effects

    public async Task SetBluetoothAsync(bool on)
    {
        Node.Settings.BluetoothDiscovery = on;
        Node.SaveSettings();
        if (on && _bluetooth is null) _bluetooth = await BluetoothService.StartAsync(Node);
        if (!on && _bluetooth is not null) { _bluetooth.Dispose(); _bluetooth = null; }
        await RefreshCapabilitiesAsync();
    }

    public async Task RefreshCapabilitiesAsync()
    {
        var (state, le) = await BluetoothService.ProbeAsync();
        Capabilities = await AdapterCapabilities.ProbeAsync(state, le);
        CapabilitiesChanged?.Invoke();
    }

    public async Task SetAirDropAsync(bool on, string? wifiInterface = null)
    {
        if (AirDrop is not null) { await AirDrop.DisposeAsync(); AirDrop = null; }
        AppSettings.AirDrop = on;
        if (wifiInterface is not null) AppSettings.AirDropInterface = wifiInterface;
        SaveAppSettings();
        if (!on) return;
        AirDrop = new AirDropBridge(Node, new AirDropBridge.Options(
            Path.Combine(Node.Settings.DownloadFolder, "AirDrop"), Node.Settings.DeviceName, AppSettings.AirDropInterface));
        AirDrop.Start();
    }

    /// <summary>Start minimized to the notification area when the user signs in.</summary>
    public void SetOpenAtSignIn(bool on)
    {
        AppSettings.OpenAtSignIn = on;
        SaveAppSettings();
        using var run = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if (on) run.SetValue("AirBridge", $"\"{Environment.ProcessPath}\" --background");
        else run.DeleteValue("AirBridge", throwOnMissingValue: false);
    }
}

public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    protected void Raise([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name);
        return true;
    }
}

public sealed class PeerItem : Observable
{
    public string Id { get; }
    public Peer Peer { get; private set; }
    string _name = "", _subtitle = "", _glyph = "";
    bool _trusted, _online;

    public string Name { get => _name; private set => Set(ref _name, value); }
    public string Subtitle { get => _subtitle; private set => Set(ref _subtitle, value); }
    public string Glyph { get => _glyph; private set => Set(ref _glyph, value); }
    public bool IsTrusted { get => _trusted; private set { if (Set(ref _trusted, value)) Raise(nameof(TrustedVisibility)); } }
    public bool IsOnline { get => _online; private set { if (Set(ref _online, value)) Raise(nameof(RowOpacity)); } }
    public bool IsAirDrop => Peer.Platform == "airdrop";
    public double RowOpacity => IsOnline ? 1 : 0.55;
    public Microsoft.UI.Xaml.Visibility TrustedVisibility => IsTrusted ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;

    public PeerItem(Peer peer, bool trusted)
    {
        Id = peer.Id;
        Peer = peer;
        Update(peer, trusted);
    }

    public void Update(Peer peer, bool trusted)
    {
        Peer = peer;
        Name = peer.Name;
        Glyph = GlyphFor(peer.Platform);
        IsTrusted = trusted;
        IsOnline = peer.IsOnline;
        Subtitle = !peer.IsOnline ? "Not nearby"
            : string.Join(", ", peer.Sources.Where(s => s != DiscoverySource.Trusted).Select(Label));
    }

    public static string GlyphFor(string platform) => platform switch
    {
        "ios" => "",      // Cell phone
        "win" => "",      // PC
        "airdrop" => "",  // Wireless
        _ => "",          // Laptop
    };

    public static string Label(DiscoverySource s) => s switch
    {
        DiscoverySource.Lan => "Wi-Fi/LAN",
        DiscoverySource.PeerToPeer => "Peer-to-peer Wi-Fi",
        DiscoverySource.Bluetooth => "Bluetooth",
        DiscoverySource.Manual => "Added by address",
        DiscoverySource.AirDrop => "AirDrop",
        _ => "Last known address",
    };
}

/// <summary>UI-thread mirror of a <see cref="TransferInfo"/> (whose events fire on background threads).</summary>
public sealed class TransferItem : Observable
{
    public TransferInfo Info { get; }

    public TransferItem(TransferInfo info, DispatcherQueue ui)
    {
        Info = info;
        info.PropertyChanged += (_, _) => ui.TryEnqueue(() =>
        {
            Raise(nameof(Percent));
            Raise(nameof(Status));
            Raise(nameof(IsActive));
            Raise(nameof(Glyph));
            Raise(nameof(CanReveal));
            if (CanReveal && _thumbnail is null && !_loadingThumbnail) _ = LoadThumbnailAsync();
        });
    }

    Microsoft.UI.Xaml.Media.ImageSource? _thumbnail;
    bool _loadingThumbnail;

    /// <summary>Windows thumbnail of what arrived (photo, document page, folder icon).</summary>
    public Microsoft.UI.Xaml.Media.ImageSource? Thumbnail { get => _thumbnail; private set { _thumbnail = value; Raise(); Raise(nameof(GlyphVisibility)); } }
    public Microsoft.UI.Xaml.Visibility GlyphVisibility => _thumbnail is null ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
    public string? PreviewPath => CanReveal && Info.SavedPaths is [var only] && File.Exists(only) ? only : null;

    async Task LoadThumbnailAsync()
    {
        _loadingThumbnail = true;
        if (Info.Direction == TransferDirection.Incoming && Info.SavedPaths is [var path, ..])
            Thumbnail = await Preview.ThumbnailAsync(path);
        Raise(nameof(PreviewPath));
    }

    public string Title => Info.Title;
    public double Percent => Info.Fraction * 100;
    public bool IsActive => Info.State == TransferState.Active;
    public bool CanReveal => Info.State == TransferState.Done && Info.SavedPaths.Count > 0;
    public string Glyph => Info.State switch
    {
        TransferState.Done => "",       // Completed
        TransferState.Failed => "",     // Error
        TransferState.Declined => "",   // Cancel
        _ => Info.Direction == TransferDirection.Incoming ? "" : "", // Download / Upload
    };

    public string Status
    {
        get
        {
            var who = $"{(Info.Direction == TransferDirection.Outgoing ? "To" : "From")} {Info.PeerName}";
            return Info.State switch
            {
                TransferState.Connecting => $"{who}, connecting",
                TransferState.WaitingForAcceptance => Info.PeerName == "Link recipient" ? "Waiting for the link to be opened" : $"{who}, waiting for them to accept",
                TransferState.Active => $"{who}, {Info.Fraction:P0} at {AppState.Current.Node.Settings.SpeedUnit.Format(Info.BytesPerSecond)}",
                TransferState.Done => $"{who}, {Format.Bytes(Info.Total)} at {AppState.Current.Node.Settings.SpeedUnit.Format(Info.AverageBytesPerSecond)}",
                TransferState.Declined => $"{who}, declined",
                _ => $"{who}, failed: {Info.Error}",
            };
        }
    }
}
