using System.Runtime.InteropServices;
using System.Text;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.Core;

/// <summary>One file put into place. A copy (`IsCopy`) left the original at `From`; undoing it removes `To`.</summary>
public sealed record MoveRecord(string From, string To, long FileSize, bool IsCopy = false);

/// <summary>Everything needed to report on and undo one run of the organizer.</summary>
public sealed class OrganizeResult
{
    public List<MoveRecord> Records { get; init; } = [];
    /// <summary>The files were copied, not moved: the originals and the library in memory are as they were.</summary>
    public bool IsCopy { get; init; }
    /// <summary>Copy runs: files skipped because a copy of them was already in the destination folder.</summary>
    public int AlreadyCopied { get; set; }
    /// <summary>Stopped by the user before every file was done.</summary>
    public bool Stopped { get; set; }
    public List<string> CreatedDirectories { get; init; } = [];
    /// <summary>Human-readable failures ("IMG_1.jpg: …").</summary>
    public List<string> Errors { get; init; } = [];
}

/// <summary>
/// Moves (or copies) the original files into the folders chosen by a plan — nothing is deleted or overwritten.
/// A file is only touched if it is still the regular file of the size seen by the scan; the move is a rename that
/// fails when the destination exists, so an existing file can't be replaced even if it appears in the meantime; every
/// move is verified afterwards and recorded, so the whole run can be reverted. Copies follow the same rules and leave
/// the originals where they are; undoing them sends the copies to the Recycle Bin.
/// </summary>
public static class Organizer
{
    sealed class MoveException(string message) : Exception(message);

    /// <summary>A path in `directory` that nothing exists at yet: "name.jpg", "name (2).jpg", …</summary>
    static string UniquePath(string directory, string name)
    {
        string candidate = Path.Combine(directory, name);
        string stem = Path.GetFileNameWithoutExtension(name), extension = Path.GetExtension(name);
        for (int index = 2; File.Exists(candidate) || Directory.Exists(candidate); index++)
        {
            candidate = Path.Combine(directory, $"{stem} ({index}){extension}");
        }
        return candidate;
    }

    /// <summary>Creates `directory` and remembers every level that did not exist before, outermost first.</summary>
    static void EnsureDirectory(string directory, List<string> created)
    {
        var missing = new List<string>();
        for (string? current = directory; current != null && !Directory.Exists(current); current = Path.GetDirectoryName(current))
        {
            missing.Insert(0, current);
        }
        Directory.CreateDirectory(directory);
        created.AddRange(missing);
    }

    static readonly HashSet<string> Junk = new(StringComparer.OrdinalIgnoreCase) { "thumbs.db", "desktop.ini", ".ds_store" };

