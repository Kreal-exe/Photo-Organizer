using System.Text;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.Core;

public sealed record MoveRecord(string From, string To, long FileSize);

/// <summary>Everything needed to report on and undo one run of the organizer.</summary>
public sealed class OrganizeResult
{
    public List<MoveRecord> Records { get; init; } = [];
    public List<string> CreatedDirectories { get; init; } = [];
    /// <summary>Human-readable failures ("IMG_1.jpg: …").</summary>
    public List<string> Errors { get; init; } = [];
}

/// <summary>
/// Moves the original files into the folders chosen by a plan — nothing is copied, deleted or overwritten.
/// A file is only touched if it is still the regular file of the size seen by the scan; the move is a rename that
/// fails when the destination exists, so an existing file can't be replaced even if it appears in the meantime; every
/// move is verified afterwards and recorded, so the whole run can be reverted.
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

    public static OrganizeResult ApplyPlan(Plan plan, Action<int, int>? progress = null) =>
        MoveItems(plan.PendingItems, plan.Root, item => item.DestinationFolder!, progress);

    /// <summary>Same safety rules; files already there are left alone.</summary>
    public static OrganizeResult MoveItemsToFolder(IReadOnlyList<PhotoItem> items, string folder, string root, Action<int, int>? progress = null) =>
        MoveItems(items, root, _ => folder, progress);

    /// <summary>Moves every file back to where it was. Returns the failures and a record of every file put back.</summary>
    public static (List<string> Errors, List<MoveRecord> Moves) Revert(OrganizeResult result)
    {
        var errors = new List<string>();
        var moves = new List<MoveRecord>();
        for (int i = result.Records.Count - 1; i >= 0; i--)
        {
            var record = result.Records[i];
            try
            {
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
        for (int i = result.CreatedDirectories.Count - 1; i >= 0; i--) RemoveIfEmpty(result.CreatedDirectories[i]);
        // Folders the files were taken out of (a redo has no list of created ones): up to three levels, as deep as the
        // date folders go, and never past a folder that still holds something.
        foreach (string start in moves.Select(m => Path.GetDirectoryName(m.From)!).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            string? directory = start;
            for (int level = 0; level < 3 && directory != null && RemoveIfEmpty(directory); level++) directory = Path.GetDirectoryName(directory);
        }
        return (errors, moves);
    }

    /// <summary>
    /// Saves the list of moves ("to ← from", one per line) to %APPDATA%, so that a run can still be traced back by hand
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
            var text = new StringBuilder($"# {root}\n# куда\t← откуда\n");
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
