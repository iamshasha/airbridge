using System.Buffers.Binary;
using AirBridge.Protocol;
using Microsoft.Win32.SafeHandles;

namespace AirBridge.Engine;

/// <summary>User-picked files and folders expanded into protocol items with their local paths.</summary>
public sealed class OutgoingItems
{
    public List<FileItem> Items { get; } = [];
    public List<string> Paths { get; } = [];
    public long Total => Items.Where(i => !i.IsDirectory).Sum(i => i.Size);

    public void Add(string protocolPath, string localPath, long size, bool dir)
    {
        Items.Add(new FileItem(Items.Count, protocolPath, dir ? 0 : size, dir ? true : null));
        Paths.Add(localPath);
    }

    public string Title
    {
        get
        {
            var tops = Items.Select(i => i.Path.Split('/')[0]).Distinct().ToList();
            return tops.Count == 1 ? tops[0] : $"{Items.Count(i => !i.IsDirectory)} files";
        }
    }

    public static OutgoingItems Expand(IEnumerable<string> roots)
    {
        var result = new OutgoingItems();
        foreach (var root in roots)
        {
            var full = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar);
            var name = Path.GetFileName(full);
            if (Directory.Exists(full))
            {
                result.Add(name, full, 0, dir: true);
                var options = new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.Hidden | FileAttributes.System | FileAttributes.ReparsePoint };
                foreach (var entry in new DirectoryInfo(full).EnumerateFileSystemInfos("*", options).OrderBy(e => e.FullName, StringComparer.Ordinal))
                {
                    var rel = name + "/" + Path.GetRelativePath(full, entry.FullName).Replace(Path.DirectorySeparatorChar, '/');
                    if (entry is DirectoryInfo) result.Add(rel, entry.FullName, 0, dir: true);
                    else if (entry is FileInfo f) result.Add(rel, f.FullName, f.Length, dir: false);
                }
            }
            else
            {
                result.Add(name, full, new FileInfo(full).Length, dir: false);
            }
        }
        return result;
    }
}

/// <summary>Sender side: hands chunks to however many streams are pumping (work stealing).</summary>
public sealed class ChunkSource : IDisposable
{
    public const int ChunkSize = 1 << 20;
    readonly OutgoingItems _items;
    readonly SafeFileHandle?[] _handles;
    readonly Lock _lock = new();
    int _file;
    long _offset;
    long _progress;

    public ChunkSource(OutgoingItems items)
    {
        _items = items;
        _handles = new SafeFileHandle?[items.Items.Count];
    }

    public long Progress => Interlocked.Read(ref _progress);
    internal void AddProgress(long n) => Interlocked.Add(ref _progress, n);

    public bool TryNext(out int index, out long offset, out int length)
    {
        lock (_lock)
        {
            while (_file < _items.Items.Count)
            {
                var item = _items.Items[_file];
                if (item.IsDirectory || _offset >= item.Size) { _file++; _offset = 0; continue; }
                index = _file;
                offset = _offset;
                length = (int)Math.Min(ChunkSize, item.Size - _offset);
                _offset += length;
                return true;
            }
        }
        index = 0; offset = 0; length = 0;
        return false;
    }

    SafeFileHandle Handle(int index)
    {
        lock (_lock)
        {
            return _handles[index] ??= File.OpenHandle(_items.Paths[index], FileMode.Open, FileAccess.Read, FileShare.ReadWrite, FileOptions.Asynchronous);
        }
    }

    /// <summary>Complete chunk plaintext: 0x02 || u32 index || u64 offset || bytes.</summary>
    public async Task<byte[]> PlaintextAsync(int index, long offset, int length, CancellationToken ct)
    {
        var buffer = new byte[13 + length];
        buffer[0] = (byte)FrameType.Chunk;
        BinaryPrimitives.WriteUInt32BigEndian(buffer.AsSpan(1), (uint)index);
        BinaryPrimitives.WriteUInt64BigEndian(buffer.AsSpan(5), (ulong)offset);
        var done = 0;
        var handle = Handle(index);
        while (done < length)
        {
            var n = await RandomAccess.ReadAsync(handle, buffer.AsMemory(13 + done, length - done), offset + done, ct).ConfigureAwait(false);
            if (n <= 0) throw new AirBridgeException(AirBridgeError.ProtocolViolation, "file changed while sending");
            done += n;
        }
        return buffer;
    }

    public void Dispose()
    {
        lock (_lock) foreach (var h in _handles) h?.Dispose();
    }
}

