using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AirBridge.Engine;

public sealed class TrustedDevice
{
    public required string Id { get; set; }
    public required string Name { get; set; }
    public required string Fingerprint { get; set; }
    public string Platform { get; set; } = "mac";
    public DateTimeOffset AddedAt { get; set; } = DateTimeOffset.Now;
    /// <summary>Accept incoming files without asking (auto download).</summary>
    public bool AutoAccept { get; set; } = true;
    /// <summary>May list and pull from our shared folder.</summary>
    public bool AllowBrowse { get; set; } = true;
    /// <summary>Put received text straight on the clipboard.</summary>
    public bool AutoClipboard { get; set; }
    public string? LastHost { get; set; }
    public int? LastPort { get; set; }
}

[JsonConverter(typeof(JsonStringEnumConverter<ReceivePolicy>))]
public enum ReceivePolicy { Everyone, TrustedOnly, Off }

/// <summary>Watched local folder pushed automatically to a trusted device (auto upload).</summary>
public sealed class SyncRule
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public required string DeviceId { get; set; }
    public required string Folder { get; set; }
    public bool Enabled { get; set; } = true;
}

public sealed class Settings
{
    public string DeviceName { get; set; } = Environment.MachineName;
    public ReceivePolicy ReceivePolicy { get; set; } = ReceivePolicy.Everyone;
    public string DownloadFolder { get; set; } = DefaultDownloads();
    public string? SharedFolder { get; set; }
    public int Port { get; set; } = 47820;
    public int ParallelStreams { get; set; } = 4;
    public bool BluetoothDiscovery { get; set; } = true;
    public List<SyncRule> SyncRules { get; set; } = [];
    public string RelayUrl { get; set; } = "";
    /// <summary>MB/s or Mbps for every speed shown.</summary>
    public SpeedUnit SpeedUnit { get; set; } = SpeedUnit.Bytes;

    static string DefaultDownloads() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "AirBridge");
}

public enum DiscoverySource { Lan, PeerToPeer, Bluetooth, Manual, Trusted, AirDrop }

public readonly record struct Endpoint(string Host, int Port);

public sealed class Peer
{
    public required string Id { get; init; }
    public string Name { get; set; } = "";
    public string Platform { get; set; } = "mac";
    public string? Fingerprint { get; set; }
    public Dictionary<DiscoverySource, List<Endpoint>> Endpoints { get; } = [];
    public DateTimeOffset LastSeen { get; set; } = DateTimeOffset.Now;
    public int? Rssi { get; set; }

    public IEnumerable<DiscoverySource> Sources => Endpoints.Where(e => e.Value.Count > 0).Select(e => e.Key);
    public bool IsOnline => Sources.Any(s => s != DiscoverySource.Trusted);

    /// <summary>Fastest first: LAN, peer-to-peer, manual, Bluetooth-learned addresses, last known.</summary>
    public IReadOnlyList<Endpoint> OrderedEndpoints =>
        new[] { DiscoverySource.Lan, DiscoverySource.PeerToPeer, DiscoverySource.Manual, DiscoverySource.Bluetooth, DiscoverySource.Trusted }
            .SelectMany(s => Endpoints.GetValueOrDefault(s) ?? []).Distinct().ToList();

    public static Peer At(string host, int port, string id = "", string name = "") =>
        new() { Id = id, Name = name, Endpoints = { [DiscoverySource.Manual] = [new Endpoint(host, port)] } };
}

public enum TransferDirection { Outgoing, Incoming }
public enum TransferState { Connecting, WaitingForAcceptance, Active, Done, Failed, Declined }

/// <summary>Progress of one transfer. Raises <see cref="PropertyChanged"/> from background threads.</summary>
public sealed class TransferInfo : INotifyPropertyChanged
{
    public required string Id { get; init; }
    public required TransferDirection Direction { get; init; }
    public required string PeerName { get; init; }
    public required string Title { get; init; }
    public bool Sync { get; init; }
    public long Total { get; init; }
    public DateTimeOffset StartedAt { get; private set; } = DateTimeOffset.Now;
    public DateTimeOffset? FinishedAt { get; private set; }
    public List<string> SavedPaths { get; } = [];

    TransferState _state;
    public TransferState State { get => _state; private set => Set(ref _state, value); }
    public string? Error { get; private set; }

    long _bytes;
    public long Bytes { get => Interlocked.Read(ref _bytes); internal set { Interlocked.Exchange(ref _bytes, value); Raise(); } }

