using System.Diagnostics;
using System.Text.RegularExpressions;
using AirBridge.Engine;

namespace AirBridge.Net;

/// <summary>
/// Lets Apple devices AirDrop to this PC (and this PC AirDrop to them) when Windows has no AirDrop.
///
/// AirDrop runs over Apple Wireless Direct Link (AWDL). Outside Apple hardware the only working stack is
/// OWL (open AWDL, TU Darmstadt SEEMOO) + OpenDrop, which need Linux and a Wi-Fi adapter with monitor
/// mode and frame injection. On Windows that means WSL2 with a USB adapter passed through by usbipd-win.
/// See windows/scripts/setup-airdrop-wsl.ps1. Apple devices see this PC only when their AirDrop is set
/// to "Everyone" (Contacts Only needs Apple-issued certificates).
/// </summary>
public sealed partial class AirDropBridge : IAsyncDisposable
{
    public sealed record Options(string ReceiveFolder, string DeviceName, string WifiInterface = "wlan1", string AwdlInterface = "awdl0");

    public sealed record AppleDevice(string Id, int Index, string Name);

    readonly Node _node;
    readonly Options _options;
    readonly CancellationTokenSource _cts = new();
    readonly List<Process> _processes = [];
    FileSystemWatcher? _watcher;

    public event Action<string>? Log;
    public bool Running { get; private set; }

    public AirDropBridge(Node node, Options options)
    {
        _node = node;
        _options = options;
    }

    /// <summary>True when OWL and OpenDrop are installed in WSL and an adapter there can do monitor mode.</summary>
    public static async Task<bool> CheckReadyAsync(CancellationToken ct = default)
    {
        var output = await Capabilities_RunWsl("command -v owl; command -v opendrop; iw list", ct).ConfigureAwait(false);
        return output is not null && output.Contains("/owl", StringComparison.Ordinal) && output.Contains("/opendrop", StringComparison.Ordinal)
            && SupportsMonitorMode(output);
    }

    static Task<string?> Capabilities_RunWsl(string script, CancellationToken ct) =>
        AdapterCapabilities.RunAsync("wsl.exe", $"-u root -e sh -c \"{script}\"", ct);

    /// <summary>`iw list` lists "Supported interface modes:" followed by "* monitor" for capable adapters.</summary>
    public static bool SupportsMonitorMode(string iwList)
    {
        var section = InterfaceModes().Match(iwList);
        return section.Success && section.Groups[1].Value.Contains("* monitor", StringComparison.Ordinal);
    }

    [GeneratedRegex(@"Supported interface modes:\s*\n((?:\s*\*.*\n?)+)")]
    private static partial Regex InterfaceModes();

    /// <summary>Windows path → path inside WSL (C:\Users\me → /mnt/c/Users/me).</summary>
    public static string ToWslPath(string windowsPath)
    {
        var full = windowsPath.Replace('\\', '/');
        return full.Length >= 2 && full[1] == ':' ? $"/mnt/{char.ToLowerInvariant(full[0])}{full[2..]}" : full;
    }

    /// <summary>OpenDrop's `find` prints lines like "Found  index 0  ID eccb2f2dcfe7  name Alice's iPhone".</summary>
    public static AppleDevice? ParseFound(string line) =>
        FoundLine().Match(line) is { Success: true } m
            ? new AppleDevice(m.Groups[2].Value, int.Parse(m.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture), m.Groups[3].Value.Trim())
            : null;

    [GeneratedRegex(@"index\s+(\d+)\s+ID\s+(\S+)\s+name\s+(.+)$", RegexOptions.IgnoreCase)]
    private static partial Regex FoundLine();

