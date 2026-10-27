using System.Diagnostics;
using AirBridge.Engine;
using AirBridge.Net;

namespace AirBridge.Core.Tests;

/// <summary>The C# mDNS against Apple's Bonjour (runs on macOS, where mDNSResponder is the other side).</summary>
public sealed class DiscoveryTests
{
    [Fact]
    public async Task WindowsFindsMacAndMacFindsWindowsOverMdns()
    {
        if (!OperatingSystem.IsMacOS()) return;
        await using var swift = await SwiftPeer.StartReceiverAsync();
        var temp = Directory.CreateTempSubdirectory("ab-mdns-").FullName;
        var node = new Node(new Store(temp), "Windows Discovery Test") { Settings = { Port = 0 } };
        node.Start();
        using var mdns = new Mdns(node);
        mdns.Start();
        try
        {
            // Windows → Mac: the Swift CLI's Bonjour advertisement shows up as a LAN peer with its real port.
            Peer? mac = null;
            for (var i = 0; i < 100 && mac is null; i++)
            {
                mac = node.Peers.FirstOrDefault(p => p.Fingerprint == swift.Fingerprint &&
                    p.Endpoints.GetValueOrDefault(DiscoverySource.Lan)?.Any(e => e.Port == swift.Port) == true);
                if (mac is null) await Task.Delay(100);
            }
            Assert.NotNull(mac);
            Assert.Equal("Swift Mac", mac.Name);

            // Mac → Windows: Bonjour resolves our instance to our port and TXT record.
            var psi = new ProcessStartInfo("dns-sd", ["-L", node.Identity.Id, "_airbridge._tcp", "local"])
            { RedirectStandardOutput = true, UseShellExecute = false };
            using var dnsSd = Process.Start(psi)!;
            var output = "";
            var deadline = DateTime.UtcNow.AddSeconds(10);
            while (DateTime.UtcNow < deadline && !output.Contains($"fp={node.Identity.Fingerprint}", StringComparison.Ordinal))
            {
                var line = await dnsSd.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(10));
                if (line is null) break;
                output += line + "\n";
            }
            dnsSd.Kill();
            Assert.Contains($":{node.ListeningPort} ", output);
            Assert.Contains($"fp={node.Identity.Fingerprint}", output);
            Assert.Contains("pl=win", output);

            // And the found Mac is actually reachable through what discovery reported.
            await node.SendTextAsync("found you over mDNS", mac);
            await swift.WaitForLineAsync(l => l == "TEXT Windows Discovery Test: found you over mDNS");
        }
        finally
        {
            await node.DisposeAsync();
            Directory.Delete(temp, recursive: true);
        }
    }
}
