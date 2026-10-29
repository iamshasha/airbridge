using AirBridge.Engine;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace AirBridge.App.Pages;

public sealed partial class DevicesPage : Page
{
    public AppState State => AppState.Current;
    PeerItem? _selected;
    readonly DispatcherTimer _progressTimer = new() { Interval = TimeSpan.FromMilliseconds(200) };

    public DevicesPage()
    {
        InitializeComponent();
        State.Peers.CollectionChanged += (_, _) => UpdateEmptyState();
        State.Node.TrustChanged += () => DispatcherQueue.TryEnqueue(ShowSelected);
        _progressTimer.Tick += (_, _) => UpdateProgressRing();
        _progressTimer.Start();
        Unloaded += (_, _) => _progressTimer.Stop();
        UpdateEmptyState();
    }

    void UpdateEmptyState() => SearchingHint.Visibility = State.Peers.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

    void OnSelectDevice(object sender, SelectionChangedEventArgs e)
    {
        _selected = DeviceList.SelectedItem as PeerItem;
        ShowSelected();
    }

    Peer? SelectedPeer => _selected is null ? null : State.Node.FindPeer(_selected.Id) ?? _selected.Peer;

    void ShowSelected()
    {
        if (_selected is not { } item || SelectedPeer is not { } peer)
        {
            Detail.Visibility = Visibility.Collapsed;
            EmptyDetail.Visibility = Visibility.Visible;
            return;
        }
        EmptyDetail.Visibility = Visibility.Collapsed;
        Detail.Visibility = Visibility.Visible;

        var trusted = State.Node.IsTrusted(peer);
        var airDrop = item.IsAirDrop;
        AvatarGlyph.Glyph = PeerItem.GlyphFor(peer.Platform);
        DeviceName.Text = peer.Name;
        DeviceStatus.Text = item.Subtitle;
        TrustedLabel.Visibility = trusted ? Visibility.Visible : Visibility.Collapsed;
        DropTitle.Text = $"Drop files here to send to {peer.Name}";
        AcceptHint.Text = airDrop ? "Sent with AirDrop. The Apple device will be asked to accept."
            : trusted ? $"{peer.Name} accepts automatically. End-to-end encrypted."
            : $"{peer.Name} will be asked to accept. End-to-end encrypted.";
        ChooseFolderButton.Visibility = ClipboardButton.Visibility = TextPanel.Visibility = airDrop ? Visibility.Collapsed : Visibility.Visible;
        PairPanel.Visibility = !trusted && !airDrop ? Visibility.Visible : Visibility.Collapsed;
        TrustPanel.Visibility = trusted ? Visibility.Visible : Visibility.Collapsed;
        FingerprintText.Text = peer.Fingerprint is { } fp ? $"Fingerprint {fp}" : "";

        if (trusted && State.Node.Trusted.TryGetValue(peer.Id, out var device))
        {
            _updatingToggles = true;
            AutoAcceptSwitch.IsOn = device.AutoAccept;
            BrowseSwitch.IsOn = device.AllowBrowse;
            ClipboardSwitch.IsOn = device.AutoClipboard;
            _updatingToggles = false;
            SyncList.Children.Clear();
            foreach (var rule in State.Node.Settings.SyncRules.Where(r => r.DeviceId == peer.Id))
            {
                var row = new Grid { ColumnSpacing = 8 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(new TextBlock { Text = rule.Folder, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center });
                var remove = new Button { Content = "Stop", Tag = rule.Id };
                remove.Click += (_, _) => { State.Node.RemoveSyncRule(rule.Id); ShowSelected(); };
                Grid.SetColumn(remove, 1);
                row.Children.Add(remove);
                SyncList.Children.Add(row);
            }
        }
    }

    /// <summary>The ring around the device fills with the progress of transfers to or from it.</summary>
    void UpdateProgressRing()
    {
        if (_selected is null) return;
        var active = State.Transfers.Where(t => t.Info.PeerName == _selected.Name && !t.Info.IsFinished && t.Info.Total > 0).ToList();
        if (active.Count == 0)
        {
            SendRing.Visibility = Visibility.Collapsed;
            return;
        }
        SendRing.Visibility = Visibility.Visible;
        SendRing.Value = active.Sum(t => t.Info.Bytes) * 100.0 / active.Sum(t => t.Info.Total);
    }

    // MARK: sending

    async Task SendAsync(IReadOnlyList<string> paths)
    {
        if (SelectedPeer is not { } peer || paths.Count == 0) return;
        try
        {
            if (_selected!.IsAirDrop)
            {
                if (State.AirDrop is not { } bridge) throw new InvalidOperationException("Turn on AirDrop in Settings first.");
                foreach (var p in paths.Where(File.Exists)) await bridge.SendAsync(peer, p);
            }
            else await Task.Run(() => State.Node.SendAsync(paths, peer));
        }
        catch (Exception e) when (e is Protocol.AirBridgeException or IOException or InvalidOperationException or UnauthorizedAccessException)
        {
            if (e is not Protocol.AirBridgeException { Kind: Protocol.AirBridgeError.Declined }) State.ReportError($"Couldn't send to {peer.Name}", e);
        }
    }

    void OnDragOver(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.Caption = SelectedPeer is { } p ? $"Send to {p.Name}" : "Send";
        DropFill.Opacity = 0.12;
        DropOutline.Stroke = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["AccentFillColorDefaultBrush"];
    }

    void OnDragLeave(object sender, DragEventArgs e) => ResetDropZone();

    void ResetDropZone()
    {
        DropFill.Opacity = 0;
        DropOutline.Stroke = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["ControlStrongStrokeColorDefaultBrush"];
    }

    async void OnDrop(object sender, DragEventArgs e)
    {
        ResetDropZone();
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        ElementSoundPlayer.Play(ElementSoundKind.Invoke);
        var items = await e.DataView.GetStorageItemsAsync();
        await SendAsync(items.Select(i => i.Path).Where(p => !string.IsNullOrEmpty(p)).ToList());
    }

    async void OnChooseFiles(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, App.Window!.Hwnd);
        var files = await picker.PickMultipleFilesAsync();
        if (files is { Count: > 0 }) await SendAsync(files.Select(f => f.Path).ToList());
    }

