using System.Text.RegularExpressions;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.Core;

public enum SuggestionKind
{
    Neighbors = 0,   // the files next to it in its folder (by name) are from the same day / month / year
    FileName = 1,    // a year (or year and month) written in the file name
    FolderName = 2,  // a year (or year and month) in the name of a folder it sits in
    FileDate = 3,    // the file system's date — often the day the file was copied, so never applied on its own
}

/// <summary>A guess at the date of an undated file, for the user to accept or not.</summary>
public sealed class Suggestion
{
    public Suggestion(SuggestionKind kind, DateTime date, Precision precision, string reason)
    {
        Kind = kind;
        Precision = precision;
        Date = precision == Precision.Day && kind == SuggestionKind.FileDate ? date : Normalized(date, precision);
        Reason = reason;
        DateText = PhotoItem.DateText(Date, precision);
    }

    public SuggestionKind Kind { get; }
    public DateTime Date { get; }
    public Precision Precision { get; }
    /// <summary>"из названия папки «Photos from 2019»".</summary>
    public string Reason { get; }
    /// <summary>"2019" / "май 2019 г." / "12 мая 2019 г.".</summary>
    public string DateText { get; }

    /// <summary>Noon of the first day of the year / month, or of the day itself: the date stored for a less precise date.</summary>
    public static DateTime Normalized(DateTime date, Precision precision) =>
        new(date.Year, precision >= Precision.Year ? 1 : date.Month, precision >= Precision.Month ? 1 : date.Day, 12, 0, 0);

    public bool SameAs(Suggestion other) => other.Precision == Precision && Normalized(other.Date, Precision) == Normalized(Date, Precision);
}

/// <summary>Works out suggestions for the undated files of a library. Built once per library.</summary>
public sealed partial class Suggester
{
    readonly Dictionary<string, List<PhotoItem>> _folders = [];
    readonly Dictionary<PhotoItem, int> _index = [];
    readonly Dictionary<PhotoItem, Suggestion?> _best = [];
    // Per folder: for each file, the nearest dated file of its numbered series before and after it. Worked out in one
    // pass each way the first time the folder is asked about, instead of walking outward from every undated file.
    readonly Dictionary<string, (PhotoItem? Before, PhotoItem? After)[]> _nearest = [];

    public Suggester(IEnumerable<PhotoItem> items)
    {
        foreach (var item in items)
        {
            if (!_folders.TryGetValue(item.CurrentFolder, out var list)) _folders[item.CurrentFolder] = list = [];
            list.Add(item);
        }
        foreach (var list in _folders.Values)
        {
            list.Sort((a, b) => NaturalComparer.Instance.Compare(a.Name, b.Name));
            for (int i = 0; i < list.Count; i++) _index[list[i]] = i;
        }
    }

    [GeneratedRegex(@"(?<!\d)(19[89]\d|20[0-4]\d)(?:[-_.](0[1-9]|1[0-2]))?(?!\d)")]
    private static partial Regex YearPattern();

    /// <summary>"2019", "2019-05", "2019_05" as (year, month or 0) in a name; null when there is none or more than one.</summary>
    public static (int Year, int Month)? YearInName(string name)
    {
        var matches = YearPattern().Matches(name);
        if (matches.Count != 1) return null;
        int year = int.Parse(matches[0].Groups[1].Value);
        int month = matches[0].Groups[2].Success ? int.Parse(matches[0].Groups[2].Value) : 0;
        if (year > DateTime.Now.Year) return null;
        return (year, month);
    }

    static Suggestion FromComponents((int Year, int Month) found, SuggestionKind kind, string reason) =>
        new(kind, new DateTime(found.Year, Math.Max(found.Month, 1), 1, 12, 0, 0), found.Month > 0 ? Precision.Month : Precision.Year, reason);

    /// <summary>"img_" for "IMG_1711.JPG": the name without its trailing number; null for names that don't end in one.</summary>
    static string? SeriesPrefix(PhotoItem item)
    {
        string name = item.Name;
        int dot = name.LastIndexOf('.');
        string baseName = dot > 0 ? name[..dot] : name;
        int end = baseName.Length;
        while (end > 0 && char.IsAsciiDigit(baseName[end - 1])) end--;
        return end == baseName.Length || end == 0 ? null : baseName[..end].ToLowerInvariant();
    }

