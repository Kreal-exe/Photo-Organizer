using System.Globalization;
using static PhotoOrganizer.Core.Strings;
using System.Buffers.Binary;
using System.Numerics;

namespace PhotoOrganizer.Core;

/// <summary>Finds copies of one picture that are not byte-identical: resized, recompressed or re-saved versions.</summary>
public static partial class SimilarCopies
{
    const int MaximumHashDistance = 2, MaximumMomentHashDistance = 12;

    /// <summary>
    /// A 64-bit fingerprint of how the picture looks (a difference hash) from a 9×8 grey picture, row by row: copies of
    /// one picture get the same value give or take a couple of bits, whatever their size or compression. Null for
    /// pictures too plain to tell apart this way (a blank wall, a black frame).
    /// </summary>
    public static ulong? VisualHash(ReadOnlySpan<byte> gray9x8)
    {
        ulong hash = 0;
        for (int row = 0; row < 8; row++)
        {
            for (int column = 0; column < 8; column++)
            {
                hash = (hash << 1) | (gray9x8[row * 9 + column] > gray9x8[row * 9 + column + 1] ? 1UL : 0UL);
            }
        }
        int bits = BitOperations.PopCount(hash);
        return bits is < 10 or > 54 ? null : hash;   // nearly uniform: any two such pictures would "match"
    }

    /// <summary>
    /// Both pictures as grey pixels on one grid of up to 160 pixels across (never finer than the smaller one), and how
    /// they differ: the share of pixels that differ clearly (more than 40 of 255, after evening out an overall change
    /// of brightness) and the mean difference. Null when either can't be read.
    /// </summary>
    public static (double Changed, double Mean)? Difference(string pathA, string pathB, int width, int height, int smallerWidth)
    {
        int w = Math.Clamp(smallerWidth / 2, 8, 160);   // at least two pixels of the smaller picture per cell
        int h = Math.Max(8, (int)Math.Round(w * (double)height / width));
        var a = Gray(pathA, w, h);
        var b = Gray(pathB, w, h);
        if (a == null || b == null) return null;
        double offset = 0;
        for (int i = 0; i < a.Length; i++) offset += a[i] - b[i];
        offset /= a.Length;
        int changed = 0;
        double sum = 0;
        for (int i = 0; i < a.Length; i++)
        {
            double d = Math.Abs(a[i] - b[i] - offset);
            sum += d;
            if (d > 40) changed++;
        }
        return ((double)changed / a.Length, sum / a.Length);
    }

    /// <summary>The picture as w×h grey values, each the average of its area.</summary>
    static float[]? Gray(string path, int w, int h)
    {
        var image = Images.Load(path, Math.Max(w, h) * 3);
        if (image == null) return null;
        var sums = new float[w * h];
        var counts = new int[w * h];
        for (int y = 0; y < image.Height; y++)
        {
            int row = Math.Min(h - 1, y * h / image.Height) * w;
            for (int x = 0; x < image.Width; x++)
            {
                int at = (y * image.Width + x) * 3, cell = row + Math.Min(w - 1, x * w / image.Width);
                sums[cell] += (image.Bgr[at] * 29 + image.Bgr[at + 1] * 150 + image.Bgr[at + 2] * 77) / 256f;
                counts[cell]++;
            }
        }
        for (int i = 0; i < sums.Length; i++) sums[i] /= Math.Max(1, counts[i]);
        return sums;
    }

    static bool AreCopies(PhotoItem a, PhotoItem b)
    {
        if (a.PixelWidth <= 0 || a.PixelHeight <= 0 || b.PixelWidth <= 0 || b.PixelHeight <= 0) return false;
        double aspectA = (double)a.PixelWidth / a.PixelHeight, aspectB = (double)b.PixelWidth / b.PixelHeight;
        if (Math.Abs(aspectA - aspectB) > 0.02 * Math.Max(aspectA, aspectB)) return false;
        // Two files that both know when they were shot, at different moments, are different shots however alike:
        // frames of a burst must not be offered for deletion.
        bool timedA = a.DateSource is DateSource.Exif or DateSource.Name, timedB = b.DateSource is DateSource.Exif or DateSource.Name;
        if (timedA && timedB && Math.Abs((a.Date - b.Date).TotalSeconds) >= 1) return false;
        // A burst takes several frames in one second, alike but for closed eyes or a turned head — fewer pixels than
        // any comparison can tell from compression: the camera's numbers (IMG_1218, IMG_1219) or the fractions of the
        // second it wrote (.365, .609) tell them apart. Copies of one shot keep both.
        if (CameraNumber(a) is { } numberA && CameraNumber(b) is { } numberB && numberA != numberB) return false;
        if (a.DateSource == DateSource.Exif && b.DateSource == DateSource.Exif
            && SubSeconds(a.Path) is { } subA && SubSeconds(b.Path) is { } subB && subA != subB) return false;
        return true;
    }