    async void OnChooseFolder(object sender, RoutedEventArgs e)
    {
        if (await PickFolderAsync() is { } folder) await SendAsync([folder.Path]);
    }

    internal static async Task<StorageFolder?> PickFolderAsync()
    {
        var picker = new FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, App.Window!.Hwnd);
        return await picker.PickSingleFolderAsync();
    }

    async void OnSendClipboard(object sender, RoutedEventArgs e)
    {
        var content = Clipboard.GetContent();
        if (content.Contains(StandardDataFormats.StorageItems))
            await SendAsync((await content.GetStorageItemsAsync()).Select(i => i.Path).ToList());
        else if (content.Contains(StandardDataFormats.Text))
            await SendTextAsync(await content.GetTextAsync());
        else State.Announce("The clipboard is empty", "Copy some text or files first.", InfoBarSeverity.Warning);
    }

    async Task SendTextAsync(string text)
    {
        if (SelectedPeer is not { } peer || string.IsNullOrWhiteSpace(text)) return;
        try
        {
            await Task.Run(() => State.Node.SendTextAsync(text.Trim(), peer));
            State.Announce($"Sent to {peer.Name}", text, InfoBarSeverity.Success);
        }
        catch (Protocol.AirBridgeException ex) { State.ReportError($"Couldn't send to {peer.Name}", ex); }
    }

    async void OnSendText(object sender, RoutedEventArgs e)
    {
        var text = MessageBox.Text;
        MessageBox.Text = "";
        await SendTextAsync(text);
    }

    void OnMessageKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; OnSendText(sender, e); }
    }

    // MARK: pairing and trust

    async void OnPair(object sender, RoutedEventArgs e)
    {
        if (SelectedPeer is not { } peer) return;
        var code = new TextBlock { FontSize = 40, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, CharacterSpacing = 200, HorizontalAlignment = HorizontalAlignment.Center };
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = $"Pairing with {peer.Name}",
            Content = new StackPanel
            {
                Spacing = 12,
                Children = { new TextBlock { Text = $"Confirm on {peer.Name} that it shows this code.", TextWrapping = TextWrapping.Wrap }, code, new ProgressBar { IsIndeterminate = true } },
            },
            CloseButtonText = "Cancel",
        };
        _ = dialog.ShowAsync();
        try
        {
            await State.Node.PairAsync(peer, c => DispatcherQueue.TryEnqueue(() => code.Text = $"{c[..3]} {c[3..]}"));
            dialog.Hide();
            State.Announce($"Paired with {peer.Name}", "Transfers between you are now automatic.", InfoBarSeverity.Success);
            ShowSelected();
        }
        catch (Protocol.AirBridgeException ex)
        {
            dialog.Hide();
            State.ReportError($"Couldn't pair with {peer.Name}", ex);
        }
    }

    bool _updatingToggles;

    void OnTrustToggle(object sender, RoutedEventArgs e)
    {
        if (_updatingToggles || _selected is null || !State.Node.Trusted.TryGetValue(_selected.Id, out var device)) return;
        device.AutoAccept = AutoAcceptSwitch.IsOn;
        device.AllowBrowse = BrowseSwitch.IsOn;
        device.AutoClipboard = ClipboardSwitch.IsOn;
        State.Node.UpdateTrusted(device);
    }

    async void OnAddSyncFolder(object sender, RoutedEventArgs e)
    {
        if (_selected is null || await PickFolderAsync() is not { } folder) return;
        State.Node.AddSyncRule(folder.Path, _selected.Id);
        ShowSelected();
    }

    void OnUnpair(object sender, RoutedEventArgs e)
    {
        UnpairFlyout.Hide();
        if (_selected is null) return;
        State.Node.Unpair(_selected.Id);
        State.Announce($"Unpaired {_selected.Name}", "", InfoBarSeverity.Informational);
        ShowSelected();
    }

    async void OnBrowse(object sender, RoutedEventArgs e)
    {
        if (SelectedPeer is not { } peer) return;
        var dialog = new BrowseDialog(peer) { XamlRoot = XamlRoot };
        await dialog.ShowAsync();
    }

    async void OnSpeedTest(object sender, RoutedEventArgs e)
    {
        if (SelectedPeer is not { } peer) return;
        await new SpeedTestDialog(peer) { XamlRoot = XamlRoot }.ShowAsync();
    }

    // MARK: add by address / open link

    async void OnAddByAddress(object sender, RoutedEventArgs e)
    {
        var box = new TextBox { PlaceholderText = "100.101.102.103:47820" };
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Add a device by address",
            Content = new StackPanel
            {
                Spacing = 8,
                Children = { new TextBlock { Text = "Use an IP address or hostname, such as a Tailscale address. The default port is 47820.", TextWrapping = TextWrapping.Wrap }, box },
            },
            PrimaryButtonText = "Connect",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || box.Text.Trim() is not { Length: > 0 } address) return;
        var parts = address.Split(':');
        var host = parts.Length == 2 ? parts[0] : address;
        var port = parts.Length == 2 && int.TryParse(parts[1], out var p) ? p : 47820;
        try
        {
            var peer = await Task.Run(() => State.Node.AddManualPeerAsync(host, port));
            DeviceList.SelectedItem = State.Peers.FirstOrDefault(i => i.Id == peer.Id);
        }
        catch (Protocol.AirBridgeException ex) { State.ReportError($"Couldn't connect to {address}", ex); }
    }

    async void OnOpenLink(object sender, RoutedEventArgs e)
    {
        var box = new TextBox { PlaceholderText = "https://…/r/…" };
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Receive from a link",
            Content = new StackPanel { Spacing = 8, Children = { new TextBlock { Text = "Paste an AirBridge link someone shared with you.", TextWrapping = TextWrapping.Wrap }, box } },
            PrimaryButtonText = "Receive",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || !Uri.TryCreate(box.Text.Trim(), UriKind.Absolute, out var link)) return;
        try { await Task.Run(() => State.Node.OpenLinkAsync(link)); }
        catch (Protocol.AirBridgeException ex) { State.ReportError("Couldn't open the link", ex); }
    }
}