/// <summary>Receiver side: preallocated part files written at arbitrary offsets from parallel streams.</summary>
public sealed class ChunkSink : IDisposable
{
    readonly IReadOnlyList<FileItem> _items;
    readonly Dictionary<int, SafeFileHandle> _handles = [];
    readonly Dictionary<int, (string Part, string Target)> _paths = [];
    readonly TaskCompletionSource _done = new(TaskCreationOptions.RunContinuationsAsynchronously);
    long _progress;

    public long Total { get; }
    public long Progress => Interlocked.Read(ref _progress);
    public List<string> FinalPaths { get; } = [];
    public bool IsComplete => _done.Task.IsCompletedSuccessfully;

    public ChunkSink(IReadOnlyList<FileItem> items, string baseDirectory, bool overwrite)
    {
        _items = items;
        Total = items.Where(i => !i.IsDirectory).Sum(i => i.Size);
        Directory.CreateDirectory(baseDirectory);

        // Rename colliding top-level names once so a folder's children stay together.
        var topLevel = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var item in items)
        {
            var top = SafeComponents(item.Path)[0];
            if (!topLevel.ContainsKey(top))
                topLevel[top] = overwrite ? top : UniqueName(top, baseDirectory, topLevel.Values.ToHashSet());
        }
        foreach (var item in items)
        {
            var comps = SafeComponents(item.Path);
            comps[0] = topLevel[comps[0]];
            var target = Path.Combine([baseDirectory, .. comps]);
            if (item.IsDirectory) { Directory.CreateDirectory(target); continue; }
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            var part = Path.Combine(Path.GetDirectoryName(target)!, $".{Path.GetFileName(target)}.abpart");
            var handle = File.OpenHandle(part, FileMode.Create, FileAccess.Write, FileShare.None, FileOptions.Asynchronous, item.Size);
            _handles[item.I] = handle;
            _paths[item.I] = (part, target);
        }
        FinalPaths.AddRange(topLevel.Values.Order(StringComparer.Ordinal).Select(n => Path.Combine(baseDirectory, n)));
        if (Total == 0) _done.TrySetResult();
    }

    static readonly char[] InvalidNameChars = [':', '*', '?', '"', '<', '>', '|'];

    public static string[] SafeComponents(string path)
    {
        var comps = path.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries);
        if (comps.Length == 0 || comps.Any(c => c is "." or ".." || c.Contains('\0')))
            throw new AirBridgeException(AirBridgeError.ProtocolViolation, $"unsafe path {path}");
        // Characters Windows forbids in names become '-'.
        return comps.Select(c => string.Concat(c.Select(ch => InvalidNameChars.Contains(ch) || ch < 32 ? '-' : ch)).TrimEnd('.', ' ')).ToArray();
    }

    static string UniqueName(string name, string dir, HashSet<string> taken)
    {
        bool Free(string n) => !taken.Contains(n) && !File.Exists(Path.Combine(dir, n)) && !Directory.Exists(Path.Combine(dir, n));
        if (Free(name)) return name;
        var ext = Path.GetExtension(name);
        var stem = Path.GetFileNameWithoutExtension(name);
        for (var i = 2; ; i++)
        {
            var candidate = $"{stem} ({i}){ext}";
            if (Free(candidate)) return candidate;
        }
    }

    /// <summary>Writes one decrypted chunk payload (u32 index || u64 offset || bytes).</summary>
    public async Task WriteAsync(ReadOnlyMemory<byte> payload, CancellationToken ct)
    {
        if (payload.Length < 12) throw new AirBridgeException(AirBridgeError.ProtocolViolation, "short chunk");
        var index = (int)BinaryPrimitives.ReadUInt32BigEndian(payload.Span);
        var offset = (long)BinaryPrimitives.ReadUInt64BigEndian(payload.Span[4..]);
        var data = payload[12..];
        if (index >= _items.Count || !_handles.TryGetValue(index, out var handle) || offset < 0 || offset + data.Length > _items[index].Size)
            throw new AirBridgeException(AirBridgeError.ProtocolViolation, "chunk out of range");
        await RandomAccess.WriteAsync(handle, data, offset, ct).ConfigureAwait(false);
        if (Interlocked.Add(ref _progress, data.Length) >= Total) _done.TrySetResult();
    }

    public void Fail(Exception error) => _done.TrySetException(error);

    public Task Completion => _done.Task;

    /// <summary>Closes files and moves parts into place.</summary>
    public void Commit()
    {
        foreach (var (i, handle) in _handles)
        {
            handle.Dispose();
            var (part, target) = _paths[i];
            File.Move(part, target, overwrite: true);
        }
        _handles.Clear();
    }

    public void Discard()
    {
        foreach (var h in _handles.Values) h.Dispose();
        _handles.Clear();
        foreach (var (part, _) in _paths.Values) { try { File.Delete(part); } catch (IOException) { } }
    }

    public void Dispose() => Discard();
}
