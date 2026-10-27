using AirBridge.Engine;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using Windows.Storage;
using Windows.Storage.FileProperties;

namespace AirBridge.App;

/// <summary>
/// Windows notifications with previews and actions, so AirBridge is usable from the background:
/// accept or decline requests, open or reveal received files, copy received text.
/// </summary>
internal static class Notifications
{
    /// <summary>Arguments of a clicked notification or button (action, id, path).</summary>
    public static event Action<IDictionary<string, string>>? Invoked;

    public static void Register()
    {
        try
        {
            AppNotificationManager.Default.NotificationInvoked += (_, args) => Invoked?.Invoke(args.Arguments);
            AppNotificationManager.Default.Register();
        }
        catch (Exception) { /* notifications unavailable (policy, unsupported OS) */ }
    }

    static void Show(AppNotificationBuilder builder, string? tag = null)
    {
        try
        {
            var notification = builder.BuildNotification();
            if (tag is not null) notification.Tag = tag;
            AppNotificationManager.Default.Show(notification);
        }
        catch (Exception) { }
    }

    public static void Remove(string tag)
    {
        try { _ = AppNotificationManager.Default.RemoveByTagAsync(tag); } catch (Exception) { }
    }

    public static void Simple(string title, string body) =>
        Show(new AppNotificationBuilder().AddArgument("action", "show").AddText(title).AddText(body));

    /// <summary>An incoming offer or pairing request, answerable from the notification itself.</summary>
    public static void Prompt(string id, PromptRequest request)
    {
        var builder = new AppNotificationBuilder()
            .AddArgument("action", "prompt").AddArgument("id", id)
            .SetScenario(AppNotificationScenario.Reminder) // stays on screen until answered
            .AddText(request.Summary);
        if (request.Kind == PromptKind.Pairing)
        {
            builder.AddText($"Check that {request.PeerName} shows {request.Code![..3]} {request.Code[3..]}.")
                .AddButton(new AppNotificationButton("Pair").AddArgument("action", "accept").AddArgument("id", id))
                .AddButton(new AppNotificationButton("Don't pair").AddArgument("action", "decline").AddArgument("id", id));
        }
        else
        {
            var files = (request.Items ?? []).Where(i => !i.IsDirectory).ToList();
            var preview = string.Join(", ", files.Take(3).Select(f => Path.GetFileName(f.Path)));
            if (files.Count > 3) preview += $" and {files.Count - 3} more";
            builder.AddText(preview)
                .AddButton(new AppNotificationButton("Accept").AddArgument("action", "accept").AddArgument("id", id))
                .AddButton(new AppNotificationButton("Decline").AddArgument("action", "decline").AddArgument("id", id));
        }
        Show(builder, tag: id);
    }

    /// <summary>A finished incoming transfer, with a picture of what arrived when one is available.</summary>
    public static async Task ReceivedAsync(TransferInfo transfer)
    {
        var path = transfer.SavedPaths.FirstOrDefault();
        var builder = new AppNotificationBuilder()
            .AddArgument("action", "transfers")
            .AddText($"Received {transfer.Title}")
            .AddText($"From {transfer.PeerName}, {Format.Bytes(transfer.Total)}");
        if (path is not null)
        {
            if (await PreviewImageAsync(path) is { } image)
            {
                if (Preview.IsImage(path)) builder.SetHeroImage(image);
                else builder.SetInlineImage(image);
            }
            builder.AddButton(new AppNotificationButton("Open").AddArgument("action", "open").AddArgument("path", path))
                .AddButton(new AppNotificationButton("Show in folder").AddArgument("action", "reveal").AddArgument("path", path));
        }
        Show(builder);
    }

    public static void Text(ReceivedText text, bool copied)
    {
        var body = text.Text.Length > 300 ? text.Text[..300] + "…" : text.Text;
        var builder = new AppNotificationBuilder()
            .AddArgument("action", "received")
            .AddText($"Text from {text.From}")
            .AddText(copied ? $"Copied to the clipboard: {body}" : body);
        if (!copied) builder.AddButton(new AppNotificationButton("Copy").AddArgument("action", "copy").AddArgument("id", text.Id.ToString()));
        Show(builder);
    }

    /// <summary>The file itself for pictures; the Windows thumbnail (as PNG/JPEG) for everything else.</summary>
    static async Task<Uri?> PreviewImageAsync(string path)
    {
        if (Preview.IsImage(path) && Path.GetExtension(path).ToLowerInvariant() is ".png" or ".jpg" or ".jpeg" or ".gif")
            return new Uri(path);
        try
        {
            var item = Directory.Exists(path) ? (IStorageItemProperties)await StorageFolder.GetFolderFromPathAsync(path) : await StorageFile.GetFileFromPathAsync(path);
            using var thumbnail = await item.GetThumbnailAsync(ThumbnailMode.SingleItem, 256);
            var extension = thumbnail?.ContentType switch { "image/png" => ".png", "image/jpeg" => ".jpg", _ => null };
            if (thumbnail is null || extension is null) return null;
            var temp = Path.Combine(Path.GetTempPath(), $"airbridge-preview-{Guid.NewGuid():N}{extension}");
            await using (var output = File.Create(temp))
                await thumbnail.AsStreamForRead().CopyToAsync(output);
            return new Uri(temp);
        }
        catch (Exception) { return null; }
    }
}
