using AirBridge.Engine;
using AirBridge.Net;

namespace AirBridge.Core.Tests;

public class CapabilityParsingTests
{
    const string Drivers = """
        Interface name: Wi-Fi

            Driver                    : Intel(R) Wi-Fi 6E AX211 160MHz
            Vendor                    : Intel Corporation
            Radio types supported     : 802.11b 802.11g 802.11n 802.11a 802.11ac 802.11ax
            FIPS 140-2 mode supported : Yes
            Hosted network supported  : No
        """;

    const string WirelessCapabilities = """
        Wireless Device Capabilities
            WiFi Direct Device                                  : Supported
            WiFi Direct GO                                      : Supported
            WiFi Direct Client                                  : Supported
            Network monitor mode                                : Not supported
        """;

    const string IwList = """
        Wiphy phy1
        	max # scan SSIDs: 4
        	Supported interface modes:
        		 * IBSS
        		 * managed
        		 * AP
        		 * monitor
        		 * mesh point
        	Band 1:
        """;

    [Fact]
    public void ParsesNetshOutput()
    {
        Assert.True(AdapterCapabilities.Supports5GHz(Drivers));
        Assert.False(AdapterCapabilities.Supports5GHz("Radio types supported : 802.11b 802.11g 802.11n"));
        Assert.True(AdapterCapabilities.SupportsWifiDirect(WirelessCapabilities));
        Assert.False(AdapterCapabilities.ParseMonitorMode(WirelessCapabilities));
        Assert.True(AdapterCapabilities.ParseMonitorMode("Network monitor mode : Supported"));
        Assert.Null(AdapterCapabilities.ParseMonitorMode(Drivers));
    }

    [Fact]
    public void ParsesLinuxAdapterModesAndOpenDropOutput()
    {
        Assert.True(AirDropBridge.SupportsMonitorMode(IwList));
        Assert.False(AirDropBridge.SupportsMonitorMode(IwList.Replace("* monitor", "* P2P-client", StringComparison.Ordinal)));
        var found = AirDropBridge.ParseFound("Found  index 0  ID eccb2f2dcfe7  name Alice’s iPhone");
        Assert.Equal(new AirDropBridge.AppleDevice("eccb2f2dcfe7", 0, "Alice’s iPhone"), found);
        Assert.Null(AirDropBridge.ParseFound("Looking for receivers. Press Ctrl+C to stop ..."));
        Assert.Equal("/mnt/c/Users/me/Downloads", AirDropBridge.ToWslPath(@"C:\Users\me\Downloads"));
    }

    [Fact]
    public void LinksParseLikeTheSwiftImplementation()
    {
        var https = Node.ParseLink(new Uri("https://relay.example.workers.dev/r/AbCdEfGhIjKlMnOpQrStUv#00ff"));
        Assert.Equal(("https://relay.example.workers.dev/", "AbCdEfGhIjKlMnOpQrStUv", "00ff"), (https?.Base.ToString(), https?.Room, https?.Fingerprint));
        var deep = Node.ParseLink(new Uri("airbridge://join/AbCdEfGhIjKlMnOpQrStUv?relay=relay.example.workers.dev#00ff"));
        Assert.Equal("wss://relay.example.workers.dev/room/R?role=join", Node.RelaySocketUri(deep!.Value.Base, "R", "join").ToString());
    }

    [Fact]
    public void UnsafePathsAreRejectedAndWindowsNamesCleaned()
    {
        Assert.Throws<AirBridge.Protocol.AirBridgeException>(() => ChunkSink.SafeComponents("../x"));
        Assert.Throws<AirBridge.Protocol.AirBridgeException>(() => ChunkSink.SafeComponents(@"a\..\..\x"));
        Assert.Equal(["abs", "x"], ChunkSink.SafeComponents("/abs/x"));
        Assert.Equal(["Notes- draft-.txt"], ChunkSink.SafeComponents("Notes: draft?.txt"));
    }
}
