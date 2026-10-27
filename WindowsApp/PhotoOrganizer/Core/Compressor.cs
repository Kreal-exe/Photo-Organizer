using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.Core;

/// <summary>
/// Replaces files by their compressed versions: the new file is written next to the original under a hidden name,
/// checked, then the original goes to the Recycle Bin and the new one takes its place (a RAW becomes a .jpg of the same
/// name), with the original's file dates. Nothing is lost if anything fails on the way: the original stays.
/// </summary>
public static class Compressor
{
    public sealed record Outcome(PhotoItem Item, string? NewPath, long Before, long After, bool Hdr, string? Error);

    /// <summary>A RAW photo to a JPEG of `megapixels`.</summary>
    public static Outcome Photo(PhotoItem item, int megapixels)
    {
        string source = item.Path;
        bool upper = Path.GetExtension(source).Any(char.IsUpper);
        string target = Path.ChangeExtension(source, upper ? ".JPG" : ".jpg");
        string temporary = Temporary(source);
        try
        {
            var result = RawPhoto.Compress(source, temporary, megapixels);
            return Replace(item, temporary, target, result.Hdr);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException or NotSupportedException
                                       or ArgumentException or InvalidOperationException or System.Runtime.InteropServices.COMException
                                       or FileFormatException or OverflowException or IndexOutOfRangeException)
        {
            TryDelete(temporary);
            return new Outcome(item, null, item.FileSize, 0, false, e.Message);
        }
    }

    /// <summary>A video to HEVC as `job` says, in the same container under the same name.</summary>
    public static Outcome Video(PhotoItem item, VideoInfo info, VideoJob job, Action<VideoProgress>? progress, CancellationToken token)
    {
        string source = item.Path;
        string temporary = Temporary(source);
        string? error = VideoCompressor.Compress(source, temporary, info, job, progress, token);
        if (error != null) return new Outcome(item, null, item.FileSize, 0, info.Hdr, error);
        // Less than a fifth smaller (a video already compressed about as far as it goes without loss: a 26 Mbit/s HEVC
        // of movement came out 3 % smaller): not worth a second generation — the original stays. A rebuild, larger by
        // design (see VideoJob.Rebuild), takes the old one's place.
        if (!job.Rebuild && new FileInfo(temporary).Length > new FileInfo(source).Length * 0.8)
        {
            TryDelete(temporary);
            return new Outcome(item, null, item.FileSize, item.FileSize, info.Hdr, null);
        }
        return Replace(item, temporary, source, info.Hdr);
    }

    /// <summary>Hidden next to the file, with an extension no scan takes for a photo or a video.</summary>
    static string Temporary(string source) =>
        Path.Combine(Path.GetDirectoryName(source)!, "." + Path.GetFileName(source) + ".po-compressing");

    static Outcome Replace(PhotoItem item, string temporary, string target, bool hdr)
    {
        string source = item.Path;
        var original = new FileInfo(source);
        DateTime created = original.CreationTimeUtc, modified = original.LastWriteTimeUtc;
        long before = original.Length;
        // Another file already has the name (a JPEG next to the RAW): the new one gets "name (2).jpg".
        // One at a time: photos are compressed several at once, and the shell's Recycle Bin and the free names are shared.
        lock (ReplaceLock)
        {
            if (!string.Equals(target, source, StringComparison.OrdinalIgnoreCase)) target = FreeName(target);
            Organizer.Recycle([source]);
            if (File.Exists(source))
            {
                TryDelete(temporary);
                return new Outcome(item, null, before, 0, hdr, Organizer.WhyNotRecycled(source));
            }
            return Rename(item, temporary, target, hdr, before, created, modified);
        }
    }

    static readonly object ReplaceLock = new();

    static Outcome Rename(PhotoItem item, string temporary, string target, bool hdr, long before, DateTime created, DateTime modified)
    {
        try
        {
            File.Move(temporary, target, overwrite: false);
            File.SetCreationTimeUtc(target, created);
            File.SetLastWriteTimeUtc(target, modified);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // The original is in the Recycle Bin and the new file is still under its hidden name: said, with where.
            return new Outcome(item, null, before, 0, hdr, $"{e.Message} ({temporary})");
        }
        return new Outcome(item, target, before, new FileInfo(target).Length, hdr, null);
    }

    static string FreeName(string path)
    {
        if (!File.Exists(path)) return path;
        string folder = Path.GetDirectoryName(path)!, name = Path.GetFileNameWithoutExtension(path), extension = Path.GetExtension(path);
        for (int n = 2; ; n++)
        {
            string candidate = Path.Combine(folder, $"{name} ({n}){extension}");
            if (!File.Exists(candidate)) return candidate;
        }
    }

    static void TryDelete(string path)
    {
        try { File.Delete(path); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>"Сжато 1 563 файла: 117,6 ГБ → 4,7 ГБ (−96 %)".</summary>
    public static string Summary(IReadOnlyCollection<Outcome> outcomes)
    {
        var done = outcomes.Where(o => o.NewPath != null).ToList();
        return F("Сжато: %@ — %@", Count(done.Count, L("файл"), L("файла"), L("файлов")), Compression.Saving(done.Sum(o => o.Before), done.Sum(o => o.After)));
    }
}
