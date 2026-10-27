using System.Net;
using System.Net.WebSockets;
using System.Security.Cryptography;
using AirBridge.Engine;
using AirBridge.Protocol;

namespace AirBridge.Core.Tests;

/// <summary>Full flows between the Windows engine and the Swift reference implementation, in both directions.</summary>
public sealed class InteropTests : IAsyncLifetime
{
    string _temp = "";
    Node _node = null!;

    public Task InitializeAsync()
    {
        Assert.True(SwiftPeer.Available, $"Build the Swift CLI first: swift build -c release ({SwiftPeer.CliPath})");
        _temp = Directory.CreateTempSubdirectory("ab-net-").FullName;
        _node = new Node(new Store(Path.Combine(_temp, "state")), "Windows PC");
        _node.Settings.Port = 0;
        _node.Settings.DownloadFolder = Path.Combine(_temp, "Downloads");
        _node.Settings.SharedFolder = Directory.CreateDirectory(Path.Combine(_temp, "Shared")).FullName;
        _node.PromptHandler = _ => Task.FromResult(true);
        _node.Start();
        return Task.CompletedTask;
    }

    public async Task DisposeAsync()
    {
        await _node.DisposeAsync();
        try { Directory.Delete(_temp, recursive: true); } catch (IOException) { }
    }

    static void WriteRandom(string path, int size)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, RandomNumberGenerator.GetBytes(size));
    }

    static string Hash(string path) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));

    static string MakeFolder(string root)
    {
        var folder = Path.Combine(root, "Holiday Photos");
        WriteRandom(Path.Combine(folder, "big.raw"), (40 << 20) + 12345); // > 8 MiB → parallel streams
        WriteRandom(Path.Combine(folder, "nested", "note.txt"), 17);
        Directory.CreateDirectory(Path.Combine(folder, "empty"));
        File.WriteAllBytes(Path.Combine(folder, "zero.dat"), []);
        return folder;
    }

    static void AssertSameFolder(string expected, string actual)
    {
        Assert.Equal(Hash(Path.Combine(expected, "big.raw")), Hash(Path.Combine(actual, "big.raw")));
        Assert.Equal(Hash(Path.Combine(expected, "nested", "note.txt")), Hash(Path.Combine(actual, "nested", "note.txt")));
        Assert.True(Directory.Exists(Path.Combine(actual, "empty")));
        Assert.True(File.Exists(Path.Combine(actual, "zero.dat")));
    }

    [Fact]
    public async Task WindowsPairsWithMacThenSendsTextFolderBrowsesPullsAndUnpairs()
    {
        await using var swift = await SwiftPeer.StartReceiverAsync();

        // Pairing: both sides must derive the same 6-digit code.
        string? code = null;
        await _node.PairAsync(Peer.At("127.0.0.1", swift.Port), c => code = c);
        var swiftCode = (await swift.WaitForLineAsync(l => l.StartsWith("PAIRCODE ", StringComparison.Ordinal))).Split(' ')[1];
        Assert.Equal(swiftCode, code);
        var mac = Assert.Single(_node.Trusted.Values);
        Assert.Equal(swift.Fingerprint, mac.Fingerprint);
        var peer = _node.FindPeer(mac.Id)!;

        await _node.SendTextAsync("Hello Mac, from Windows", peer);
        await swift.WaitForLineAsync(l => l == "TEXT Windows PC: Hello Mac, from Windows");

        // Trusted → auto-accepted, 4 parallel streams for the 40 MB file.
        var folder = MakeFolder(_temp);
        var sent = await _node.SendAsync([folder], peer);
        Assert.Equal(TransferState.Done, sent.State);
        await swift.WaitForLineAsync(l => l.StartsWith("TRANSFER Holiday Photos done", StringComparison.Ordinal));
        AssertSameFolder(folder, Path.Combine(swift.Downloads, "Holiday Photos"));

        // Browse and pull from the Mac's shared folder.
        WriteRandom(Path.Combine(swift.Shared, "report.pdf"), 3 << 20);
        var entries = await _node.BrowseAsync(peer);
        Assert.Contains(entries, e => e.Name == "report.pdf" && e.Size == 3 << 20);
        var pulled = await _node.PullAsync(["report.pdf"], peer);
        Assert.Equal(TransferState.Done, pulled.State);
        Assert.Equal(Hash(Path.Combine(swift.Shared, "report.pdf")), Hash(Path.Combine(_node.Settings.DownloadFolder, "report.pdf")));

        // Unpairing tells the Mac.
        _node.Unpair(mac.Id);
        await swift.WaitForLineAsync(l => l == "UNPAIRED Windows PC");
    }

    [Fact]
    public async Task MacSendsFolderAndTextToWindows()
    {
        var swiftHome = Directory.CreateTempSubdirectory("ab-swift-send-").FullName;
        try
        {
            var folder = MakeFolder(swiftHome);
            var (exit, output) = await SwiftPeer.RunAsync(swiftHome, "send", $"127.0.0.1:{_node.ListeningPort}", folder);
            Assert.True(exit == 0, output);
            AssertSameFolder(folder, Path.Combine(_node.Settings.DownloadFolder, "Holiday Photos"));
            var record = _node.Transfers.First(t => t.Direction == TransferDirection.Incoming);
            Assert.Equal(TransferState.Done, record.State);

            (exit, output) = await SwiftPeer.RunAsync(swiftHome, "text", $"127.0.0.1:{_node.ListeningPort}", "Hi Windows 👋");
            Assert.True(exit == 0, output);
            Assert.Equal("Hi Windows 👋", _node.Inbox[0].Text);
        }
        finally { Directory.Delete(swiftHome, recursive: true); }
    }

    [Fact]
    public async Task InternetLinksWorkBothWaysThroughTheRelay()
    {
        await using var relay = await MockRelay.StartAsync();
        var swiftHome = Directory.CreateTempSubdirectory("ab-swift-link-").FullName;
        try
        {
            // Mac shares a link, Windows opens it.
            var file = Path.Combine(swiftHome, "movie.mov");
            WriteRandom(file, (5 << 20) + 777);
            var share = SwiftPeer.RunAsync(swiftHome, "share", relay.BaseUrl, file);
            var link = await relay.WaitForLinkAsync(swiftHome);
            await _node.OpenLinkAsync(link);
            var (exit, output) = await share;
            Assert.True(exit == 0, output);
            Assert.Equal(Hash(file), Hash(Path.Combine(_node.Settings.DownloadFolder, "movie.mov")));

            // Windows shares a link, the Mac opens it.
            _node.Settings.RelayUrl = relay.BaseUrl;
            var mine = Path.Combine(_temp, "slides.key");
            WriteRandom(mine, 2 << 20);
            var linkSource = new TaskCompletionSource<Uri>();
            var sharing = _node.ShareViaLinkAsync([mine], linkSource.SetResult);
            var myLink = await linkSource.Task;
            (exit, output) = await SwiftPeer.RunAsync(swiftHome, "open", myLink.ToString());
            Assert.True(exit == 0, output);
            Assert.Equal(TransferState.Done, (await sharing).State);
            Assert.Equal(Hash(mine), Hash(Path.Combine(swiftHome, "Downloads", "slides.key")));
        }
        finally { Directory.Delete(swiftHome, recursive: true); }
    }
}

