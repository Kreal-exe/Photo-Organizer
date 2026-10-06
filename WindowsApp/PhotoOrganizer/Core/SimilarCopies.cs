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
    /// Sets of copies, each ordered best quality first. Sets `BetterCopy` on every lesser copy, `Tiny` on the
    /// thumbnails (at most half as large as the best version, along the longest side), and clears both on everything
    /// else. Deliberately strict, because the result is offered for deletion.
    /// </summary>
    public static List<List<PhotoItem>> FindSets(IEnumerable<PhotoItem> items)
    {
        var hashed = new List<PhotoItem>();
        foreach (var item in items)
        {
            item.BetterCopy = null;
            item.Tiny = false;
            item.BestOfCopies = false;
            if (item.VisualHash != null && !item.IsDuplicate && !item.Video) hashed.Add(item);
        }
        int count = hashed.Count;
        if (count < 2) return [];
        var hashes = hashed.Select(i => i.VisualHash!.Value).ToArray();
        var parent = Enumerable.Range(0, count).ToArray();
        int Find(int i)
        {
            while (parent[i] != i) { parent[i] = parent[parent[i]]; i = parent[i]; }
            return i;
        }
        // Two 64-bit values at most 2 bits apart agree on at least two of their four 16-bit quarters, so looking only
        // at files that share a quarter finds every pair without comparing everything with everything.
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
                        int a = members[x], b = members[y];
                        if (BitOperations.PopCount(hashes[a] ^ hashes[b]) > MaximumHashDistance) continue;
                        if (Find(a) != Find(b) && AreCopies(hashed[a], hashed[b])) parent[Find(b)] = Find(a);
                    }
                }
            }
        }
        var sets = new List<List<PhotoItem>>();
        foreach (var group in Enumerable.Range(0, count).GroupBy(Find))
        {
            var set = group.Select(i => hashed[i]).ToList();
            if (set.Count < 2) continue;
            set.Sort(CompareQuality);
            var best = set[0];
            best.BestOfCopies = true;
            int bestSide = Math.Max(best.PixelWidth, best.PixelHeight);
            foreach (var copy in set.Skip(1))
            {
                copy.BetterCopy = best;
                copy.Tiny = Math.Max(copy.PixelWidth, copy.PixelHeight) * 2 <= bestSide;
                foreach (var twin in copy.Duplicates ?? []) twin.Tiny = copy.Tiny;   // an exact copy of a thumbnail is one too
            }
            sets.Add(set);
        }
        sets.Sort((a, b) => PhotoItem.ByDate(a[0], b[0]));
        return sets;
    }
}
