using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.Core;

/// <summary>
/// Replaces files by their compressed versions: the new file is written next to the original under a hidden name,
/// checked, then the original goes to the Recycle Bin — or to the folder chosen (OriginalsFolder) — and the new one takes
/// its place (a RAW becomes a .jpg of the same name), with the original's file dates. Nothing is lost if anything fails
/// on the way: the original stays.
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
        long size = new FileInfo(source).Length;
        // Three short pieces first: what they come to says whether the whole is worth it — a minute of work saved, and
        // the video marked, when it is not (see WontShrink).
        if (!job.Rebuild && VideoCompressor.TrialRatio(source, info, job, token) is > TrialLimit and var trial)
        {
            WontShrink.Remember(source, job.Quality, trial);
            return new Outcome(item, null, item.FileSize, item.FileSize, info.Hdr, null);
        }
        string temporary = Temporary(source);
        string? error = VideoCompressor.Compress(source, temporary, info, job, progress, token);
        // An original with frames that cannot be decoded: whatever is made of it lacks them. It stays as it is, marked
        // with why — not an error to be shown again on every run.
        if (error == VideoCompressor.Damaged)
        {
            WontShrink.Remember(source, int.MaxValue, 1, VideoCompressor.Damaged);
            return new Outcome(item, null, item.FileSize, item.FileSize, info.Hdr, null);
        }
        if (error != null) return new Outcome(item, null, item.FileSize, 0, info.Hdr, error);
        // Less than a fifth smaller (a video already compressed about as far as it goes without loss: a 26 Mbit/s HEVC
        // of movement came out 3 % smaller): not worth a second generation — the original stays, and is marked so that
        // it is not tried again. A rebuild, larger by design (see VideoJob.Rebuild), takes the old one's place.
        long after = new FileInfo(temporary).Length;
        if (!job.Rebuild && after > size * KeepLimit)
        {
            TryDelete(temporary);
            WontShrink.Remember(source, job.Quality, (double)after / size);
            return new Outcome(item, null, item.FileSize, item.FileSize, info.Hdr, null);
        }
        // At the levels that promise no visible loss, what came out is looked at before it takes the original's place
        // (see VideoCompressor.Quality): a piece under LeastVmaf, or all under MeanVmaf, and it is made again at a
        // higher quality; still short, the original stays, marked with what it came to.
        if (!job.Rebuild && job.Quality <= Compression.DefaultVideoQuality && !token.IsCancellationRequested
            && VideoCompressor.Quality(source, temporary, info) is { } looks && (looks.Worst < LeastVmaf || looks.Mean < MeanVmaf))
        {
            TryDelete(temporary);
            if (job.CqLower == 0) return Video(item, info, job with { CqLower = 3 }, progress, token);
            WontShrink.Remember(source, job.Quality, (double)after / size, WontShrink.Vmaf(looks.Worst));
            return new Outcome(item, null, item.FileSize, item.FileSize, info.Hdr, null);
        }
        // An AVI, MKV or WMV becomes an MP4 of the same name; the rest keeps its own.
        string target = source;
        if (VideoCompressor.BecomesMp4(source)) target = Path.ChangeExtension(source, Path.GetExtension(source).Any(char.IsUpper) ? ".MP4" : ".mp4");
        return Replace(item, temporary, target, info.Hdr);
    }

    /// <summary>
    /// VMAF a compressed video must keep, against its original, at the levels that promise no visible loss: above 95 a
    /// picture is taken for the original, 2 points less are seen by no one (Netflix); a 2 s piece may dip to 91 (a
    /// burst of noise in the dark), the whole must stay at 94. The smeared start that every video had (66) and 4K of
    /// leaves at 85 would have been caught.
    /// </summary>
    const double LeastVmaf = 91, MeanVmaf = 94;

    /// <summary>A compressed video no lighter than this part of its original is not kept.</summary>
    public const double KeepLimit = 0.8;
    /// <summary>
    /// Pieces of a video that came to more than this part of the original say the whole would not be kept: a little
    /// above KeepLimit, as pieces are not the whole (between, the whole is compressed and decides).
    /// </summary>
    const double TrialLimit = 0.88;

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
            if (OriginalsFolder is { } folder)
            {
                // Into the folder chosen, under the path it had on its disk ("D:\Photos\2017\11\01\IMG_3484.MOV" to
                // "<folder>\Photos\2017\11\01\IMG_3484.MOV"): nothing mixed up, and each one is found where it was.
                string kept = FreeName(KeptPath(folder, source));
                try
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(kept)!);
                    File.Move(source, kept);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    TryDelete(temporary);
                    return new Outcome(item, null, before, 0, hdr, e.Message);
                }
            }
            else
            {
                Organizer.Recycle([source]);
                if (File.Exists(source))
                {
                    TryDelete(temporary);
                    return new Outcome(item, null, before, 0, hdr, Organizer.WhyNotRecycled(source));
                }
            }
            return Rename(item, temporary, target, hdr, before, created, modified);
        }
    }

    static readonly object ReplaceLock = new();

    /// <summary>
    /// The folder the originals go to instead of the Recycle Bin, chosen in the compress window ("compressOriginalsFolder");
    /// null: the Recycle Bin. The Bin of a disk holds a part of it (95 GB of a 1.8 TB disk by default): what does not
    /// fit, Windows deletes for good without asking.
    /// </summary>
    public static string? OriginalsFolder
    {
        get => Settings.Shared.GetString("compressOriginalsFolder") is { Length: > 0 } folder ? folder : null;
        set => Settings.Shared.Set("compressOriginalsFolder", value);
    }

    /// <summary>Where an original goes in `folder`: under the path it had on its disk, its drive left out.</summary>
    public static string KeptPath(string folder, string source)
    {
        string root = Path.GetPathRoot(source) ?? "";
        return Path.Combine(folder, source[root.Length..].TrimStart('\\', '/'));
    }

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
