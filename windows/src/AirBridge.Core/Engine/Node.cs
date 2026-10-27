using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using AirBridge.Protocol;

namespace AirBridge.Engine;

/// <summary>
/// The AirBridge engine for Windows: listener, trust, and every flow in PROTOCOL.md.
/// Thread-safe; events fire on background threads (UI layers marshal to their dispatcher).
/// </summary>
public sealed class Node : IAsyncDisposable
{
    public DeviceIdentity Identity { get; }
    public Settings Settings { get; }
    public string Platform { get; }
    public int? ListeningPort { get; private set; }

    /// <summary>Decides incoming offers and pairing requests. Without a handler, unknown requests are declined.</summary>
    public Func<PromptRequest, Task<bool>>? PromptHandler { get; set; }

    public event Action<ReceivedText, bool /*toClipboard*/>? TextReceived;
    public event Action<TransferInfo>? TransferAdded;
    public event Action<TransferInfo>? TransferFinished;
    public event Action? PeersChanged;
    public event Action? TrustChanged;
    /// <summary>The named device unpaired this one.</summary>
    public event Action<string>? UnpairedByPeer;

    readonly Store _store;
    readonly Lock _lock = new();
    readonly Dictionary<string, TrustedDevice> _trusted;
    readonly Dictionary<string, Peer> _peers = [];
    readonly List<TransferInfo> _transfers = [];
    readonly List<ReceivedText> _inbox = [];
    readonly ConcurrentDictionary<string, ActiveTransfer> _active = new();
    readonly CancellationTokenSource _shutdown = new();
    TcpListener? _listener;
    Task? _ticker;
    int _deliveringUnpairs;

    public Node(Store store, string defaultName, string platform = "win")
    {
        _store = store;
        Platform = platform;
        Identity = DeviceIdentity.LoadOrCreate(Path.Combine(store.Directory, "identity.json"));
        Settings = store.Load<Settings>("settings.json") ?? new Settings { DeviceName = defaultName };
        _trusted = store.Load<Dictionary<string, TrustedDevice>>("trusted.json") ?? [];
        RebuildTrustedPeers();
    }

    public SecureChannel.LocalInfo Local => new(Identity, Settings.DeviceName, Platform, (ushort)(ListeningPort ?? 0));

    public void SaveSettings() => _store.Save(Settings, "settings.json");

    // MARK: state snapshots

