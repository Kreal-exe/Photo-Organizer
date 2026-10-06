using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace PhotoOrganizer.Core;

public enum ScanPhase { Enumerating, Metadata, Duplicates }

/// <summary>Finds every image and video under a folder, reads its date and pixel size, and detects byte-identical copies.</summary>
public sealed partial class Scanner
{
    const FileAttributes CloudOnlyAttributes = FileAttributes.Offline | (FileAttributes)0x40000 | (FileAttributes)0x400000;
    static readonly HashSet<string> SkippedFolders = new(StringComparer.OrdinalIgnoreCase)
    {
        "$recycle.bin", "system volume information", "@eadir", ".thumbnails",
    };
    static readonly DateTime Year1990 = new(1990, 1, 1);

    readonly CancellationTokenSource _cancel = new();
    List<string> _sidecars = [];

    public Scanner(string root)
    {
        Root = System.IO.Path.GetFullPath(root).TrimEnd('\\', '/');
        if (Root.EndsWith(':')) Root += "\\";
    }

    public string Root { get; }
    /// <summary>Top-level folders whose files are never picked as the original of a duplicate set.</summary>
    public List<string> DeprioritizedFolders { get; set; } = [];

    public void Cancel() => _cancel.Cancel();

    /// <summary>Blocking. `progress(phase, done, total)` is called from worker threads. Returns null when cancelled.</summary>
    public List<PhotoItem>? Scan(Action<ScanPhase, int, int>? progress = null)
    {
        var token = _cancel.Token;
        var items = Enumerate(progress, token);
        if (token.IsCancellationRequested) return null;
        // What earlier scans of this folder read is reused: only new and changed files are read again.
        using var cache = new ScanCache(Root);
        ForEach(items, ScanPhase.Metadata, progress, item => ReadMetadata(item, cache), token);
        if (token.IsCancellationRequested) return null;
        DateFromTakeoutSidecars(items, _sidecars);
        DateFromNeighbors(items);
        ManualDates.ApplyTo(items);
        FindDuplicates(items, cache, progress, token);
        if (token.IsCancellationRequested) return null;
        items.Sort(PhotoItem.ByDate);
        return items;
    }

    // --- Dates in file names ----------------------------------------------------------------------------------------

    // The separator between year and month must be repeated between month and day ("2022-09-09", "20220909").
    [GeneratedRegex(@"(?<!\d)((?:19|20)\d{2})([-_.]?)(0[1-9]|1[0-2])\2(0[1-9]|[12]\d|3[01])")]
    private static partial Regex DateInName();

    [GeneratedRegex(@"^(?:[-_ T.]| at )?([01]\d|2[0-3])[-_.:]?([0-5]\d)[-_.:]?([0-5]\d)")]
    private static partial Regex TimeInName();

    /// <summary>
    /// A date (and time, when present) written in a file name: "20220909_145141.mp4", "IMG-20220909-WA0001.jpg",
    /// "Screenshot 2022-09-09 at 14.51.41.png". Null when there is none.
    /// </summary>
    public static DateTime? DateFromFileName(string name)
    {
        int dot = name.LastIndexOf('.');
        string baseName = dot > 0 ? name[..dot] : name;
        foreach (Match match in DateInName().Matches(baseName))
        {
            string rest = baseName[(match.Index + match.Length)..];
            var clock = TimeInName().Match(rest);
            // "2019123456": eight digits that merely look like a date inside a longer number.
            if (!clock.Success && rest.Length > 0 && char.IsAsciiDigit(rest[0])) continue;
            try
            {
                int year = int.Parse(match.Groups[1].Value), month = int.Parse(match.Groups[3].Value), day = int.Parse(match.Groups[4].Value);
                var date = clock.Success
                    ? new DateTime(year, month, day, int.Parse(clock.Groups[1].Value), int.Parse(clock.Groups[2].Value), int.Parse(clock.Groups[3].Value))
                    : new DateTime(year, month, day, 12, 0, 0);
                if (date > DateTime.Now.AddDays(1)) continue;
                return date;
            }
            catch (ArgumentOutOfRangeException)
            {
            }
        }
        return null;
    }

