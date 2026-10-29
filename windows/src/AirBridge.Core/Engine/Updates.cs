using System.Net;
using System.Net.Http.Headers;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;
using AirBridge.Protocol;

namespace AirBridge.Engine;

/// <summary>A newer AirBridge published on GitHub Releases.</summary>
public sealed record AppUpdate(string Version, string Notes, Uri PageUrl, Uri? DownloadUrl, long DownloadSize);

/// <summary>Checks github.com/iamshasha/airbridge for a newer release. Public repo, so no sign-in is needed.</summary>
public static class UpdateChecker
{
    public static readonly Uri LatestUrl = new("https://api.github.com/repos/iamshasha/airbridge/releases/latest");

    sealed record Release(
        [property: JsonPropertyName("tag_name")] string Tag,
        [property: JsonPropertyName("body")] string? Body,
        [property: JsonPropertyName("html_url")] Uri Page,
        [property: JsonPropertyName("draft")] bool Draft,
        [property: JsonPropertyName("prerelease")] bool Prerelease,
        [property: JsonPropertyName("assets")] List<Asset> Assets);

    sealed record Asset(
        [property: JsonPropertyName("name")] string Name,
        [property: JsonPropertyName("size")] long Size,
        [property: JsonPropertyName("browser_download_url")] Uri Url);

    /// <summary>The running app's version (from Directory.Build.props).</summary>
    public static string CurrentVersion =>
        Assembly.GetEntryAssembly()?.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "0";

    static readonly HttpClient Http = CreateClient();

    static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("AirBridge", CurrentVersion));
        return client;
    }

    /// <summary>The latest release when it is newer than <paramref name="current"/>, or null when this is up to date.</summary>
    public static async Task<AppUpdate?> CheckAsync(string current, string? asset, CancellationToken ct = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, LatestUrl);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(20));
        using var response = await Http.SendAsync(request, cts.Token).ConfigureAwait(false);
        if (response.StatusCode == HttpStatusCode.NotFound) return null; // no releases yet
        if (!response.IsSuccessStatusCode)
            throw new AirBridgeException(AirBridgeError.ProtocolViolation, $"GitHub answered {(int)response.StatusCode}");
        return Parse(await response.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false), current, asset);
    }

    public static AppUpdate? Parse(string json, string current, string? asset)
    {
        var release = JsonSerializer.Deserialize<Release>(json) ?? throw new AirBridgeException(AirBridgeError.ProtocolViolation, "bad release");
        if (release.Draft || release.Prerelease || !IsNewer(release.Tag, current)) return null;
        var file = release.Assets.FirstOrDefault(a => a.Name == asset);
        return new AppUpdate(Normalized(release.Tag), release.Body ?? "", release.Page, file?.Url, file?.Size ?? 0);
    }

    static string Normalized(string v) => v.TrimStart('v', 'V');

    /// <summary>Numeric comparison, part by part: 0.10.0 is newer than 0.9.2.</summary>
    public static bool IsNewer(string candidate, string current)
    {
        static int[] Parts(string v) => Normalized(v).Split('-')[0].Split('.')
            .Select(p => int.TryParse(p, System.Globalization.CultureInfo.InvariantCulture, out var n) ? n : 0).ToArray();
        var a = Parts(candidate);
        var b = Parts(current);
        for (var i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            var x = i < a.Length ? a[i] : 0;
            var y = i < b.Length ? b[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }

    /// <summary>Automatic checks happen at most once a day.</summary>
    public static bool IsDue(DateTimeOffset? lastCheck, DateTimeOffset? now = null) =>
        lastCheck is not { } last || (now ?? DateTimeOffset.Now) - last > TimeSpan.FromDays(1);

    /// <summary>Downloads <paramref name="url"/> to <paramref name="target"/>, reporting progress 0..1.</summary>
    public static async Task DownloadAsync(Uri url, string target, IProgress<double>? progress, CancellationToken ct = default)
    {
        using var response = await Http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        var total = response.Content.Headers.ContentLength ?? 0;
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        await using var input = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        await using var output = File.Create(target);
        var buffer = new byte[1 << 16];
        long done = 0;
        int n;
        while ((n = await input.ReadAsync(buffer, ct).ConfigureAwait(false)) > 0)
        {
            await output.WriteAsync(buffer.AsMemory(0, n), ct).ConfigureAwait(false);
            done += n;
            if (total > 0) progress?.Report((double)done / total);
        }
    }
}
