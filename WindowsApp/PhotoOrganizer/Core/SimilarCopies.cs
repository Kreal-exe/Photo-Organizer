using System.Numerics;

namespace PhotoOrganizer.Core;

/// <summary>Finds copies of one picture that are not byte-identical: resized, recompressed or re-saved versions.</summary>
public static class SimilarCopies
{
    const int MaximumHashDistance = 2;

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
        return !(timedA && timedB && Math.Abs((a.Date - b.Date).TotalSeconds) >= 1);
    }

    /// <summary>Better quality first: most pixels, then the larger file, then the one that kept its metadata.</summary>
    static int CompareQuality(PhotoItem a, PhotoItem b)
    {
        long pixelsA = (long)a.PixelWidth * a.PixelHeight, pixelsB = (long)b.PixelWidth * b.PixelHeight;
        if (pixelsA != pixelsB) return pixelsB.CompareTo(pixelsA);
        if (a.FileSize != b.FileSize) return b.FileSize.CompareTo(a.FileSize);
        bool exifA = a.DateSource == DateSource.Exif, exifB = b.DateSource == DateSource.Exif;
        if (exifA != exifB) return exifA ? -1 : 1;
        return NaturalComparer.Instance.Compare(a.RelativePath, b.RelativePath);
    }

    static bool HasOwnDate(PhotoItem item) => item.DateSource is DateSource.Exif or DateSource.Name or DateSource.Takeout;

    /// <summary>Gives every copy without a date of its own the date of a copy in the same set that has one.</summary>
    public static int ShareDates(IEnumerable<List<PhotoItem>> sets)
    {
        int shared = 0;
        foreach (var set in sets)
        {
            PhotoItem? source = null;
            foreach (var item in set)
            {
                if (HasOwnDate(item) && (source == null || (item.DateSource == DateSource.Exif && source.DateSource != DateSource.Exif))) source = item;
            }
            if (source == null) continue;
            foreach (var item in set)
            {
                foreach (var copy in new[] { item }.Concat(item.Duplicates ?? []))   // exact twins too
                {
                    if (HasOwnDate(copy)) continue;
                    copy.Date = source.Date;
                    copy.DateSource = DateSource.Copy;
                    shared++;
                }
            }
        }
        return shared;
    }

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
        var hashed = items.Where(i => i.VisualHash != null && !i.IsDuplicate && !i.Video).ToList();
        int count = hashed.Count;
        if (count < 2) return [];
        var hashes = hashed.Select(i => i.VisualHash!.Value).ToArray();
        // Two 64-bit values at most 2 bits apart agree on at least two of their four 16-bit quarters, so looking only
        // at files that share a quarter finds every pair without comparing everything with everything.
        var candidates = new HashSet<(int, int)>();
        for (int quarter = 0; quarter < 4; quarter++)
        {
            int shift = quarter * 16;
            foreach (var bucket in Enumerable.Range(0, count).GroupBy(i => (hashes[i] >> shift) & 0xFFFF))
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
        sets.Sort((a, b) => PhotoItem.ByDate(a[0], b[0]));
        return sets;
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
                foreach (var twin in copy.Duplicates ?? []) twin.Tiny = copy.Tiny;   // an exact copy of a thumbnail is one too
            }
        }
    }

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
