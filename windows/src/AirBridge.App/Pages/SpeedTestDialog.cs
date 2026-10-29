using AirBridge.Engine;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace AirBridge.App.Pages;

/// <summary>
/// Upload then download speed with one device. The ring fills through both phases (upload, then download);
/// the number inside is the live speed in the unit picked under it, which is also used everywhere else.
/// </summary>
public sealed class SpeedTestDialog : ContentDialog
{
    readonly Peer _peer;
    readonly ProgressRing _ring = new() { IsIndeterminate = false, Width = 200, Height = 200, Maximum = 1 };
    readonly TextBlock _value = new() { Text = "–", FontSize = 32, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center };
    readonly TextBlock _phase = new() { Text = "Connecting", Opacity = 0.7, HorizontalAlignment = HorizontalAlignment.Center };
    readonly TextBlock _upload = Result();
    readonly TextBlock _download = Result();
    readonly TextBlock _error = new() { Foreground = (Brush)Application.Current.Resources["SystemFillColorCriticalBrush"], TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
    readonly SelectorBar _units = new() { HorizontalAlignment = HorizontalAlignment.Center };
    SpeedTestProgress? _progress;
    SpeedTestResult? _result;
    bool _running;

    static Node Node => AppState.Current.Node;
    static SpeedUnit Unit => Node.Settings.SpeedUnit;

    public SpeedTestDialog(Peer peer)
    {
        _peer = peer;
        Title = $"Speed with {peer.Name}";
        PrimaryButtonText = "Test again";
        CloseButtonText = "Done";
        DefaultButton = ContentDialogButton.Close;
        IsPrimaryButtonEnabled = false;

        foreach (var unit in Enum.GetValues<SpeedUnit>())
            _units.Items.Add(new SelectorBarItem { Text = unit.Label(), Tag = unit, IsSelected = unit == Unit });
        _units.SelectionChanged += (_, _) =>
        {
            if (_units.SelectedItem?.Tag is not SpeedUnit unit || unit == Unit) return;
            Node.Settings.SpeedUnit = unit;
            Node.SaveSettings();
            ElementSoundPlayer.Play(ElementSoundKind.Invoke);
            Render();
        };

        Content = new StackPanel
        {
            Spacing = 16,
            Width = 360,
            Children =
            {
                new Grid
                {
                    HorizontalAlignment = HorizontalAlignment.Center,
                    Children =
                    {
                        _ring,
                        new StackPanel { VerticalAlignment = VerticalAlignment.Center, Children = { _value, _phase } },
                    },
                },
                new Grid
                {
                    ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition() },
                    Children = { Column("Upload", "", _upload, 0), Column("Download", "", _download, 1) },
                },
                _units,
                _error,
            },
        };
        PrimaryButtonClick += (sender, args) => { args.Cancel = true; _ = RunAsync(); };
        Opened += (_, _) => _ = RunAsync();
    }

    static TextBlock Result() => new() { Text = "–", FontSize = 20, HorizontalAlignment = HorizontalAlignment.Center };

    static StackPanel Column(string title, string glyph, TextBlock value, int column)
    {
        var panel = new StackPanel
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            Children =
            {
                new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = HorizontalAlignment.Center, Opacity = 0.7,
                    Children = { new FontIcon { Glyph = glyph, FontSize = 12 }, new TextBlock { Text = title } },
                },
                value,
            },
        };
        Grid.SetColumn(panel, column);
        return panel;
    }

    async Task RunAsync()
    {
        if (_running) return;
        _running = true;
        _result = null;
        _progress = null;
        _error.Visibility = Visibility.Collapsed;
        IsPrimaryButtonEnabled = false;
        Render();
        var ui = DispatcherQueue;
        try
        {
            _result = await Node.SpeedTestAsync(_peer, p => ui.TryEnqueue(() => { _progress = p; Render(); }));
            ElementSoundPlayer.Play(ElementSoundKind.Show);
        }
        catch (Exception e) when (e is Protocol.AirBridgeException or IOException)
        {
            _error.Text = e.Message;
            _error.Visibility = Visibility.Visible;
        }
        _running = false;
        _progress = null;
        IsPrimaryButtonEnabled = true;
        Render();
    }

    void Render()
    {
        var unit = Unit;
        _ring.Value = _progress is { } p ? (p.Phase == SpeedTestPhase.Upload ? 0 : 0.5) + p.Fraction / 2 : _result is null ? 0 : 1;
        _value.Text = _running && _progress is { BytesPerSecond: > 0 } live ? unit.Format(live.BytesPerSecond)
            : _result is { } r ? unit.Format((r.Upload + r.Download) / 2) : "–";
        _phase.Text = _running
            ? _progress is null ? "Connecting" : _progress.Phase == SpeedTestPhase.Upload ? "Uploading" : "Downloading"
            : _result is null ? "Ready" : "Average of both";
        _upload.Text = _result is { } u ? unit.Format(u.Upload) : "–";
        _download.Text = _result is { } d ? unit.Format(d.Download) : "–";
    }
}
