using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Media.Core;
using Windows.Storage;
using Windows.Storage.FileProperties;

namespace AirBridge.App;

/// <summary>Which received files AirBridge can show in-app, and how.</summary>
public static class Preview
{
    static readonly HashSet<string> Images = [".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".tif", ".tiff", ".ico", ".heic", ".heif", ".jfif"];
    static readonly HashSet<string> Text = [".txt", ".md", ".json", ".csv", ".log", ".xml", ".yaml", ".yml", ".ini", ".cs", ".swift", ".js", ".ts", ".py", ".html", ".css", ".sh", ".ps1", ".sql"];
    static readonly HashSet<string> Media = [".mp4", ".mov", ".m4v", ".wmv", ".avi", ".mkv", ".mp3", ".m4a", ".wav", ".aac", ".flac", ".ogg"];

    static string Ext(string path) => Path.GetExtension(path).ToLowerInvariant();
    public static bool IsImage(string path) => Images.Contains(Ext(path));
    public static bool IsText(string path) => Text.Contains(Ext(path));
    public static bool IsMedia(string path) => Media.Contains(Ext(path));
    public static bool IsPdf(string path) => Ext(path) == ".pdf";

    /// <summary>Small picture for list rows: the Windows thumbnail of any file or folder.</summary>
    public static async Task<ImageSource?> ThumbnailAsync(string path, uint size = 64)
    {
        try
        {
            var item = Directory.Exists(path) ? (IStorageItemProperties)await StorageFolder.GetFolderFromPathAsync(path) : await StorageFile.GetFileFromPathAsync(path);
            using var thumbnail = await item.GetThumbnailAsync(ThumbnailMode.SingleItem, size);
            if (thumbnail is null) return null;
            var bitmap = new BitmapImage();
            await bitmap.SetSourceAsync(thumbnail);
            return bitmap;
        }
        catch (Exception) { return null; }
    }

    public static void Reveal(string path) =>
        Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });

    public static void Open(string path) =>
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
}

/// <summary>In-app preview of a received file: pictures, text and code, PDFs, video and audio.</summary>
public sealed class PreviewDialog : ContentDialog
{
    readonly MediaPlayerElement? _player;

    public PreviewDialog(string path)
    {
        Title = Path.GetFileName(path);
        PrimaryButtonText = "Open";
        SecondaryButtonText = "Show in folder";
        CloseButtonText = "Close";
        DefaultButton = ContentDialogButton.Close;
        PrimaryButtonClick += (_, _) => Preview.Open(path);
        SecondaryButtonClick += (_, _) => Preview.Reveal(path);
        Resources["ContentDialogMaxWidth"] = 960.0;

        FrameworkElement content;
        if (Preview.IsImage(path))
        {
            content = new Image { Source = new BitmapImage(new Uri(path)), Stretch = Stretch.Uniform, MaxHeight = 560 };
        }
        else if (Preview.IsText(path))
        {
            var text = ReadHead(path, 64 * 1024);
            content = new ScrollViewer
            {
                MaxHeight = 560,
                Content = new TextBlock { Text = text, FontFamily = new FontFamily("Cascadia Mono, Consolas"), IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap },
            };
        }
        else if (Preview.IsMedia(path))
        {
            _player = new MediaPlayerElement { Source = MediaSource.CreateFromUri(new Uri(path)), AreTransportControlsEnabled = true, AutoPlay = true, MaxHeight = 540 };
            content = _player;
        }
        else if (Preview.IsPdf(path))
        {
            // WebView2 (part of the Windows App SDK) renders PDFs with Edge's viewer.
            content = new WebView2 { Source = new Uri(path), Width = 880, Height = 560 };
        }
        else
        {
            var image = new Image { Width = 256, Height = 256 };
            _ = LoadThumbnailAsync(image, path);
            content = new StackPanel
            {
                Spacing = 12,
                HorizontalAlignment = HorizontalAlignment.Center,
                Children = { image, new TextBlock { Text = "There's no built-in preview for this kind of file. Open it in its app.", Opacity = 0.7 } },
            };
        }
        Content = content;
        Closed += (_, _) => _player?.MediaPlayer?.Pause();
    }

    static async Task LoadThumbnailAsync(Image image, string path) => image.Source = await Preview.ThumbnailAsync(path, 256);

    static string ReadHead(string path, int bytes)
    {
        using var stream = File.OpenRead(path);
        var buffer = new byte[Math.Min(bytes, stream.Length)];
        stream.ReadExactly(buffer);
        var text = System.Text.Encoding.UTF8.GetString(buffer);
        return stream.Length > bytes ? text + "\n…" : text;
    }
}
