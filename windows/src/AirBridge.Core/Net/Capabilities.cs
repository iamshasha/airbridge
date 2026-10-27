using System.Diagnostics;
using System.Net.NetworkInformation;
using System.Text.RegularExpressions;

namespace AirBridge.Net;

/// <summary>
/// What this PC's radios can do: which transports AirBridge can use, and whether it can emulate AirDrop
/// (that needs a Wi-Fi adapter with monitor mode + frame injection, driven from Linux in WSL2).
/// </summary>
public sealed partial record AdapterCapabilities
{
    public string? WifiAdapter { get; init; }
    public bool WifiUp { get; init; }
    public bool Wifi5GHz { get; init; }
    public bool WifiDirect { get; init; }
    public bool? MonitorMode { get; init; }
    public bool EthernetUp { get; init; }
    public IReadOnlyList<string> VpnAdapters { get; init; } = [];
    public string BluetoothState { get; init; } = "unknown";
    public bool BluetoothLE { get; init; }
    public bool WslInstalled { get; init; }
    public bool UsbipdInstalled { get; init; }
    public AirDropStatus AirDrop { get; init; } = AirDropStatus.Unsupported;

    public enum AirDropStatus
    {
        /// <summary>No WSL2 or no compatible adapter: Apple devices can't see this PC over AirDrop.</summary>
        Unsupported,
        /// <summary>WSL2 and usbipd are present; attach a monitor-mode USB Wi-Fi adapter to enable it.</summary>
        NeedsAdapter,
        /// <summary>OWL + OpenDrop are installed in WSL2 and an adapter supports monitor mode and injection.</summary>
        Ready,
    }

    public IEnumerable<(string Name, string Detail, bool Ok)> Summary =>
    [
        ("Wi-Fi", WifiAdapter is null ? "none" : $"{WifiAdapter}{(Wifi5GHz ? ", 5 GHz" : "")}{(WifiUp ? ", connected" : "")}", WifiUp),
        ("Wi-Fi Direct", WifiDirect ? "supported" : "not supported", WifiDirect),
        ("Monitor mode (built-in Wi-Fi)", MonitorMode switch { true => "supported", false => "not supported", null => "unknown" }, MonitorMode == true),
        ("Bluetooth LE", BluetoothState, BluetoothLE),
        ("Ethernet", EthernetUp ? "connected" : "not connected", EthernetUp),
        ("VPN / overlay", VpnAdapters.Count == 0 ? "none" : string.Join(", ", VpnAdapters), VpnAdapters.Count > 0),
        ("AirDrop emulation", AirDrop switch
        {
            AirDropStatus.Ready => "ready (OWL + OpenDrop in WSL2)",
            AirDropStatus.NeedsAdapter => "attach a monitor-mode USB Wi-Fi adapter to WSL2",
            _ => "needs WSL2 and a monitor-mode USB Wi-Fi adapter",
        }, AirDrop == AirDropStatus.Ready),
    ];

