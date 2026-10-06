using System.Text.RegularExpressions;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.Core;

public enum Scheme { Year = 0, YearMonth = 1, YearMonthDay = 2 }       // 2024/ · 2024/2024-03/ · 2024/2024-03/2024-03-15/
public enum YearStyle { Number = 0, Word = 1 }                          // 2024 · 2024 год
public enum MonthStyle { Iso = 0, IsoName = 1, NumberName = 2, NameYear = 3 }   // 2024-03 · 2024-03 Март · 03 Март · Март 2024
public enum DayStyle { Iso = 0, Number = 1, DayMonth = 2 }              // 2024-03-15 · 15 · 15 марта
public enum GroupKind { Date, Tiny, Duplicates, Undated }

/// <summary>One destination folder and the files that will end up in it.</summary>
public sealed class Group(GroupKind kind, string folder)
{
    public GroupKind Kind { get; } = kind;
    /// <summary>Relative to the root, with "/", after any custom name was applied.</summary>
    public string Folder { get; } = folder;
    /// <summary>The generated names it stands for (several when folders were renamed to the same name).</summary>
    public List<string> GeneratedFolders { get; } = [];
    public List<PhotoItem> Items { get; } = [];
}

/// <summary>Decides which folder every file goes to. Call Rebuild() after changing any option.</summary>
public sealed partial class Plan
{
    readonly Dictionary<string, string> _customNames = [];   // generated folder → custom folder
    string _duplicatesFolderName = DefaultDuplicatesFolderName;
    string _tinyFolderName = DefaultTinyFolderName;

    public Plan(string root, IEnumerable<PhotoItem> items)
    {
        Root = root;
        Items = items.ToList();
        DuplicateItems = Items.Where(i => i.IsDuplicate).ToList();
    }

    public static string DefaultDuplicatesFolderName => L("Дубликаты");
    public static string DefaultTinyFolderName => L("Миниатюры");
    public static string UndatedFolderName => L("Без даты");

    public string Root { get; }
    public List<PhotoItem> Items { get; private set; }
    public List<PhotoItem> DuplicateItems { get; private set; }
    public List<PhotoItem> TinyItems => Items.Where(i => i.Tiny).ToList();

    public Scheme Scheme = Scheme.Year;
    public YearStyle YearStyle = YearStyle.Number;
    public MonthStyle MonthStyle = MonthStyle.Iso;
    public DayStyle DayStyle = DayStyle.Iso;
    /// <summary>2024/2024-03/…; false: only the deepest level, directly in the root.</summary>
    public bool Nested = true;
    public bool SeparateDuplicates = true;
    public bool SeparateTiny = true;

    public List<Group> Groups { get; private set; } = [];
    /// <summary>Files that are not yet in their destination folder.</summary>
    public List<PhotoItem> PendingItems { get; private set; } = [];

    // --- Names --------------------------------------------------------------------------------------------------------

    [GeneratedRegex(@"[<>:""|?*\x00-\x1f]")]
    private static partial Regex Forbidden();

    [GeneratedRegex(@"^(con|prn|aux|nul|com\d|lpt\d)(\..*)?$", RegexOptions.IgnoreCase)]
    private static partial Regex Reserved();

    /// <summary>
    /// Cleans up a user-typed folder path: trims, drops empty / "." / ".." components and characters Windows does not
    /// allow in names. Null when nothing usable is left.
    /// </summary>
    public static string? SanitizedFolderPath(string? path)
    {
        var components = new List<string>();
        foreach (string raw in (path ?? "").Split('/', '\\'))
        {
            string component = Forbidden().Replace(raw, "-").Trim();
            component = component.TrimStart('.');      // a leading dot would hide the folder from the next scan
            component = component.TrimEnd('.', ' ');   // Windows drops trailing dots and spaces itself
            if (Reserved().IsMatch(component)) component = "_" + component;
            if (component.Length > 0) components.Add(component);
        }
        return components.Count > 0 ? string.Join("/", components) : null;
    }

    static string? FirstComponent(string? path) => SanitizedFolderPath(path)?.Split('/')[0];

    public static string SavedDuplicatesFolderName
    {
        get
        {
            string? saved = Settings.Shared.GetString("duplicatesFolderName");
            if (saved is "Дубликаты" or "Duplicates") saved = null;
            return FirstComponent(saved) ?? DefaultDuplicatesFolderName;
        }
    }