    internal Func<long>? Counter;
    double _rate;
    public double BytesPerSecond { get => _rate; private set => Set(ref _rate, value); }
    (DateTimeOffset At, long Bytes)? _lastSample;

    public double Fraction => Total > 0 ? Math.Min(1, (double)Bytes / Total) : State == TransferState.Done ? 1 : 0;
    public bool IsFinished => State is TransferState.Done or TransferState.Failed or TransferState.Declined;
    public double AverageBytesPerSecond =>
        FinishedAt is { } end && (end - StartedAt).TotalSeconds > 0 ? Bytes / (end - StartedAt).TotalSeconds : BytesPerSecond;

    internal void SetState(TransferState state) => State = state;

    internal void Activate(Func<long> counter)
    {
        Counter = counter;
        StartedAt = DateTimeOffset.Now;
        State = TransferState.Active;
    }

    /// <summary>Called a few times a second by the node while active.</summary>
    internal void Sample()
    {
        if (Counter is null) return;
        var now = DateTimeOffset.Now;
        var value = Counter();
        if (_lastSample is { } last && (now - last.At).TotalSeconds > 0.2)
        {
            var instant = (value - last.Bytes) / (now - last.At).TotalSeconds;
            BytesPerSecond = BytesPerSecond == 0 ? instant : BytesPerSecond * 0.6 + instant * 0.4;
            _lastSample = (now, value);
        }
        else _lastSample ??= (now, value);
        Bytes = value;
        Raise(nameof(Fraction));
    }

    internal void Finish(TransferState state, string? error = null)
    {
        Sample();
        if (state == TransferState.Done) Bytes = Total;
        Error = error;
        FinishedAt = DateTimeOffset.Now;
        Counter = null;
        State = state;
        Raise(nameof(IsFinished));
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    void Raise([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        Raise(name);
    }
}

public sealed record ReceivedText(Guid Id, string From, string Text, DateTimeOffset Date)
{
    public ReceivedText(string from, string text) : this(Guid.NewGuid(), from, text, DateTimeOffset.Now) { }
}

/// <summary>Something the user decides: an incoming offer or a pairing request.</summary>
public sealed record PromptRequest(string PeerName, string PeerPlatform, string Fingerprint, PromptKind Kind,
    IReadOnlyList<Protocol.FileItem>? Items = null, long Total = 0, string? Code = null)
{
    public string Summary => Kind switch
    {
        PromptKind.Pairing => $"{PeerName} wants to pair",
        _ => $"{PeerName} wants to send {Title} ({Format.Bytes(Total)})",
    };

    string Title
    {
        get
        {
            var items = Items ?? [];
            var tops = items.Select(i => i.Path.Split('/')[0]).Distinct().ToList();
            return tops.Count == 1 ? tops[0] : $"{items.Count(i => !i.IsDirectory)} files";
        }
    }
}

public enum PromptKind { Offer, Pairing }

/// <summary>JSON files under the app's data folder.</summary>
public sealed class Store(string directory)
{
    static readonly JsonSerializerOptions Options = new() { WriteIndented = true };
    public string Directory { get; } = System.IO.Directory.CreateDirectory(directory).FullName;

    public static string DefaultDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AirBridge");

    public T? Load<T>(string name)
    {
        try { return JsonSerializer.Deserialize<T>(File.ReadAllBytes(Path.Combine(Directory, name)), Options); }
        catch (Exception e) when (e is FileNotFoundException or JsonException) { return default; }
    }

    public void Save<T>(T value, string name)
    {
        var path = Path.Combine(Directory, name);
        var temp = path + ".tmp";
        File.WriteAllBytes(temp, JsonSerializer.SerializeToUtf8Bytes(value, Options));
        File.Move(temp, path, overwrite: true);
    }

    public void Remove(string name) => File.Delete(Path.Combine(Directory, name));
}

public static class Format
{
    static readonly string[] Units = ["bytes", "KB", "MB", "GB", "TB"];

    /// <summary>Decimal units like Finder and the Swift ByteCountFormatter (1 KB = 1000 bytes).</summary>
    public static string Bytes(double bytes)
    {
        var unit = 0;
        while (bytes >= 1000 && unit < Units.Length - 1) { bytes /= 1000; unit++; }
        return unit == 0 ? $"{bytes:0} {Units[0]}" : $"{bytes:0.#} {Units[unit]}";
    }
}
