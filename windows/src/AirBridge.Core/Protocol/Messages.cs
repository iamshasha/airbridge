using System.Text.Json;
using System.Text.Json.Serialization;

namespace AirBridge.Protocol;

/// <summary>Errors surfaced by the engine. Mirrors AirBridgeError in the Swift core.</summary>
public sealed class AirBridgeException(AirBridgeError kind, string? detail = null)
    : Exception(Describe(kind, detail))
{
    public AirBridgeError Kind { get; } = kind;

    static string Describe(AirBridgeError kind, string? detail) => kind switch
    {
        AirBridgeError.ConnectionClosed => "Connection closed",
        AirBridgeError.ConnectFailed => $"Could not connect: {detail}",
        AirBridgeError.ProtocolViolation => $"Protocol error: {detail}",
        AirBridgeError.AuthenticationFailed => "Device authentication failed",
        AirBridgeError.Declined => string.IsNullOrEmpty(detail) ? "Declined" : $"Declined: {detail}",
        AirBridgeError.NotTrusted => "The other device is no longer paired with this one. Pair again to continue.",
        AirBridgeError.Timeout => "Timed out",
        _ => detail ?? kind.ToString(),
    };
}

public enum AirBridgeError { ConnectionClosed, ConnectFailed, ProtocolViolation, AuthenticationFailed, Declined, NotTrusted, Timeout }

/// <summary>Handshake hello (PROTOCOL.md §2.2). Byte arrays travel as base64, like Swift's Data.</summary>
public sealed record Hello(
    [property: JsonPropertyName("v")] int V,
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("platform")] string Platform,
    [property: JsonPropertyName("port")] ushort Port,
    [property: JsonPropertyName("sigKey")] byte[] SigKey,
    [property: JsonPropertyName("ephKey")] byte[] EphKey,
    [property: JsonPropertyName("nonce")] byte[] Nonce)
{
    [JsonIgnore] public string Fingerprint => DeviceIdentity.FingerprintOf(SigKey);
}

internal sealed record Auth([property: JsonPropertyName("sig")] byte[] Sig);

/// <summary>Flat control message (PROTOCOL.md §3); unused fields are omitted on the wire.</summary>
public sealed class ControlMessage
{
    [JsonPropertyName("t")] public string T { get; set; } = "";
    [JsonPropertyName("transferId")] public string? TransferId { get; set; }
    [JsonPropertyName("items")] public List<FileItem>? Items { get; set; }
    [JsonPropertyName("total")] public long? Total { get; set; }
    [JsonPropertyName("streams")] public int? Streams { get; set; }
    [JsonPropertyName("sync")] public bool? Sync { get; set; }
    [JsonPropertyName("text")] public string? Text { get; set; }
    [JsonPropertyName("path")] public string? Path { get; set; }
    [JsonPropertyName("paths")] public List<string>? Paths { get; set; }
    [JsonPropertyName("entries")] public List<RemoteEntry>? Entries { get; set; }
    [JsonPropertyName("reason")] public string? Reason { get; set; }
    /// <summary><c>speedtest</c>: "upload" (client sends) or "download" (server sends).</summary>
    [JsonPropertyName("mode")] public string? Mode { get; set; }

    public ControlMessage() { }
    public ControlMessage(string t) => T = t;

    public static ControlMessage Error(string reason) => new("error") { Reason = reason };
    public static ControlMessage NotPaired => new("notPaired") { Reason = "This device is not paired" };
}

public sealed record FileItem(
    [property: JsonPropertyName("i")] int I,
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("size")] long Size,
    [property: JsonPropertyName("dir")] bool? Dir = null)
{
    [JsonIgnore] public bool IsDirectory => Dir == true;
}

public sealed record RemoteEntry(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("size")] long Size,
    [property: JsonPropertyName("dir")] bool Dir);

internal static class Json
{
    public static readonly JsonSerializerOptions Options = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static byte[] Encode<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, Options);

    public static T Decode<T>(ReadOnlySpan<byte> data) =>
        JsonSerializer.Deserialize<T>(data, Options) ?? throw new AirBridgeException(AirBridgeError.ProtocolViolation, $"bad {typeof(T).Name}");
}