    public static void ReadMetadata(PhotoItem item, ScanCache? cache = null)
    {
        DateTime fileDate = item.Date;   // the earlier of the file system's creation and modification dates
        if (!item.CloudOnly)
        {
            var meta = cache?.MetadataFor(item);
            if (meta == null)
            {
                meta = MetadataReader.Read(item.Path, item.Video);
                cache?.Remember(item, meta, null);
            }
            item.PixelWidth = meta.Width;
            item.PixelHeight = meta.Height;
            item.Duration = meta.Duration;
            if (meta.Latitude is { } latitude && meta.Longitude is { } longitude)
            {
                item.Latitude = latitude;
                item.Longitude = longitude;
                item.HasLocation = true;
            }
            if (meta.Date is { } date)
            {
                item.Date = date;
                item.DateSource = DateSource.Exif;
            }
        }
        // A file can't have been shot after it was created. Re-encoding, rotating or exporting a video stamps the
        // container with the time of the export while the file often keeps its original creation date — so an embedded
        // date more than a day later than the file's own is an editing date, and the file date is closer.
        if (item.DateSource == DateSource.Exif && item.Date - fileDate > TimeSpan.FromDays(1) && fileDate > Year1990)
        {
            item.Date = fileDate;
            item.DateSource = DateSource.File;
        }
        // Cameras and messengers put the capture time into the name, and it survives what the other dates don't.
        if (DateFromFileName(item.Name) is { } nameDate
            && (item.DateSource == DateSource.File || item.Date - nameDate > TimeSpan.FromDays(1)))
        {
            item.Date = nameDate;
            item.DateSource = DateSource.Name;
        }
    }

    // --- Numbered series --------------------------------------------------------------------------------------------

    /// <summary>Splits "IMG_0668" into the series "img_" and the counter 668; false for names not ending in a number.</summary>
    static bool SeriesOfName(string name, out string series, out long counter)
    {
        int dot = name.LastIndexOf('.');
        string baseName = dot > 0 ? name[..dot] : name;
        int end = baseName.Length, start = end;
        while (start > 0 && char.IsAsciiDigit(baseName[start - 1])) start--;
        series = baseName[..start].ToLowerInvariant();
        counter = 0;
        if (start == end || end - start > 9) return false;
        counter = long.Parse(baseName[start..]);
        return true;
    }

    static bool HasOwnDate(PhotoItem item) => item.DateSource is DateSource.Exif or DateSource.Name or DateSource.Takeout;

    /// <summary>
    /// Gives files that have no date of their own the date of their neighbours — but only when that is safe: the file
    /// sits in a numbered camera series (IMG_0667, IMG_0668, IMG_0669) in the same folder, between two files whose
    /// dates are known from their metadata or name, and those two were shot within three days of each other.
    /// </summary>
    public static void DateFromNeighbors(IEnumerable<PhotoItem> items)
    {
        var groups = new Dictionary<(string, string), List<(long Counter, PhotoItem Item)>>();
        foreach (var item in items)
        {
            if (!SeriesOfName(item.Name, out var series, out var counter)) continue;
            var key = (item.CurrentFolder, series);
            if (!groups.TryGetValue(key, out var group)) groups[key] = group = [];
            group.Add((counter, item));
        }
        foreach (var group in groups.Values)
        {
            if (group.Count < 3) continue;
            group.Sort((a, b) => a.Counter.CompareTo(b.Counter));
            for (int index = 0; index < group.Count; index++)
            {
                var (counter, item) = group[index];
                if (item.DateSource != DateSource.File) continue;
                (long Counter, PhotoItem Item)? before = null, after = null;
                for (int i = index - 1; i >= 0 && before == null; i--) if (HasOwnDate(group[i].Item)) before = group[i];
                for (int i = index + 1; i < group.Count && after == null; i++) if (HasOwnDate(group[i].Item)) after = group[i];
                if (before is not { } b || after is not { } a || b.Counter >= counter || a.Counter <= counter) continue;
                TimeSpan span = a.Item.Date - b.Item.Date;
                if (span < TimeSpan.Zero) continue;
                if (item.Date >= b.Item.Date && item.Date <= a.Item.Date) continue;
                if (span > TimeSpan.FromDays(3))
                {
                    // Too far apart to guess the day, but when both are from the same month, so is everything between.
                    if (b.Item.Date.Year != a.Item.Date.Year || b.Item.Date.Month != a.Item.Date.Month) continue;
                    item.Date = new DateTime(b.Item.Date.Year, b.Item.Date.Month, 1, 12, 0, 0);
                    item.DateSource = DateSource.NeighborsMonth;
                    continue;
                }
                double position = (double)(counter - b.Counter) / (a.Counter - b.Counter);
                item.Date = b.Item.Date + span * position;
                item.DateSource = DateSource.Neighbors;
            }
        }
    }

    // --- Google Takeout ---------------------------------------------------------------------------------------------

    [GeneratedRegex(@"\((\d+)\)\.json$", RegexOptions.IgnoreCase)]
    private static partial Regex CopyNumber();

