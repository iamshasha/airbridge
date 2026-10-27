using System.Buffers.Binary;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using AirBridge.Engine;

namespace AirBridge.Net;

/// <summary>
/// Minimal multicast DNS (RFC 6762) / DNS-SD (RFC 6763) for `_airbridge._tcp`: advertises this device and
/// browses for others. Interoperates with Apple's Bonjour, so Windows sees Macs/iPhones and vice versa.
/// </summary>
public sealed class Mdns : IDisposable
{
    public const string ServiceType = "_airbridge._tcp.local";
    static readonly IPAddress Group = IPAddress.Parse("224.0.0.251");
    const int Port = 5353;
    const ushort TypeA = 1, TypePtr = 12, TypeTxt = 16, TypeSrv = 33, TypeAny = 255;

    readonly Node _node;
    readonly UdpClient _udp;
    readonly CancellationTokenSource _cts = new();
    readonly string _hostName;
    readonly Lock _lock = new();
    readonly Dictionary<string, Instance> _instances = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, (List<IPAddress> Addresses, DateTimeOffset Expires)> _hosts = new(StringComparer.OrdinalIgnoreCase);

    sealed class Instance
    {
        public string? Target;
        public int Port;
        public Dictionary<string, string> Txt = [];
        public DateTimeOffset Expires;
        public bool Reported;
    }

