using System.Text.Json;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.Core;

/// <summary>
/// Videos that do not get a fifth smaller at a quality level — their compressed version would not be kept (see
/// Compressor.KeepLimit) — told before any work, and remembered once tried, so that they are offered apart, with why,
/// and never encoded again for nothing. What failed at a level fails at every gentler one; a stronger level is tried.
/// </summary>
public static class WontShrink
{
    // Why: a cause other than the size (VideoCompressor.Damaged), at every level.
    sealed record Mark(long Size, long Written, int Level, double Ratio, string? Why = null);

    static string StorePath => AppData.File("compress-wont-shrink.json");
    static readonly Lock StoreLock = new();
    static Dictionary<string, Mark>? _marks;

    static Dictionary<string, Mark> Marks
    {
        get
        {
            if (_marks != null) return _marks;
            try
            {
                if (File.Exists(StorePath) && JsonSerializer.Deserialize<Dictionary<string, Mark>>(File.ReadAllText(StorePath)) is { } saved)
                    return _marks = new(saved, StringComparer.OrdinalIgnoreCase);
            }
            catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException or NotSupportedException)
            {
            }
            return _marks = new(StringComparer.OrdinalIgnoreCase);
        }
    }

    const string VmafMark = "vmaf:";

    /// <summary>The why for a video whose compressed picture fell short (Compressor.LeastVmaf) even at a higher quality.</summary>
    public static string Vmaf(double worst) => VmafMark + Math.Round(worst).ToString(System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>`path` came to `ratio` of its size at quality `level` (Compression.VideoQualityNames).</summary>
    public static void Remember(string path, int level, double ratio, string? why = null)
    {
        try
        {
            var file = new FileInfo(path);
            lock (StoreLock)
            {
                Marks[path] = new Mark(file.Length, file.LastWriteTimeUtc.Ticks, level, ratio, why);
                AppData.WriteAtomically(StorePath, JsonSerializer.Serialize(Marks));
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }

    /// <summary>
    /// Why `path` will not be a fifth smaller at quality `level`: tried before and came out too large, or recorded at so
    /// few bits that HEVC needs as many (an H.264 720p60 of 3.3 Mbit/s came out 40 % larger at quality 28; one of 1080p60
    /// at 23 Mbit/s, 0.19 bits a pixel, 57–70 %). Null: it is to be compressed.
    /// </summary>
    public static string? Reason(string path, VideoInfo info, VideoJob job, bool screenRecording)
    {
        if (job.Rebuild) return null;
        Mark? mark;
        lock (StoreLock) Marks.TryGetValue(path, out mark);
        if (mark != null && job.Quality <= mark.Level)
        {
            try
            {
                var file = new FileInfo(path);
                if (file.Length == mark.Size && file.LastWriteTimeUtc.Ticks == mark.Written && mark.Why == VideoCompressor.Damaged)
                    return L("в оригинале есть битые кадры: в сжатом их не будет");
                if (file.Length == mark.Size && file.LastWriteTimeUtc.Ticks == mark.Written && mark.Why?.StartsWith(VmafMark) == true)
                    return F("сжатое отличалось бы от оригинала (VMAF %@ из 100)", mark.Why[VmafMark.Length..]);
                if (file.Length == mark.Size && file.LastWriteTimeUtc.Ticks == mark.Written)
                    return F("пробовали: выходит %@ % от оригинала", Math.Round(mark.Ratio * 100));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
            }
        }
        // Few bits for its pixels, at its own size and at the gentler levels: HEVC without loss needs about as many.
        bool smaller = (long)job.Width * job.Height < (long)info.Width * info.Height * 0.9;
        double frames = info.Fps is > 0 and < 1000 ? info.Fps : 30;
        double bitsPerPixel = info.VideoBitrate / ((double)info.Width * info.Height * frames);
        if (!screenRecording && !smaller && job.Quality <= Compression.DefaultVideoQuality && info.VideoBitrate > 0 && bitsPerPixel < 0.09)
            return F("записано с малым битрейтом (%@ Мбит/с): без потерь меньше не станет", Math.Round(info.VideoBitrate / 1e6, 1));
        return null;
    }
}