    /// <summary>Starts OWL (brings up awdl0), OpenDrop's receiver, and discovery of nearby Apple devices.</summary>
    public void Start()
    {
        if (Running) return;
        Running = true;
        Directory.CreateDirectory(_options.ReceiveFolder);
        StartWsl($"owl -i {_options.WifiInterface} -N");
        _ = Task.Run(async () =>
        {
            await Task.Delay(TimeSpan.FromSeconds(3), _cts.Token).ConfigureAwait(false); // let OWL bring awdl0 up
            StartWsl($"cd '{ToWslPath(_options.ReceiveFolder)}' && opendrop receive -i {_options.AwdlInterface} -n '{_options.DeviceName.Replace("'", "", StringComparison.Ordinal)}'");
            await DiscoverLoopAsync().ConfigureAwait(false);
        });
        WatchReceiveFolder();
    }

    Process StartWsl(string script, Action<string>? onLine = null)
    {
        var psi = new ProcessStartInfo("wsl.exe") { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        foreach (var a in new[] { "-u", "root", "-e", "sh", "-c", script }) psi.ArgumentList.Add(a);
        var p = Process.Start(psi) ?? throw new InvalidOperationException("wsl.exe did not start");
        p.OutputDataReceived += (_, e) => { if (e.Data is { } l) { Log?.Invoke(l); onLine?.Invoke(l); } };
        p.ErrorDataReceived += (_, e) => { if (e.Data is { } l) { Log?.Invoke(l); onLine?.Invoke(l); } };
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        lock (_processes) _processes.Add(p);
        return p;
    }

    async Task DiscoverLoopAsync()
    {
        // `opendrop find` runs until stopped; restart it periodically so devices that leave drop off.
        while (!_cts.IsCancellationRequested)
        {
            var seen = new List<AppleDevice>();
            var p = StartWsl($"timeout 20 opendrop find -i {_options.AwdlInterface}", line =>
            {
                if (ParseFound(line) is not { } device) return;
                lock (seen) seen.Add(device);
                _node.UpdatePeer($"airdrop:{device.Id}", device.Name, "airdrop", null, DiscoverySource.AirDrop, [new Endpoint("airdrop", device.Index)]);
            });
            try { await p.WaitForExitAsync(_cts.Token).ConfigureAwait(false); } catch (OperationCanceledException) { return; }
            var current = _node.Peers.Where(x => x.Platform == "airdrop").ToList();
            lock (seen)
                foreach (var gone in current.Where(c => seen.All(s => $"airdrop:{s.Id}" != c.Id)))
                    _node.RemoveSource(gone.Id, DiscoverySource.AirDrop);
        }
    }

    /// <summary>Sends a file to a nearby Apple device found by discovery (peer ids start with "airdrop:").</summary>
    public async Task SendAsync(Peer peer, string path, CancellationToken ct = default)
    {
        if (peer.Platform != "airdrop" || peer.Endpoints.GetValueOrDefault(DiscoverySource.AirDrop) is not [var ep, ..])
            throw new ArgumentException("Not an AirDrop device", nameof(peer));
        var record = _node.RecordExternalTransfer(TransferDirection.Outgoing, peer.Name, Path.GetFileName(path), new FileInfo(path).Length);
        var p = StartWsl($"opendrop send -i {_options.AwdlInterface} -r {ep.Port} -f '{ToWslPath(path)}'");
        await p.WaitForExitAsync(ct).ConfigureAwait(false);
        _node.FinishExternalTransfer(record, p.ExitCode == 0, p.ExitCode == 0 ? null : "The Apple device declined or didn't answer");
    }

    void WatchReceiveFolder()
    {
        _watcher = new FileSystemWatcher(_options.ReceiveFolder) { IncludeSubdirectories = false, EnableRaisingEvents = true };
        _watcher.Created += (_, e) => _ = Task.Run(() => OnReceivedAsync(e.FullPath));
        _watcher.Renamed += (_, e) => _ = Task.Run(() => OnReceivedAsync(e.FullPath));
    }

    /// <summary>OpenDrop writes the file while receiving; report it once its size stops changing.</summary>
    async Task OnReceivedAsync(string path)
    {
        if (Path.GetFileName(path).StartsWith('.')) return;
        long last = -1;
        for (var i = 0; i < 600; i++)
        {
            await Task.Delay(500).ConfigureAwait(false);
            if (!File.Exists(path) && !Directory.Exists(path)) return;
            var size = File.Exists(path) ? new FileInfo(path).Length : 0;
            if (size == last) break;
            last = size;
        }
        var record = _node.RecordExternalTransfer(TransferDirection.Incoming, "AirDrop", Path.GetFileName(path), last);
        record.SavedPaths.Add(path);
        _node.FinishExternalTransfer(record, true, null);
    }

    public async ValueTask DisposeAsync()
    {
        await _cts.CancelAsync().ConfigureAwait(false);
        _watcher?.Dispose();
        lock (_processes)
            foreach (var p in _processes)
            {
                try { if (!p.HasExited) p.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                p.Dispose();
            }
        // OWL leaves awdl0 up if killed abruptly; tidy it.
        await AdapterCapabilities.RunAsync("wsl.exe", "-u root -e sh -c \"pkill owl; pkill -f 'opendrop receive'\"", default).ConfigureAwait(false);
        Running = false;
    }
}