    public Mdns(Node node)
    {
        _node = node;
        _hostName = $"ab-{node.Identity.Id[..8].ToLowerInvariant()}.local";
        _udp = new UdpClient(AddressFamily.InterNetwork);
        // Share 5353 with the OS responder (mDNSResponder on macOS, Dnscache on Windows).
        _udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        _udp.Client.Bind(new IPEndPoint(IPAddress.Any, Port));
        _udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, 255);
        _udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastLoopback, true);
        foreach (var address in LocalAddresses())
        {
            try { _udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.AddMembership, new MulticastOption(Group, address)); }
            catch (SocketException) { /* interface without multicast */ }
        }
    }

    string InstanceName => $"{_node.Identity.Id}.{ServiceType}";

    public void Start()
    {
        _ = Task.Run(ReceiveLoopAsync);
        _ = Task.Run(QueryLoopAsync);
        _ = Task.Run(async () =>
        {
            // Announce twice, one second apart (RFC 6762 §8.3).
            for (var i = 0; i < 2 && !_cts.IsCancellationRequested; i++)
            {
                await SendAsync(BuildResponse(ttl: 120)).ConfigureAwait(false);
                await Task.Delay(1000, _cts.Token).ConfigureAwait(false);
            }
        });
    }

    /// <summary>Re-announce after a rename or port change.</summary>
    public Task AnnounceAsync() => SendAsync(BuildResponse(ttl: 120));

    public static IEnumerable<IPAddress> LocalAddresses() =>
        NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback && n.SupportsMulticast)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses)
            .Select(a => a.Address)
            .Where(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a))
            .Distinct();

    readonly Lock _sendLock = new();

    /// <summary>
    /// Multicasts on every interface explicitly. Left to the OS, the packet goes out the default multicast
    /// route only, which is often a VPN tunnel that no responder listens on.
    /// </summary>
    Task SendAsync(byte[] packet)
    {
        lock (_sendLock)
        {
            foreach (var address in LocalAddresses())
            {
                try
                {
                    _udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface, address.GetAddressBytes());
                    _udp.Client.SendTo(packet, new IPEndPoint(Group, Port));
                }
                catch (Exception e) when (e is SocketException or ObjectDisposedException) { }
            }
        }
        return Task.CompletedTask;
    }

    async Task QueryLoopAsync()
    {
        // Exponential back-off up to a minute, plus expiry of instances that stopped answering.
        var delay = TimeSpan.FromSeconds(1);
        while (!_cts.IsCancellationRequested)
        {
            await SendAsync(BuildQuery(ServiceType, TypePtr)).ConfigureAwait(false);
            try { await Task.Delay(delay, _cts.Token).ConfigureAwait(false); } catch (OperationCanceledException) { return; }
            delay = TimeSpan.FromSeconds(Math.Min(60, delay.TotalSeconds * 2));
            ExpireInstances();
        }
    }

    async Task ReceiveLoopAsync()
    {
        while (!_cts.IsCancellationRequested)
        {
            UdpReceiveResult result;
            try { result = await _udp.ReceiveAsync(_cts.Token).ConfigureAwait(false); }
            catch (Exception e) when (e is SocketException or OperationCanceledException or ObjectDisposedException) { return; }
            try { await HandlePacketAsync(result.Buffer, result.RemoteEndPoint).ConfigureAwait(false); }
            catch (Exception e) when (e is IndexOutOfRangeException or ArgumentException or FormatException) { /* malformed packet */ }
        }
    }

    async Task HandlePacketAsync(byte[] packet, IPEndPoint from)
    {
        var message = DnsMessage.Parse(packet);
        if (!message.IsResponse)
        {
            var wanted = message.Questions.Any(q =>
                (q.Type is TypePtr or TypeAny && q.Name.Equals(ServiceType, StringComparison.OrdinalIgnoreCase)) ||
                (q.Type is TypeSrv or TypeTxt or TypeAny && q.Name.Equals(InstanceName, StringComparison.OrdinalIgnoreCase)) ||
                (q.Type is TypeA or TypeAny && q.Name.Equals(_hostName, StringComparison.OrdinalIgnoreCase)));
            if (!wanted) return;
            var response = BuildResponse(ttl: 120);
            // Legacy unicast queries (source port ≠ 5353) get a direct reply.
            if (from.Port != Port) await _udp.SendAsync(response, from, _cts.Token).ConfigureAwait(false);
            else await SendAsync(response).ConfigureAwait(false);
            return;
        }
        IngestRecords(message.Records);
    }

    void IngestRecords(IEnumerable<DnsRecord> records)
    {
        var now = DateTimeOffset.Now;
        var changed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        lock (_lock)
        {
            foreach (var r in records)
            {
                switch (r.Type)
                {
                    case TypePtr when r.Name.Equals(ServiceType, StringComparison.OrdinalIgnoreCase):
                        var name = r.PtrName!;
                        if (name.Equals(InstanceName, StringComparison.OrdinalIgnoreCase)) break;
                        if (r.Ttl == 0) { if (_instances.TryGetValue(name, out var gone)) gone.Expires = now; changed.Add(name); break; }
                        if (!_instances.TryGetValue(name, out var inst)) _instances[name] = inst = new Instance();
                        inst.Expires = now.AddSeconds(r.Ttl);
                        changed.Add(name);
                        break;
                    case TypeSrv when r.Name.EndsWith(ServiceType, StringComparison.OrdinalIgnoreCase) && !r.Name.Equals(InstanceName, StringComparison.OrdinalIgnoreCase):
                        var srv = Get(r.Name, now, r.Ttl);
                        srv.Target = r.SrvTarget;
                        srv.Port = r.SrvPort;
                        changed.Add(r.Name);
                        break;
                    case TypeTxt when r.Name.EndsWith(ServiceType, StringComparison.OrdinalIgnoreCase) && !r.Name.Equals(InstanceName, StringComparison.OrdinalIgnoreCase):
                        Get(r.Name, now, r.Ttl).Txt = r.Txt!;
                        changed.Add(r.Name);
                        break;
                    case TypeA:
                        var host = _hosts.GetValueOrDefault(r.Name, ([], now));
                        if (!host.Addresses.Contains(r.Address!)) host.Addresses.Add(r.Address!);
                        _hosts[r.Name] = (host.Addresses, now.AddSeconds(Math.Max(r.Ttl, 1)));
                        foreach (var (n, i) in _instances) if (string.Equals(i.Target, r.Name, StringComparison.OrdinalIgnoreCase)) changed.Add(n);
                        break;
                }
            }
        }
        foreach (var name in changed) Report(name);

        // Ask for whatever is still missing (SRV/TXT for new instances, A for new targets).
        foreach (var name in changed)
        {
            Instance? inst;
            lock (_lock) inst = _instances.GetValueOrDefault(name);
            if (inst is null) continue;
            if (inst.Target is null || inst.Txt.Count == 0) _ = SendAsync(BuildQuery(name, TypeAny));
            else if (!_hosts.ContainsKey(inst.Target)) _ = SendAsync(BuildQuery(inst.Target, TypeA));
        }
    }

    Instance Get(string name, DateTimeOffset now, uint ttl)
    {
        if (!_instances.TryGetValue(name, out var inst)) _instances[name] = inst = new Instance();
        inst.Expires = ttl == 0 ? now : now.AddSeconds(ttl);
        return inst;
    }

    void Report(string name)
    {
        Instance? inst;
        List<IPAddress>? addresses = null;
        lock (_lock)
        {
            inst = _instances.GetValueOrDefault(name);
            if (inst?.Target is { } t && _hosts.TryGetValue(t, out var h)) addresses = [.. h.Addresses];
        }
        if (inst is null || !inst.Txt.TryGetValue("id", out var id)) return;
        if (inst.Expires <= DateTimeOffset.Now)
        {
            _node.RemoveSource(id, DiscoverySource.Lan);
            lock (_lock) _instances.Remove(name);
            return;
        }
        if (addresses is not { Count: > 0 } || inst.Port == 0) return;
        inst.Reported = true;
        _node.UpdatePeer(id, inst.Txt.GetValueOrDefault("n", id), inst.Txt.GetValueOrDefault("pl", "mac"), inst.Txt.GetValueOrDefault("fp"),
            DiscoverySource.Lan, addresses.Select(a => new Endpoint(a.ToString(), inst.Port)).ToList());
    }

    void ExpireInstances()
    {
        List<string> expired;
        lock (_lock) expired = _instances.Where(i => i.Value.Expires <= DateTimeOffset.Now).Select(i => i.Key).ToList();
        foreach (var name in expired) Report(name);
    }

    // MARK: packets

    static byte[] BuildQuery(string name, ushort type)
    {
        var w = new DnsWriter();
        w.Header(id: 0, flags: 0, questions: 1, answers: 0);
        w.Name(name);
        w.U16(type);
        w.U16(1);
        return w.ToArray();
    }

    byte[] BuildResponse(uint ttl)
    {
        var addresses = LocalAddresses().ToList();
        var txt = new Dictionary<string, string>
        {
            ["id"] = _node.Identity.Id, ["n"] = _node.Settings.DeviceName, ["fp"] = _node.Identity.Fingerprint, ["pl"] = _node.Platform, ["v"] = "1",
        };
        var w = new DnsWriter();
        w.Header(id: 0, flags: 0x8400, questions: 0, answers: (ushort)(3 + addresses.Count));
        // PTR (shared record, no cache-flush bit)
        w.Name(ServiceType); w.U16(TypePtr); w.U16(1); w.U32(ttl);
        w.Rdata(r => r.Name(InstanceName));
        // SRV and TXT (unique records: cache-flush bit set)
        w.Name(InstanceName); w.U16(TypeSrv); w.U16(0x8001); w.U32(ttl);
        w.Rdata(r => { r.U16(0); r.U16(0); r.U16((ushort)(_node.ListeningPort ?? 0)); r.Name(_hostName); });
        w.Name(InstanceName); w.U16(TypeTxt); w.U16(0x8001); w.U32(ttl);
        w.Rdata(r =>
        {
            foreach (var (k, v) in txt)
            {
                var entry = Encoding.UTF8.GetBytes($"{k}={v}");
                r.U8((byte)Math.Min(255, entry.Length));
                r.Bytes(entry.AsSpan(0, Math.Min(255, entry.Length)));
            }
        });
        foreach (var a in addresses)
        {
            w.Name(_hostName); w.U16(TypeA); w.U16(0x8001); w.U32(ttl);
            w.Rdata(r => r.Bytes(a.GetAddressBytes()));
        }
        return w.ToArray();
    }

    public void Dispose()
    {
        // Goodbye packet (TTL 0) so others drop us immediately.
        SendAsync(BuildResponse(ttl: 0));
        _cts.Cancel();
        _udp.Dispose();
        _cts.Dispose();
    }
}

