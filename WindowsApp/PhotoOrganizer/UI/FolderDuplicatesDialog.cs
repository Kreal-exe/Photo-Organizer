using System.Windows;
using System.Windows.Controls;
using PhotoOrganizer.Core;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.UI;

/// <summary>
/// "Дубликаты по папкам…": exact copies grouped by the folders they lie in, so that a photo set copied into several
/// folders is cleaned up as a whole — the folder chosen for each group keeps its files, the copies in the others go to
/// the Recycle Bin. (The automatic "original" of each copy is chosen file by file, by date and path, and so ends up
/// now in one folder, now in another.)
/// </summary>
public sealed class FolderDuplicatesDialog : Dialog
{
    /// <summary>Copies lying in the same folders: every set has a copy in each of them.</summary>
    sealed class Group(List<string> folders, List<List<PhotoItem>> sets)
    {
        public List<string> Folders { get; } = folders;
        public List<List<PhotoItem>> Sets { get; } = sets;
        public int Kept;
        public bool Included = true;
        public readonly TextBlock Hint = new() { Margin = new Thickness(24, 4, 0, 0), Visibility = Visibility.Collapsed };
    }

    readonly List<Group> _groups;
    readonly TextBlock _summary = new() { Margin = new Thickness(0, 6, 0, 0) };
    readonly CheckBox _wholeFolders = new() { IsChecked = true, Margin = new Thickness(0, 4, 0, 10), Content = L("Папки, в которых останутся только копии, удалять целиком") };
    readonly Dictionary<string, List<string>> _filesOnDisk = new(StringComparer.OrdinalIgnoreCase);
    readonly Button _remove;

    public FolderDuplicatesDialog(Window owner, IEnumerable<List<PhotoItem>> sets) : base(owner, L("Дубликаты по папкам"), 640)
    {
        _groups = sets.Where(s => s.Count > 1)
                      .GroupBy(s => string.Join("\n", s.Select(FolderOf).Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.OrdinalIgnoreCase)),
                               StringComparer.OrdinalIgnoreCase)
                      .Select(g => new Group(g.Key.Split('\n').ToList(), g.ToList()))
                      .OrderByDescending(g => g.Sets.Count).ThenBy(g => g.Folders[0], StringComparer.CurrentCultureIgnoreCase).ToList();
        foreach (var group in _groups)
        {
            // At first the folder that holds most of the originals the app chose.
            group.Kept = group.Folders.Select((folder, index) => (index, count: group.Sets.Count(s => SameFolder(FolderOf(s[0]), folder))))
                                      .OrderByDescending(f => f.count).First().index;
        }