    /// <summary>
    /// The nearest dated files before and after `item` in its folder (by name), from the same numbered series: what
    /// they have in common. Names that are not numbered (hashes, ids) say nothing about order.
    /// </summary>
    Suggestion? Neighbours(PhotoItem item)
    {
        if (!_index.TryGetValue(item, out int index) || SeriesPrefix(item) == null) return null;
        var (before, after) = NearestIn(item.CurrentFolder)[index];
        if (before == null || after == null) return null;
        DateTime a = before.Date, b = after.Date;
        if (a.Year != b.Year) return null;
        var precision = a.Month != b.Month ? Precision.Year : a.Day != b.Day ? Precision.Month : Precision.Day;
        // A file can't be more precise than the least precise of its two neighbours.
        precision = (Precision)Math.Max((int)precision, Math.Max((int)before.Precision, (int)after.Precision));
        return new Suggestion(SuggestionKind.Neighbors, before.Date, precision, F("как у соседних файлов %@ и %@", before.Name, after.Name));
    }

    (PhotoItem? Before, PhotoItem? After)[] NearestIn(string folder)
    {
        if (_nearest.TryGetValue(folder, out var nearest)) return nearest;
        var files = _folders[folder];
        var series = files.Select(SeriesPrefix).ToArray();
        nearest = new (PhotoItem?, PhotoItem?)[files.Count];
        var last = new Dictionary<string, PhotoItem>();
        for (int i = 0; i < files.Count; i++)
        {
            if (series[i] is not { } prefix) continue;
            nearest[i].Item1 = last.GetValueOrDefault(prefix);
            if (!files[i].Undated) last[prefix] = files[i];
        }
        last.Clear();
        for (int i = files.Count - 1; i >= 0; i--)
        {
            if (series[i] is not { } prefix) continue;
            nearest[i].Item2 = last.GetValueOrDefault(prefix);
            if (!files[i].Undated) last[prefix] = files[i];
        }
        return _nearest[folder] = nearest;
    }

    /// <summary>Best first: neighbours, then the file name, then the folder name, then the file date. Empty for a dated file.</summary>
    public List<Suggestion> SuggestionsFor(PhotoItem item)
    {
        var found = new List<Suggestion>();
        if (!item.Undated) return found;
        void Add(Suggestion? suggestion)
        {
            if (suggestion != null && !found.Any(s => s.SameAs(suggestion))) found.Add(suggestion);
        }
        var folders = item.CurrentFolder.Split('/', StringSplitOptions.RemoveEmptyEntries);
        // A folder named after a year is the user's own sorting: neighbours that disagree with it are not suggested.
        int folderYear = 0;
        for (int i = folders.Length - 1; i >= 0; i--)
        {
            if (YearInName(folders[i]) is { } inFolder) { folderYear = inFolder.Year; break; }
        }
        var neighbours = Neighbours(item);
        if (neighbours != null && (folderYear == 0 || neighbours.Date.Year == folderYear)) Add(neighbours);
        int dot = item.Name.LastIndexOf('.');
        if (YearInName(dot > 0 ? item.Name[..dot] : item.Name) is { } inName)
        {
            Add(FromComponents(inName, SuggestionKind.FileName, F("из имени файла «%@»", item.Name)));
        }
        for (int i = folders.Length - 1; i >= 0; i--)
        {
            if (YearInName(folders[i]) is not { } inFolder) continue;
            Add(FromComponents(inFolder, SuggestionKind.FolderName, F("из названия папки «%@»", folders[i])));
            break;
        }
        if (item.FileDate is { } fileDate)
        {
            Add(new Suggestion(SuggestionKind.FileDate, fileDate, Precision.Day, L("дата файла — часто это день, когда файл скопировали")));
        }
        return found;
    }

    /// <summary>The suggestion "Accept suggestions" would apply: the first one that is not the file date, or null.</summary>
    public Suggestion? Best(PhotoItem item)
    {
        if (!_best.TryGetValue(item, out var best))
        {
            best = SuggestionsFor(item).FirstOrDefault(s => s.Kind != SuggestionKind.FileDate);
            _best[item] = best;
        }
        return best;
    }
}