    /// <summary>An unusable name restores the default one.</summary>
    public string DuplicatesFolderName
    {
        get => _duplicatesFolderName;
        set => _duplicatesFolderName = FirstComponent(value) ?? DefaultDuplicatesFolderName;
    }

    public string TinyFolderName
    {
        get => _tinyFolderName;
        set => _tinyFolderName = FirstComponent(value) ?? DefaultTinyFolderName;
    }

    /// <summary>Renames one destination folder; null or an empty name restores the generated one.</summary>
    public void SetCustomName(string? name, Group group)
    {
        string? sanitized = string.IsNullOrEmpty(name) ? null : SanitizedFolderPath(name);
        switch (group.Kind)
        {
            case GroupKind.Duplicates: DuplicatesFolderName = sanitized ?? ""; break;
            case GroupKind.Tiny: TinyFolderName = sanitized ?? ""; break;
            default:
                foreach (string generated in group.GeneratedFolders)
                {
                    if (sanitized == null || sanitized == generated) _customNames.Remove(generated);
                    else _customNames[generated] = sanitized;
                }
                break;
        }
    }

    public bool HasCustomNames => _customNames.Count > 0;
    public void RemoveCustomNames() => _customNames.Clear();

    static T Clamp<T>(int value) where T : struct, Enum
    {
        var values = Enum.GetValues<T>().Select(v => Convert.ToInt32(v)).ToArray();
        return (T)Enum.ToObject(typeof(T), Math.Min(Math.Max(value, values.Min()), values.Max()));
    }

    public void LoadOptions()
    {
        var s = Settings.Shared;
        Scheme = Clamp<Scheme>(s.Get("scheme", 0));
        YearStyle = Clamp<YearStyle>(s.Get("yearStyle", 0));
        MonthStyle = Clamp<MonthStyle>(s.Get("monthStyle", 0));
        DayStyle = Clamp<DayStyle>(s.Get("dayStyle", 0));
        Nested = s.Get("nested", true);
        SeparateDuplicates = s.Get("separateDuplicates", true);
        SeparateTiny = s.Get("separateTiny", true);
        // A saved name that is just the default of another interface language is not a choice the user made.
        string? duplicates = s.GetString("duplicatesFolderName"), tiny = s.GetString("tinyFolderName");
        DuplicatesFolderName = duplicates is "Дубликаты" or "Duplicates" ? "" : duplicates ?? "";
        TinyFolderName = tiny is "Миниатюры" or "Thumbnails" ? "" : tiny ?? "";
    }

    public void SaveOptions()
    {
        var s = Settings.Shared;
        s.Set("scheme", (int)Scheme);
        s.Set("yearStyle", (int)YearStyle);
        s.Set("monthStyle", (int)MonthStyle);
        s.Set("dayStyle", (int)DayStyle);
        s.Set("nested", Nested);
        s.Set("separateDuplicates", SeparateDuplicates);
        s.Set("separateTiny", SeparateTiny);
        s.Set("duplicatesFolderName", DuplicatesFolderName);
        s.Set("tinyFolderName", TinyFolderName);
    }

    public string DateFolder(PhotoItem item)
    {
        string[] months = [L("Январь"), L("Февраль"), L("Март"), L("Апрель"), L("Май"), L("Июнь"),
                           L("Июль"), L("Август"), L("Сентябрь"), L("Октябрь"), L("Ноябрь"), L("Декабрь")];
        string[] genitive = [L("января"), L("февраля"), L("марта"), L("апреля"), L("мая"), L("июня"),
                             L("июля"), L("августа"), L("сентября"), L("октября"), L("ноября"), L("декабря")];
        int year = item.Date.Year, month = item.Date.Month, day = item.Date.Day;
        string name = months[month - 1];
        var levels = new List<string> { YearStyle == YearStyle.Word ? F("%04ld год", year.ToString("0000")) : $"{year:0000}" };
        // A date known only to the year (or month) goes to that level, not to the January (or the 1st) folder.
        var scheme = Scheme;
        if (item.Precision == Precision.Year) scheme = Scheme.Year;
        else if (item.Precision == Precision.Month && scheme > Scheme.YearMonth) scheme = Scheme.YearMonth;
        if (scheme >= Scheme.YearMonth)
        {
            levels.Add(MonthStyle switch
            {
                MonthStyle.Iso => $"{year:0000}-{month:00}",
                MonthStyle.IsoName => $"{year:0000}-{month:00} {name}",
                MonthStyle.NumberName => $"{month:00} {name}",
                _ => $"{name} {year:0000}",
            });
        }
        if (scheme >= Scheme.YearMonthDay)
        {
            levels.Add(DayStyle switch
            {
                DayStyle.Iso => $"{year:0000}-{month:00}-{day:00}",
                DayStyle.Number => $"{day:00}",
                _ => $"{day:00} {genitive[month - 1]}",
            });
        }
        return Nested ? string.Join("/", levels) : levels[^1];
    }

