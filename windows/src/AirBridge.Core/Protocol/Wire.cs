using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;

namespace AirBridge.Protocol;

/// <summary>Byte stream carrying length-prefixed frames: direct TCP, or a WebSocket to the internet relay.</summary>
public abstract class Wire : IAsyncDisposable
{
    public const int MaxFrame = 16 << 20;

    public abstract bool IsRelay { get; }
    /// <summary>Address the peer connected from (TCP only), used to remember trusted devices.</summary>
    public virtual IPEndPoint? RemoteEndPoint => null;

    public abstract ValueTask ReadExactlyAsync(Memory<byte> buffer, CancellationToken ct = default);
    /// <summary>Writes in call order. Callers serialize writes per wire.</summary>
    public abstract ValueTask WriteAsync(ReadOnlyMemory<byte> data, CancellationToken ct = default);
    public abstract void Close();

    public async ValueTask<byte[]> ReceiveFrameAsync(CancellationToken ct = default)
    {
        var header = new byte[4];
        await ReadExactlyAsync(header, ct).ConfigureAwait(false);
        var length = BinaryPrimitives.ReadInt32BigEndian(header);
        if (length < 0 || length > MaxFrame) throw new AirBridgeException(AirBridgeError.ProtocolViolation, "frame too large");
        var body = new byte[length];
        await ReadExactlyAsync(body, ct).ConfigureAwait(false);
        return body;
    }

    public ValueTask SendFrameAsync(ReadOnlySpan<byte> payload, CancellationToken ct = default)
    {
        var frame = new byte[payload.Length + 4];
        BinaryPrimitives.WriteInt32BigEndian(frame, payload.Length);
        payload.CopyTo(frame.AsSpan(4));
        return WriteAsync(frame, ct);
    }

    public ValueTask DisposeAsync()
    {
        Close();
        GC.SuppressFinalize(this);
        return ValueTask.CompletedTask;
    }
}

public sealed class TcpWire : Wire
{
    readonly Socket _socket;
    readonly NetworkStream _stream;

    public TcpWire(Socket socket)
    {
        _socket = socket;
        _socket.NoDelay = true;
        _socket.SendBufferSize = 4 << 20;
        _socket.ReceiveBufferSize = 4 << 20;
        _socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
        _stream = new NetworkStream(socket, ownsSocket: true);
    }

    public override bool IsRelay => false;
    public override IPEndPoint? RemoteEndPoint => _socket.RemoteEndPoint as IPEndPoint;

    public static async Task<TcpWire> ConnectAsync(string host, int port, TimeSpan timeout, CancellationToken ct = default)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout);
        var socket = new Socket(SocketType.Stream, ProtocolType.Tcp) { DualMode = true };
        try
        {
            await socket.ConnectAsync(host, port, cts.Token).ConfigureAwait(false);
            return new TcpWire(socket);
        }
        catch (Exception e) when (e is SocketException or OperationCanceledException)
        {
            socket.Dispose();
            if (e is OperationCanceledException && !ct.IsCancellationRequested)
                throw new AirBridgeException(AirBridgeError.Timeout);
            throw new AirBridgeException(AirBridgeError.ConnectFailed, e.Message);
        }
    }

    public override async ValueTask ReadExactlyAsync(Memory<byte> buffer, CancellationToken ct = default)
    {
        try { await _stream.ReadExactlyAsync(buffer, ct).ConfigureAwait(false); }
        catch (EndOfStreamException) { throw new AirBridgeException(AirBridgeError.ConnectionClosed); }
        catch (IOException e) { throw new AirBridgeException(AirBridgeError.ConnectFailed, e.Message); }
    }

    public override async ValueTask WriteAsync(ReadOnlyMemory<byte> data, CancellationToken ct = default)
    {
        try { await _stream.WriteAsync(data, ct).ConfigureAwait(false); }
        catch (IOException e) { throw new AirBridgeException(AirBridgeError.ConnectFailed, e.Message); }
    }

    public override void Close() => _stream.Dispose();
}

/// <summary>
/// WebSocket to the relay (relay/src/index.js). The relay pairs two sockets and says "ready";
/// after that it is a plain byte stream split into messages of at most 256 KiB (Cloudflare caps at 1 MiB).
/// </summary>
public sealed class RelayWire : Wire
{
    public const int MessageSize = 256 << 10;
    readonly ClientWebSocket _socket;
    readonly byte[] _buffer = new byte[MessageSize * 2];
    int _start, _end;

    RelayWire(ClientWebSocket socket) => _socket = socket;

    public override bool IsRelay => true;

    public static async Task<RelayWire> ConnectAsync(Uri url, TimeSpan waitForPeer, CancellationToken ct = default)
    {
        var socket = new ClientWebSocket();
        socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(20);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(waitForPeer);
        try
        {
            await socket.ConnectAsync(url, cts.Token).ConfigureAwait(false);
            var buffer = new byte[256];
            while (true)
            {
                var result = await socket.ReceiveAsync(buffer, cts.Token).ConfigureAwait(false);
                if (result.MessageType == WebSocketMessageType.Close) throw new AirBridgeException(AirBridgeError.ConnectionClosed);
                if (result.MessageType != WebSocketMessageType.Text) continue;
                var text = Encoding.UTF8.GetString(buffer, 0, result.Count);
                if (text == "ready") return new RelayWire(socket);
                if (text.StartsWith("error", StringComparison.Ordinal)) throw new AirBridgeException(AirBridgeError.ConnectFailed, text);
            }
        }
        catch (Exception e) when (e is WebSocketException or OperationCanceledException)
        {
            socket.Dispose();
            if (e is OperationCanceledException && !ct.IsCancellationRequested) throw new AirBridgeException(AirBridgeError.Timeout);
            throw new AirBridgeException(AirBridgeError.ConnectFailed, e.Message);
        }
    }

    public override async ValueTask ReadExactlyAsync(Memory<byte> buffer, CancellationToken ct = default)
    {
        var filled = 0;
        while (filled < buffer.Length)
        {
            if (_start == _end)
            {
                _start = _end = 0;
                var result = await _socket.ReceiveAsync(_buffer.AsMemory(), ct).ConfigureAwait(false);
                if (result.MessageType == WebSocketMessageType.Close) throw new AirBridgeException(AirBridgeError.ConnectionClosed);
                if (result.MessageType == WebSocketMessageType.Text) continue;
                _end = result.Count;
            }
            var n = Math.Min(buffer.Length - filled, _end - _start);
            _buffer.AsMemory(_start, n).CopyTo(buffer[filled..]);
            _start += n;
            filled += n;
        }
    }

    public override async ValueTask WriteAsync(ReadOnlyMemory<byte> data, CancellationToken ct = default)
    {
        for (var offset = 0; offset < data.Length; offset += MessageSize)
        {
            var piece = data.Slice(offset, Math.Min(MessageSize, data.Length - offset));
            await _socket.SendAsync(piece, WebSocketMessageType.Binary, true, ct).ConfigureAwait(false);
        }
    }

    public override void Close()
    {
        try { _socket.Abort(); } catch (ObjectDisposedException) { }
        _socket.Dispose();
    }
}
