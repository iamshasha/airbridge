using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace AirBridge.Protocol;

public enum FrameType : byte { Control = 1, Chunk = 2 }

/// <summary>Authenticated, encrypted channel over a <see cref="Wire"/> (PROTOCOL.md §2.2–2.3).</summary>
public sealed class SecureChannel : IAsyncDisposable
{
    static readonly byte[] Label = "AirBridge/1"u8.ToArray();

    public Wire Wire { get; }
    public Hello Peer { get; }
    public bool IsClient { get; }
    /// <summary>6-digit pairing code both sides derive from the transcript.</summary>
    public string Sas { get; }

    readonly AesGcm _send;
    readonly AesGcm _recv;
    readonly SemaphoreSlim _sendLock = new(1, 1);
    ulong _sendCounter;
    ulong _recvCounter;

    SecureChannel(Wire wire, Hello peer, bool isClient, byte[] sendKey, byte[] recvKey, string sas)
    {
        Wire = wire;
        Peer = peer;
        IsClient = isClient;
        _send = new AesGcm(sendKey, 16);
        _recv = new AesGcm(recvKey, 16);
        Sas = sas;
    }

    public sealed record LocalInfo(DeviceIdentity Identity, string Name, string Platform, ushort Port);

    public static async Task<SecureChannel> HandshakeAsync(Wire wire, LocalInfo local, bool isClient, CancellationToken ct = default)
    {
        using var eph = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        var hello = new Hello(1, local.Identity.Id, local.Name, local.Platform, local.Port, local.Identity.PublicKeyRaw,
            DeviceIdentity.RawPublicKey(eph.ExportParameters(false)), RandomNumberGenerator.GetBytes(32));
        var myHello = Json.Encode(hello);
        await wire.SendFrameAsync(myHello, ct).ConfigureAwait(false);
        var theirHello = await wire.ReceiveFrameAsync(ct).ConfigureAwait(false);

        Hello peer;
        try { peer = Json.Decode<Hello>(theirHello); }
        catch (System.Text.Json.JsonException) { throw new AirBridgeException(AirBridgeError.ProtocolViolation, "bad hello"); }
        if (peer.V != 1) throw new AirBridgeException(AirBridgeError.ProtocolViolation, $"unsupported version {peer.V}");
        if (peer.Id == local.Identity.Id) throw new AirBridgeException(AirBridgeError.ProtocolViolation, "connected to self");

        var transcript = TranscriptHash(isClient ? myHello : theirHello, isClient ? theirHello : myHello);
        var signature = local.Identity.SigningKey.SignData(transcript, HashAlgorithmName.SHA256);
        await wire.SendFrameAsync(Json.Encode(new Auth(signature)), ct).ConfigureAwait(false);
        var auth = Json.Decode<Auth>(await wire.ReceiveFrameAsync(ct).ConfigureAwait(false));

        byte[] shared;
        try
        {
            using var peerKey = ECDsa.Create(DeviceIdentity.PublicParameters(peer.SigKey));
            if (!peerKey.VerifyData(transcript, auth.Sig, HashAlgorithmName.SHA256))
                throw new AirBridgeException(AirBridgeError.AuthenticationFailed);
            using var peerEph = ECDiffieHellman.Create(DeviceIdentity.PublicParameters(peer.EphKey));
            shared = eph.DeriveRawSecretAgreement(peerEph.PublicKey);
        }
        catch (CryptographicException) { throw new AirBridgeException(AirBridgeError.AuthenticationFailed); }

        var c2s = HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 32, transcript, "AirBridge/1 c2s"u8.ToArray());
        var s2c = HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 32, transcript, "AirBridge/1 s2c"u8.ToArray());
        return new SecureChannel(wire, peer, isClient, isClient ? c2s : s2c, isClient ? s2c : c2s, SasCode(transcript));
    }

    internal static byte[] TranscriptHash(byte[] client, byte[] server)
    {
        var t = new byte[Label.Length + 8 + client.Length + server.Length];
        var span = t.AsSpan();
        Label.CopyTo(span);
        var o = Label.Length;
        BinaryPrimitives.WriteUInt32BigEndian(span[o..], (uint)client.Length); o += 4;
        client.CopyTo(span[o..]); o += client.Length;
        BinaryPrimitives.WriteUInt32BigEndian(span[o..], (uint)server.Length); o += 4;
        server.CopyTo(span[o..]);
        return SHA256.HashData(t);
    }

    internal static string SasCode(byte[] transcript)
    {
        var digest = SHA256.HashData([.. "AirBridge/SAS"u8, .. transcript]);
        return (BinaryPrimitives.ReadUInt32BigEndian(digest) % 1_000_000).ToString("D6", System.Globalization.CultureInfo.InvariantCulture);
    }

    static void Nonce(Span<byte> nonce, ulong counter)
    {
        nonce[..4].Clear();
        BinaryPrimitives.WriteUInt64BigEndian(nonce[4..], counter);
    }

    // MARK: encrypted frames

    public Task SendAsync(FrameType type, ReadOnlySpan<byte> payload, CancellationToken ct = default)
    {
        var plain = new byte[payload.Length + 1];
        plain[0] = (byte)type;
        payload.CopyTo(plain.AsSpan(1));
        return SendPlaintextAsync(plain, ct);
    }

    /// <summary><paramref name="plain"/> must already start with the frame type byte.</summary>
    public async Task SendPlaintextAsync(ReadOnlyMemory<byte> plain, CancellationToken ct = default)
    {
        var frame = new byte[4 + plain.Length + 16];
        await _sendLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            // Sealing and writing under one lock keeps the nonce counter in wire order.
            Span<byte> nonce = stackalloc byte[12];
            Nonce(nonce, _sendCounter++);
            BinaryPrimitives.WriteInt32BigEndian(frame, plain.Length + 16);
            _send.Encrypt(nonce, plain.Span, frame.AsSpan(4, plain.Length), frame.AsSpan(4 + plain.Length, 16));
            await Wire.WriteAsync(frame, ct).ConfigureAwait(false);
        }
        finally { _sendLock.Release(); }
    }

    /// <summary>Receives one frame. Only one reader per channel.</summary>
    public async Task<(FrameType Type, ReadOnlyMemory<byte> Payload)> ReceiveAsync(CancellationToken ct = default)
    {
        var body = await Wire.ReceiveFrameAsync(ct).ConfigureAwait(false);
        if (body.Length < 17) throw new AirBridgeException(AirBridgeError.ProtocolViolation, "short frame");
        var plain = new byte[body.Length - 16];
        var nonce = new byte[12];
        Nonce(nonce, _recvCounter++);
        try { _recv.Decrypt(nonce, body.AsSpan(0, plain.Length), body.AsSpan(plain.Length), plain); }
        catch (CryptographicException) { throw new AirBridgeException(AirBridgeError.AuthenticationFailed); }
        if (plain[0] is not ((byte)FrameType.Control or (byte)FrameType.Chunk))
            throw new AirBridgeException(AirBridgeError.ProtocolViolation, "unknown frame type");
        return ((FrameType)plain[0], plain.AsMemory(1));
    }

    public Task SendAsync(ControlMessage message, CancellationToken ct = default) =>
        SendAsync(FrameType.Control, Json.Encode(message), ct);

    public async Task<ControlMessage> ReceiveControlAsync(CancellationToken ct = default)
    {
        var (type, payload) = await ReceiveAsync(ct).ConfigureAwait(false);
        if (type != FrameType.Control) throw new AirBridgeException(AirBridgeError.ProtocolViolation, "expected control frame");
        return Json.Decode<ControlMessage>(payload.Span);
    }

    public void Close() => Wire.Close();

    public async ValueTask DisposeAsync()
    {
        await Wire.DisposeAsync().ConfigureAwait(false);
        _send.Dispose();
        _recv.Dispose();
        _sendLock.Dispose();
    }
}
