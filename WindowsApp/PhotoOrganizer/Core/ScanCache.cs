using System.Security.Cryptography;
using System.Text;

namespace PhotoOrganizer.Core;

/// <summary>
/// What the scanner has read from each file of a folder — the metadata and the content hash — kept in
/// %APPDATA%\Photo Organizer\scans, one file per folder. Records are appended as files are read, so a scan cut short (the
/// app closed, the PC turned off) continues where it stopped, and a rescan only reads files that are new or changed
/// (another size or modification time).
/// </summary>
public sealed class ScanCache : IDisposable
{
    const int Version = 1;

    sealed record Entry(long Size, long Modified, Metadata? Metadata, string? Hash);

    readonly Dictionary<string, Entry> _entries = new(StringComparer.OrdinalIgnoreCase);
    readonly string _path;
    readonly Lock _lock = new();
    BinaryWriter? _writer;
    int _unflushed;

    public ScanCache(string root)
    {
        string name = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(root.ToLowerInvariant())))[..16];
        string directory = Path.Combine(AppData.Directory, "scans");
        Directory.CreateDirectory(directory);
        _path = Path.Combine(directory, name + ".bin");
        int records = 0;
        try
        {
            using var reader = new BinaryReader(File.OpenRead(_path));
            if (reader.ReadInt32() == Version)
            {
                while (reader.BaseStream.Position < reader.BaseStream.Length)
                {
                    string key = reader.ReadString();
                    long size = reader.ReadInt64(), modified = reader.ReadInt64();
                    Metadata? metadata = null;
                    if (reader.ReadBoolean())
                    {
                        metadata = new Metadata { Width = reader.ReadInt32(), Height = reader.ReadInt32(), Duration = reader.ReadDouble() };
                        if (reader.ReadBoolean()) metadata.Date = new DateTime(reader.ReadInt64());
                        if (reader.ReadBoolean()) (metadata.Latitude, metadata.Longitude) = (reader.ReadDouble(), reader.ReadDouble());
                    }
                    string? hash = reader.ReadBoolean() ? reader.ReadString() : null;
                    // A later record of a file adds to the earlier one: the hash is often found after the metadata.
                    if (_entries.TryGetValue(key, out var old) && old.Size == size && old.Modified == modified)
                    {
                        _entries[key] = new Entry(size, modified, metadata ?? old.Metadata, hash ?? old.Hash);
                    }
                    else
                    {
                        _entries[key] = new Entry(size, modified, metadata, hash);
                    }
                    records++;
                }
            }
        }
        catch (Exception e) when (e is IOException or EndOfStreamException or UnauthorizedAccessException)
        {
            // A missing file, or one cut short when the app was closed: what was read is kept.
        }
        if (records == 0 || records > _entries.Count * 2 + 200) Rewrite();
    }

    void Rewrite()
    {
        try
        {
            using (var writer = new BinaryWriter(File.Create(_path + ".tmp")))
            {
                writer.Write(Version);
                foreach (var (key, entry) in _entries) Write(writer, key, entry);
            }
            File.Move(_path + ".tmp", _path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }

    static void Write(BinaryWriter writer, string key, Entry entry)
    {
        writer.Write(key);
        writer.Write(entry.Size);
        writer.Write(entry.Modified);
        writer.Write(entry.Metadata != null);
        if (entry.Metadata is { } m)
        {
            writer.Write(m.Width);
            writer.Write(m.Height);
            writer.Write(m.Duration);
            writer.Write(m.Date.HasValue);
            if (m.Date is { } date) writer.Write(date.Ticks);
            bool located = m.Latitude.HasValue && m.Longitude.HasValue;
            writer.Write(located);
            if (located)
            {
                writer.Write(m.Latitude!.Value);
                writer.Write(m.Longitude!.Value);
            }
        }
        writer.Write(entry.Hash != null);
        if (entry.Hash != null) writer.Write(entry.Hash);
    }

    static long Stamp(PhotoItem item) => File.GetLastWriteTimeUtc(item.Path).Ticks;

    Entry? Current(PhotoItem item, out long modified)
    {
        modified = Stamp(item);
        lock (_lock)
        {
            return _entries.TryGetValue(item.RelativePath, out var entry) && entry.Size == item.FileSize && entry.Modified == modified ? entry : null;
        }
    }

    /// <summary>The metadata read from this file before, when it has not changed since.</summary>
    public Metadata? MetadataFor(PhotoItem item) => Current(item, out _)?.Metadata;

    public string? HashFor(PhotoItem item) => Current(item, out _)?.Hash;

    public void Remember(PhotoItem item, Metadata? metadata, string? hash)
    {
        var old = Current(item, out long modified);
        var entry = new Entry(item.FileSize, modified, metadata ?? old?.Metadata, hash ?? old?.Hash);
        lock (_lock)
        {
            _entries[item.RelativePath] = entry;
            try
            {
                _writer ??= new BinaryWriter(new FileStream(_path, FileMode.Append, FileAccess.Write, FileShare.Read));
                Write(_writer, item.RelativePath, entry);
                // On disk every hundred files, so that closing the app loses little.
                if (++_unflushed >= 100)
                {
                    _writer.Flush();
                    _unflushed = 0;
                }
            }
            catch (IOException)
            {
            }
        }
    }

    public void Dispose()
    {
        lock (_lock)
        {
            _writer?.Dispose();
            _writer = null;
        }
    }
}