sealed record DnsQuestion(string Name, ushort Type);

sealed record DnsRecord(string Name, ushort Type, uint Ttl)
{
    public string? PtrName { get; init; }
    public string? SrvTarget { get; init; }
    public int SrvPort { get; init; }
    public Dictionary<string, string>? Txt { get; init; }
    public IPAddress? Address { get; init; }
}

sealed class DnsMessage
{
    public bool IsResponse;
    public List<DnsQuestion> Questions = [];
    public List<DnsRecord> Records = [];

    public static DnsMessage Parse(byte[] p)
    {
        var m = new DnsMessage { IsResponse = (p[2] & 0x80) != 0 };
        var qd = BinaryPrimitives.ReadUInt16BigEndian(p.AsSpan(4));
        var total = BinaryPrimitives.ReadUInt16BigEndian(p.AsSpan(6)) + BinaryPrimitives.ReadUInt16BigEndian(p.AsSpan(8)) + BinaryPrimitives.ReadUInt16BigEndian(p.AsSpan(10));
        var o = 12;
        for (var i = 0; i < qd; i++)
        {
            var name = ReadName(p, ref o);
            m.Questions.Add(new DnsQuestion(name, BinaryPrimitives.ReadUInt16BigEndian(p.AsSpan(o))));
            o += 4;
        }
        for (var i = 0; i < total; i++)
        {
            var name = ReadName(p, ref o);
            var type = BinaryPrimitives.ReadUInt16BigEndian(p.AsSpan(o));
            var ttl = BinaryPrimitives.ReadUInt32BigEndian(p.AsSpan(o + 4));
            var len = BinaryPrimitives.ReadUInt16BigEndian(p.AsSpan(o + 8));
            o += 10;
            var start = o;
            var record = new DnsRecord(name, type, ttl);
            switch (type)
            {
                case 12: var po = start; record = record with { PtrName = ReadName(p, ref po) }; break;
                case 33:
                    var so = start + 6;
                    record = record with { SrvPort = BinaryPrimitives.ReadUInt16BigEndian(p.AsSpan(start + 4)), SrvTarget = ReadName(p, ref so) };
                    break;
                case 16: record = record with { Txt = ParseTxt(p.AsSpan(start, len)) }; break;
                case 1 when len == 4: record = record with { Address = new IPAddress(p.AsSpan(start, 4)) }; break;
            }
            m.Records.Add(record);
            o = start + len;
        }
        return m;
    }

