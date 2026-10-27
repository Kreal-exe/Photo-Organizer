using System.Security.Cryptography;
using System.Text;

namespace PhotoOrganizer.Core;

/// <summary>
/// What the scanner has read from each file of a folder — the metadata and the content hash — kept in
/// %APPDATA%\Photo Organizer\scans, one file per folder. Records are appended as files are read, so a scan cut short (the
/// app closed, the PC turned off) continues where it stopped, and a rescan only reads files that are new or changed.
/// A file is the one of its record when it has the same name and size: at the same place in the folder, or else in
/// another of its subfolders (moved, organized into years) when no other record has that name and size. The time of the
/// last change is kept but not compared: a copy does not keep it everywhere — FAT and exFAT round it to two seconds, so a
/// library copied to such a drive had four files in ten read again.
/// </summary>
public sealed class ScanCache : IDisposable
{
    // 2: videos' own dates and places (QuickTime keys) and the full size of RAW files are read again.
    // 3: PNGs found without a date are read again — their EXIF (iPhone screenshots keep the date there) was not read.
    const int Version = 3;

    sealed record Entry(long Size, long Modified, Metadata? Metadata, string? Hash);

    readonly Dictionary<string, Entry> _entries = new(StringComparer.OrdinalIgnoreCase);
    /// <summary>The place of each record by its file's name and size; null where two records have both alike.</summary>
    readonly Dictionary<(string Name, long Size), string?> _byName = new(NameComparer.Instance);
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
        int records = Load(_path, _entries, out bool damaged, out bool upgraded);
        // A folder opened for the first time at this place — moved or copied from another (another disk, another
        // name): the cache of its old place fits its files and is taken over, so nothing is read again.
        bool adopted = records == 0 && !damaged && Adopt(root, directory);
        if (damaged || upgraded || adopted || records == 0 || records > _entries.Count * 2 + 200) Rewrite();
        foreach (var (key, entry) in _entries) Place(key, entry);
    }

    sealed class NameComparer : IEqualityComparer<(string Name, long Size)>
    {
        public static readonly NameComparer Instance = new();
        public bool Equals((string Name, long Size) a, (string Name, long Size) b) =>
            a.Size == b.Size && string.Equals(a.Name, b.Name, StringComparison.OrdinalIgnoreCase);
        public int GetHashCode((string Name, long Size) key) => HashCode.Combine(StringComparer.OrdinalIgnoreCase.GetHashCode(key.Name), key.Size);
    }

    static string NameOf(string relativePath) => relativePath[(relativePath.LastIndexOfAny(['/', '\\']) + 1)..];

    /// <summary>
    /// Notes where the record of this name and size is (called with the lock held, or before others can see it). Two
    /// records of one name and size are one file when they read the same (moved, and read again at its new place — a
    /// cache keeps the records of both places): the later place stands. Otherwise they are two files, and neither is
    /// taken for a file found elsewhere.
    /// </summary>
    void Place(string relativePath, Entry entry, bool scanning = false)
    {
        var name = (NameOf(relativePath), entry.Size);
        if (!_byName.TryGetValue(name, out string? place) || place == null ||
            string.Equals(place, relativePath, StringComparison.OrdinalIgnoreCase))
        {
            if (place == null && _byName.ContainsKey(name)) return;
            _byName[name] = relativePath;
            return;
        }
        // Nothing read from it yet while scanning: decided when something is.
        if (scanning && entry.Hash == null && entry.Metadata == null) return;
        _byName[name] = !_entries.TryGetValue(place, out var known) || Same(known, entry) ? relativePath : null;
    }

    /// <summary>
    /// Two records of one name and size are of one file: by the content hash when both have it (only files that may be
    /// duplicates are hashed), or else by the capture date, pixel size, length and place read from them.
    /// </summary>
    static bool Same(Entry a, Entry b)
    {
        if (a.Hash != null && b.Hash != null) return a.Hash == b.Hash;
        return a.Metadata is { } x && b.Metadata is { } y && x.Width == y.Width && x.Height == y.Height &&
               x.Duration == y.Duration && x.Date == y.Date && x.Latitude == y.Latitude && x.Longitude == y.Longitude;
    }

    /// <summary>
    /// Reads a cache file into `entries` (a later record of a file adding to the earlier one: the hash is often found
    /// after the metadata). Returns how many records were read; `damaged` when the file was cut short (the app closed
    /// while writing: what was read is kept, the rest could never be read), `upgraded` when it was of the version before.
    /// </summary>
    static int Load(string path, Dictionary<string, Entry> entries, out bool damaged, out bool upgraded)
    {
        int records = 0;
        damaged = upgraded = false;
        try
        {
            using var reader = new BinaryReader(File.OpenRead(path));
            int version = reader.ReadInt32();
            upgraded = version == 2;
            if (version == Version || upgraded)
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
                    if (upgraded && metadata is { Date: null } && key.EndsWith(".png", StringComparison.OrdinalIgnoreCase)) metadata = null;
                    if (entries.TryGetValue(key, out var old) && old.Size == size)
                    {
                        entries[key] = new Entry(size, modified, metadata ?? old.Metadata, hash ?? old.Hash);
                    }
                    else
                    {
                        entries[key] = new Entry(size, modified, metadata, hash);
                    }
                    records++;
                }
            }
        }
        catch (FileNotFoundException)
        {
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or FormatException or ArgumentException)
        {
            damaged = true;
        }
        return records;
    }

    /// <summary>
    /// Takes over the cache of another folder when it describes this one: its files under the same relative paths, of
    /// the same sizes (see the class). Of 400 records sampled, those whose file
    /// is here are judged — a cache keeps records of files since moved within the folder (organized into years) or
    /// gone — and at least half of them, ten or more, must be unchanged. The cache with most such files wins. False
    /// when none fits.
    /// </summary>
    bool Adopt(string root, string directory)
    {
        Dictionary<string, Entry>? best = null;
        int bestMatched = 0;
        try
        {
            foreach (var file in new DirectoryInfo(directory).GetFiles("*.bin").OrderByDescending(f => f.LastWriteTimeUtc))
            {
                if (string.Equals(file.FullName, _path, StringComparison.OrdinalIgnoreCase)) continue;
                var entries = new Dictionary<string, Entry>(StringComparer.OrdinalIgnoreCase);
                if (Load(file.FullName, entries, out bool damaged, out _) == 0 || damaged || entries.Count < 20) continue;
                int step = Math.Max(1, entries.Count / 400), index = 0, sampled = 0, present = 0, matched = 0;
                foreach (var (key, entry) in entries)
                {
                    if (index++ % step != 0) continue;
                    sampled++;
                    try
                    {
                        var info = new FileInfo(Path.Combine(root, key.Replace('/', Path.DirectorySeparatorChar)));
                        if (info.Exists)
                        {
                            present++;
                            if (info.Length == entry.Size) matched++;
                        }
                    }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
                    {
                    }
                    if (sampled >= 400) break;
                }
                if (matched < 10 || matched * 2 < present || matched <= bestMatched) continue;
                best = entries;
                bestMatched = matched;
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
        if (best == null) return false;
        foreach (var (key, entry) in best) _entries[key] = entry;
        return true;
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
            if (_entries.TryGetValue(item.RelativePath, out var entry) && entry.Size == item.FileSize) return entry;
            // Moved to another subfolder: the record of the one file of this name and size.
            return _byName.TryGetValue((NameOf(item.RelativePath), item.FileSize), out string? place) && place != null &&
                   _entries.TryGetValue(place, out entry) && entry.Size == item.FileSize ? entry : null;
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
            Place(item.RelativePath, entry, scanning: true);
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