    /// <summary>Removes a directory that holds nothing but (possibly) Explorer's Thumbs.db / desktop.ini.</summary>
    static bool RemoveIfEmpty(string directory)
    {
        try
        {
            var entries = Directory.GetFileSystemEntries(directory);
            if (entries.Any(e => !Junk.Contains(Path.GetFileName(e)))) return false;
            foreach (string entry in entries)
            {
                File.SetAttributes(entry, FileAttributes.Normal);
                File.Delete(entry);
            }
            Directory.Delete(directory);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    static bool IsUnchangedFile(string path, long size)
    {
        var info = new FileInfo(path);
        return info.Exists && (info.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) == 0 && info.Length == size;
    }

    /// <summary>Moves `source` into `directory` as `name` (or "name (2)", …) without ever replacing an existing file.</summary>
    static string MoveExclusively(string source, string directory, string name)
    {
        for (int attempt = 0; attempt < 100; attempt++)
        {
            string destination = UniquePath(directory, name);
            try
            {
                // MoveFileEx without MOVEFILE_REPLACE_EXISTING: fails when the name exists. Another drive: copy, then delete.
                File.Move(source, destination, overwrite: false);
                return destination;
            }
            catch (IOException) when (File.Exists(destination) && File.Exists(source))
            {
                // The name was taken since we looked; try the next one.
            }
        }
        throw new MoveException(L("не удалось подобрать свободное имя"));
    }

    /// <summary>Copies `source` into `directory` as `name` (or "name (2)", …) without ever replacing an existing file.</summary>
    static string CopyExclusively(string source, string directory, string name)
    {
        for (int attempt = 0; attempt < 100; attempt++)
        {
            string destination = UniquePath(directory, name);
            try
            {
                // CopyFile with bFailIfExists: fails when the name exists.
                File.Copy(source, destination, overwrite: false);
                return destination;
            }
            catch (IOException) when (File.Exists(destination) && File.Exists(source))
            {
                // The name was taken since we looked; try the next one.
            }
        }
        throw new MoveException(L("не удалось подобрать свободное имя"));
    }

    /// <summary>
    /// A copy of `source` already in `directory`: "name.jpg", "name (2).jpg", … while they exist, the first regular
    /// file with the original's size and time of last change (±2 s: FAT and exFAT keep it to two seconds). A file of
    /// the same name that differs is another picture.
    /// </summary>
    static bool HasCopy(string source, long size, string directory, string name)
    {
        if (!Directory.Exists(directory)) return false;
        DateTime written = File.GetLastWriteTimeUtc(source);
        string stem = Path.GetFileNameWithoutExtension(name), extension = Path.GetExtension(name);
        string candidate = Path.Combine(directory, name);
        for (int index = 2; File.Exists(candidate) || Directory.Exists(candidate); index++)
        {
            if (IsUnchangedFile(candidate, size) && Math.Abs((File.GetLastWriteTimeUtc(candidate) - written).TotalSeconds) <= 2) return true;
            candidate = Path.Combine(directory, $"{stem} ({index}){extension}");
        }
        return false;
    }

    /// <summary>SHA-256 of the file as hex (the scanner's ContentHash), remembered per path; null when unreadable.</summary>
    static string? HashOf(string path, Dictionary<string, string?> known)
    {
        if (known.TryGetValue(path, out var hash)) return hash;
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 20);
            hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(stream));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            hash = null;
        }
        return known[path] = hash;
    }

    /// <summary>The picture a file shows, as the library knows it: its original when it is an exact copy, the best version when a lesser one.</summary>
    static PhotoItem PictureOf(PhotoItem item)
    {
        var picture = item.DuplicateOf ?? item;
        picture = picture.BetterCopy ?? picture;
        return picture.DuplicateOf ?? picture;
    }

    /// <summary>
    /// "name.jpg", "name (2).jpg"… already in `directory` showing the same picture, pixel by pixel, though saved
    /// differently (the same shot with other metadata or compression is not copied again next to itself).
    /// </summary>
    static bool SamePictureThere(PhotoItem item, string directory, string name)
    {
        if (item.Video || item.PixelWidth <= 0 || item.PixelHeight <= 0 || !Directory.Exists(directory)) return false;
        string stem = Path.GetFileNameWithoutExtension(name), extension = Path.GetExtension(name);
        foreach (string candidate in Directory.EnumerateFiles(directory, stem + "*" + extension))
        {
            string other = Path.GetFileNameWithoutExtension(candidate);
            if (!other.Equals(stem, StringComparison.OrdinalIgnoreCase)
                && !System.Text.RegularExpressions.Regex.IsMatch(other, "^" + System.Text.RegularExpressions.Regex.Escape(stem) + @" \(\d+\)$", System.Text.RegularExpressions.RegexOptions.IgnoreCase)) continue;
            var difference = SimilarCopies.Difference(item.Path, candidate, item.PixelWidth, item.PixelHeight, item.PixelWidth);
            if (difference is { } d && d.Changed <= SimilarCopies.MaximumChangedShare) return true;
        }
        return false;
    }

    /// <summary>Every file in `root` and the folders inside it, by size; empty when it does not exist.</summary>
    static Dictionary<long, List<string>> FilesBySize(string root)
    {
        var bySize = new Dictionary<long, List<string>>();
        if (!Directory.Exists(root)) return bySize;
        foreach (var file in new DirectoryInfo(root).EnumerateFiles("*", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true }))
        {
            if (!bySize.TryGetValue(file.Length, out var list)) bySize[file.Length] = list = [];
            list.Add(file.FullName);
        }
        return bySize;
    }

    /// <summary>
    /// The folder for a file below `root`, with a year folder ("2015") going into one that is already there under
    /// another name for the same year ("2015 год", "2015г"): an archive kept by hand is filled up, not doubled.
    /// </summary>
    public static Func<string, string> IntoExistingYearFolders(string root)
    {
        var known = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        return relative =>
        {
            if (known.TryGetValue(relative, out var found)) return found;
            var parts = relative.Split('/');
            string current = root;
            for (int i = 0; i < parts.Length; i++)
            {
                string part = parts[i];
                if (part.Length >= 4 && part[..4].All(char.IsAsciiDigit) && (part.Length == 4 || !char.IsAsciiDigit(part[4]))
                    && Directory.Exists(current) && !Directory.Exists(Path.Combine(current, part)))
                {
                    string year = part[..4];
                    string? existing = Directory.EnumerateDirectories(current).Select(Path.GetFileName).OfType<string>()
                                                .Where(n => n.StartsWith(year, StringComparison.Ordinal) && (n.Length == 4 || !char.IsAsciiDigit(n[4])))
                                                .Order(StringComparer.OrdinalIgnoreCase).FirstOrDefault();
                    if (existing != null) parts[i] = existing;
                }
                current = Path.Combine(current, parts[i]);
            }
            return known[relative] = string.Join("/", parts);
        };
    }

    /// <summary>
    /// Copies each item into folderForItem(item), a path relative to `root` written with "/". A file of the same name
    /// already there (see HasCopy) is skipped; folders that exist are filled up; the originals are left alone.
    /// `skipSameContent`: nor is a file copied whose very contents are anywhere in `root` already (or were copied in
    /// this run) — whatever its name and folder.
    /// </summary>
    public static OrganizeResult CopyItems(IReadOnlyList<PhotoItem> items, string root, Func<PhotoItem, string> folderForItem,
                                           Action<int, int>? progress = null, bool skipSameContent = false, CancellationToken token = default)
    {
        var result = new OrganizeResult { IsCopy = true };
        var bySize = skipSameContent ? FilesBySize(root) : [];
        var hashes = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
        // Versions of one picture the library knows about (exact copies, and resized or re-saved ones — the same
        // picture in files that differ by a few bytes of metadata): one of them is copied, the best.
        if (skipSameContent)
        {
            int all = items.Count;
            items = items.GroupBy(PictureOf).SelectMany(g => g.OrderByDescending(i => i == g.Key)
                                                              .ThenByDescending(i => (long)i.PixelWidth * i.PixelHeight)
                                                              .ThenByDescending(i => i.FileSize).Take(1)).ToList();
            result.AlreadyCopied = all - items.Count;
        }
        int total = items.Count;
        for (int done = 1; done <= total; done++)
        {
            if (token.IsCancellationRequested)
            {
                result.Stopped = true;
                break;
            }
            var item = items[done - 1];
            string directory = Path.Combine([root, .. folderForItem(item).Split('/')]);
            try
            {
                if (!IsUnchangedFile(item.Path, item.FileSize)) throw new MoveException(L("файл изменился или исчез после сканирования — пропущен"));
                string name = Path.GetFileName(item.Path);
                // Already in its folder: a copy next to it would only be a duplicate.
                if (string.Equals(Path.GetFullPath(directory).TrimEnd('\\'), Path.GetFullPath(Path.GetDirectoryName(item.Path)!).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                    continue;
                // The same picture already in the folder under its own name, saved differently (other metadata, size).
                if (skipSameContent && SamePictureThere(item, directory, name))
                {
                    result.AlreadyCopied++;
                    continue;
                }
                // By name, size and time — unless the contents are compared anyway, which also catches those copies and
                // never takes another picture of the same size and time for one.
                if (!skipSameContent && HasCopy(item.Path, item.FileSize, directory, name))
                {
                    result.AlreadyCopied++;
                    continue;
                }
                string? hash = null;
                if (skipSameContent && bySize.TryGetValue(item.FileSize, out var sameSize))
                {
                    hash = item.ContentHash ?? HashOf(item.Path, hashes);
                    if (hash != null && sameSize.Any(path => HashOf(path, hashes) == hash))
                    {
                        result.AlreadyCopied++;
                        continue;
                    }
                }
                EnsureDirectory(directory, result.CreatedDirectories);
                string destination = CopyExclusively(item.Path, directory, name);
                if (skipSameContent)
                {
                    // Copied now: the same picture once more in the selection is not copied again.
                    if (!bySize.TryGetValue(item.FileSize, out var list)) bySize[item.FileSize] = list = [];
                    list.Add(destination);
                    hashes[destination] = hash ?? item.ContentHash ?? HashOf(item.Path, hashes);
                }
                result.Records.Add(new MoveRecord(item.Path, destination, item.FileSize, IsCopy: true));
                // CopyFile keeps the time of the last change but not the creation time: both as on the original.
                File.SetCreationTimeUtc(destination, File.GetCreationTimeUtc(item.Path));
                File.SetLastWriteTimeUtc(destination, File.GetLastWriteTimeUtc(item.Path));
                if (!IsUnchangedFile(destination, item.FileSize)) throw new MoveException(L("после копирования размер файла не совпал — проверьте копию вручную"));
            }
            catch (Exception e) when (e is MoveException or IOException or UnauthorizedAccessException)
            {
                result.Errors.Add($"{item.RelativePath}: {e.Message}");
            }
            finally
            {
                if (progress != null && (done % 10 == 0 || done == total)) progress(done, total);
            }
        }
        return result;
    }

    /// <summary>Moves each item into folderForItem(item), a path relative to `root` written with "/".</summary>
    public static OrganizeResult MoveItems(IReadOnlyList<PhotoItem> items, string root, Func<PhotoItem, string> folderForItem,
                                           Action<int, int>? progress = null)
    {
        var result = new OrganizeResult();
        var sourceDirectories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        int total = items.Count;
        for (int done = 1; done <= total; done++)
        {
            var item = items[done - 1];
            string sourceDirectory = Path.GetDirectoryName(item.Path)!;
            string directory = Path.Combine([root, .. folderForItem(item).Split('/')]);
            try
            {
                if (!IsUnchangedFile(item.Path, item.FileSize)) throw new MoveException(L("файл изменился или исчез после сканирования — пропущен"));
                EnsureDirectory(directory, result.CreatedDirectories);
                if (!string.Equals(Path.GetFullPath(directory).TrimEnd('\\'), Path.GetFullPath(sourceDirectory).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                {
                    string destination = MoveExclusively(item.Path, directory, Path.GetFileName(item.Path));
                    result.Records.Add(new MoveRecord(item.Path, destination, item.FileSize));
                    sourceDirectories.Add(sourceDirectory);
                    if (!IsUnchangedFile(destination, item.FileSize)) throw new MoveException(L("после перемещения размер файла не совпал — проверьте его вручную"));
                }
            }
            catch (Exception e) when (e is MoveException or IOException or UnauthorizedAccessException)
            {
                result.Errors.Add($"{item.RelativePath}: {e.Message}");
            }
            if (progress != null && (done % 10 == 0 || done == total)) progress(done, total);
        }
        // Tidy up folders that were emptied by the move, walking up but never touching the root itself.
        string rootPrefix = root.TrimEnd('\\') + "\\";
        foreach (string directory in sourceDirectories)
        {
            for (string? current = directory;
                 current != null && current.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase) && RemoveIfEmpty(current);
                 current = Path.GetDirectoryName(current))
            {
            }
        }
        return result;
    }

    public static OrganizeResult ApplyPlan(Plan plan, Action<int, int>? progress = null) => plan.CopiesFiles
        ? CopyItems(plan.PendingItems, plan.Root, item => item.DestinationFolder!, progress)
        : MoveItems(plan.PendingItems, plan.Root, item => item.DestinationFolder!, progress);

    /// <summary>Same safety rules; files already there are left alone.</summary>
    public static OrganizeResult MoveItemsToFolder(IReadOnlyList<PhotoItem> items, string folder, string root, Action<int, int>? progress = null) =>
        MoveItems(items, root, _ => folder, progress);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct ShFileOperation
    {
        public IntPtr Window;
        public uint Function;
        public string From;
        public string? To;
        public ushort Flags;
        public bool Aborted;
        public IntPtr NameMappings;
        public string? ProgressTitle;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHFileOperation(ref ShFileOperation operation);

    [StructLayout(LayoutKind.Sequential)]
    struct ShQueryRbInfo
    {
        public int Size;
        public long SizeInBytes;
        public long NumItems;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHQueryRecycleBin(string root, ref ShQueryRbInfo info);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool GetVolumeNameForVolumeMountPoint(string mountPoint, System.Text.StringBuilder name, int length);

    /// <summary>
    /// Room left in the Recycle Bin of the disk `path` is on, in bytes; null when unknown. What does not fit is deleted
    /// for good by Windows (or pushes older files out of the bin), without asking: callers warn first.
    /// </summary>
    public static long? RecycleBinRoom(string path)
    {
        try
        {
            string root = Path.GetPathRoot(Path.GetFullPath(path))!;
            // Network shares and removable drives have no Recycle Bin: Windows deletes from them for good.
            if (root.StartsWith(@"\\") || new DriveInfo(root).DriveType is DriveType.Removable or DriveType.Network or DriveType.CDRom) return 0;
            var volume = new System.Text.StringBuilder(64);
            if (!GetVolumeNameForVolumeMountPoint(root, volume, volume.Capacity)) return null;
            string guid = volume.ToString()[(volume.ToString().IndexOf('{'))..].TrimEnd('\\');
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey($@"Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\{guid}");
            if (key?.GetValue("NukeOnDelete") is int nuke && nuke != 0) return 0;
            if (key?.GetValue("MaxCapacity") is not int megabytes) return null;
            var info = new ShQueryRbInfo { Size = Marshal.SizeOf<ShQueryRbInfo>() };
            long used = SHQueryRecycleBin(root, ref info) == 0 ? info.SizeInBytes : 0;
            return Math.Max(0, megabytes * 1024L * 1024L - used);
        }
        catch (Exception e) when (e is IOException or ArgumentException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            return null;
        }
    }

    /// <summary>Moves files to the Recycle Bin, where they can be restored from; one shell call for the lot.</summary>
    public static void Recycle(IEnumerable<string> paths)
    {
        var operation = new ShFileOperation
        {
            Function = 3,                       // FO_DELETE
            From = string.Join("\0", paths) + "\0\0",
            Flags = 0x40 | 0x10 | 0x400 | 0x4,  // FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT
        };
        SHFileOperation(ref operation);
    }

    /// <summary>Why a file is still there after going to the Recycle Bin: what Windows says when it is opened for deleting.</summary>
    public static string WhyNotRecycled(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return e.Message;
        }
        return L("не удалось переместить в Корзину");
    }

    /// <summary>
    /// Moves every file back to where it was; copies go to the Recycle Bin instead, the originals are not touched.
    /// Returns the failures, a record of every file put back and the number of copies removed.
    /// </summary>
    public static (List<string> Errors, List<MoveRecord> Moves, int Recycled) Revert(OrganizeResult result)
    {
        var errors = new List<string>();
        var moves = new List<MoveRecord>();
        var copies = new List<string>();
        for (int i = result.Records.Count - 1; i >= 0; i--)
        {
            var record = result.Records[i];
            try
            {
                if (record.IsCopy)
                {
                    // Only the copy as it was made: one changed since then is somebody's work now.
                    if (!IsUnchangedFile(record.To, record.FileSize)) throw new MoveException(L("копия изменилась или исчезла — оставлена как есть"));
                    copies.Add(record.To);
                    continue;
                }
                if (!IsUnchangedFile(record.To, record.FileSize)) throw new MoveException(L("файл изменился или исчез после раскладки — оставлен как есть"));
                string directory = Path.GetDirectoryName(record.From)!;
                Directory.CreateDirectory(directory);
                string back = MoveExclusively(record.To, directory, Path.GetFileName(record.From));
                moves.Add(new MoveRecord(record.To, back, record.FileSize));
            }
            catch (Exception e) when (e is MoveException or IOException or UnauthorizedAccessException)
            {
                errors.Add($"{Path.GetFileName(record.To)}: {e.Message}");
            }
        }
        for (int start = 0; start < copies.Count; start += 100) Recycle(copies.Skip(start).Take(100));
        // What is still there could not be moved to the Recycle Bin.
        foreach (string copy in copies.Where(File.Exists)) errors.Add($"{Path.GetFileName(copy)}: {WhyNotRecycled(copy)}");
        int recycled = copies.Count(copy => !File.Exists(copy));
        for (int i = result.CreatedDirectories.Count - 1; i >= 0; i--) RemoveIfEmpty(result.CreatedDirectories[i]);
        // Folders the files were taken out of (a redo has no list of created ones): up to three levels, as deep as the
        // date folders go, and never past a folder that still holds something.
        foreach (string start in moves.Select(m => Path.GetDirectoryName(m.From)!).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            string? directory = start;
            for (int level = 0; level < 3 && directory != null && RemoveIfEmpty(directory); level++) directory = Path.GetDirectoryName(directory);
        }
        return (errors, moves, recycled);
    }

    /// <summary>
    /// Saves the list of moves or copies ("to ← from", one per line) to %APPDATA%, so that a run can still be traced back by hand
    /// after the app has quit. Returns the file, or null when there was nothing to write.
    /// </summary>
    public static string? WriteJournal(OrganizeResult result, string root)
    {
        if (result.Records.Count == 0) return null;
        try
        {
            string directory = Path.Combine(AppData.Directory, "Журнал");
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, DateTime.Now.ToString("yyyy-MM-dd HH-mm-ss") + ".txt");
            // The same header as on the Mac.
            var text = new StringBuilder($"# {root}\n# {(result.IsCopy ? "копирование (оригиналы на месте)" : "перемещение")}\n# куда\t← откуда\n");
            foreach (var record in result.Records) text.Append($"{record.To}\t← {record.From}\n");
            File.WriteAllText(path, text.ToString(), new UTF8Encoding(false));
            return path;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }
}
