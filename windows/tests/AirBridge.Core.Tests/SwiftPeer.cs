using System.Diagnostics;
using System.Threading.Channels;

namespace AirBridge.Core.Tests;

/// <summary>
/// Runs the Swift reference implementation (`airbridge-cli`, built with `swift build -c release`)
/// as a real peer, so these tests prove wire compatibility with the Mac and iPhone apps.
/// </summary>
public sealed class SwiftPeer : IAsyncDisposable
{
    public static readonly string RepoRoot = FindRepoRoot();
    public static string CliPath => Path.Combine(RepoRoot, ".build", "release", "airbridge-cli");
    public static bool Available => File.Exists(CliPath);

    readonly Process _process;
    readonly Channel<string> _lines = Channel.CreateUnbounded<string>();
    public string Home { get; }
    public string Downloads { get; }
    public string Shared { get; }
    public int Port { get; private set; }
    public string Fingerprint { get; private set; } = "";
    public List<string> Output { get; } = [];

    SwiftPeer(Process process, string home)
    {
        _process = process;
        Home = home;
        Downloads = Path.Combine(home, "Downloads");
        Shared = Path.Combine(home, "Shared");
    }

    static string FindRepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Package.swift"))) dir = dir.Parent;
        return dir?.FullName ?? throw new InvalidOperationException("repo root not found");
    }

    static ProcessStartInfo StartInfo(string home, params string[] args)
    {
        var psi = new ProcessStartInfo(CliPath)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        psi.Environment["AIRBRIDGE_HOME"] = Path.Combine(home, "state");
        psi.Environment["AIRBRIDGE_PORT"] = "0";
        psi.Environment["AIRBRIDGE_DOWNLOADS"] = Path.Combine(home, "Downloads");
        psi.Environment["AIRBRIDGE_SHARED"] = Path.Combine(home, "Shared");
        psi.Environment["AIRBRIDGE_NAME"] = "Swift Mac";
        return psi;
    }

    /// <summary>Starts `airbridge-cli receive`, which auto-accepts offers and pairing.</summary>
    public static async Task<SwiftPeer> StartReceiverAsync()
    {
        var home = Directory.CreateTempSubdirectory("ab-swift-").FullName;
        Directory.CreateDirectory(Path.Combine(home, "Shared"));
        var process = Process.Start(StartInfo(home, "receive"))!;
        var peer = new SwiftPeer(process, home);
        _ = peer.PumpAsync(process.StandardOutput);
        _ = peer.PumpAsync(process.StandardError);
        var listening = await peer.WaitForLineAsync(l => l.StartsWith("Listening on port ", StringComparison.Ordinal));
        peer.Port = int.Parse(listening.Split(' ')[3].TrimEnd(';'), System.Globalization.CultureInfo.InvariantCulture);
        peer.Fingerprint = (await peer.WaitForLineAsync(l => l.StartsWith("FINGERPRINT ", StringComparison.Ordinal))).Split(' ')[1];
        return peer;
    }

    /// <summary>Runs a one-shot CLI command (send/text/open) and returns its output.</summary>
    public static async Task<(int Exit, string Output)> RunAsync(string home, params string[] args)
    {
        using var process = Process.Start(StartInfo(home, args))!;
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(60));
        await process.WaitForExitAsync(cts.Token);
        return (process.ExitCode, await stdout + await stderr);
    }

    async Task PumpAsync(StreamReader reader)
    {
        while (await reader.ReadLineAsync() is { } line)
        {
            lock (Output) Output.Add(line);
            await _lines.Writer.WriteAsync(line);
        }
    }

    public async Task<string> WaitForLineAsync(Func<string, bool> match, int seconds = 30)
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
        try
        {
            while (true)
            {
                var line = await _lines.Reader.ReadAsync(cts.Token);
                if (match(line)) return line;
            }
        }
        catch (OperationCanceledException)
        {
            string all;
            lock (Output) all = string.Join('\n', Output);
            throw new TimeoutException($"Swift peer never printed the expected line. Output so far:\n{all}");
        }
    }

    public async ValueTask DisposeAsync()
    {
        try { _process.Kill(entireProcessTree: true); await _process.WaitForExitAsync(); } catch (InvalidOperationException) { }
        _process.Dispose();
        try { Directory.Delete(Home, recursive: true); } catch (IOException) { }
    }
}
