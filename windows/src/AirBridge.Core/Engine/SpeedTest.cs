using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Text.Json.Serialization;
using AirBridge.Protocol;

namespace AirBridge.Engine;

/// <summary>How speeds are shown: megabytes per second (like file sizes) or megabits per second (like network plans).</summary>
[JsonConverter(typeof(JsonStringEnumConverter<SpeedUnit>))]
public enum SpeedUnit { Bytes, Bits }

public static class SpeedFormat
{
    static readonly string[] ByteUnits = ["B/s", "KB/s", "MB/s", "GB/s"];
    static readonly string[] BitUnits = ["bps", "kbps", "Mbps", "Gbps"];

    public static string Label(this SpeedUnit unit) => unit == SpeedUnit.Bytes ? "MB/s" : "Mbps";

    /// <summary>"112 MB/s" or "899 Mbps". Decimal units throughout, like Explorer and internet providers.</summary>
    public static string Format(this SpeedUnit unit, double bytesPerSecond)
    {
        var v = Math.Max(0, unit == SpeedUnit.Bytes ? bytesPerSecond : bytesPerSecond * 8);
        var units = unit == SpeedUnit.Bytes ? ByteUnits : BitUnits;
        var i = 0;
        while (v >= 1000 && i < units.Length - 1) { v /= 1000; i++; }
        var format = v >= 100 || i == 0 ? "0" : v >= 10 ? "0.0" : "0.00";
        return v.ToString(format, CultureInfo.CurrentCulture) + " " + units[i];
    }
}

public sealed record SpeedTestResult(double Upload, double Download);

public enum SpeedTestPhase { Upload, Download }

public sealed record SpeedTestProgress(SpeedTestPhase Phase, double Fraction, double BytesPerSecond);

/// <summary>Zero-filled chunks up to <see cref="Total"/> bytes. Encryption makes them incompressible on the wire.</summary>
public sealed class SpeedSource(long total)
{
    readonly byte[] _chunk = CreateChunk();
    long _handedOut;
    long _sent;

    public long Total { get; } = total;
    public long Sent => Interlocked.Read(ref _sent);

    static byte[] CreateChunk()
    {
        var chunk = new byte[13 + ChunkSource.ChunkSize];
        chunk[0] = (byte)FrameType.Chunk;
        return chunk;
    }

    public bool TryNext(out int length)
    {
        while (true)
        {
            var done = Interlocked.Read(ref _handedOut);
            if (done >= Total) { length = 0; return false; }
            length = (int)Math.Min(ChunkSource.ChunkSize, Total - done);
            if (Interlocked.CompareExchange(ref _handedOut, done + length, done) == done) return true;
        }
    }

    public ReadOnlyMemory<byte> Plaintext(int length) => _chunk.AsMemory(0, 13 + length);
    internal void AddSent(int n) => Interlocked.Add(ref _sent, n);
}

/// <summary>Counts bytes arriving on any number of streams until <see cref="Total"/> is reached.</summary>
public sealed class SpeedSink(long total)
{
    readonly TaskCompletionSource _done = new(TaskCreationOptions.RunContinuationsAsynchronously);
    long _received;

    public long Total { get; } = total;
    public long Received => Interlocked.Read(ref _received);
    public bool IsComplete => Received >= Total;
    public Task Completion => _done.Task;

    public void Add(int n) { if (Interlocked.Add(ref _received, n) >= Total) _done.TrySetResult(); }
    public void Fail(Exception e) => _done.TrySetException(e);
}

public sealed partial class Node
{
    const long SpeedTestLimit = 1L << 30;

    /// <summary>
    /// Measures throughput to and from <paramref name="peer"/> over the same encrypted parallel streams files use.
    /// A short probe sizes each phase to take about three seconds on this network.
    /// </summary>
    public async Task<SpeedTestResult> SpeedTestAsync(Peer peer, Action<SpeedTestProgress>? progress = null, CancellationToken ct = default)
    {
        var upload = await MeasureAsync(peer, SpeedTestPhase.Upload, progress, ct).ConfigureAwait(false);
        var download = await MeasureAsync(peer, SpeedTestPhase.Download, progress, ct).ConfigureAwait(false);
        return new SpeedTestResult(upload, download);
    }

    async Task<double> MeasureAsync(Peer peer, SpeedTestPhase phase, Action<SpeedTestProgress>? progress, CancellationToken ct)
    {
        var probe = await SpeedRunAsync(peer, phase, 8L << 20, null, ct).ConfigureAwait(false);
        var total = Math.Clamp((long)(probe * 3), 16L << 20, SpeedTestLimit);
        return await SpeedRunAsync(peer, phase, total, (f, r) => progress?.Invoke(new SpeedTestProgress(phase, f, r)), ct).ConfigureAwait(false);
    }

