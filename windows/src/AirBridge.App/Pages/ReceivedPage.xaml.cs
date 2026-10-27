using AirBridge.Engine;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace AirBridge.App.Pages;

public sealed partial class ReceivedPage : Page
{
    public AppState State => AppState.Current;

    public ReceivedPage()
    {
        InitializeComponent();
        State.Inbox.CollectionChanged += (_, _) => UpdateEmpty();
        UpdateEmpty();
    }

    void UpdateEmpty()
    {
        Empty.Visibility = State.Inbox.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ClearButton.IsEnabled = State.Inbox.Count > 0;
    }

    void OnCopy(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is not ReceivedText item) return;
        var package = new DataPackage();
        package.SetText(item.Text);
        Clipboard.SetContent(package);
        State.Announce("Copied", "", InfoBarSeverity.Success);
    }

    void OnDelete(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is not ReceivedText item) return;
        State.Node.DeleteText(item.Id);
        State.Inbox.Remove(item);
        ElementSoundPlayer.Play(ElementSoundKind.Hide);
    }

    void OnClearAll(object sender, RoutedEventArgs e)
    {
        ClearFlyout.Hide();
        State.Node.ClearInbox();
        State.Inbox.Clear();
        ElementSoundPlayer.Play(ElementSoundKind.Hide);
    }
}