    [System.Text.RegularExpressions.GeneratedRegex(@"^(IMG|DSC|DSCF|DSCN|DJI|GOPR|_DSC|_MG|P)_?(\d{4,5})(?!\d)", System.Text.RegularExpressions.RegexOptions.IgnoreCase)]
    private static partial System.Text.RegularExpressions.Regex CameraName();

    /// <summary>What a copy gets after the name: "_1", "(1)", " copy", " - Copy 2".</summary>
    [System.Text.RegularExpressions.GeneratedRegex(@"(_\d{1,2}|\s?\(\d+\)|\s(-\s)?copy(\s\d+)?)$", System.Text.RegularExpressions.RegexOptions.IgnoreCase)]
    private static partial System.Text.RegularExpressions.Regex CopySuffix();

    /// <summary>The number a camera gave the shot ("IMG_1218(3).JPG" → "IMG1218"); null for names it did not give.</summary>
    static string? CameraNumber(PhotoItem item)
    {
        var match = CameraName().Match(Path.GetFileNameWithoutExtension(item.Name));
        return match.Success ? match.Groups[1].Value.ToUpperInvariant().TrimStart('_') + match.Groups[2].Value : null;
    }

    static readonly System.Collections.Concurrent.ConcurrentDictionary<string, string?> SubSecondsRead = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>The fractions of the second of the capture time (Exif SubSecTimeOriginal) of a JPEG or a RAW; null when not written.</summary>
    static string? SubSeconds(string path) => SubSecondsRead.GetOrAdd(path, p =>
    {
        try
        {
            var buffer = new byte[256 * 1024];
            int read;
            using (var stream = new FileStream(p, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) read = stream.ReadAtLeast(buffer, buffer.Length, false);
            var data = buffer.AsSpan(0, read);
            Tiff? tiff;
            if (read > 2 && data[0] == 0xFF && data[1] == 0xD8)
            {
                // A JPEG: the TIFF structure inside its Exif segment.
                int at = data.IndexOf("Exif\0\0"u8);
                if (at < 0) return null;
                tiff = Tiff.TryRead(data[(at + 6)..].ToArray());
            }
            else
            {
                tiff = Tiff.TryRead(data.ToArray());
            }
            return tiff?.Exif is { } exif ? tiff.Text(exif, 37521)?.Trim() is { Length: > 0 } sub ? sub : null : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    });

    /// <summary>
    /// Which of a RAW photo and a JPEG (or HEIC) of the same shot is kept as the original: 0 the better quality (the
    /// RAW, most pixels), 1 the RAW, 2 the JPEG — a library that already has the JPEGs can let the RAW files go.
    /// </summary>
    public static int RawPreference
    {
        get => Math.Clamp(Settings.Shared.Get("rawJpegPreference", 0), 0, 2);
        set => Settings.Shared.Set("rawJpegPreference", value);
    }

    /// <summary>
    /// Which copy is kept: 0 the better quality, 1 the compressed one, so that what was compressed stays compressed — of
    /// a RAW and a JPEG of one shot the JPEG (old ProRAW files come back next to the JPEGs made of them), of copies of a
    /// video HEVC, then the lightest. Among ordinary photos the larger still wins: the lightest would be a thumbnail.
    /// </summary>
    public static int CompressedPreference
    {
        get => Math.Clamp(Settings.Shared.Get("compressedCopyPreference", Settings.Shared.Get("videoCopyPreference", 0)), 0, 1);
        set => Settings.Shared.Set("compressedCopyPreference", value);
    }

    /// <summary>
    /// The kept one first: of a RAW and a JPEG of the same shot, the one RawPreference asks for; otherwise the better
    /// quality — most pixels, then the larger file, then the one that kept its metadata.
    /// </summary>
    static int CompareQuality(PhotoItem a, PhotoItem b)
    {
        bool rawA = Compression.IsRaw(a), rawB = Compression.IsRaw(b);
        if (rawA != rawB && CompressedPreference == 1) return rawA ? 1 : -1;
        if (rawA != rawB && RawPreference != 0) return rawA == (RawPreference == 1) ? -1 : 1;
        if (a.Video && b.Video)
        {
            if (CompressedPreference == 1)
            {
                // The lightest; of two as light, HEVC.
                if (a.FileSize != b.FileSize) return a.FileSize.CompareTo(b.FileSize);
                bool hevcA = IsHevc(a.Path), hevcB = IsHevc(b.Path);
                if (hevcA != hevcB) return hevcA ? -1 : 1;
            }
            else if ((long)a.PixelWidth * a.PixelHeight == (long)b.PixelWidth * b.PixelHeight)
            {
                // Of one frame size, the camera's own file over one encoded again (by this app or another): every
                // encoding loses — a copy that came back from iCloud encoded by Apple and then compressed here was
                // larger than the camera's H.264 and scored lower against it (VMAF), with a higher bitrate. More pixels
                // still win: a 720p original over a 640p copy of it.
                bool againA = IsReencoded(a.Path), againB = IsReencoded(b.Path);
                if (againA != againB) return againA ? 1 : -1;
            }
        }
        long pixelsA = (long)a.PixelWidth * a.PixelHeight, pixelsB = (long)b.PixelWidth * b.PixelHeight;
        if (pixelsA != pixelsB) return pixelsB.CompareTo(pixelsA);
        // As good as each other: the one under the camera's own name, not the one a copy got ("IMG_0389_1", "IMG_0409(1)").
        if (Math.Abs(a.FileSize - b.FileSize) <= Math.Max(a.FileSize, b.FileSize) / 100)
        {
            bool copyA = CopySuffix().IsMatch(Path.GetFileNameWithoutExtension(a.Name)), copyB = CopySuffix().IsMatch(Path.GetFileNameWithoutExtension(b.Name));
            if (copyA != copyB) return copyA ? 1 : -1;
        }
        if (a.FileSize != b.FileSize) return b.FileSize.CompareTo(a.FileSize);
        bool exifA = a.DateSource == DateSource.Exif, exifB = b.DateSource == DateSource.Exif;
        if (exifA != exifB) return exifA ? -1 : 1;
        return NaturalComparer.Instance.Compare(a.RelativePath, b.RelativePath);
    }

    static bool HasOwnDate(PhotoItem item) => item.DateSource is DateSource.Exif or DateSource.Name or DateSource.Takeout or DateSource.Manual;

    /// <summary>
    /// Gives every copy of a set the right date: one without a date of its own gets it, and so does one whose own date
    /// is another moment — an export that wrote its own time into the file (Google's). See TrustedDate.
    /// </summary>
    public static int ShareDates(IEnumerable<List<PhotoItem>> sets)
    {
        int shared = 0;
        foreach (var set in sets)
        {
            var members = set.SelectMany(item => new[] { item }.Concat(item.Duplicates ?? [])).ToList();   // exact twins too
            if (TrustedDate(members) is not { } source) continue;
            foreach (var copy in members)
            {
                if (copy == source || copy.DateSource == DateSource.Manual) continue;
                // The same moment, maybe written in another time zone: its own date stays. A date given by hand goes only
                // to the copies without one — a camera's date is not overwritten by what was set on another copy.
                if (HasOwnDate(copy) && (source.DateSource == DateSource.Manual || SameClock(Math.Abs((copy.Date - source.Date).TotalSeconds)))) continue;
                copy.Date = source.Date;
                copy.DateSource = DateSource.Copy;
                shared++;
            }
        }
        return shared;
    }

    /// <summary>
    /// The copy whose date is the right one: the date given by hand; else the one that agrees with the moment its name
    /// says (VID_20180516_135705); else the earliest — a recording is made before any copy or export of it.
    /// </summary>
    static PhotoItem? TrustedDate(List<PhotoItem> members)
    {
        var own = members.Where(HasOwnDate).ToList();
        if (own.Count == 0) return null;
        if (own.FirstOrDefault(i => i.DateSource == DateSource.Manual) is { } manual) return manual;
        foreach (var item in own)
        {
            if (Scanner.DateFromFileName(item.Name) is { } named && named.TimeOfDay != TimeSpan.FromHours(12)
                && SameClock(Math.Abs((item.Date - named).TotalSeconds))) return item;
        }
        return own.OrderBy(i => i.Date).ThenBy(i => i.DateSource == DateSource.Exif ? 0 : 1).First();
    }

    /// <summary>Both shot at the same fraction of a second, as the camera wrote it (a moment no other frame shares).</summary>
    static bool SameSubSeconds(PhotoItem a, PhotoItem b) =>
        a.DateSource == DateSource.Exif && b.DateSource == DateSource.Exif && SubSeconds(a.Path) is { } subA && subA.Length > 0 && subA == SubSeconds(b.Path);

    /// <summary>
    /// Pictures that differ in a share of pixels above this are different pictures, however alike their fingerprints:
    /// screenshots of one app with other numbers differ in 1–2 %, recompressed and resized copies in under 0.1 %.
    /// </summary>
    internal const double MaximumChangedShare = 0.003;

    /// <summary>
    /// Sets of copies, each ordered best quality first. Deliberately strict, because the result is offered for deletion:
    /// fingerprints at most 2 bits apart, the same proportions, the same moment when both files know it, and then the
    /// pictures themselves compared pixel by pixel. Blocking (it reads the candidates); call it on a worker and apply
    /// the result with Mark.
    /// </summary>
    public static List<List<PhotoItem>> FindSets(IReadOnlyList<PhotoItem> items, CancellationToken token = default)
    {
        // With a fingerprint, or — a dark or plain picture has none worth having — a moment from the camera to go by.
        var hashed = items.Where(i => !i.IsDuplicate && !i.Video && (i.VisualHash != null || i.DateSource == DateSource.Exif)).ToList();
        int count = hashed.Count;
        if (count < 2) return VideoSets(items, token);
        var hashes = hashed.Select(i => i.VisualHash ?? 0).ToArray();
        var fingerprinted = hashed.Select(i => i.VisualHash != null).ToArray();
        // Two 64-bit values at most 2 bits apart agree on at least two of their four 16-bit quarters, so looking only
        // at files that share a quarter finds every pair without comparing everything with everything.
        var candidates = new HashSet<(int, int)>();
        for (int quarter = 0; quarter < 4; quarter++)
        {
            int shift = quarter * 16;
            foreach (var bucket in Enumerable.Range(0, count).Where(i => fingerprinted[i]).GroupBy(i => (hashes[i] >> shift) & 0xFFFF))
            {
                var members = bucket.ToArray();
                for (int x = 0; x < members.Length; x++)
                {
                    for (int y = x + 1; y < members.Length; y++)
                    {
                        int a = Math.Min(members[x], members[y]), b = Math.Max(members[x], members[y]);
                        if (BitOperations.PopCount(hashes[a] ^ hashes[b]) <= MaximumHashDistance && AreCopies(hashed[a], hashed[b])) candidates.Add((a, b));
                    }
                }
            }
        }
        // A thumbnail squeezed hard moves the fingerprint a few bits more (a 600×800 copy of a 12-megapixel photo:
        // 3 to 6), and a dark one more still, or has none. Shot at the same second, with the same proportions — and,
        // when the fingerprints are far apart or missing, at the same fraction of that second — the two are compared all
        // the same: the pixels decide, as for every candidate.
        foreach (var moment in Enumerable.Range(0, count).Where(i => hashed[i].DateSource == DateSource.Exif)
                                         .GroupBy(i => hashed[i].Date.Ticks / TimeSpan.TicksPerSecond))
        {
            var members = moment.ToArray();
            if (members.Length is < 2 or > 20) continue;
            for (int x = 0; x < members.Length; x++)
            {
                for (int y = x + 1; y < members.Length; y++)
                {
                    int a = Math.Min(members[x], members[y]), b = Math.Max(members[x], members[y]);
                    bool near = fingerprinted[a] && fingerprinted[b] && BitOperations.PopCount(hashes[a] ^ hashes[b]) <= MaximumMomentHashDistance;
                    if ((near || SameSubSeconds(hashed[a], hashed[b])) && AreCopies(hashed[a], hashed[b])) candidates.Add((a, b));
                }
            }
        }
        // The fingerprint is coarse (9×8 pixels): every candidate is checked on the pictures themselves.
        var verdicts = Verdicts.Load();
        var confirmed = new System.Collections.Concurrent.ConcurrentBag<(int, int)>();
        try
        {
            Parallel.ForEach(candidates, new ParallelOptions { MaxDegreeOfParallelism = Math.Clamp(Environment.ProcessorCount / 2, 2, 8), CancellationToken = token },
                pair =>
                {
                    if (SameContent(hashed[pair.Item1], hashed[pair.Item2], verdicts)) confirmed.Add(pair);
                });
        }
        catch (OperationCanceledException)
        {
            return [];
        }
        finally
        {
            verdicts.Save();
        }
        var parent = Enumerable.Range(0, count).ToArray();
        int Find(int i)
        {
            while (parent[i] != i) { parent[i] = parent[parent[i]]; i = parent[i]; }
            return i;
        }
        foreach (var (a, b) in confirmed) parent[Find(b)] = Find(a);
        var sets = new List<List<PhotoItem>>();
        foreach (var group in Enumerable.Range(0, count).GroupBy(Find))
        {
            var set = group.Select(i => hashed[i]).ToList();
            if (set.Count < 2) continue;
            set.Sort(CompareQuality);
            sets.Add(set);
        }
        sets.AddRange(VideoSets(items, token));
        sets.Sort((a, b) => PhotoItem.ByDate(a[0], b[0]));
        return sets;
    }

    /// <summary>
    /// Copies of one video saved again (IMG_0389.MOV and IMG_0389_1.MOV, an export that wrote other metadata around
    /// the same pictures): the same length and frame size, and then the proof — the same video stream, frame for frame
    /// (see VideoStreamPrint). And one video encoded again (Google Photos' H.264, this app's HEVC): see SameMoment. The
    /// camera's number alone proves nothing: an iPhone counts to IMG_9999 and starts again, so IMG_7797 of 2021 and
    /// IMG_7797 of 2024 are different videos of one length. Each set ordered best quality first.
    /// </summary>
    static List<List<PhotoItem>> VideoSets(IReadOnlyList<PhotoItem> items, CancellationToken token)
    {
        var videos = items.Where(i => i.Video && !i.IsDuplicate && i.Duration >= 0.5 && i.PixelWidth > 0 && i.PixelHeight > 0 && i.FileSize > 0)
                          .OrderBy(i => i.Duration).ToList();
        var parent = Enumerable.Range(0, videos.Count).ToArray();
        int Find(int i)
        {
            while (parent[i] != i) { parent[i] = parent[parent[i]]; i = parent[i]; }
            return i;
        }
        var candidates = new HashSet<int>();
        for (int a = 0; a < videos.Count; a++)
        {
            for (int b = a + 1; b < videos.Count && videos[b].Duration - videos[a].Duration <= MaximumMomentDurationDifference; b++)
            {
                if (SameMoment(videos[a], videos[b]) || SameNamedMoment(videos[a], videos[b])) parent[Find(b)] = Find(a);
                if (videos[b].Duration - videos[a].Duration > MaximumDurationDifference || !MayBeVideoCopies(videos[a], videos[b])) continue;
                candidates.Add(a);
                candidates.Add(b);
            }
        }
        // Only the index of each file is read (its table of frames) and its first frame: a few hundredths of a second.
        var prints = new System.Collections.Concurrent.ConcurrentDictionary<int, string>();
        try
        {
            Parallel.ForEach(candidates, new ParallelOptions { MaxDegreeOfParallelism = 8, CancellationToken = token },
                i => { if (VideoStreamPrint(videos[i].Path) is { } print) prints[i] = print; });
        }
        catch (OperationCanceledException)
        {
            return [];
        }
        foreach (var group in prints.GroupBy(p => p.Value))
        {
            int first = group.First().Key;
            foreach (var (index, _) in group) parent[Find(index)] = Find(first);
        }
        var sets = new List<List<PhotoItem>>();
        foreach (var group in Enumerable.Range(0, videos.Count).GroupBy(Find))
        {
            var set = group.Select(i => videos[i]).ToList();
            if (set.Count < 2) continue;
            set.Sort(CompareQuality);
            sets.Add(set);
        }
        return sets;
    }

    const double MaximumDurationDifference = 0.05, MaximumMomentDurationDifference = 0.25;

    /// <summary>
    /// One recording kept twice in different encodings (IMG_0389.MOV in Google Photos' H.264, IMG_0389 (2).MOV in this
    /// app's HEVC): no byte in common, but the moment it was shot, to the second, as both files say; the same shape of
    /// frame (the size may differ — 4K and its 1080p); the same length within a quarter of a second; and the same
    /// camera's number, or the same name but for a copy's suffix. A camera can't start two videos in one second, and an
    /// export's date shared by several videos is not enough: their numbers differ.
    /// </summary>
    static bool SameMoment(PhotoItem a, PhotoItem b)
    {
        bool timedA = a.DateSource is DateSource.Exif or DateSource.Name, timedB = b.DateSource is DateSource.Exif or DateSource.Name;
        if (!timedA || !timedB || !SameClock(Math.Abs((a.Date - b.Date).TotalSeconds))) return false;
        double aspectA = (double)Math.Max(a.PixelWidth, a.PixelHeight) / Math.Min(a.PixelWidth, a.PixelHeight);
        double aspectB = (double)Math.Max(b.PixelWidth, b.PixelHeight) / Math.Min(b.PixelWidth, b.PixelHeight);
        if (Math.Abs(aspectA - aspectB) > 0.01 * aspectA) return false;
        if (CameraNumber(a) is { } numberA && CameraNumber(b) is { } numberB) return numberA == numberB;
        return BaseName(a).Equals(BaseName(b), StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// The same recording under a name that says when it was made ("VID_20180516_135705.mp4"), of the same length and
    /// shape: kept twice by an export that wrote another date inside (Google's). A name with the moment to the second is
    /// one recording's own; a camera's counter (IMG_7797) is not — it starts again — and does not count here.
    /// </summary>
    static bool SameNamedMoment(PhotoItem a, PhotoItem b)
    {
        if (!BaseName(a).Equals(BaseName(b), StringComparison.OrdinalIgnoreCase)) return false;
        if (Scanner.DateFromFileName(a.Name) is not { } date || date.TimeOfDay == TimeSpan.FromHours(12)) return false;   // no time of day in it
        double aspectA = (double)Math.Max(a.PixelWidth, a.PixelHeight) / Math.Min(a.PixelWidth, a.PixelHeight);
        double aspectB = (double)Math.Max(b.PixelWidth, b.PixelHeight) / Math.Min(b.PixelWidth, b.PixelHeight);
        return Math.Abs(aspectA - aspectB) <= 0.01 * aspectA;
    }

    /// <summary>
    /// The same moment: within a second, or apart by whole time zones (up to 14 hours, in quarters of an hour) — one
    /// file says it in local time, the other in UTC, read as this computer's local time.
    /// </summary>
    static bool SameClock(double seconds)
    {
        if (seconds > 14 * 3600 + 1) return false;
        double rest = seconds % 900;
        return rest < 1 || rest > 899;
    }

    /// <summary>The name without its extension and without what a copy gets ("_1", "(2)", " copy").</summary>
    static string BaseName(PhotoItem item) => CopySuffix().Replace(Path.GetFileNameWithoutExtension(item.Name), "");

    /// <summary>What is cheap to check, before the files are read.</summary>
    static bool MayBeVideoCopies(PhotoItem a, PhotoItem b)
    {
        if (Math.Max(a.PixelWidth, a.PixelHeight) != Math.Max(b.PixelWidth, b.PixelHeight)
            || Math.Min(a.PixelWidth, a.PixelHeight) != Math.Min(b.PixelWidth, b.PixelHeight)) return false;
        return !(CameraNumber(a) is { } numberA && CameraNumber(b) is { } numberB && numberA != numberB);
    }

    /// <summary>
    /// The video stream of a MOV or MP4, independent of everything written around it: a hash of the size of every
    /// frame of its video track and of the first frame's bytes. Two files with the same print hold the same pictures,
    /// bit for bit — whatever their dates, names or other tracks. Null when the file is not a MOV/MP4 or unreadable.
    /// </summary>
    internal static string? VideoStreamPrint(string path)
    {
        try
        {
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 16);
            long length = file.Length;
            byte[]? moov = ReadMovie(file);
            if (moov == null) return null;
            foreach (var trak in Boxes(moov, 0, moov.Length).Where(b => b.Type == "trak"))
            {
                if (Child(moov, trak.Start, trak.End, "mdia") is not { } mdia) continue;
                if (Child(moov, mdia.Start, mdia.End, "hdlr") is not { } hdlr || hdlr.End - hdlr.Start < 12
                    || !moov.AsSpan(hdlr.Start + 8, 4).SequenceEqual("vide"u8)) continue;
                if (Child(moov, mdia.Start, mdia.End, "minf") is not { } minf || Child(moov, minf.Start, minf.End, "stbl") is not { } stbl) continue;
                if (Child(moov, stbl.Start, stbl.End, "stsz") is not { } stsz || stsz.End - stsz.Start < 12) return null;
                using var hash = System.Security.Cryptography.IncrementalHash.CreateHash(System.Security.Cryptography.HashAlgorithmName.SHA256);
                hash.AppendData(moov.AsSpan(stsz.Start, stsz.End - stsz.Start));
                // The first frame itself: at the start of the first chunk, as long as the table says.
                long offset = -1;
                if (Child(moov, stbl.Start, stbl.End, "stco") is { } stco && stco.End - stco.Start >= 12)
                    offset = BinaryPrimitives.ReadUInt32BigEndian(moov.AsSpan(stco.Start + 8));
                else if (Child(moov, stbl.Start, stbl.End, "co64") is { } co64 && co64.End - co64.Start >= 16)
                    offset = (long)BinaryPrimitives.ReadUInt64BigEndian(moov.AsSpan(co64.Start + 8));
                uint fixedSize = BinaryPrimitives.ReadUInt32BigEndian(moov.AsSpan(stsz.Start + 4));
                long firstSize = fixedSize != 0 ? fixedSize
                    : stsz.End - stsz.Start >= 16 ? BinaryPrimitives.ReadUInt32BigEndian(moov.AsSpan(stsz.Start + 12)) : 0;
                if (offset < 0 || firstSize <= 0 || offset + firstSize > length) return null;
                var first = new byte[Math.Min(firstSize, 4 << 20)];
                file.Position = offset;
                file.ReadExactly(first);
                hash.AppendData(first);
                return Convert.ToHexString(hash.GetHashAndReset());
            }
            return null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or EndOfStreamException)
        {
            return null;
        }
    }

    /// <summary>The movie box (moov) of a MOV or MP4, the index of its tracks; null when there is none.</summary>
    static byte[]? ReadMovie(FileStream file)
    {
        long position = 0, length = file.Length;
        var header = new byte[16];
        while (position + 8 <= length)
        {
            file.Position = position;
            if (file.ReadAtLeast(header, 16, false) < 8) return null;
            long size = BinaryPrimitives.ReadUInt32BigEndian(header);
            int headerSize = 8;
            if (size == 1)
            {
                size = (long)BinaryPrimitives.ReadUInt64BigEndian(header.AsSpan(8));
                headerSize = 16;
            }
            else if (size == 0)
            {
                size = length - position;
            }
            if (size < headerSize) return null;
            if (header.AsSpan(4, 4).SequenceEqual("moov"u8))
            {
                if (size > 64 << 20) return null;
                var moov = new byte[size - headerSize];
                file.Position = position + headerSize;
                file.ReadExactly(moov);
                return moov;
            }
            position += size;
        }
        return null;
    }

    static readonly System.Collections.Concurrent.ConcurrentDictionary<string, bool> HevcRead = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Whether a video's pictures are HEVC (hvc1, hev1): what compressing makes, and what keeps more in fewer bytes.</summary>
    static readonly System.Collections.Concurrent.ConcurrentDictionary<string, bool> ReencodedRead = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Whether FFmpeg wrote the video (its name is in the file's metadata): encoded again after the camera.</summary>
    static bool IsReencoded(string path) => ReencodedRead.GetOrAdd(path, p =>
    {
        try
        {
            using var file = new FileStream(p, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 16);
            return ReadMovie(file) is { } moov && moov.AsSpan().IndexOf("Lavf"u8) >= 0;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or EndOfStreamException)
        {
            return false;
        }
    });

    static bool IsHevc(string path) => HevcRead.GetOrAdd(path, p =>
    {
        try
        {
            using var file = new FileStream(p, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 16);
            if (ReadMovie(file) is not { } moov) return false;
            foreach (var trak in Boxes(moov, 0, moov.Length).Where(b => b.Type == "trak"))
            {
                if (Child(moov, trak.Start, trak.End, "mdia") is not { } mdia) continue;
                if (Child(moov, mdia.Start, mdia.End, "hdlr") is not { } hdlr || hdlr.End - hdlr.Start < 12
                    || !moov.AsSpan(hdlr.Start + 8, 4).SequenceEqual("vide"u8)) continue;
                if (Child(moov, mdia.Start, mdia.End, "minf") is not { } minf || Child(moov, minf.Start, minf.End, "stbl") is not { } stbl
                    || Child(moov, stbl.Start, stbl.End, "stsd") is not { } stsd || stsd.End - stsd.Start < 16) return false;
                var type = moov.AsSpan(stsd.Start + 12, 4);   // the first sample description: version and count, its size, its type
                return type.SequenceEqual("hvc1"u8) || type.SequenceEqual("hev1"u8);
            }
            return false;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or EndOfStreamException)
        {
            return false;
        }
    });

    /// <summary>The boxes directly inside [start, end) of an MP4 structure: type and body.</summary>
    static IEnumerable<(string Type, int Start, int End)> Boxes(byte[] data, int start, int end)
    {
        int position = start;
        while (position + 8 <= end)
        {
            long size = BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(position));
            int headerSize = 8;
            if (size == 1 && position + 16 <= end)
            {
                size = (long)BinaryPrimitives.ReadUInt64BigEndian(data.AsSpan(position + 8));
                headerSize = 16;
            }
            else if (size == 0)
            {
                size = end - position;
            }
            if (size < headerSize || position + size > end) yield break;
            yield return (System.Text.Encoding.ASCII.GetString(data, position + 4, 4), position + headerSize, (int)(position + size));
            position += (int)size;
        }
    }

    static (int Start, int End)? Child(byte[] data, int start, int end, string type)
    {
        foreach (var box in Boxes(data, start, end))
        {
            if (box.Type == type) return (box.Start, box.End);
        }
        return null;
    }

    /// <summary>The sets put in order again after RawPreference changed, and marked anew on the files.</summary>
    public static void Reorder(IEnumerable<PhotoItem> items, List<List<PhotoItem>> sets)
    {
        foreach (var set in sets) set.Sort(CompareQuality);
        Mark(items, sets);
    }

    /// <summary>
    /// Marks the result of FindSets on the files: `BetterCopy` on every lesser copy, `Tiny` on the thumbnails (at most
    /// half as large as the best version, along the longest side); clears both on everything else.
    /// </summary>
    public static void Mark(IEnumerable<PhotoItem> items, List<List<PhotoItem>> sets)
    {
        foreach (var item in items)
        {
            item.BetterCopy = null;
            item.Tiny = false;
            item.BestOfCopies = false;
            item.SameAsBest = false;
            item.CopyNote = null;
        }
        foreach (var set in sets)
        {
            var best = set[0];
            best.BestOfCopies = true;
            int bestSide = Math.Max(best.PixelWidth, best.PixelHeight);
            foreach (var copy in set.Skip(1))
            {
                copy.BetterCopy = best;
                copy.Tiny = Math.Max(copy.PixelWidth, copy.PixelHeight) * 2 <= bestSide;
                copy.SameAsBest = SameQuality(best, copy);
                copy.CopyNote = Note(best, copy);
                foreach (var twin in copy.Duplicates ?? []) twin.Tiny = copy.Tiny;   // an exact copy of a thumbnail is one too
            }
            best.SameAsBest = set.Skip(1).All(c => c.SameAsBest);
            if (best.Video && set.Skip(1).Any(c => c.CopyNote == L("Перекодирован"))) best.CopyNote = L("Файл камеры");
        }
    }

    /// <summary>
    /// Why a copy stands below the best one, in a word on its badge: fewer pixels; encoded again where the best is the
    /// camera's own file; or merely lighter (or, when the compressed one is preferred, heavier). Null when nothing to say.
    /// </summary>
    static string? Note(PhotoItem best, PhotoItem copy)
    {
        if ((long)copy.PixelWidth * copy.PixelHeight < (long)best.PixelWidth * best.PixelHeight) return L("Меньше пикселей");
        if (best.Video && copy.Video && IsReencoded(copy.Path) && !IsReencoded(best.Path)) return L("Перекодирован");
        if (best.FileSize <= 0) return null;
        double ratio = (double)copy.FileSize / best.FileSize;
        if (ratio < 0.99) return F("Легче на %@ %", Math.Round((1 - ratio) * 100).ToString(CultureInfo.InvariantCulture));
        if (ratio > 1.01) return F("Тяжелее на %@ %", Math.Round((ratio - 1) * 100).ToString(CultureInfo.InvariantCulture));
        return null;
    }

    /// <summary>The same frame and the size within 1 %: nothing to choose between them but the name.</summary>
    static bool SameQuality(PhotoItem a, PhotoItem b) =>
        Math.Max(a.PixelWidth, a.PixelHeight) == Math.Max(b.PixelWidth, b.PixelHeight)
        && Math.Min(a.PixelWidth, a.PixelHeight) == Math.Min(b.PixelWidth, b.PixelHeight)
        && Compression.IsRaw(a) == Compression.IsRaw(b)
        && Math.Abs(a.FileSize - b.FileSize) <= Math.Max(a.FileSize, b.FileSize) / 100;

    static bool SameContent(PhotoItem a, PhotoItem b, Verdicts verdicts)
    {
        string key = Verdicts.Key(a, b);
        if (verdicts.TryGet(key, out bool same)) return same;
        var smaller = (long)a.PixelWidth * a.PixelHeight <= (long)b.PixelWidth * b.PixelHeight ? a : b;
        var difference = Difference(a.Path, b.Path, a.PixelWidth, a.PixelHeight, smaller.PixelWidth);
        if (difference == null) return false;   // unreadable now: not remembered, asked again next time
        same = difference.Value.Changed <= MaximumChangedShare;
        verdicts.Set(key, same);
        return same;
    }

    /// <summary>What the pixel comparison found for each pair, kept in the data folder so that it is done once.</summary>
    sealed class Verdicts
    {
        static readonly string FilePath = AppData.File("copies.txt");
        readonly Dictionary<string, bool> _known = [];
        readonly List<string> _added = [];

        public static string Key(PhotoItem a, PhotoItem b)
        {
            string ka = a.RecognitionKey ?? $"{a.Path}|{a.FileSize}", kb = b.RecognitionKey ?? $"{b.Path}|{b.FileSize}";
            return string.CompareOrdinal(ka, kb) < 0 ? $"{ka} {kb}" : $"{kb} {ka}";
        }

        public static Verdicts Load()
        {
            var verdicts = new Verdicts();
            try
            {
                foreach (string line in File.ReadLines(FilePath))
                {
                    int tab = line.LastIndexOf('\t');
                    if (tab > 0) verdicts._known[line[..tab]] = line[(tab + 1)..] == "1";
                }
            }
            catch (IOException)
            {
            }
            return verdicts;
        }

        public bool TryGet(string key, out bool same)
        {
            lock (_known) return _known.TryGetValue(key, out same);
        }

        public void Set(string key, bool same)
        {
            lock (_known)
            {
                _known[key] = same;
                _added.Add($"{key}\t{(same ? 1 : 0)}");
            }
        }

        public void Save()
        {
            lock (_known)
            {
                if (_added.Count == 0) return;
                try
                {
                    File.AppendAllLines(FilePath, _added);
                    _added.Clear();
                }
                catch (IOException)
                {
                }
            }
        }
    }
}