    /// <summary>One timed run. Returns bytes per second.</summary>
    async Task<double> SpeedRunAsync(Peer peer, SpeedTestPhase phase, long total, Action<double, double>? report, CancellationToken ct)
    {
        string? fingerprint;
        lock (_lock) fingerprint = peer.Fingerprint ?? _trusted.GetValueOrDefault(peer.Id)?.Fingerprint;
        var (control, endpoint) = await ConnectAsync(peer.OrderedEndpoints, fingerprint, ct).ConfigureAwait(false);
        await using var controlScope = control.ConfigureAwait(false);
        var upload = phase == SpeedTestPhase.Upload;
        var transferId = Guid.NewGuid().ToString().ToUpperInvariant();
        await control.SendAsync(new ControlMessage("speedtest")
        {
            TransferId = transferId, Total = total, Mode = upload ? "upload" : "download", Streams = Math.Max(1, Settings.ParallelStreams),
        }, ct).ConfigureAwait(false);
        var reply = await control.ReceiveControlAsync(ct).ConfigureAwait(false);
        if (reply.T != "accept")
        {
            if (reply.T == "error" && reply.Reason?.StartsWith("unknown request", StringComparison.Ordinal) == true)
                throw new AirBridgeException(AirBridgeError.ProtocolViolation, $"{peer.Name} needs a newer AirBridge for speed tests");
            throw new AirBridgeException(AirBridgeError.Declined, reply.Reason ?? "");
        }
        var streams = Math.Clamp(reply.Streams ?? 1, 1, 16);
        var source = new SpeedSource(total);
        var sink = new SpeedSink(total);
        Role role = upload ? new Role.Blast(source) : new Role.Drain(sink);
        Func<long> counter = upload ? () => source.Sent : () => sink.Received;
        var clock = Stopwatch.StartNew();
        double Rate(long bytes) => bytes / Math.Max(clock.Elapsed.TotalSeconds, 1e-3);

        using var tickerStop = new CancellationTokenSource();
        var ticker = report is null ? Task.CompletedTask : Task.Run(async () =>
        {
            try
            {
                while (!tickerStop.IsCancellationRequested)
                {
                    await Task.Delay(150, tickerStop.Token).ConfigureAwait(false);
                    var b = counter();
                    report((double)b / total, Rate(b));
                }
            }
            catch (OperationCanceledException) { }
        }, CancellationToken.None);

        var opened = new ConcurrentBag<SecureChannel>();
        try
        {
            var tasks = Enumerable.Range(0, streams).Select(_ => Task.Run(async () =>
            {
                var (channel, _) = await ConnectAsync([endpoint], control.Peer.Fingerprint, ct).ConfigureAwait(false);
                opened.Add(channel);
                await channel.SendAsync(new ControlMessage("stream") { TransferId = transferId }, ct).ConfigureAwait(false);
                await RunStreamAsync(channel, role, ct).ConfigureAwait(false);
            }, ct)).ToList();

            if (upload)
            {
                // The receiver says "complete" once every byte has arrived.
                var confirmation = control.ReceiveControlAsync(ct);
                try { await Task.WhenAll(tasks).ConfigureAwait(false); }
                catch { control.Close(); throw; }
                var done = await confirmation.ConfigureAwait(false);
                if (done.T != "complete") throw new AirBridgeException(AirBridgeError.ProtocolViolation, done.Reason ?? "speed test failed");
            }
            else
            {
                foreach (var t in tasks) _ = t.ContinueWith(x => sink.Fail(x.Exception!.GetBaseException()), TaskContinuationOptions.OnlyOnFaulted);
                await sink.Completion.ConfigureAwait(false);
                try { await control.SendAsync(new ControlMessage("complete") { TransferId = transferId }, ct).ConfigureAwait(false); }
                catch (AirBridgeException) { }
            }
        }
        finally
        {
            foreach (var c in opened) c.Close();
            await tickerStop.CancelAsync().ConfigureAwait(false);
            await ticker.ConfigureAwait(false);
        }
        var result = Rate(total);
        report?.Invoke(1, result);
        return result;
    }

    /// <summary>Server side: count an upload, or stream a download, on the client's stream connections.</summary>
    async Task HandleSpeedTestAsync(ControlMessage msg, SecureChannel control)
    {
        if (Settings.ReceivePolicy == ReceivePolicy.Off)
        {
            await control.SendAsync(ControlMessage.Error("Receiving is turned off")).ConfigureAwait(false);
            return;
        }
        if (msg.TransferId is not { } transferId || msg.Total is not (> 0 and <= SpeedTestLimit) || msg.Mode is not ("upload" or "download"))
        {
            await control.SendAsync(ControlMessage.Error("Bad speed test request")).ConfigureAwait(false);
            return;
        }
        var total = msg.Total.Value;
        var streams = Math.Clamp(msg.Streams ?? Settings.ParallelStreams, 1, 16);
        var sink = new SpeedSink(total);
        Role role = msg.Mode == "upload" ? new Role.Drain(sink) : new Role.Blast(new SpeedSource(total));
        _active[transferId] = new ActiveTransfer(control.Peer.Fingerprint, role);
        try
        {
            await control.SendAsync(new ControlMessage("accept") { TransferId = transferId, Streams = streams }).ConfigureAwait(false);
            if (msg.Mode == "upload")
            {
                // If the client disappears, its control socket closes; stop waiting.
                _ = Task.Run(async () =>
                {
                    try { await control.ReceiveAsync(_shutdown.Token).ConfigureAwait(false); } catch (Exception) { }
                    sink.Fail(new AirBridgeException(AirBridgeError.ConnectionClosed));
                });
                await sink.Completion.ConfigureAwait(false);
                await control.SendAsync(new ControlMessage("complete") { TransferId = transferId }).ConfigureAwait(false);
            }
            else
            {
                // The client says "complete" (or hangs up) when it has everything.
                try { await control.ReceiveControlAsync(_shutdown.Token).ConfigureAwait(false); } catch (AirBridgeException) { }
            }
        }
        finally { _active.TryRemove(transferId, out _); }
    }
}