    // --- Result -------------------------------------------------------------------------------------------------------

    /// <summary>
    /// Files that are gone (to the Recycle Bin, moved elsewhere): they leave the plan, and exact-duplicate sets are
    /// re-formed from what is left (a remaining copy becomes the original). Call Rebuild() afterwards.
    /// </summary>
    public void RemoveItems(ICollection<PhotoItem> removed)
    {
        if (removed.Count == 0) return;
        var gone = new HashSet<PhotoItem>(removed);
        Items = Items.Where(i => !gone.Contains(i)).ToList();
        var originals = new HashSet<PhotoItem>();
        foreach (var item in removed)
        {
            if (item.Duplicates is { Count: > 0 }) originals.Add(item);
            if (item.DuplicateOf != null) originals.Add(item.DuplicateOf);
        }
        foreach (var original in originals)
        {
            var members = new List<PhotoItem> { original };
            members.AddRange(original.Duplicates ?? []);
            members = members.Where(m => !gone.Contains(m)).ToList();
            foreach (var member in members)
            {
                member.DuplicateOf = null;
                member.Duplicates = null;
            }
            if (members.Count < 2) continue;
            members[0].Duplicates = members.Skip(1).ToList();
            foreach (var copy in members[0].Duplicates!) copy.DuplicateOf = members[0];
        }
        DuplicateItems = Items.Where(i => i.IsDuplicate).ToList();
    }

    /// <summary>Files the app moved: (from, to) absolute paths. Call Rebuild() afterwards.</summary>
    public void ItemsMoved(IEnumerable<(string From, string To)> moves)
    {
        var byPath = Items.GroupBy(i => i.Path, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
        string rootPrefix = Root.TrimEnd('\\') + "\\";
        foreach (var (from, to) in moves)
        {
            if (!byPath.TryGetValue(from, out var item) || !to.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase)) continue;
            item.MovedTo(to, Path.GetRelativePath(Root, to).Replace('\\', '/'));
        }
    }

    public void SortItemsByDate() => Items.Sort(PhotoItem.ByDate);

    public void Rebuild()
    {
        // `Items` is sorted by date, so date groups come out in chronological order whatever their names are.
        var dateGroups = new List<Group>();
        var byFolder = new Dictionary<string, Group>();
        var tiny = new Group(GroupKind.Tiny, TinyFolderName);
        var duplicates = new Group(GroupKind.Duplicates, DuplicatesFolderName);
        string undatedName = UndatedFolderName;
        var undated = new Group(GroupKind.Undated, _customNames.GetValueOrDefault(undatedName, undatedName));
        undated.GeneratedFolders.Add(undatedName);
        tiny.GeneratedFolders.Add(tiny.Folder);
        duplicates.GeneratedFolders.Add(duplicates.Folder);
        var generatedFolders = new HashSet<string>();
        var pending = new List<PhotoItem>();
        foreach (var item in Items)
        {
            Group group;
            // Thumbnails first: an exact copy of a thumbnail is still a thumbnail.
            if (SeparateTiny && item.Tiny) group = tiny;
            else if (SeparateDuplicates && (item.IsDuplicate || item.BetterCopy != null)) group = duplicates;
            else if (item.Undated) group = undated;
            else
            {
                string generated = DateFolder(item);
                string folder = _customNames.GetValueOrDefault(generated, generated);
                if (!byFolder.TryGetValue(folder, out group!))
                {
                    group = byFolder[folder] = new Group(GroupKind.Date, folder);
                    dateGroups.Add(group);
                }
                if (generatedFolders.Add(generated)) group.GeneratedFolders.Add(generated);
            }
            group.Items.Add(item);
            item.DestinationFolder = group.Folder;
            if (item.NeedsMove) pending.Add(item);
        }
        // Custom names only make sense for the naming scheme they were typed for.
        foreach (string generated in _customNames.Keys.ToList())
        {
            if (!generatedFolders.Contains(generated) && generated != undatedName) _customNames.Remove(generated);
        }
        foreach (var group in new[] { undated, tiny, duplicates }) if (group.Items.Count > 0) dateGroups.Add(group);
        Groups = dateGroups;
        PendingItems = pending;
    }
}