        Heading(L("Дубликаты по папкам"));
        Note(L("Одинаковые файлы собраны по папкам, в которых они лежат. Для каждой группы выберите папку, которая останется, — копии из остальных папок будут перемещены в Корзину."), "Secondary", 6);
        Note(L("Сначала выбрана папка, где больше файлов, которые приложение считает оригиналами: не из папок вроде «Копии» или «Backup», с самой ранней датой съёмки, с самым коротким путём."), bottom: 6);
        _wholeFolders.Click += (_, _) => Update();
        Body.Children.Add(_wholeFolders);
        foreach (var group in _groups) Body.Children.Add(Card(group));
        Body.Children.Add(_summary);
        _remove = AddButton(L("Переместить в Корзину"), () => DialogResult = true, primary: true);
        AddButton(L("Отмена"), () => DialogResult = false).IsCancel = true;
        Finish();
        Update();
    }

    /// <summary>The files to send to the Recycle Bin: in each set one file stays, in the folder chosen for its group.</summary>
    public List<PhotoItem> Victims()
    {
        var victims = new List<PhotoItem>();
        foreach (var group in _groups.Where(g => g.Included))
        {
            string kept = group.Folders[group.Kept];
            foreach (var set in group.Sets)
            {
                // The set is in the app's order (its chosen original first): the first file in the kept folder stays.
                var stays = set.First(i => SameFolder(FolderOf(i), kept));
                // The file that stays must still be there, or the set would lose its last copy.
                if (!System.IO.File.Exists(stays.Path) || new System.IO.FileInfo(stays.Path).Length != stays.FileSize) continue;
                victims.AddRange(set.Where(i => i != stays));
            }
        }
        return victims;
    }

    /// <summary>
    /// Folders with nothing left in them but the copies going away (and the Mac's or Explorer's own little files): they
    /// go to the Recycle Bin whole. Never a library folder itself; of folders inside one another only the outer one.
    /// </summary>
    public List<string> FoldersToRemove() => _wholeFolders.IsChecked == true ? EmptiedFolders(Victims()) : [];

    List<string> EmptiedFolders(List<PhotoItem> victims)
    {
        var going = victims.Select(i => i.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var roots = victims.Select(i => i.Root.TrimEnd('\\', '/')).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var emptied = victims.Select(FolderOf).Distinct(StringComparer.OrdinalIgnoreCase)
                             .Where(folder => !roots.Contains(folder.TrimEnd('\\')) && FilesOnDisk(folder) is { Count: > 0 } files && files.All(going.Contains))
                             .ToList();
        return emptied.Where(folder => !emptied.Any(outer => folder.StartsWith(outer + "\\", StringComparison.OrdinalIgnoreCase))).ToList();
    }

    /// <summary>The files in the folder and the folders inside it, without the system's and the Mac's hidden ones.</summary>
    List<string> FilesOnDisk(string folder)
    {
        if (_filesOnDisk.TryGetValue(folder, out var known)) return known;
        var files = new List<string>();
        try
        {
            foreach (string path in System.IO.Directory.EnumerateFiles(folder, "*", System.IO.SearchOption.AllDirectories))
            {
                var parts = System.IO.Path.GetRelativePath(folder, path).Split('\\');
                // Only the system's own little files are ignored; anything else (.edits, hidden files) keeps the folder.
                string leaf = parts[^1];
                if (leaf is "Thumbs.db" or "desktop.ini" or ".DS_Store" or "Icon\r" || leaf.StartsWith("._")) continue;
                files.Add(path);
            }
        }
        catch (Exception e) when (e is System.IO.IOException or UnauthorizedAccessException)
        {
            files.Clear();   // what cannot be looked through is not removed
        }
        return _filesOnDisk[folder] = files;
    }

    static string FolderOf(PhotoItem item) => System.IO.Path.GetDirectoryName(item.Path) ?? "";

    static bool SameFolder(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

    /// <summary>The folder as the user knows it: from the library folder's name down.</summary>
    string Shown(string folder, List<PhotoItem> set)
    {
        var item = set.First(i => SameFolder(FolderOf(i), folder));
        string root = System.IO.Path.GetFileName(item.Root.TrimEnd('\\', '/'));
        return item.CurrentFolder.Length == 0 ? root : root + "\\" + item.CurrentFolder.Replace('/', '\\');
    }

    FrameworkElement Card(Group group)
    {
        var panel = new StackPanel();
        long size = group.Sets.Sum(s => s[0].FileSize);
        var include = new CheckBox
        {
            IsChecked = true,
            FontWeight = FontWeights.SemiBold,
            Content = group.Folders.Count == 1
                ? F("%@ — копии в одной папке, останется по одному файлу", Count(group.Sets.Count, L("одинаковый файл"), L("одинаковых файла"), L("одинаковых файлов")))
                : F("%@ в %@ · %@", Count(group.Sets.Count, L("одинаковый файл"), L("одинаковых файла"), L("одинаковых файлов")),
                    Count(group.Folders.Count, L("папке"), L("папках"), L("папках")), Size(size)),
        };
        include.Click += (_, _) => { group.Included = include.IsChecked == true; Update(); };
        panel.Children.Add(include);
        var choices = new StackPanel { Margin = new Thickness(24, 6, 0, 0) };
        string name = "group" + _groups.IndexOf(group);
        for (int index = 0; index < group.Folders.Count; index++)
        {
            int chosen = index;
            string folder = group.Folders[index];
            if (group.Folders.Count == 1)
            {
                choices.Children.Add(Ui.Text(Shown(folder, group.Sets[0]), "Secondary"));
                continue;
            }
            var radio = new RadioButton
            {
                GroupName = name,
                IsChecked = index == group.Kept,
                Margin = new Thickness(0, 2, 0, 2),
                Content = new TextBlock { Text = F("Оставить: %@", Shown(folder, group.Sets[0])), TextTrimming = TextTrimming.CharacterEllipsis },
                ToolTip = folder,
            };
            radio.Checked += (_, _) => { group.Kept = chosen; Update(); };
            choices.Children.Add(radio);
        }
        panel.Children.Add(choices);
        Ui.Styled(group.Hint, "Hint");
        panel.Children.Add(group.Hint);
        include.Checked += (_, _) => choices.IsEnabled = true;
        include.Unchecked += (_, _) => choices.IsEnabled = false;
        var card = new Border { Child = panel, Padding = new Thickness(12, 10, 12, 10), Margin = new Thickness(0, 0, 0, 8), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6) };
        card.SetResourceReference(Border.BorderBrushProperty, "Separator");
        return card;
    }

    void Update()
    {
        var victims = Victims();
        var folders = FoldersToRemove();
        foreach (var group in _groups)
        {
            var whole = group.Included ? group.Folders.Where(f => folders.Any(r => SameFolder(f, r) || f.StartsWith(r + "\\", StringComparison.OrdinalIgnoreCase))).ToList() : [];
            group.Hint.Text = string.Join("\n", whole.Select(f => F("В папке «%@» не останется ничего, кроме этих копий, — она уйдёт в Корзину целиком.", Shown(f, group.Sets[0]))));
            group.Hint.Visibility = whole.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        _summary.Text = victims.Count == 0 ? L("Ничего не выбрано.")
            : F("В Корзину: %@, освободится %@. Вернуть можно из Корзины.", FilesDetail(victims.Count), Size(victims.Sum(i => i.FileSize)))
              + (folders.Count > 0 ? " " + F("Папок целиком: %@.", Number(folders.Count)) : "");
        _remove.IsEnabled = victims.Count > 0;
    }
}