    static string PathKey(string path) => path.ToLowerInvariant().Normalize(NormalizationForm.FormC);

    /// <summary>
    /// Google Takeout writes a .json next to every photo with the moment Google Photos knew it was taken
    /// ("photoTakenTime"). Its name is the photo's, more or less, so files are matched by the "title" inside.
    /// </summary>
    public static void DateFromTakeoutSidecars(IEnumerable<PhotoItem> items, List<string> sidecars)
    {
        if (sidecars.Count == 0) return;
        var dates = new Dictionary<string, DateTime>();
        var places = new Dictionary<string, (double, double)>();
        foreach (string path in sidecars)
        {
            try
            {
                if (new FileInfo(path).Length > 1_000_000) continue;
                using var json = JsonDocument.Parse(File.ReadAllBytes(path));
                var root = json.RootElement;
                if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("title", out var titleElement)
                    || titleElement.ValueKind != JsonValueKind.String) continue;
                double timestamp = 0, latitude = 0, longitude = 0;
                if (root.TryGetProperty("photoTakenTime", out var taken) && taken.ValueKind == JsonValueKind.Object
                    && taken.TryGetProperty("timestamp", out var stamp))
                {
                    timestamp = stamp.ValueKind == JsonValueKind.String
                        ? double.TryParse(stamp.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var t) ? t : 0
                        : stamp.ValueKind == JsonValueKind.Number ? stamp.GetDouble() : 0;
                }
                if (root.TryGetProperty("geoData", out var geo) && geo.ValueKind == JsonValueKind.Object)
                {
                    if (geo.TryGetProperty("latitude", out var la) && la.ValueKind == JsonValueKind.Number) latitude = la.GetDouble();
                    if (geo.TryGetProperty("longitude", out var lo) && lo.ValueKind == JsonValueKind.Number) longitude = lo.GetDouble();
                }
                bool hasPlace = (latitude != 0 || longitude != 0) && Math.Abs(latitude) <= 90 && Math.Abs(longitude) <= 180;
                if (timestamp < 631152000 && !hasPlace) continue;
                string title = titleElement.GetString()!;
                var match = CopyNumber().Match(System.IO.Path.GetFileName(path));
                if (match.Success)
                {
                    int dot = title.LastIndexOf('.');
                    title = dot > 0 ? $"{title[..dot]}({match.Groups[1].Value}){title[dot..]}" : $"{title}({match.Groups[1].Value})";
                }
                string key = PathKey(System.IO.Path.Combine(System.IO.Path.GetDirectoryName(path)!, title));
                if (timestamp >= 631152000) dates[key] = DateTimeOffset.FromUnixTimeSeconds((long)timestamp).LocalDateTime;
                if (hasPlace) places[key] = (latitude, longitude);
            }
            catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException or ArgumentException)
            {
            }
        }
        foreach (var item in items)
        {
            string key = PathKey(item.Path);
            if (places.TryGetValue(key, out var place) && !item.HasLocation)
            {
                (item.Latitude, item.Longitude) = place;
                item.HasLocation = true;
            }
            if (item.DateSource == DateSource.Exif) continue;   // the camera's own record is more exact
            if (dates.TryGetValue(key, out var date))
            {
                item.Date = date;
                item.DateSource = DateSource.Takeout;
            }
        }
    }

    // --- Phases -----------------------------------------------------------------------------------------------------

    public static string? MediaKind(string name)
    {
        string extension = MetadataReader.Extension(name);
        if (MetadataReader.ImageExtensions.Contains(extension)) return "image";
        if (MetadataReader.VideoExtensions.Contains(extension)) return "video";
        return null;
    }

    List<PhotoItem> Enumerate(Action<ScanPhase, int, int>? progress, CancellationToken token)
    {
        var items = new List<PhotoItem>();
        _sidecars = [];
        var stack = new Stack<string>();
        stack.Push(Root);
        var options = new EnumerationOptions { IgnoreInaccessible = true, AttributesToSkip = 0, RecurseSubdirectories = false };
        while (stack.Count > 0 && !token.IsCancellationRequested)
        {
            string directory = stack.Pop();
            IEnumerable<FileSystemInfo> entries;
            try
            {
                entries = new DirectoryInfo(directory).EnumerateFileSystemInfos("*", options).ToList();
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                continue;
            }
            foreach (var entry in entries)
            {
                string name = entry.Name;
                if (name.StartsWith('.')) continue;
                var attributes = entry.Attributes;
                if ((attributes & (FileAttributes.Hidden | FileAttributes.System)) != 0) continue;
                if ((attributes & FileAttributes.Directory) != 0)
                {
                    if ((attributes & FileAttributes.ReparsePoint) == 0 && !SkippedFolders.Contains(name)) stack.Push(entry.FullName);
                    continue;
                }
                if (name.EndsWith(".json", StringComparison.OrdinalIgnoreCase))
                {
                    _sidecars.Add(entry.FullName);
                    continue;
                }
                string? kind = MediaKind(name);
                if (kind == null) continue;
                var file = (FileInfo)entry;
                string relative = System.IO.Path.GetRelativePath(Root, entry.FullName).Replace('\\', '/');
                var item = new PhotoItem(entry.FullName, relative)
                {
                    Video = kind == "video",
                    CloudOnly = (attributes & CloudOnlyAttributes) != 0,
                    FileSize = file.Length,
                };
                // Copying a file resets its creation date but keeps the modification date: the earlier one is the better guess.
                DateTime created = file.CreationTime, modified = file.LastWriteTime;
                item.Date = created < modified ? created : modified;
                item.FileDate = item.Date;
                items.Add(item);
                if (progress != null && items.Count % 50 == 0) progress(ScanPhase.Enumerating, items.Count, 0);
            }
        }
        return items;
    }

    static void ForEach(List<PhotoItem> items, ScanPhase phase, Action<ScanPhase, int, int>? progress, Action<PhotoItem> work,
                        CancellationToken token)
    {
        int total = items.Count, done = 0;
        if (total == 0) return;
        progress?.Invoke(phase, 0, total);
        try
        {
            Parallel.ForEach(items, new ParallelOptions { MaxDegreeOfParallelism = Math.Min(16, Environment.ProcessorCount * 2), CancellationToken = token },
                item =>
                {
                    try { work(item); }
                    catch (Exception) { /* one unreadable file must not stop the scan */ }
                    int finished = Interlocked.Increment(ref done);
                    if (progress != null && (finished % 20 == 0 || finished == total)) progress(phase, finished, total);
                });
        }
        catch (OperationCanceledException)
        {
        }
    }

    static string? HashFile(string path, CancellationToken token)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 20);
            using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            byte[] buffer = new byte[1 << 20];
            int read;
            while ((read = stream.Read(buffer)) > 0)
            {
                sha.AppendData(buffer, 0, read);
                if (token.IsCancellationRequested) return null;
            }
            return Convert.ToHexString(sha.GetHashAndReset());
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    void FindDuplicates(List<PhotoItem> items, ScanCache cache, Action<ScanPhase, int, int>? progress, CancellationToken token)
    {
        // Only files that share their size with another file can be identical, so only those get hashed.
        var candidates = items.Where(i => i.FileSize > 0 && !i.CloudOnly).GroupBy(i => i.FileSize)
                              .Where(g => g.Count() > 1).SelectMany(g => g).ToList();
        ForEach(candidates, ScanPhase.Duplicates, progress, item =>
        {
            item.ContentHash = cache.HashFor(item);
            if (item.ContentHash != null) return;
            item.ContentHash = HashFile(item.Path, token);
            if (item.ContentHash != null) cache.Remember(item, null, item.ContentHash);
        }, token);
        if (token.IsCancellationRequested) return;
        foreach (var bucket in candidates.Where(i => i.ContentHash != null).GroupBy(i => (i.FileSize, i.ContentHash)))
        {
            var set = bucket.ToList();
            if (set.Count < 2) continue;
            set.Sort(CompareAsOriginal);
            var original = set[0];
            original.Duplicates = set.Skip(1).ToList();
            foreach (var copy in original.Duplicates) copy.DuplicateOf = original;
        }
    }

    /// <summary>The file most likely to be the original first: "IMG_1.jpg" beats "IMG_1 - копия.jpg" and "Backup/IMG_1.jpg".</summary>
    int CompareAsOriginal(PhotoItem a, PhotoItem b)
    {
        bool aLow = DeprioritizedFolders.Contains(a.RelativePath.Split('/')[0]), bLow = DeprioritizedFolders.Contains(b.RelativePath.Split('/')[0]);
        if (aLow != bLow) return aLow ? 1 : -1;
        int byDate = a.Date.CompareTo(b.Date);
        if (byDate != 0) return byDate;
        if (a.RelativePath.Length != b.RelativePath.Length) return a.RelativePath.Length.CompareTo(b.RelativePath.Length);
        return NaturalComparer.Instance.Compare(a.RelativePath, b.RelativePath);
    }
}
