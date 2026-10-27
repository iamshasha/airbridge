using AirBridge.Engine;
using AirBridge.Protocol;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AirBridge.App.Pages;

/// <summary>Browse and download from a paired device's shared folder.</summary>
public sealed class BrowseDialog : ContentDialog
{
    readonly Peer _peer;
    readonly List<string> _path = [];
    readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Multiple, Height = 360 };
    readonly TextBlock _location = new() { Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] };
    readonly Button _up = new() { Content = new FontIcon { Glyph = "", FontSize = 14 } };
    readonly TextBlock _message = new() { Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
    IReadOnlyList<RemoteEntry> _entries = [];

    public BrowseDialog(Peer peer)
    {
        _peer = peer;
        Title = $"{peer.Name} shared folder";
        PrimaryButtonText = "Download";
        CloseButtonText = "Close";
        DefaultButton = ContentDialogButton.Primary;
        IsPrimaryButtonEnabled = false;
        ToolTipService.SetToolTip(_up, "Up one folder");
        _up.Click += async (_, _) => { if (_path.Count > 0) { _path.RemoveAt(_path.Count - 1); await LoadAsync(); } };
        _list.SelectionChanged += (_, _) => IsPrimaryButtonEnabled = _list.SelectedItems.Count > 0;
        _list.IsItemClickEnabled = true;
        _list.DoubleTapped += async (_, _) =>
        {
            if (_list.SelectedIndex >= 0 && _entries[_list.SelectedIndex].Dir) { _path.Add(_entries[_list.SelectedIndex].Name); await LoadAsync(); }
        };
        Content = new StackPanel
        {
            Spacing = 8,
            Width = 460,
            Children =
            {
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { _up, _location } },
                _message,
                _list,
                new TextBlock { Text = "Double-click a folder to open it.", Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], Opacity = 0.7 },
            },
        };
        PrimaryButtonClick += OnDownload;
        Opened += async (_, _) => await LoadAsync();
    }

    async Task LoadAsync()
    {
        _location.Text = _path.Count == 0 ? "Shared" : _path[^1];
        _up.IsEnabled = _path.Count > 0;
        _list.Items.Clear();
        _message.Text = "Loading…";
        try
        {
            _entries = await Task.Run(() => AppState.Current.Node.BrowseAsync(_peer, string.Join('/', _path)));
            foreach (var e in _entries)
            {
                _list.Items.Add(new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 12,
                    Children =
                    {
                        new FontIcon { Glyph = e.Dir ? "" : "", FontSize = 16 },
                        new TextBlock { Text = e.Dir ? e.Name : $"{e.Name}  ({Format.Bytes(e.Size)})" },
                    },
                });
            }
            _message.Text = _entries.Count == 0 ? "This folder is empty." : "";
        }
        catch (AirBridgeException ex) { _message.Text = ex.Message; }
    }

    void OnDownload(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        var paths = _list.SelectedItems.Select(item => _entries[_list.Items.IndexOf(item)].Name).Select(n => string.Join('/', _path.Append(n))).ToList();
        _ = Task.Run(async () =>
        {
            try { await AppState.Current.Node.PullAsync(paths, _peer); }
            catch (AirBridgeException ex) { App.Window!.DispatcherQueue.TryEnqueue(() => AppState.Current.ReportError("Couldn't download", ex)); }
        });
    }
}