/// <summary>In-process stand-in for relay/src/index.js: pairs host and join sockets per room and pipes binary.</summary>
sealed class MockRelay : IAsyncDisposable
{
    readonly HttpListener _listener = new();
    readonly Dictionary<string, (WebSocket? Host, WebSocket? Join, TaskCompletionSource Done)> _rooms = [];
    public string BaseUrl { get; }

    MockRelay(int port)
    {
        BaseUrl = $"http://127.0.0.1:{port}";
        _listener.Prefixes.Add(BaseUrl + "/");
    }

    public static Task<MockRelay> StartAsync()
    {
        var probe = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        var port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        var relay = new MockRelay(port);
        relay._listener.Start();
        _ = relay.AcceptLoopAsync();
        return Task.FromResult(relay);
    }

    async Task AcceptLoopAsync()
    {
        while (_listener.IsListening)
        {
            HttpListenerContext ctx;
            try { ctx = await _listener.GetContextAsync(); } catch (Exception) { return; }
            _ = HandleAsync(ctx);
        }
    }

    async Task HandleAsync(HttpListenerContext ctx)
    {
        var parts = ctx.Request.Url!.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (!ctx.Request.IsWebSocketRequest || parts is not ["room", var room]) { ctx.Response.StatusCode = 404; ctx.Response.Close(); return; }
        var role = ctx.Request.QueryString["role"];
        var socket = (await ctx.AcceptWebSocketAsync(null)).WebSocket;
        (WebSocket? Host, WebSocket? Join, TaskCompletionSource Done) entry;
        lock (_rooms)
        {
            entry = _rooms.GetValueOrDefault(room, (null, null, new TaskCompletionSource()));
            entry = role == "host" ? entry with { Host = socket } : entry with { Join = socket };
            _rooms[room] = entry;
        }
        if (entry is { Host: { } host, Join: { } join })
        {
            var ready = "ready"u8.ToArray();
            await host.SendAsync(ready, WebSocketMessageType.Text, true, default);
            await join.SendAsync(ready, WebSocketMessageType.Text, true, default);
            _ = PipeAsync(host, join);
            _ = PipeAsync(join, host);
        }
        await entry.Done.Task; // keep the request alive until the room closes
    }

    static async Task PipeAsync(WebSocket from, WebSocket to)
    {
        var buffer = new byte[1 << 20];
        try
        {
            while (true)
            {
                var r = await from.ReceiveAsync(buffer, default);
                if (r.MessageType == WebSocketMessageType.Close) break;
                Assert.True(r.Count <= 1 << 20, "messages must fit Cloudflare's 1 MiB cap");
                await to.SendAsync(buffer.AsMemory(0, r.Count), r.MessageType, r.EndOfMessage, default);
            }
        }
        catch (Exception) { }
        try { to.Abort(); } catch (Exception) { }
    }

    /// <summary>The Swift CLI prints "Share this link: …"; we can't read its stdout mid-run, so poll rooms instead.</summary>
    public async Task<Uri> WaitForLinkAsync(string swiftHome)
    {
        _ = swiftHome;
        for (var i = 0; i < 300; i++)
        {
            lock (_rooms)
                foreach (var (room, entry) in _rooms)
                    if (entry.Host is not null && entry.Join is null)
                        return new Uri($"{BaseUrl}/r/{room}");
            await Task.Delay(20);
        }
        throw new TimeoutException("Swift never connected to the relay");
    }

    public ValueTask DisposeAsync()
    {
        _listener.Stop();
        lock (_rooms) foreach (var e in _rooms.Values) e.Done.TrySetResult();
        return ValueTask.CompletedTask;
    }
}