    public static async Task<AdapterCapabilities> ProbeAsync(string bluetoothState = "unknown", bool bluetoothLE = false, CancellationToken ct = default)
    {
        var interfaces = NetworkInterface.GetAllNetworkInterfaces();
        var wifi = interfaces.FirstOrDefault(n => n.NetworkInterfaceType == NetworkInterfaceType.Wireless80211);
        var caps = new AdapterCapabilities
        {
            WifiAdapter = wifi?.Description,
            WifiUp = wifi?.OperationalStatus == OperationalStatus.Up,
            EthernetUp = interfaces.Any(n => n.NetworkInterfaceType is NetworkInterfaceType.Ethernet or NetworkInterfaceType.GigabitEthernet && n.OperationalStatus == OperationalStatus.Up
                && !IsVpn(n)),
            VpnAdapters = interfaces.Where(n => n.OperationalStatus == OperationalStatus.Up && IsVpn(n)).Select(n => n.Name).ToList(),
            BluetoothState = bluetoothState,
            BluetoothLE = bluetoothLE,
        };
        if (!OperatingSystem.IsWindows()) return caps;

        var drivers = await RunAsync("netsh", "wlan show drivers", ct).ConfigureAwait(false);
        var capabilities = await RunAsync("netsh", "wlan show wirelesscapabilities", ct).ConfigureAwait(false);
        var wsl = await RunAsync("wsl.exe", "--status", ct).ConfigureAwait(false);
        var usbipd = await RunAsync("usbipd", "--version", ct).ConfigureAwait(false);
        caps = caps with
        {
            Wifi5GHz = drivers is not null && Supports5GHz(drivers),
            WifiDirect = SupportsWifiDirect((drivers ?? "") + (capabilities ?? "")),
            MonitorMode = capabilities is null ? null : ParseMonitorMode(capabilities),
            WslInstalled = wsl is not null,
            UsbipdInstalled = usbipd is not null,
        };
        var airDrop = caps.WslInstalled && caps.UsbipdInstalled
            ? await AirDropBridge.CheckReadyAsync(ct).ConfigureAwait(false) ? AirDropStatus.Ready : AirDropStatus.NeedsAdapter
            : AirDropStatus.Unsupported;
        return caps with { AirDrop = airDrop };
    }

    static bool IsVpn(NetworkInterface n) =>
        n.NetworkInterfaceType is NetworkInterfaceType.Tunnel or NetworkInterfaceType.Ppp ||
        VpnName().IsMatch(n.Description) || VpnName().IsMatch(n.Name);

    [GeneratedRegex("tailscale|wireguard|zerotier|openvpn|tap-windows|wintun|vpn", RegexOptions.IgnoreCase)]
    private static partial Regex VpnName();

    // MARK: netsh parsing (unit-tested with sample output)

    /// <summary>`netsh wlan show drivers` → "Radio types supported : 802.11b 802.11g 802.11n 802.11a 802.11ac 802.11ax".</summary>
    public static bool Supports5GHz(string drivers) =>
        RadioTypes().Match(drivers) is { Success: true } m && Regex.IsMatch(m.Groups[1].Value, @"802\.11(a\b|ac|ax|be)");

    [GeneratedRegex(@"Radio types supported\s*:\s*(.+)", RegexOptions.IgnoreCase)]
    private static partial Regex RadioTypes();

    /// <summary>"Wi-Fi Direct Device ... : Supported" (or the older "Hosted network supported : Yes").</summary>
    public static bool SupportsWifiDirect(string drivers) =>
        Regex.IsMatch(drivers, @"Wi-?Fi Direct (Device|GO|Client)[^\r\n:]*:\s*(Supported|Yes)", RegexOptions.IgnoreCase);

    /// <summary>`netsh wlan show wirelesscapabilities` → "Network monitor mode : Supported". Null if absent.</summary>
    public static bool? ParseMonitorMode(string output) =>
        MonitorLine().Match(output) is { Success: true } m ? !m.Groups[1].Value.Contains("not", StringComparison.OrdinalIgnoreCase) : null;

    [GeneratedRegex(@"monitor mode\s*:\s*([^\r\n]+)", RegexOptions.IgnoreCase)]
    private static partial Regex MonitorLine();

    internal static async Task<string?> RunAsync(string file, string args, CancellationToken ct)
    {
        try
        {
            using var p = Process.Start(new ProcessStartInfo(file, args)
            {
                RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true,
                StandardOutputEncoding = file.StartsWith("wsl", StringComparison.OrdinalIgnoreCase) ? System.Text.Encoding.Unicode : null,
            });
            if (p is null) return null;
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromSeconds(10));
            var output = await p.StandardOutput.ReadToEndAsync(cts.Token).ConfigureAwait(false);
            await p.WaitForExitAsync(cts.Token).ConfigureAwait(false);
            return p.ExitCode == 0 ? output : null;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or OperationCanceledException or InvalidOperationException)
        {
            return null;
        }
    }
}