    public IReadOnlyList<Peer> Peers { get { lock (_lock) return _peers.Values.OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase).ThenBy(p => p.Id, StringComparer.Ordinal).ToList(); } }
    public IReadOnlyList<TransferInfo> Transfers { get { lock (_lock) return [.. _transfers]; } }
    public IReadOnlyList<ReceivedText> Inbox { get { lock (_lock) return [.. _inbox]; } }
    public IReadOnlyDictionary<string, TrustedDevice> Trusted { get { lock (_lock) return new Dictionary<string, TrustedDevice>(_trusted); } }

    public Peer? FindPeer(string id) { lock (_lock) return _peers.GetValueOrDefault(id); }

    public bool IsTrusted(Peer peer)
    {
        lock (_lock)
            return _trusted.TryGetValue(peer.Id, out var t) && (peer.Fingerprint is null || peer.Fingerprint == t.Fingerprint);
    }

    TrustedDevice? TrustedFor(Hello hello)
    {
        lock (_lock)
            return _trusted.TryGetValue(hello.Id, out var t) && t.Fingerprint == hello.Fingerprint ? t : null;
    }

    // MARK: lifecycle

    /// <summary>Starts the listener (and the progress/sync ticker). Discovery lives in <c>Discovery</c> classes.</summary>
    public void Start(bool listen = true)
    {
        if (listen) StartListener();
        _ticker = Task.Run(TickLoopAsync);
    }

    void StartListener()
    {
        foreach (var port in new[] { Settings.Port, 0 })
        {
            try
            {
                var listener = new TcpListener(IPAddress.IPv6Any, port);
                listener.Server.DualMode = true;
                listener.Start(64);
                _listener = listener;
                ListeningPort = ((IPEndPoint)listener.LocalEndpoint).Port;
                _ = Task.Run(AcceptLoopAsync);
                return;
            }
            catch (SocketException) when (port != 0) { /* port taken: fall back to any free port */ }
        }
    }

    async Task AcceptLoopAsync()
    {
        while (!_shutdown.IsCancellationRequested && _listener is { } listener)
        {
            Socket socket;
            try { socket = await listener.AcceptSocketAsync(_shutdown.Token).ConfigureAwait(false); }
            catch (Exception e) when (e is OperationCanceledException or ObjectDisposedException or SocketException) { return; }
            _ = Task.Run(() => HandleIncomingAsync(new TcpWire(socket)));
        }
    }

    async Task TickLoopAsync()
    {
        var lastSync = DateTimeOffset.MinValue;
        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(250));
        try
        {
            while (await timer.WaitForNextTickAsync(_shutdown.Token).ConfigureAwait(false))
            {
                foreach (var t in Transfers.Where(t => !t.IsFinished)) t.Sample();
                if (DateTimeOffset.Now - lastSync > TimeSpan.FromSeconds(5))
                {
                    lastSync = DateTimeOffset.Now;
                    _ = DeliverPendingUnpairsAsync();
                    RunSyncRules();
                }
            }
        }
        catch (OperationCanceledException) { }
    }

    public async ValueTask DisposeAsync()
    {
        await _shutdown.CancelAsync().ConfigureAwait(false);
        _listener?.Stop();
        if (_ticker is not null) await _ticker.ConfigureAwait(false);
        Identity.Dispose();
    }

    // MARK: peers

    /// <summary>Discovery sources report what they see here (mDNS, Bluetooth, AirDrop bridge).</summary>
    public void UpdatePeer(string id, string name, string platform, string? fingerprint, DiscoverySource source, IReadOnlyList<Endpoint> endpoints, int? rssi = null)
    {
        if (id == Identity.Id) return;
        lock (_lock)
        {
            if (!_peers.TryGetValue(id, out var peer)) _peers[id] = peer = new Peer { Id = id };
            peer.Name = name;
            peer.Platform = platform;
            peer.Fingerprint = fingerprint ?? peer.Fingerprint;
            peer.LastSeen = DateTimeOffset.Now;
            peer.Rssi = rssi ?? peer.Rssi;
            peer.Endpoints[source] = [.. endpoints];
        }
        PeersChanged?.Invoke();
    }

    public void RemoveSource(string id, DiscoverySource source)
    {
        lock (_lock)
        {
            if (!_peers.TryGetValue(id, out var peer)) return;
            peer.Endpoints.Remove(source);
            if (!peer.Sources.Any() && !_trusted.ContainsKey(id)) _peers.Remove(id);
        }
        PeersChanged?.Invoke();
    }

    /// <summary>Adds a device by address (VPN, routed network, internet). Its identity is learned on first connect.</summary>
    public async Task<Peer> AddManualPeerAsync(string host, int port, CancellationToken ct = default)
    {
        var (channel, _) = await ConnectAsync([new Endpoint(host, port)], null, ct).ConfigureAwait(false);
        await using (channel.ConfigureAwait(false))
        {
            var hello = channel.Peer;
            UpdatePeer(hello.Id, hello.Name, hello.Platform, hello.Fingerprint, DiscoverySource.Manual, [new Endpoint(host, port)]);
            return FindPeer(hello.Id)!;
        }
    }

    void RebuildTrustedPeers()
    {
        lock (_lock)
        {
            foreach (var device in _trusted.Values)
            {
                if (!_peers.TryGetValue(device.Id, out var peer))
                    _peers[device.Id] = peer = new Peer { Id = device.Id, Name = device.Name, Platform = device.Platform };
                peer.Fingerprint = device.Fingerprint;
                if (device.LastHost is { } h && device.LastPort is { } p) peer.Endpoints[DiscoverySource.Trusted] = [new Endpoint(h, p)];
            }
        }
        PeersChanged?.Invoke();
    }

    // MARK: trust

    public void UpdateTrusted(TrustedDevice device)
    {
        lock (_lock)
        {
            _trusted[device.Id] = device;
            _store.Save(_trusted, "trusted.json");
        }
        RebuildTrustedPeers();
        TrustChanged?.Invoke();
    }

    /// <summary>Unpairs locally and tells the other device, now or the next time it is reachable.</summary>
    public void Unpair(string id)
    {
        lock (_lock)
        {
            if (_trusted.TryGetValue(id, out var device))
            {
                var pending = _store.Load<Dictionary<string, TrustedDevice>>("pending-unpairs.json") ?? [];
                pending[id] = device;
                _store.Save(pending, "pending-unpairs.json");
            }
        }
        RemoveTrust(id);
        _ = DeliverPendingUnpairsAsync();
    }

    internal void RemoveTrust(string id)
    {
        lock (_lock)
        {
            _trusted.Remove(id);
            _store.Save(_trusted, "trusted.json");
            if (_peers.TryGetValue(id, out var peer))
            {
                peer.Endpoints.Remove(DiscoverySource.Trusted);
                if (!peer.IsOnline) _peers.Remove(id);
            }
            Settings.SyncRules.RemoveAll(r => r.DeviceId == id);
        }
        SaveSettings();
        PeersChanged?.Invoke();
        TrustChanged?.Invoke();
    }

    async Task DeliverPendingUnpairsAsync()
    {
        if (Interlocked.Exchange(ref _deliveringUnpairs, 1) == 1) return;
        try
        {
            var pending = _store.Load<Dictionary<string, TrustedDevice>>("pending-unpairs.json") ?? [];
            foreach (var (id, device) in pending.ToList())
            {
                var endpoints = FindPeer(id)?.OrderedEndpoints.ToList() ?? [];
                if (device.LastHost is { } h && device.LastPort is { } p) endpoints.Add(new Endpoint(h, p));
                if (endpoints.Count == 0) continue;
                try
                {
                    var (channel, _) = await ConnectAsync(endpoints, device.Fingerprint).ConfigureAwait(false);
                    await using (channel.ConfigureAwait(false))
                    {
                        await channel.SendAsync(new ControlMessage("unpair")).ConfigureAwait(false);
                        try { await channel.ReceiveControlAsync().ConfigureAwait(false); } catch (AirBridgeException) { }
                    }
                    pending.Remove(id);
                }
                catch (AirBridgeException) { /* not reachable yet */ }
            }
            _store.Save(pending, "pending-unpairs.json");
        }
        finally { Interlocked.Exchange(ref _deliveringUnpairs, 0); }
    }

    void PeerRevokedTrust(Hello hello)
    {
        var device = TrustedFor(hello);
        if (device is null) return;
        RemoveTrust(hello.Id);
        UnpairedByPeer?.Invoke(device.Name);
    }

    void Trust(Hello hello, Endpoint? address)
    {
        TrustedDevice device;
        lock (_lock)
        {
            device = _trusted.GetValueOrDefault(hello.Id) ?? new TrustedDevice { Id = hello.Id, Name = hello.Name, Fingerprint = hello.Fingerprint, Platform = hello.Platform };
        }
        device.Name = hello.Name;
        device.Fingerprint = hello.Fingerprint;
        device.Platform = hello.Platform;
        if (address is { } a) { device.LastHost = a.Host; device.LastPort = a.Port; }
        UpdateTrusted(device);
    }

    /// <summary>Remember where a trusted device answered from, so it is reachable without discovery next time.</summary>
    void RememberAddress(Hello hello, Wire wire)
    {
        if (TrustedFor(hello) is not { } device || hello.Port == 0 || wire.RemoteEndPoint is not { } remote) return;
        var address = remote.Address.IsIPv4MappedToIPv6 ? remote.Address.MapToIPv4() : remote.Address;
        if (address.IsIPv6LinkLocal) return;
        var host = address.ToString();
        if (device.LastHost == host && device.LastPort == hello.Port) return;
        device.LastHost = host;
        device.LastPort = hello.Port;
        UpdateTrusted(device);
    }

    // MARK: inbox

    public void DeleteText(Guid id) { lock (_lock) _inbox.RemoveAll(t => t.Id == id); }
    public void ClearInbox() { lock (_lock) _inbox.Clear(); }
    public void ClearFinishedTransfers() { lock (_lock) _transfers.RemoveAll(t => t.IsFinished); }

    TransferInfo AddTransfer(TransferInfo t)
    {
        lock (_lock) _transfers.Insert(0, t);
        TransferAdded?.Invoke(t);
        return t;
    }

    void Finish(TransferInfo t, TransferState state, string? error = null)
    {
        t.Finish(state, error);
        TransferFinished?.Invoke(t);
    }

    /// <summary>Transfers handled outside the AirBridge protocol (the AirDrop bridge) still show up in the list.</summary>
    public TransferInfo RecordExternalTransfer(TransferDirection direction, string peerName, string title, long size)
    {
        var record = AddTransfer(new TransferInfo
        {
            Id = Guid.NewGuid().ToString().ToUpperInvariant(), Direction = direction, PeerName = peerName, Title = title, Total = size,
        });
        record.Activate(() => 0);
        return record;
    }

    public void FinishExternalTransfer(TransferInfo record, bool success, string? error) =>
        Finish(record, success ? TransferState.Done : TransferState.Failed, error);

    static TransferState FailureState(Exception e) =>
        e is AirBridgeException { Kind: AirBridgeError.Declined } ? TransferState.Declined : TransferState.Failed;

    // MARK: connecting

    internal async Task<(SecureChannel Channel, Endpoint Endpoint)> ConnectAsync(IReadOnlyList<Endpoint> endpoints, string? fingerprint, CancellationToken ct = default)
    {
        Exception last = new AirBridgeException(AirBridgeError.ConnectFailed, "device is not reachable");
        foreach (var endpoint in endpoints)
        {
            try
            {
                var wire = await TcpWire.ConnectAsync(endpoint.Host, endpoint.Port, TimeSpan.FromSeconds(6), ct).ConfigureAwait(false);
                SecureChannel channel;
                try { channel = await SecureChannel.HandshakeAsync(wire, Local, isClient: true, ct).ConfigureAwait(false); }
                catch { wire.Close(); throw; }
                if (fingerprint is not null && channel.Peer.Fingerprint != fingerprint)
                {
                    await channel.DisposeAsync().ConfigureAwait(false);
                    throw new AirBridgeException(AirBridgeError.AuthenticationFailed);
                }
                return (channel, endpoint);
            }
            catch (AirBridgeException e) when (e.Kind != AirBridgeError.AuthenticationFailed) { last = e; }
        }
        throw last;
    }

    async Task<(SecureChannel Channel, Endpoint Endpoint)> ConnectAsync(Peer peer, CancellationToken ct)
    {
        string? fingerprint;
        lock (_lock) fingerprint = peer.Fingerprint ?? _trusted.GetValueOrDefault(peer.Id)?.Fingerprint;
        var result = await ConnectAsync(peer.OrderedEndpoints, fingerprint, ct).ConfigureAwait(false);
        RememberAddress(result.Channel.Peer, result.Channel.Wire);
        return result;
    }

    // MARK: outgoing operations

    /// <summary>Sends files and folders (push). <paramref name="sync"/> marks auto-upload transfers that overwrite.</summary>
    public Task<TransferInfo> SendAsync(IEnumerable<string> paths, Peer peer, bool sync = false, CancellationToken ct = default) =>
        SendAsync(OutgoingItems.Expand(paths), peer, sync, ct);

    internal async Task<TransferInfo> SendAsync(OutgoingItems outgoing, Peer peer, bool sync, CancellationToken ct = default)
    {
        var transferId = Guid.NewGuid().ToString().ToUpperInvariant();
        var record = AddTransfer(new TransferInfo
        {
            Id = transferId, Direction = TransferDirection.Outgoing, PeerName = peer.Name, Title = outgoing.Title, Total = outgoing.Total, Sync = sync,
        });
        try
        {
            var (control, endpoint) = await ConnectAsync(peer, ct).ConfigureAwait(false);
            await using (control.ConfigureAwait(false))
                await PushAsync(outgoing, transferId, sync, control, endpoint, record, ct).ConfigureAwait(false);
        }
        catch (Exception e) when (e is AirBridgeException or IOException or UnauthorizedAccessException)
        {
            Finish(record, FailureState(e), e.Message);
            throw;
        }
        Finish(record, TransferState.Done);
        return record;
    }

    /// <summary>Client-side push once the control channel is up. <paramref name="endpoint"/> null means relay.</summary>
    async Task PushAsync(OutgoingItems outgoing, string transferId, bool sync, SecureChannel control, Endpoint? endpoint, TransferInfo record, CancellationToken ct)
    {
        await control.SendAsync(new ControlMessage("offer")
        {
            TransferId = transferId, Items = outgoing.Items, Total = outgoing.Total, Sync = sync ? true : null,
        }, ct).ConfigureAwait(false);
        record.SetState(TransferState.WaitingForAcceptance);
        var reply = await control.ReceiveControlAsync(ct).ConfigureAwait(false);
        if (reply.T == "notPaired")
        {
            PeerRevokedTrust(control.Peer);
            throw new AirBridgeException(AirBridgeError.NotTrusted);
        }
        if (reply.T != "accept") throw new AirBridgeException(AirBridgeError.Declined, reply.Reason ?? "");

        using var source = new ChunkSource(outgoing);
        record.Activate(() => source.Progress);
        if (endpoint is { } ep && reply.Streams is > 0 and var n)
        {
            await RunClientTransferAsync(control, ep, transferId, Math.Min(n, 16), new Role.Send(source), ct).ConfigureAwait(false);
        }
        else
        {
            await RunStreamAsync(control, new Role.Send(source), ct).ConfigureAwait(false);
            var done = await control.ReceiveControlAsync(ct).ConfigureAwait(false);
            if (done.T != "complete") throw new AirBridgeException(AirBridgeError.ProtocolViolation, done.Reason ?? "transfer failed");
        }
    }

    /// <summary>Sends the same files to several devices at once.</summary>
    public Task SendAsync(IReadOnlyList<string> paths, IEnumerable<Peer> peers) =>
        Task.WhenAll(peers.Select(async p => { try { await SendAsync(paths, p).ConfigureAwait(false); } catch (AirBridgeException) { } }));

    public async Task SendTextAsync(string text, Peer peer, CancellationToken ct = default)
    {
        var (control, _) = await ConnectAsync(peer, ct).ConfigureAwait(false);
        await using (control.ConfigureAwait(false))
        {
            await control.SendAsync(new ControlMessage("text") { Text = text }, ct).ConfigureAwait(false);
            var reply = await control.ReceiveControlAsync(ct).ConfigureAwait(false);
            if (reply.T != "ok") throw new AirBridgeException(AirBridgeError.Declined, reply.Reason ?? "");
        }
    }

    /// <summary>Pairs with a device. <paramref name="showCode"/> gets the 6-digit code to compare.</summary>
    public async Task PairAsync(Peer peer, Action<string> showCode, CancellationToken ct = default)
    {
        var (control, endpoint) = await ConnectAsync(peer.OrderedEndpoints, peer.Fingerprint, ct).ConfigureAwait(false);
        await using (control.ConfigureAwait(false))
        {
            showCode(control.Sas);
            await control.SendAsync(new ControlMessage("pair"), ct).ConfigureAwait(false);
            var reply = await control.ReceiveControlAsync(ct).ConfigureAwait(false);
            if (reply.T != "pairAccepted") throw new AirBridgeException(AirBridgeError.Declined, reply.Reason ?? "");
            Trust(control.Peer, endpoint);
            RememberAddress(control.Peer, control.Wire);
        }
    }

    public async Task<IReadOnlyList<RemoteEntry>> BrowseAsync(Peer peer, string path = "", CancellationToken ct = default)
    {
        var (control, _) = await ConnectAsync(peer, ct).ConfigureAwait(false);
        await using (control.ConfigureAwait(false))
        {
            await control.SendAsync(new ControlMessage("list") { Path = path }, ct).ConfigureAwait(false);
            var reply = await control.ReceiveControlAsync(ct).ConfigureAwait(false);
            if (reply.T == "notPaired") { PeerRevokedTrust(control.Peer); throw new AirBridgeException(AirBridgeError.NotTrusted); }
            if (reply.T != "listing") throw new AirBridgeException(AirBridgeError.Declined, reply.Reason ?? "");
            return reply.Entries ?? [];
        }
    }

    /// <summary>Downloads paths from a trusted device's shared folder.</summary>
    public async Task<TransferInfo> PullAsync(IEnumerable<string> paths, Peer peer, CancellationToken ct = default)
    {
        var (control, endpoint) = await ConnectAsync(peer, ct).ConfigureAwait(false);
        await using (control.ConfigureAwait(false))
        {
            await control.SendAsync(new ControlMessage("pull") { Paths = [.. paths] }, ct).ConfigureAwait(false);
            var offer = await control.ReceiveControlAsync(ct).ConfigureAwait(false);
            if (offer.T == "notPaired") { PeerRevokedTrust(control.Peer); throw new AirBridgeException(AirBridgeError.NotTrusted); }
            if (offer.T != "offer") throw new AirBridgeException(AirBridgeError.Declined, offer.Reason ?? "");
            return await ReceiveOfferAsync(offer, control, requested: true, endpoint, ct).ConfigureAwait(false);
        }
    }

    // MARK: internet links (relay)

    public bool RelayConfigured => Uri.TryCreate(Settings.RelayUrl, UriKind.Absolute, out var u) && u.Host.Length > 0;

    /// <summary>Shares files through a one-time internet link; returns once the recipient has received them.</summary>
    public async Task<TransferInfo> ShareViaLinkAsync(IEnumerable<string> paths, Action<Uri> onLink, CancellationToken ct = default)
    {
        if (!Uri.TryCreate(Settings.RelayUrl, UriKind.Absolute, out var baseUri))
            throw new AirBridgeException(AirBridgeError.ConnectFailed, "Set a relay URL in Settings first");
        var outgoing = OutgoingItems.Expand(paths);
        var room = Convert.ToBase64String(RandomNumberGenerator.GetBytes(16)).Replace('+', '-').Replace('/', '_').TrimEnd('=');
        // The fingerprint travels in the fragment, which browsers never send to the relay.
        onLink(new Uri($"{baseUri.GetLeftPart(UriPartial.Authority)}/r/{room}#{Identity.Fingerprint}"));

        var transferId = Guid.NewGuid().ToString().ToUpperInvariant();
        var record = AddTransfer(new TransferInfo
        {
            Id = transferId, Direction = TransferDirection.Outgoing, PeerName = "Link recipient", Title = outgoing.Title, Total = outgoing.Total,
        });
        record.SetState(TransferState.WaitingForAcceptance);
        try
        {
            var wire = await RelayWire.ConnectAsync(RelaySocketUri(baseUri, room, "host"), TimeSpan.FromHours(1), ct).ConfigureAwait(false);
            var control = await SecureChannel.HandshakeAsync(wire, Local, isClient: true, ct).ConfigureAwait(false);
            await using (control.ConfigureAwait(false))
                await PushAsync(outgoing, transferId, false, control, null, record, ct).ConfigureAwait(false);
        }
        catch (Exception e) when (e is AirBridgeException or IOException)
        {
            Finish(record, FailureState(e), e.Message);
            throw;
        }
        Finish(record, TransferState.Done);
        return record;
    }

    public static Uri RelaySocketUri(Uri baseUri, string room, string role)
    {
        var scheme = baseUri.Scheme == "http" ? "ws" : "wss";
        return new Uri($"{scheme}://{baseUri.Authority}/room/{room}?role={role}");
    }

    /// <summary>Accepts https://relay/r/&lt;room&gt;#&lt;fingerprint&gt; or airbridge://join/&lt;room&gt;?relay=&lt;host&gt;#&lt;fingerprint&gt;.</summary>
    public static (Uri Base, string Room, string? Fingerprint)? ParseLink(Uri link)
    {
        var parts = link.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var fingerprint = link.Fragment.TrimStart('#') is { Length: > 0 } f ? f : null;
        if (link.Scheme == "airbridge" && link.Host == "join" && parts.Length >= 1)
        {
            var relay = System.Web.HttpUtility.ParseQueryString(link.Query)["relay"];
            if (relay is null) return null;
            return (new Uri(relay.Contains("://", StringComparison.Ordinal) ? relay : $"https://{relay}"), parts[0], fingerprint);
        }
        if (link.Scheme is "https" or "http" && parts is ["r", var room])
            return (new Uri(link.GetLeftPart(UriPartial.Authority)), room, fingerprint);
        return null;
    }

    /// <summary>Opens a link someone shared: connects through the relay and receives their files.</summary>
    public async Task OpenLinkAsync(Uri link, CancellationToken ct = default)
    {
        if (ParseLink(link) is not var (baseUri, room, fingerprint))
            throw new AirBridgeException(AirBridgeError.ProtocolViolation, "Not an AirBridge link");
        var wire = await RelayWire.ConnectAsync(RelaySocketUri(baseUri, room, "join"), TimeSpan.FromSeconds(30), ct).ConfigureAwait(false);
        var control = await SecureChannel.HandshakeAsync(wire, Local, isClient: false, ct).ConfigureAwait(false);
        await using (control.ConfigureAwait(false))
        {
            if (fingerprint is not null && !string.Equals(control.Peer.Fingerprint, fingerprint, StringComparison.OrdinalIgnoreCase))
                throw new AirBridgeException(AirBridgeError.AuthenticationFailed);
            var offer = await control.ReceiveControlAsync(ct).ConfigureAwait(false);
            if (offer.T != "offer") throw new AirBridgeException(AirBridgeError.ProtocolViolation, "expected an offer");
            await ReceiveOfferAsync(offer, control, requested: false, null, ct).ConfigureAwait(false);
        }
    }

    // MARK: transfer plumbing

    internal abstract record Role
    {
        public sealed record Send(ChunkSource Source) : Role;
        public sealed record Receive(ChunkSink Sink) : Role;
    }

    internal sealed record ActiveTransfer(string Fingerprint, Role Role);

    /// <summary>Client side of the data phase: open the stream connections and run them.</summary>
    async Task RunClientTransferAsync(SecureChannel control, Endpoint endpoint, string transferId, int streams, Role role, CancellationToken ct)
    {
        var fingerprint = control.Peer.Fingerprint;
        var opened = new ConcurrentBag<SecureChannel>();
        try
        {
            var tasks = Enumerable.Range(0, streams).Select(_ => Task.Run(async () =>
            {
                var (channel, _) = await ConnectAsync([endpoint], fingerprint, ct).ConfigureAwait(false);
                opened.Add(channel);
                await channel.SendAsync(new ControlMessage("stream") { TransferId = transferId }, ct).ConfigureAwait(false);
                await RunStreamAsync(channel, role, ct).ConfigureAwait(false);
            }, ct)).ToList();

            switch (role)
            {
                case Role.Send:
                    // Streams finish pumping; the receiver confirms on the control connection.
                    var confirmation = control.ReceiveControlAsync(ct);
                    try { await Task.WhenAll(tasks).ConfigureAwait(false); }
                    catch { control.Close(); throw; }
                    var done = await confirmation.ConfigureAwait(false);
                    if (done.T != "complete") throw new AirBridgeException(AirBridgeError.ProtocolViolation, done.Reason ?? "transfer failed");
                    break;
                case Role.Receive(var sink):
                    foreach (var t in tasks) _ = t.ContinueWith(x => sink.Fail(x.Exception!.GetBaseException()), TaskContinuationOptions.OnlyOnFaulted);
                    await sink.Completion.ConfigureAwait(false);
                    sink.Commit();
                    await control.SendAsync(new ControlMessage("complete") { TransferId = transferId }, ct).ConfigureAwait(false);
                    break;
            }
        }
        finally
        {
            foreach (var c in opened) c.Close();
        }
    }

    /// <summary>Runs one bound stream in either direction until the transfer's data is exhausted.</summary>
    static async Task RunStreamAsync(SecureChannel channel, Role role, CancellationToken ct)
    {
        switch (role)
        {
            case Role.Send(var source):
                // Read the next chunk while the previous one is being encrypted and sent.
                Task<byte[]>? next = null;
                int nextLength = 0;
                if (source.TryNext(out var i0, out var o0, out var l0)) { next = source.PlaintextAsync(i0, o0, l0, ct); nextLength = l0; }
                while (next is not null)
                {
                    var plain = await next.ConfigureAwait(false);
                    var length = nextLength;
                    next = source.TryNext(out var i, out var o, out var l) ? source.PlaintextAsync(i, o, l, ct) : null;
                    nextLength = l;
                    await channel.SendPlaintextAsync(plain, ct).ConfigureAwait(false);
                    source.AddProgress(length);
                }
                break;
            case Role.Receive(var sink):
                while (!sink.IsComplete)
                {
                    var (type, payload) = await channel.ReceiveAsync(ct).ConfigureAwait(false);
                    if (type == FrameType.Chunk) await sink.WriteAsync(payload, ct).ConfigureAwait(false);
                }
                break;
        }
    }

    // MARK: incoming

    async Task HandleIncomingAsync(Wire wire)
    {
        try
        {
            var channel = await SecureChannel.HandshakeAsync(wire, Local, isClient: false, _shutdown.Token).ConfigureAwait(false);
            await using (channel.ConfigureAwait(false))
            {
                var first = await channel.ReceiveControlAsync(_shutdown.Token).ConfigureAwait(false);
                switch (first.T)
                {
                    case "stream": await AttachStreamAsync(channel, first).ConfigureAwait(false); break;
                    case "offer": await ReceiveOfferAsync(first, channel, requested: false, null, _shutdown.Token).ConfigureAwait(false); break;
                    case "text": await HandleTextAsync(first, channel).ConfigureAwait(false); break;
                    case "pair": await HandlePairAsync(channel).ConfigureAwait(false); break;
                    case "list": await HandleListAsync(first, channel).ConfigureAwait(false); break;
                    case "pull": await HandlePullAsync(first, channel).ConfigureAwait(false); break;
                    case "unpair":
                        PeerRevokedTrust(channel.Peer);
                        await channel.SendAsync(new ControlMessage("ok")).ConfigureAwait(false);
                        break;
                    default: await channel.SendAsync(ControlMessage.Error($"unknown request {first.T}")).ConfigureAwait(false); break;
                }
            }
        }
        catch (Exception e) when (e is AirBridgeException or IOException or OperationCanceledException or UnauthorizedAccessException)
        {
            wire.Close();
        }
    }

    async Task AttachStreamAsync(SecureChannel channel, ControlMessage msg)
    {
        if (msg.TransferId is not { } id || !_active.TryGetValue(id, out var transfer) || transfer.Fingerprint != channel.Peer.Fingerprint)
            throw new AirBridgeException(AirBridgeError.ProtocolViolation, "unknown transfer");
        try
        {
            await RunStreamAsync(channel, transfer.Role, _shutdown.Token).ConfigureAwait(false);
            if (transfer.Role is Role.Send)
            {
                // Keep the socket open until the client hangs up so buffered bytes are not cut off.
                try { await channel.ReceiveAsync(_shutdown.Token).ConfigureAwait(false); } catch (AirBridgeException) { }
            }
        }
        catch (Exception e) when (transfer.Role is Role.Receive)
        {
            ((Role.Receive)transfer.Role).Sink.Fail(e);
            throw;
        }
    }

    /// <summary>Receiver side of an offer, pushed to us (server) or answering our pull (client).</summary>
    async Task<TransferInfo> ReceiveOfferAsync(ControlMessage offer, SecureChannel control, bool requested, Endpoint? clientEndpoint, CancellationToken ct)
    {
        var hello = control.Peer;
        if (offer.TransferId is not { } transferId || offer.Items is not { } items)
            throw new AirBridgeException(AirBridgeError.ProtocolViolation, "malformed offer");
        var total = items.Where(i => !i.IsDirectory).Sum(i => i.Size);
        var device = TrustedFor(hello);
        var sync = offer.Sync == true && device is not null;
        if (device is not null) RememberAddress(hello, control.Wire);
        // An auto-upload from a device we no longer trust: tell it, so it stops syncing and drops the pairing.
        if (offer.Sync == true && device is null)
        {
            await control.SendAsync(ControlMessage.NotPaired, ct).ConfigureAwait(false);
            throw new AirBridgeException(AirBridgeError.NotTrusted);
        }

        var reason = "";
        bool decision;
        if (requested) decision = true;
        else if (Settings.ReceivePolicy == ReceivePolicy.Off) { decision = false; reason = "Receiving is turned off"; }
        else if (device is not null && (device.AutoAccept || sync)) decision = true;
        else if (Settings.ReceivePolicy == ReceivePolicy.TrustedOnly && device is null) { decision = false; reason = "Only trusted devices may send"; }
        else decision = PromptHandler is { } ask && await ask(new PromptRequest(hello.Name, hello.Platform, hello.Fingerprint, PromptKind.Offer, items, total)).ConfigureAwait(false);

        if (!decision)
        {
            await control.SendAsync(new ControlMessage("decline") { TransferId = transferId, Reason = reason.Length > 0 ? reason : "The recipient declined" }, ct).ConfigureAwait(false);
            throw new AirBridgeException(AirBridgeError.Declined, reason);
        }

        var baseDir = sync ? Path.Combine(Settings.DownloadFolder, SafeFolderName(hello.Name)) : Settings.DownloadFolder;
        var tops = items.Select(i => i.Path.Split('/')[0]).Distinct().ToList();
        var record = AddTransfer(new TransferInfo
        {
            Id = transferId, Direction = TransferDirection.Incoming, PeerName = hello.Name, Sync = sync, Total = total,
            Title = tops.Count == 1 ? tops[0] : $"{items.Count(i => !i.IsDirectory)} files",
        });

        try
        {
            using var sink = new ChunkSink(items, baseDir, overwrite: sync);
            record.Activate(() => sink.Progress);
            // Over the relay every byte already shares one pipe; use the control socket for data.
            var streams = control.Wire.IsRelay ? 0 : total < 8 << 20 ? 1 : Math.Max(1, Settings.ParallelStreams);
            var accept = new ControlMessage("accept") { TransferId = transferId, Streams = streams };
            try
            {
                if (streams == 0)
                {
                    await control.SendAsync(accept, ct).ConfigureAwait(false);
                    await RunStreamAsync(control, new Role.Receive(sink), ct).ConfigureAwait(false);
                    sink.Commit();
                    await control.SendAsync(new ControlMessage("complete") { TransferId = transferId }, ct).ConfigureAwait(false);
                }
                else if (clientEndpoint is { } ep)
                {
                    await control.SendAsync(accept, ct).ConfigureAwait(false);
                    await RunClientTransferAsync(control, ep, transferId, streams, new Role.Receive(sink), ct).ConfigureAwait(false);
                }
                else
                {
                    _active[transferId] = new ActiveTransfer(hello.Fingerprint, new Role.Receive(sink));
                    try
                    {
                        await control.SendAsync(accept, ct).ConfigureAwait(false);
                        // If the sender disappears, the control socket closes; fail instead of waiting forever.
                        _ = Task.Run(async () =>
                        {
                            try { await control.ReceiveAsync(ct).ConfigureAwait(false); } catch (Exception) { }
                            sink.Fail(new AirBridgeException(AirBridgeError.ConnectionClosed));
                        }, ct);
                        await sink.Completion.ConfigureAwait(false);
                        sink.Commit();
                        await control.SendAsync(new ControlMessage("complete") { TransferId = transferId }, ct).ConfigureAwait(false);
                    }
                    finally { _active.TryRemove(transferId, out _); }
                }
            }
            catch { sink.Discard(); throw; }
            record.SavedPaths.AddRange(sink.FinalPaths);
        }
        catch (Exception e) when (e is AirBridgeException or IOException or UnauthorizedAccessException)
        {
            Finish(record, FailureState(e), e.Message);
            throw;
        }
        Finish(record, TransferState.Done);
        return record;
    }

    async Task HandleTextAsync(ControlMessage msg, SecureChannel control)
    {
        var device = TrustedFor(control.Peer);
        if (Settings.ReceivePolicy == ReceivePolicy.Off || (device is null && Settings.ReceivePolicy != ReceivePolicy.Everyone)
            || msg.Text is not { } text || text.Length > 1 << 20)
        {
            await control.SendAsync(ControlMessage.Error("Not accepted")).ConfigureAwait(false);
            return;
        }
        var item = new ReceivedText(control.Peer.Name, text);
        lock (_lock) _inbox.Insert(0, item);
        TextReceived?.Invoke(item, device?.AutoClipboard == true);
        await control.SendAsync(new ControlMessage("ok")).ConfigureAwait(false);
    }

    async Task HandlePairAsync(SecureChannel control)
    {
        var hello = control.Peer;
        if (Settings.ReceivePolicy == ReceivePolicy.Off)
        {
            await control.SendAsync(new ControlMessage("pairDeclined") { Reason = "Receiving is turned off" }).ConfigureAwait(false);
            return;
        }
        var accepted = PromptHandler is { } ask && await ask(new PromptRequest(hello.Name, hello.Platform, hello.Fingerprint, PromptKind.Pairing, Code: control.Sas)).ConfigureAwait(false);
        if (accepted)
        {
            Trust(hello, null);
            RememberAddress(hello, control.Wire);
            await control.SendAsync(new ControlMessage("pairAccepted")).ConfigureAwait(false);
        }
        else
        {
            await control.SendAsync(new ControlMessage("pairDeclined") { Reason = "Pairing was declined" }).ConfigureAwait(false);
        }
    }

    /// <summary>Resolves a path inside the shared folder, refusing anything that escapes it.</summary>
    string? SharedPath(string relative)
    {
        if (Settings.SharedFolder is not { } root) return null;
        var rootFull = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar);
        var parts = relative.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Contains("..")) return null;
        var full = Path.GetFullPath(Path.Combine([rootFull, .. parts]));
        return full == rootFull || full.StartsWith(rootFull + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ? full : null;
    }

    async Task HandleListAsync(ControlMessage msg, SecureChannel control)
    {
        if (TrustedFor(control.Peer) is not { AllowBrowse: true })
        {
            await control.SendAsync(ControlMessage.NotPaired).ConfigureAwait(false);
            return;
        }
        if (SharedPath(msg.Path ?? "") is not { } dir || !Directory.Exists(dir))
        {
            await control.SendAsync(ControlMessage.Error("No shared folder")).ConfigureAwait(false);
            return;
        }
        var options = new EnumerationOptions { AttributesToSkip = FileAttributes.Hidden | FileAttributes.System };
        var entries = new DirectoryInfo(dir).EnumerateFileSystemInfos("*", options)
            .Select(e => new RemoteEntry(e.Name, e is FileInfo f ? f.Length : 0, e is DirectoryInfo))
            .OrderBy(e => e.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
        await control.SendAsync(new ControlMessage("listing") { Entries = entries }).ConfigureAwait(false);
    }

    async Task HandlePullAsync(ControlMessage msg, SecureChannel control)
    {
        var hello = control.Peer;
        if (TrustedFor(hello) is not { AllowBrowse: true })
        {
            await control.SendAsync(ControlMessage.NotPaired).ConfigureAwait(false);
            return;
        }
        var paths = (msg.Paths ?? []).Select(SharedPath).OfType<string>().Where(p => File.Exists(p) || Directory.Exists(p)).ToList();
        if (paths.Count == 0)
        {
            await control.SendAsync(ControlMessage.Error("Nothing to send")).ConfigureAwait(false);
            return;
        }
        var outgoing = OutgoingItems.Expand(paths);
        var transferId = Guid.NewGuid().ToString().ToUpperInvariant();
        var record = AddTransfer(new TransferInfo
        {
            Id = transferId, Direction = TransferDirection.Outgoing, PeerName = hello.Name, Title = outgoing.Title, Total = outgoing.Total,
        });
        using var source = new ChunkSource(outgoing);
        _active[transferId] = new ActiveTransfer(hello.Fingerprint, new Role.Send(source));
        try
        {
            await control.SendAsync(new ControlMessage("offer") { TransferId = transferId, Items = outgoing.Items, Total = outgoing.Total }).ConfigureAwait(false);
            var reply = await control.ReceiveControlAsync().ConfigureAwait(false);
            if (reply.T != "accept") throw new AirBridgeException(AirBridgeError.Declined, reply.Reason ?? "");
            record.Activate(() => source.Progress);
            var done = await control.ReceiveControlAsync().ConfigureAwait(false);
            if (done.T != "complete") throw new AirBridgeException(AirBridgeError.ProtocolViolation, "transfer failed");
            Finish(record, TransferState.Done);
        }
        catch (AirBridgeException e) { Finish(record, FailureState(e), e.Message); }
        finally { _active.TryRemove(transferId, out _); }
    }

    static string SafeFolderName(string name)
    {
        var cleaned = string.Concat(name.Select(c => Path.GetInvalidFileNameChars().Contains(c) || c is '/' or '\\' or ':' ? '-' : c)).Trim();
        return cleaned.Length == 0 || cleaned.StartsWith('.') ? "Device" : cleaned;
    }

    // MARK: auto-sync (auto upload)

    readonly ConcurrentDictionary<string, bool> _syncBusy = new();

    public void AddSyncRule(string folder, string deviceId)
    {
        lock (_lock) Settings.SyncRules.Add(new SyncRule { DeviceId = deviceId, Folder = folder });
        SaveSettings();
    }

    public void RemoveSyncRule(string id)
    {
        lock (_lock) Settings.SyncRules.RemoveAll(r => r.Id == id);
        SaveSettings();
        try { _store.Remove($"sync-{id}.json"); } catch (IOException) { }
    }

    void RunSyncRules()
    {
        List<SyncRule> rules;
        lock (_lock) rules = Settings.SyncRules.Where(r => r.Enabled).ToList();
        foreach (var rule in rules)
        {
            if (FindPeer(rule.DeviceId) is not { } peer || !IsTrusted(peer) || !_syncBusy.TryAdd(rule.Id, true)) continue;
            _ = Task.Run(async () =>
            {
                try
                {
                    var manifestName = $"sync-{rule.Id}.json";
                    var previous = _store.Load<Dictionary<string, string>>(manifestName) ?? [];
                    var (changes, manifest) = ScanChanges(rule.Folder, previous);
                    if (changes.Items.Count == 0) return;
                    await SendAsync(changes, peer, sync: true).ConfigureAwait(false);
                    _store.Save(manifest, manifestName);
                }
                catch (Exception e) when (e is AirBridgeException or IOException or UnauthorizedAccessException) { /* retry on the next scan */ }
                finally { _syncBusy.TryRemove(rule.Id, out _); }
            });
        }
    }

    /// <summary>Files whose size or modification time changed since the last successful sync.</summary>
    internal static (OutgoingItems Changes, Dictionary<string, string> Manifest) ScanChanges(string folder, Dictionary<string, string> previous)
    {
        var all = OutgoingItems.Expand([folder]);
        var manifest = new Dictionary<string, string>();
        var changed = new OutgoingItems();
        for (var i = 0; i < all.Items.Count; i++)
        {
            var item = all.Items[i];
            if (item.IsDirectory) continue;
            var mtime = new DateTimeOffset(File.GetLastWriteTimeUtc(all.Paths[i])).ToUnixTimeSeconds();
            var signature = $"{item.Size}:{mtime}";
            manifest[item.Path] = signature;
            if (previous.GetValueOrDefault(item.Path) != signature) changed.Add(item.Path, all.Paths[i], item.Size, dir: false);
        }
        return (changed, manifest);
    }
}