    static Dictionary<string, string> ParseTxt(ReadOnlySpan<byte> data)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        var o = 0;
        while (o < data.Length)
        {
            int len = data[o++];
            var entry = Encoding.UTF8.GetString(data.Slice(o, Math.Min(len, data.Length - o)));
            o += len;
            var eq = entry.IndexOf('=', StringComparison.Ordinal);
            if (eq > 0) result[entry[..eq]] = entry[(eq + 1)..];
        }
        return result;
    }

    static string ReadName(byte[] p, ref int o)
    {
        var labels = new List<string>();
        var pos = o;
        var jumped = false;
        for (var guard = 0; guard < 128; guard++)
        {
            int len = p[pos];
            if (len == 0) { pos++; break; }
            if ((len & 0xC0) == 0xC0)
            {
                var pointer = ((len & 0x3F) << 8) | p[pos + 1];
                if (!jumped) o = pos + 2;
                jumped = true;
                pos = pointer;
                continue;
            }
            labels.Add(Encoding.UTF8.GetString(p, pos + 1, len));
            pos += len + 1;
        }
        if (!jumped) o = pos;
        return string.Join('.', labels);
    }
}

sealed class DnsWriter
{
    readonly MemoryStream _s = new();

    public void Header(ushort id, ushort flags, ushort questions, ushort answers)
    {
        U16(id); U16(flags); U16(questions); U16(answers); U16(0); U16(0);
    }

    public void U8(byte v) => _s.WriteByte(v);
    public void U16(ushort v) { Span<byte> b = stackalloc byte[2]; BinaryPrimitives.WriteUInt16BigEndian(b, v); _s.Write(b); }
    public void U32(uint v) { Span<byte> b = stackalloc byte[4]; BinaryPrimitives.WriteUInt32BigEndian(b, v); _s.Write(b); }
    public void Bytes(ReadOnlySpan<byte> b) => _s.Write(b);

    public void Name(string name)
    {
        foreach (var label in name.TrimEnd('.').Split('.'))
        {
            var bytes = Encoding.UTF8.GetBytes(label);
            U8((byte)bytes.Length);
            Bytes(bytes);
        }
        U8(0);
    }

    public void Rdata(Action<DnsWriter> write)
    {
        var inner = new DnsWriter();
        write(inner);
        var data = inner.ToArray();
        U16((ushort)data.Length);
        Bytes(data);
    }

    public byte[] ToArray() => _s.ToArray();
}
