using AirBridge.Engine;
using AirBridge.Net;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AirBridge.App.Pages;

public sealed partial class SettingsPage : Page
{
    AppState State => AppState.Current;
    Settings S => State.Node.Settings;
    bool _loading = true;

    public SettingsPage()
    {
        InitializeComponent();
        NameBox.Text = S.DeviceName;
        PolicyBox.SelectedItem = PolicyBox.Items.OfType<ComboBoxItem>().First(i => (string)i.Tag == S.ReceivePolicy.ToString());
        BackgroundSwitch.IsOn = State.AppSettings.KeepRunningInBackground;
        SignInSwitch.IsOn = State.AppSettings.OpenAtSignIn;
        DownloadPath.Text = S.DownloadFolder;
        SharedPath.Text = S.SharedFolder ?? "Not shared";
        BluetoothSwitch.IsOn = S.BluetoothDiscovery;
        StreamsBox.Value = S.ParallelStreams;
        UnitButtons.SelectedIndex = S.SpeedUnit == SpeedUnit.Bits ? 1 : 0;
        RelayBox.Text = S.RelayUrl;
        AirDropSwitch.IsOn = State.AppSettings.AirDrop;
        AirDropInterfaceBox.Text = State.AppSettings.AirDropInterface;
        IdentityText.Text = $"This PC's fingerprint: {State.Node.Identity.Fingerprint}. Listening on port {State.Node.ListeningPort}.";
        State.CapabilitiesChanged += OnCapabilitiesChanged;
        Unloaded += (_, _) => State.CapabilitiesChanged -= OnCapabilitiesChanged;
        ShowCapabilities();
        ShowTrusted();
        _loading = false;
    }

    void Save() => State.Node.SaveSettings();

    void OnNameChanged(object sender, RoutedEventArgs e)
    {
        if (NameBox.Text.Trim() is not { Length: > 0 } name || name == S.DeviceName) return;
        S.DeviceName = name;
        Save();
    }

    void OnPolicyChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || PolicyBox.SelectedItem is not ComboBoxItem { Tag: string tag }) return;
        S.ReceivePolicy = Enum.Parse<ReceivePolicy>(tag);
        Save();
    }

    void OnBackgroundToggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        State.AppSettings.KeepRunningInBackground = BackgroundSwitch.IsOn;
        State.SaveAppSettings();
    }

    void OnSignInToggled(object sender, RoutedEventArgs e)
    {
        if (!_loading) State.SetOpenAtSignIn(SignInSwitch.IsOn);
    }

    async void OnChangeDownloads(object sender, RoutedEventArgs e)
    {
        if (await DevicesPage.PickFolderAsync() is not { } folder) return;
        S.DownloadFolder = folder.Path;
        DownloadPath.Text = folder.Path;
        Save();
    }

    async void OnChangeShared(object sender, RoutedEventArgs e)
    {
        if (await DevicesPage.PickFolderAsync() is not { } folder) return;
        S.SharedFolder = folder.Path;
        SharedPath.Text = folder.Path;
        Save();
    }

    void OnUnitChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        S.SpeedUnit = UnitButtons.SelectedIndex == 1 ? SpeedUnit.Bits : SpeedUnit.Bytes;
        Save();
    }

    async void OnBluetoothToggled(object sender, RoutedEventArgs e)
    {
        if (!_loading) await State.SetBluetoothAsync(BluetoothSwitch.IsOn);
    }

    void OnStreamsChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (_loading || double.IsNaN(args.NewValue)) return;
        S.ParallelStreams = (int)Math.Clamp(args.NewValue, 1, 8);
        Save();
    }

    void OnRelayChanged(object sender, RoutedEventArgs e)
    {
        S.RelayUrl = RelayBox.Text.Trim();
        Save();
    }

    async void OnAirDropToggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        var iface = AirDropInterfaceBox.Text.Trim() is { Length: > 0 } i ? i : "wlan1";
        if (AirDropSwitch.IsOn && State.Capabilities.AirDrop != AdapterCapabilities.AirDropStatus.Ready)
        {
            State.Announce("AirDrop isn't set up yet", "Run windows\\scripts\\setup-airdrop-wsl.ps1, then turn this on again.", InfoBarSeverity.Warning);
            AirDropSwitch.IsOn = false;
            return;
        }
        await State.SetAirDropAsync(AirDropSwitch.IsOn, iface);
        ShowCapabilities();
    }

    async void OnRefreshCapabilities(object sender, RoutedEventArgs e) => await State.RefreshCapabilitiesAsync();

    void OnCapabilitiesChanged() => DispatcherQueue.TryEnqueue(ShowCapabilities);

    void ShowCapabilities()
    {
        CapabilityList.Children.Clear();
        foreach (var (name, detail, ok) in State.Capabilities.Summary)
        {
            var row = new Grid { ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new FontIcon
            {
                Glyph = ok ? "" : "",
                FontSize = 14,
                Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources[ok ? "SystemFillColorSuccessBrush" : "TextFillColorSecondaryBrush"],
            });
            var label = new TextBlock { Text = name };
            Grid.SetColumn(label, 1);
            row.Children.Add(label);
            var value = new TextBlock { Text = detail, Opacity = 0.7, TextWrapping = TextWrapping.Wrap, MaxWidth = 320, TextAlignment = TextAlignment.Right };
            Grid.SetColumn(value, 2);
            row.Children.Add(value);
            CapabilityList.Children.Add(row);
        }
        AirDropStatus.Text = State.AirDrop?.Running == true ? "AirDrop is on." : State.Capabilities.AirDrop switch
        {
            AdapterCapabilities.AirDropStatus.Ready => "Ready to turn on.",
            AdapterCapabilities.AirDropStatus.NeedsAdapter => "WSL2 is ready. Attach a monitor-mode USB Wi-Fi adapter with usbipd.",
            _ => "Not set up on this PC.",
        };
    }

    void ShowTrusted()
    {
        TrustedList.Children.Clear();
        var devices = State.Node.Trusted.Values.OrderBy(d => d.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
        if (devices.Count == 0)
        {
            TrustedList.Children.Add(new TextBlock { Text = "Pair with a device from its page to trust it.", Opacity = 0.7 });
            return;
        }
        foreach (var d in devices)
        {
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new StackPanel
            {
                Children =
                {
                    new TextBlock { Text = d.Name },
                    new TextBlock { Text = $"Paired {d.AddedAt:d}", Opacity = 0.7, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] },
                },
            });
            var unpair = new Button { Content = "Unpair", VerticalAlignment = VerticalAlignment.Center };
            unpair.Click += (_, _) => { State.Node.Unpair(d.Id); ShowTrusted(); };
            Grid.SetColumn(unpair, 1);
            row.Children.Add(unpair);
            TrustedList.Children.Add(row);
        }
    }
}
