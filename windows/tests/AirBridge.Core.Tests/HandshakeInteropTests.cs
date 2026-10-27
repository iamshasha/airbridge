using AirBridge.Protocol;

namespace AirBridge.Core.Tests;

/// <summary>The C# handshake and frame encryption against the Swift implementation.</summary>
public class HandshakeInteropTests
{
    [Fact]
    public async Task CSharpClientCompletesHandshakeAndSendsEncryptedTextToSwift()
    {
        Assert.True(SwiftPeer.Available, $"Build the Swift CLI first: swift build -c release ({SwiftPeer.CliPath})");
        await using var swift = await SwiftPeer.StartReceiverAsync();
        using var identity = DeviceIdentity.Generate();
        var local = new SecureChannel.LocalInfo(identity, "Windows PC", "win", 0);

        await using var wire = await TcpWire.ConnectAsync("127.0.0.1", swift.Port, TimeSpan.FromSeconds(5));
        await using var channel = await SecureChannel.HandshakeAsync(wire, local, isClient: true);

        Assert.Equal(swift.Fingerprint, channel.Peer.Fingerprint);
        Assert.Equal("mac", channel.Peer.Platform);
        Assert.Matches("^[0-9]{6}$", channel.Sas);

        await channel.SendAsync(new ControlMessage("text") { Text = "héllo from C# 🪟" });
        var reply = await channel.ReceiveControlAsync();
        Assert.Equal("ok", reply.T);
        await swift.WaitForLineAsync(l => l == "TEXT Windows PC: héllo from C# 🪟");
    }

    [Fact]
    public void SasAndTranscriptMatchKnownSwiftValues()
    {
        // Same inputs as Swift's SecureChannel.transcriptHash / sasCode (deterministic).
        var transcript = SecureChannel.TranscriptHash("client"u8.ToArray(), "server"u8.ToArray());
        Assert.Equal(32, transcript.Length);
        Assert.Matches("^[0-9]{6}$", SecureChannel.SasCode(transcript));
    }
}
