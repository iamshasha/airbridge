using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Pickers;

namespace AirBridge.App.Pages;

public sealed partial class TransfersPage : Page
{
    public AppState State => AppState.Current;

    public TransfersPage()
    {
        InitializeComponent();
        State.Transfers.CollectionChanged += (_, _) => UpdateEmpty();
        UpdateEmpty();
    }

    void UpdateEmpty() => Empty.Visibility = State.Transfers.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

    void OnClear(object sender, RoutedEventArgs e)
    {
        State.Node.ClearFinishedTransfers();
        for (var i = State.Transfers.Count - 1; i >= 0; i--)
            if (State.Transfers[i].Info.IsFinished) State.Transfers.RemoveAt(i);
    }

    void OnReveal(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is TransferItem { Info.SavedPaths: [var first, ..] }) Preview.Reveal(first);
    }

    async void OnPreview(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is not TransferItem { Info.SavedPaths: [var first, ..] }) return;
        if (Directory.Exists(first)) { Preview.Open(first); return; }
        await new PreviewDialog(first) { XamlRoot = XamlRoot }.ShowAsync();
    }

    async void OnShareLink(object sender, RoutedEventArgs e)
    {
        if (!State.Node.RelayConfigured)
        {
            State.Announce("Set a relay URL first", "Settings › Internet links. See relay/README.md for the free Cloudflare setup.", InfoBarSeverity.Warning);
            return;
        }
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, App.Window!.Hwnd);
        var files = await picker.PickMultipleFilesAsync();
        if (files is not { Count: > 0 }) return;

        var linkBox = new TextBox { IsReadOnly = true, PlaceholderText = "Creating link…" };
        var status = new TextBlock { Text = "Send this link to the recipient. It works once, from anywhere, and stays end-to-end encrypted. Keep AirBridge open until it's done.", TextWrapping = TextWrapping.Wrap };
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = files.Count == 1 ? $"Share {files[0].Name}" : $"Share {files.Count} files",
            Content = new StackPanel { Spacing = 12, Width = 440, Children = { status, linkBox } },
            PrimaryButtonText = "Copy link",
            CloseButtonText = "Hide",
            DefaultButton = ContentDialogButton.Primary,
        };
        dialog.PrimaryButtonClick += (_, args) =>
        {
            args.Cancel = true; // keep the dialog open after copying
            var package = new DataPackage();
            package.SetText(linkBox.Text);
            Clipboard.SetContent(package);
            dialog.PrimaryButtonText = "Copied";
            ElementSoundPlayer.Play(ElementSoundKind.Invoke);
        };
        _ = dialog.ShowAsync();
        try
        {
            await Task.Run(() => State.Node.ShareViaLinkAsync(files.Select(f => f.Path), link => DispatcherQueue.TryEnqueue(() => linkBox.Text = link.ToString())));
            status.Text = "The recipient received everything.";
            dialog.CloseButtonText = "Done";
        }
        catch (Protocol.AirBridgeException ex)
        {
            dialog.Hide();
            State.ReportError("Link transfer failed", ex);
        }
    }
}
