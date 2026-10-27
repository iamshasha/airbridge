using System.Security.Cryptography;
using System.Text.Json;

namespace AirBridge.Protocol;

/// <summary>Long-term device identity: a stable id plus a P-256 signing key whose fingerprint peers trust.</summary>
public sealed class DeviceIdentity : IDisposable
{
    public string Id { get; }
    public ECDsa SigningKey { get; }

    /// <summary>Raw 64-byte X||Y public key, the format CryptoKit's rawRepresentation uses.</summary>
    public byte[] PublicKeyRaw { get; }
    public string Fingerprint => FingerprintOf(PublicKeyRaw);

    DeviceIdentity(string id, ECDsa key)
    {
        Id = id;
        SigningKey = key;
        PublicKeyRaw = RawPublicKey(key.ExportParameters(false));
    }

    public static string FingerprintOf(byte[] rawPublicKey) =>
        Convert.ToHexStringLower(SHA256.HashData(rawPublicKey).AsSpan(0, 16));

    public static DeviceIdentity Generate() =>
        new(Guid.NewGuid().ToString().ToUpperInvariant(), ECDsa.Create(ECCurve.NamedCurves.nistP256));

    internal static byte[] RawPublicKey(ECParameters p) => [.. p.Q.X!, .. p.Q.Y!];

    internal static ECParameters PublicParameters(byte[] raw)
    {
        if (raw.Length != 64) throw new AirBridgeException(AirBridgeError.ProtocolViolation, "bad public key");
        return new ECParameters { Curve = ECCurve.NamedCurves.nistP256, Q = new ECPoint { X = raw[..32], Y = raw[32..] } };
    }

    sealed record Stored(string Id, byte[] D, byte[] X, byte[] Y);

    /// <summary>Loads the identity from <paramref name="path"/>, creating it on first launch.</summary>
    public static DeviceIdentity LoadOrCreate(string path)
    {
        try
        {
            var stored = JsonSerializer.Deserialize<Stored>(File.ReadAllBytes(path));
            if (stored is not null)
            {
                var key = ECDsa.Create(new ECParameters
                {
                    Curve = ECCurve.NamedCurves.nistP256,
                    D = stored.D,
                    Q = new ECPoint { X = stored.X, Y = stored.Y },
                });
                return new DeviceIdentity(stored.Id, key);
            }
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException or JsonException or CryptographicException) { }

        var identity = Generate();
        var p = identity.SigningKey.ExportParameters(true);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, JsonSerializer.SerializeToUtf8Bytes(new Stored(identity.Id, p.D!, p.Q.X!, p.Q.Y!)));
        if (!OperatingSystem.IsWindows())
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        return identity;
    }

    public void Dispose() => SigningKey.Dispose();
}
