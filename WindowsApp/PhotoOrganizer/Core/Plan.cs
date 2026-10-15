using System.Text.RegularExpressions;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.Core;

public enum Scheme { Year = 0, YearMonth = 1, YearMonthDay = 2 }       // 2024/ · 2024/2024-03/ · 2024/2024-03/2024-03-15/
/// <summary>What the library is organized by: the date (2024/…), or a first level of folders by type, person or format.</summary>
public enum Arrangement { Date = 0, Type = 1, Person = 2, Format = 3 }
/// <summary>How "Разложить…" of a section (screenshots, a person…) arranges its files inside the section's folder.</summary>
public enum FolderLayout { Flat = 0, Year = 1, YearMonth = 2, YearMonthDay = 3 }
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
    string _screenshotsFolderName = DefaultScreenshotsFolderName;

    public Plan(string root, IEnumerable<PhotoItem> items, IEnumerable<string>? sources = null)
    {
        Root = root;
        Sources = (sources ?? [root]).ToList();
        Items = items.ToList();
        DuplicateItems = Items.Where(i => i.IsDuplicate).ToList();
        KeptFolders = LoadKeptFolders(root);
    }

    static HashSet<string> LoadKeptFolders(string root) =>
        new((Settings.Shared.GetObject<Dictionary<string, List<string>>>("keptFolders")?.GetValueOrDefault(root.ToLowerInvariant()) ?? [])
            .Select(f => f.Normalize()), StringComparer.OrdinalIgnoreCase);

    /// <summary>The library's folders (several when more than one was opened).</summary>
    public List<string> Sources { get; }

    /// <summary>
    /// Organizes into another folder than the first one of the library: files from all the library's folders are
    /// moved there. Call Rebuild() afterwards.
    /// </summary>
    public void SetDestination(string root)
    {
        Root = Scanner.NormalizedRoot(root);
        KeptFolders = LoadKeptFolders(Root);
    }

    /// <summary>
    /// Other folders are put together into one of the library's folders (the destination is one of Sources): what is
    /// already in the destination stays as it is — not moved, not removed, and the original of any copy of it; from
    /// the other folders, the files it does not have yet are organized into it and the copies of what it has go to the
    /// Recycle Bin.
    /// </summary>
    public bool Merging => Sources.Count > 1 && Sources.Any(s => string.Equals(s, Root, StringComparison.OrdinalIgnoreCase));

    /// <summary>While merging: a file that was already in the destination folder.</summary>
    public bool InDestination(PhotoItem item) => Merging && string.Equals(item.Root, Root, StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// While merging, the original of each set of exact copies is a file of the destination when it has one: the copies
    /// brought from the other folders are the ones to go, whatever their names and dates.
    /// </summary>
    void PreferOriginalsInDestination()
    {
        if (!Merging) return;
        bool changed = false;
        foreach (var original in Items)
        {
            if (original.Duplicates is not { Count: > 0 } || InDestination(original)) continue;
            int index = original.Duplicates.FindIndex(InDestination);
            if (index < 0) continue;
            var keeper = original.Duplicates[index];
            var copies = original.Duplicates.ToList();
            copies[index] = original;
            original.Duplicates = null;
            keeper.DuplicateOf = null;
            keeper.Duplicates = copies;
            foreach (var copy in copies) copy.DuplicateOf = keeper;
            changed = true;
        }
        if (changed) DuplicateItems = Items.Where(i => i.IsDuplicate).ToList();
    }

    /// <summary>
    /// Top-level folders the user filled by hand ("Скриншоты", a person's name…, see "Разложить…" and "Переместить в
    /// папку…"): their files stay where they are when the library is organized by date. Remembered per library.
    /// </summary>
    public HashSet<string> KeptFolders { get; private set; }

    public void KeepFolder(string folder)
    {
        // Compared in composed form: a folder named on a Mac ("й" decomposed) is the same folder.
        if (FirstComponent(folder)?.Normalize() is not { } top || !KeptFolders.Add(top)) return;
        var all = Settings.Shared.GetObject<Dictionary<string, List<string>>>("keptFolders") ?? [];
        all[Root.ToLowerInvariant()] = KeptFolders.ToList();
        Settings.Shared.Set("keptFolders", all);
    }

    bool InKeptFolder(PhotoItem item) =>
        KeptFolders.Count > 0 && item.CurrentFolder.Length > 0 && string.Equals(item.Root, Root, StringComparison.OrdinalIgnoreCase)
        && KeptFolders.Contains(item.CurrentFolder.Split('/')[0].Normalize());

    /// <summary>The folder a file goes to inside a section's folder: the folder itself, or its date folders below it.</summary>
    public string SectionFolder(PhotoItem item, string folder, FolderLayout layout)
    {
        if (layout == FolderLayout.Flat) return folder;
        if (item.Undated) return $"{folder}/{UndatedFolderName}";
        var (scheme, nested) = (Scheme, Nested);
        try
        {
            Scheme = (Scheme)((int)layout - 1);
            Nested = true;
            return $"{folder}/{DateFolder(item)}";
        }
        finally
        {
            (Scheme, Nested) = (scheme, nested);
        }
    }

    public static string DefaultDuplicatesFolderName => L("Дубликаты");
    public static string DefaultTinyFolderName => L("Миниатюры");
    public static string DefaultScreenshotsFolderName => L("Скриншоты");
    public static string UndatedFolderName => L("Без даты");

    /// <summary>The folder everything is organized into: the library's first folder, or another chosen one.</summary>
    public string Root { get; private set; }
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
    /// <summary>
    /// Duplicates — exact copies and lesser versions of a picture, not thumbnails — go to the Recycle Bin when the files
    /// are moved (when copied, they are not copied): only one file of each picture, the original or the best version,
    /// is organized. Only a copy whose original stays is removed.
    /// </summary>
    public bool RemovesDuplicates = true;
    /// <summary>What Rebuild found to go to the Recycle Bin with RemovesDuplicates and RemovesTiny (empty when the files are copied).</summary>
    public List<PhotoItem> DuplicatesToRemove { get; private set; } = [];
    /// <summary>
    /// Which files are organized: photos, videos, pictures (postcards, memes, drawings, see Pictures) and collages
    /// (what Google Photos made, see MediaTypes.IsGooglePhotosCreation). The kinds turned off stay where they are — e.g.
    /// only the real photos go into the year folders, with or without the videos, or only the videos.
    /// </summary>
    public bool OrganizesPhotos = true, OrganizesVideos = true, OrganizesPictures = true, OrganizesCollages = true;
    public bool SeparateTiny = true;
    /// <summary>Thumbnails go to the Recycle Bin with the duplicates (see DuplicatesToRemove) — only those whose larger version stays.</summary>
    public bool RemovesTiny;
    /// <summary>
    /// The kinds not organized (unticked: pictures, collages…) go to the Recycle Bin instead of staying where they are —
    /// the files of folders kept by "Разложить…" excepted. Off unless asked for.
    /// </summary>
    public bool RemovesUnorganized;
    /// <summary>What Rebuild found to go to the Recycle Bin with RemovesUnorganized (empty when the files are copied).</summary>
    public List<PhotoItem> UnorganizedToRemove { get; private set; } = [];
    /// <summary>Screenshots to a folder of their own (with date folders inside), whatever the rest is organized by.</summary>
    public bool SeparateScreenshots;
    /// <summary>
    /// Where that folder is: false — one folder at the top with the date folders inside (Скриншоты/2024/…); true — one
    /// inside every date folder, next to the photos of that date (2024/Скриншоты/…).
    /// </summary>
    public bool ScreenshotsInEachDate;
    public Arrangement Arrangement = Arrangement.Date;
    /// <summary>Copies the files into the folders instead of moving them; the originals stay where they are.</summary>
    public bool CopiesFiles;
    /// <summary>By type, person or format: date folders inside each of those folders (by the options above), or not.</summary>
    public bool DatesInside = true;
    /// <summary>
    /// For organizing by person: the files in which exactly one named person was recognised, and that person's name.
    /// Set by the window from the people found; files not in it are organized by date.
    /// </summary>
    public Dictionary<PhotoItem, string> PersonNames { get; set; } = [];

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

    public string ScreenshotsFolderName
    {
        get => _screenshotsFolderName;
        set => _screenshotsFolderName = FirstComponent(value) ?? DefaultScreenshotsFolderName;
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
        RemovesDuplicates = s.Get("removesDuplicates", true);
        OrganizesPhotos = s.Get("organizesPhotos", true);
        OrganizesVideos = s.Get("organizesVideos", true);
        // "Без картинок — не трогать" of the earlier pictures choice is pictures left alone.
        OrganizesPictures = s.Get("organizesPictures", s.Get("picturesMode", 0) != 2);
        OrganizesCollages = s.Get("organizesCollages", OrganizesPictures);
        SeparateTiny = s.Get("separateTiny", true);
        RemovesTiny = s.Get("removesTiny", false);
        RemovesUnorganized = s.Get("removesUnorganized", false);
        Arrangement = Clamp<Arrangement>(s.Get("arrangement", 0));
        SeparateScreenshots = s.Get("separateScreenshots", false);
        ScreenshotsInEachDate = s.Get("screenshotsInEachDate", false);
        string? screenshots = s.GetString("screenshotsFolderName");
        ScreenshotsFolderName = screenshots is "Скриншоты" or "Screenshots" ? "" : screenshots ?? "";
        DatesInside = s.Get("datesInside", true);
        CopiesFiles = s.Get("organizeCopiesFiles", false);
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
        s.Set("removesDuplicates", RemovesDuplicates);
        s.Set("organizesPhotos", OrganizesPhotos);
        s.Set("organizesVideos", OrganizesVideos);
        s.Set("organizesPictures", OrganizesPictures);
        s.Set("organizesCollages", OrganizesCollages);
        s.Set("separateTiny", SeparateTiny);
        s.Set("removesTiny", RemovesTiny);
        s.Set("removesUnorganized", RemovesUnorganized);
        s.Set("arrangement", (int)Arrangement);
        s.Set("separateScreenshots", SeparateScreenshots);
        s.Set("screenshotsInEachDate", ScreenshotsInEachDate);
        s.Set("screenshotsFolderName", ScreenshotsFolderName);
        s.Set("datesInside", DatesInside);
        s.Set("organizeCopiesFiles", CopiesFiles);
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
        // Into the destination, or (undone) back into one of the library's folders: the deepest that holds it.
        var roots = Sources.Append(Root).Distinct(StringComparer.OrdinalIgnoreCase).OrderByDescending(r => r.Length).ToList();
        foreach (var (from, to) in moves)
        {
            if (!byPath.TryGetValue(from, out var item)) continue;
            string? root = roots.FirstOrDefault(r => to.StartsWith(r.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase));
            if (root == null) continue;
            item.MovedTo(to, root, Path.GetRelativePath(root, to).Replace('\\', '/'));
        }
    }

    public void SortItemsByDate() => Items.Sort(PhotoItem.ByDate);

    /// <summary>The first-level folder of a file when the library is not organized by date; null for the date folders.</summary>
    string? SectionOf(PhotoItem item) => SeparateScreenshots && Screenshots.IsScreenshot(item) ? ScreenshotsFolderName : Arrangement switch
    {
        Arrangement.Type => MediaTypes.TypeFolder(item),
        Arrangement.Format => MediaTypes.FormatFolder(item),
        Arrangement.Person => PersonNames.TryGetValue(item, out var name) ? SanitizedFolderPath(name)?.Replace('/', '-') : null,
        _ => null,
    };

    /// <summary>Whether the kind of `item` is organized at all (photos, videos, pictures, collages).</summary>
    bool Organizes(PhotoItem item) =>
        MediaTypes.IsGooglePhotosCreation(item) ? OrganizesCollages
        : item.IsPicture ? OrganizesPictures
        : item.Video ? OrganizesVideos : OrganizesPhotos;

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
        var sectionGroups = new List<Group>();
        var pending = new List<PhotoItem>();
        PreferOriginalsInDestination();
        // Duplicates to remove: copies of the kinds organized whose original (or best version) stays — never the last
        // file of a picture. They are left where they are until they go to the Recycle Bin. While merging, nothing
        // already in the destination goes, and a copy brought along of what it has goes whatever its kind.
        var removed = new HashSet<PhotoItem>();
        if (RemovesDuplicates || RemovesTiny)
        {
            var doomed = Items.Where(i => (i.IsDuplicate || i.BetterCopy != null) && !InDestination(i)
                && (Organizes(i) || i.DuplicateOf is { } original && InDestination(original))
                && (i.Tiny ? RemovesTiny : RemovesDuplicates)).ToHashSet();
            foreach (var item in doomed)
            {
                var keeper = item.DuplicateOf ?? item.BetterCopy;
                if (keeper != null && doomed.Contains(keeper)) keeper = keeper.BetterCopy is { } best && !doomed.Contains(best) ? best : null;
                if (keeper != null) removed.Add(item);
            }
        }
        DuplicatesToRemove = CopiesFiles ? [] : Items.Where(removed.Contains).ToList();
        // The kinds not organized, when they are to go too ("Неотмеченное — в Корзину") — not while merging: the
        // destination is kept as it is, and the other folders' files that are not copies of its own stay where they are.
        UnorganizedToRemove = RemovesUnorganized && !CopiesFiles && !Merging
            ? Items.Where(i => !Organizes(i) && !removed.Contains(i) && !InKeptFolder(i)).ToList()
            : [];
        foreach (var item in Items)
        {
            item.DestinationRoot = Root;
            // Left where they are: sorted by hand into a folder of their own, of a kind not to organize, or a duplicate
            // to remove (or, when copying, not to copy) — and, while merging, whatever was in the destination already.
            bool copy = item.IsDuplicate || item.BetterCopy != null;
            if (!Organizes(item) || InKeptFolder(item) || removed.Contains(item) || InDestination(item))
            {
                item.DestinationFolder = item.CurrentFolder;
                continue;
            }
            Group group;
            // Thumbnails first: an exact copy of a thumbnail is still a thumbnail.
            if (SeparateTiny && item.Tiny) group = tiny;
            else if (SeparateDuplicates && copy) group = duplicates;
            else if (SeparateScreenshots && ScreenshotsInEachDate && Screenshots.IsScreenshot(item))
            {
                // A screenshots folder inside the folder of its date (or of the undated files).
                string generated = $"{(item.Undated ? undatedName : DateFolder(item))}/{ScreenshotsFolderName}";
                string folder = _customNames.GetValueOrDefault(generated, generated);
                if (!byFolder.TryGetValue(folder, out group!))
                {
                    group = byFolder[folder] = new Group(GroupKind.Date, folder);
                    dateGroups.Add(group);
                }
                if (generatedFolders.Add(generated)) group.GeneratedFolders.Add(generated);
            }
            else if (SectionOf(item) is { } section)
            {
                // By type, person or format: that folder first, the date folders (or the undated one) inside. The
                // screenshots folder always has its dates.
                bool datesInside = DatesInside || Arrangement == Arrangement.Date;
                string generated = !datesInside ? section : item.Undated ? $"{section}/{undatedName}" : $"{section}/{DateFolder(item)}";
                string folder = _customNames.GetValueOrDefault(generated, generated);
                if (!byFolder.TryGetValue(folder, out group!))
                {
                    group = byFolder[folder] = new Group(GroupKind.Date, folder);
                    sectionGroups.Add(group);
                }
                if (generatedFolders.Add(generated)) group.GeneratedFolders.Add(generated);
            }
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
        // The type, person or format folders by name (each in date order inside), before the date folders of the rest.
        dateGroups.InsertRange(0, sectionGroups.OrderBy(g => g.Folder.Split('/')[0], NaturalComparer.Instance));   // stable
        foreach (var group in new[] { undated, tiny, duplicates }) if (group.Items.Count > 0) dateGroups.Add(group);
        Groups = dateGroups;
        PendingItems = pending;
    }
}
