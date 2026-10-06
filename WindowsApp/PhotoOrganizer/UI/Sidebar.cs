using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using PhotoOrganizer.Core;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.UI;

public enum FilterKind
{
    All,
    Undated,       // files without a date and without a suggestion
    Suggested,     // files without a date, grouped by the rule that suggests one
    Duplicates,    // duplicate sets, originals included
    Tiny,
    Nudity,        // files the optional nudity model flagged
    Person,        // files with one person; Key holds the person's key
    Similar,       // results of the last search by photo (or by a person's face)
    Object,        // a saved object filter; Key holds its search words
    ObjectSearch,  // what the search by object found, on its own page
    Map,           // the files that know where they were taken, on a map
}

public sealed record Filter(FilterKind Kind, string? Key = null);

/// <summary>Source list: the library, the date suggestions, the search by face, people and the "to check" lists.</summary>
public sealed class Sidebar : DockPanel
{
    sealed record Row(string Title, string? Glyph = null, long Count = -1, Filter? Filter = null, string? Section = null, Person? Person = null,
                      bool AddButton = false);

    readonly StackPanel _rows = new();
    readonly Slider _scale = new() { Minimum = 1, Maximum = 3, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 8, 0) };
    readonly Thumbnails _thumbnails;
    readonly Dictionary<Person, Border> _faceHolders = [];
    List<Row> _model = [];
    Dictionary<string, long> _counts = [];
    List<Person> _people = [];
    List<(string Query, long Count)> _objectFilters = [];
    bool _hasLibrary;

    public Filter Selected { get; private set; } = new(FilterKind.All);
    public event Action<Filter>? FilterSelected;
    public event Action<Person>? RenamePerson;
    public event Action<Person>? PersonAlone;
    /// <summary>The "+" of the Objects section was pressed; the element is the button, for placing a menu.</summary>
    public event Action<FrameworkElement>? AddObjectFilter;
    public event Action<string>? RemoveObjectFilter;

    public Sidebar(Thumbnails thumbnails)
    {
        _thumbnails = thumbnails;
        _thumbnails.Loaded += key => { if (key.StartsWith("face|")) RefreshFaces(); };
        SetResourceReference(BackgroundProperty, "Sidebar");
        MinWidth = 180;
        _scale.Value = Math.Clamp(Settings.Shared.Get("sidebarScale", 1.0), 1, 3);
        _scale.ToolTip = L("Размер строк и лиц в боковой панели");
        _scale.ValueChanged += (_, _) =>
        {
            Settings.Shared.Set("sidebarScale", _scale.Value);
            Render();
        };
        // A small and a large figure at the ends, as the Mac's slider has: without them it looks like a scroll bar.
        var sizes = new DockPanel { Margin = new Thickness(16, 6, 16, 10), ToolTip = _scale.ToolTip };
        var small = Ui.Glyph("person", 10, "Tertiary");
        var large = Ui.Glyph("person", 16, "Tertiary");
        DockPanel.SetDock(small, Dock.Left);
        DockPanel.SetDock(large, Dock.Right);
        sizes.Children.Add(small);
        sizes.Children.Add(large);
        sizes.Children.Add(_scale);
        SetDock(sizes, Dock.Bottom);
        Children.Add(sizes);
        var scroll = new ScrollViewer { Content = _rows, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Padding = new Thickness(0, 8, 0, 0) };
        Children.Add(scroll);
    }

    double Scale => _scale.Value;

    static HashSet<string> Collapsed => Settings.Shared.GetList("collapsedSidebarSections").ToHashSet();

    /// <summary>
    /// counts: library, suggested, undated, duplicates, tiny, similar (-1 when there was no search yet), located, nudity
    /// (-1 hides the row: the feature is off). objectFilters: saved object filters with their counts.
    /// </summary>
    public void Rebuild(bool hasLibrary, Dictionary<string, long> counts, List<Person> people, Filter? selecting = null,
                        List<(string Query, long Count)>? objectFilters = null)
    {
        _hasLibrary = hasLibrary;
        _counts = counts;
        _people = people;
        _objectFilters = objectFilters ?? [];
        var rows = new List<Row>();
        if (hasLibrary)
        {
            rows.Add(new Row(L("Медиатека"), "library", counts.GetValueOrDefault("library"), new Filter(FilterKind.All)));
            if (counts.GetValueOrDefault("suggested") > 0)
                rows.Add(new Row(L("Предполагаемые даты"), "calendar-clock", counts["suggested"], new Filter(FilterKind.Suggested)));
            rows.Add(new Row(L("Поиск по объектам"), "object-search", -1, new Filter(FilterKind.ObjectSearch)));
            // Always there: selecting it is how the search by photo is found and started.
            rows.Add(new Row(L("Поиск по фото"), "photo-search", counts.GetValueOrDefault("similar", -1), new Filter(FilterKind.Similar)));
            rows.Add(new Row(L("Карта"), "map", counts.GetValueOrDefault("located"), new Filter(FilterKind.Map)));
            if (people.Count > 0)
            {
                rows.Add(new Row(L("Люди"), Section: "people"));
                // The long tail of people seen in a handful of photos would bury everything below.
                foreach (var person in people.Take(30))
                    rows.Add(new Row(person.DisplayName, "person", person.Items.Count, new Filter(FilterKind.Person, person.Key), Person: person));
            }
            rows.Add(new Row(L("Объекты"), Section: "objects", AddButton: true));
            foreach (var (query, count) in _objectFilters) rows.Add(new Row(query, "tag", count, new Filter(FilterKind.Object, query)));
            rows.Add(new Row(L("Проверить"), Section: "attention"));
            rows.Add(new Row(L("Без даты"), "calendar-warning", counts.GetValueOrDefault("undated"), new Filter(FilterKind.Undated)));
            rows.Add(new Row(L("Дубликаты"), "duplicates", counts.GetValueOrDefault("duplicates"), new Filter(FilterKind.Duplicates)));
            rows.Add(new Row(L("Миниатюры"), "thumbnails", counts.GetValueOrDefault("tiny"), new Filter(FilterKind.Tiny)));
            if (counts.GetValueOrDefault("nudity", -1) >= 0)
                rows.Add(new Row(L("Откровенные"), "explicit", counts["nudity"], new Filter(FilterKind.Nudity)));
        }
        // Rows of collapsed sections are left out; their headers stay.
        var collapsed = Collapsed;
        bool hidden = false;
        var visible = new List<Row>();
        foreach (var row in rows)
        {
            if (row.Filter == null) hidden = collapsed.Contains(row.Section!);
            if (row.Filter == null || !hidden) visible.Add(row);
        }
        _model = visible;
        var target = selecting ?? Selected;
        Selected = visible.Any(r => r.Filter == target) ? target : new Filter(FilterKind.All);
        Render();
    }

    public void Select(Filter filter)
    {
        Selected = filter;
        Render();
    }

    void Render()
    {
        _rows.Children.Clear();
        _faceHolders.Clear();
        foreach (var row in _model) _rows.Children.Add(row.Filter == null ? Header(row) : Item(row));
    }

    UIElement Header(Row row)
    {
        bool collapsed = Collapsed.Contains(row.Section!);
        var grid = new Grid { Margin = new Thickness(14, 12, 14, 4), Background = Brushes.Transparent, Cursor = Cursors.Hand,
                              ToolTip = collapsed ? L("Щёлкните, чтобы развернуть") : L("Щёлкните, чтобы свернуть") };
        var title = Ui.Text(row.Title, size: 11.5, weight: FontWeights.SemiBold);
        title.SetResourceReference(TextBlock.ForegroundProperty, "Tertiary");
        grid.Children.Add(title);
        var chevron = Ui.Glyph(collapsed ? "chevron-right" : "chevron-down", 9, "Tertiary");
        chevron.HorizontalAlignment = HorizontalAlignment.Right;
        grid.Children.Add(chevron);
        if (row.AddButton)
        {
            var add = Ui.Glyph("add", 12, "Secondary");
            add.HorizontalAlignment = HorizontalAlignment.Right;
            add.Margin = new Thickness(0, 0, 22, 0);
            add.Cursor = Cursors.Hand;
            add.ToolTip = L("Добавить фильтр по объекту");
            add.Background = Brushes.Transparent;
            add.MouseLeftButtonUp += (_, e) =>
            {
                e.Handled = true;
                AddObjectFilter?.Invoke(add);
            };
            grid.Children.Add(add);
        }
        grid.MouseLeftButtonUp += (_, _) =>
        {
            var set = Collapsed;
            if (!set.Remove(row.Section!)) set.Add(row.Section!);
            Settings.Shared.Set("collapsedSidebarSections", set.Order().ToList());
            var before = Selected;
            Rebuild(_hasLibrary, _counts, _people, before, _objectFilters);
            // Collapsing the section that held the selection moves it to the library.
            if (Selected != before) FilterSelected?.Invoke(Selected);
        };
        return grid;
    }

    UIElement Item(Row row)
    {
        double scale = Scale, iconSize = Math.Round(22 * scale);
        bool selected = row.Filter == Selected;
        var border = new Border { Margin = new Thickness(8, 1, 8, 1), Padding = new Thickness(8, 0, 10, 0), CornerRadius = new CornerRadius(6), Height = Math.Round(32 * scale), Background = Brushes.Transparent };
        if (selected) border.SetResourceReference(Border.BackgroundProperty, "Selection");
        border.MouseEnter += (_, _) => { if (row.Filter != Selected) border.SetResourceReference(Border.BackgroundProperty, "Hover"); };
        border.MouseLeave += (_, _) => { if (row.Filter != Selected) border.Background = Brushes.Transparent; };
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(iconSize) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = new Border { Width = iconSize, Height = iconSize, CornerRadius = new CornerRadius(iconSize / 2), Child = Ui.Glyph(row.Glyph ?? "photo", Math.Round(16 * scale), "Accent") };
        if (row.Person != null)
        {
            _faceHolders[row.Person] = icon;
            ShowFace(row.Person, icon);
        }
        grid.Children.Add(icon);
        // Text grows slower than the icons: the point of enlarging is to make the faces out.
        var title = Ui.Text(row.Title, size: Math.Round(13.5 * (1 + (scale - 1) * 0.3), 1));
        title.VerticalAlignment = VerticalAlignment.Center;
        title.Margin = new Thickness(9, 0, 6, 0);
        SetColumn(title, 1);
        grid.Children.Add(title);
        if (row.Count >= 0)
        {
            var count = Ui.Text(Number(row.Count), "Secondary", 12);
            count.VerticalAlignment = VerticalAlignment.Center;
            SetColumn(count, 2);
            grid.Children.Add(count);
        }
        border.Child = grid;
        border.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount == 2 && row.Person != null)
            {
                RenamePerson?.Invoke(row.Person);
                return;
            }
            if (row.Filter == Selected) return;
            Selected = row.Filter!;
            Render();
            FilterSelected?.Invoke(Selected);
        };
        if (row.Filter?.Kind == FilterKind.Object)
        {
            var menu = new ContextMenu();
            var remove = new MenuItem { Header = L("Удалить фильтр") };
            remove.Click += (_, _) => RemoveObjectFilter?.Invoke(row.Filter.Key!);
            menu.Items.Add(remove);
            border.ContextMenu = menu;
        }
        if (row.Person != null)
        {
            var menu = new ContextMenu();
            var rename = new MenuItem { Header = L("Назвать…") };
            rename.Click += (_, _) => RenamePerson?.Invoke(row.Person);
            var alone = new MenuItem { Header = L("Только фото без других людей") };
            alone.Click += (_, _) => PersonAlone?.Invoke(row.Person);
            menu.Items.Add(rename);
            menu.Items.Add(alone);
            border.ContextMenu = menu;
        }
        return border;
    }

    static void SetColumn(UIElement element, int column) => Grid.SetColumn(element, column);

    /// <summary>A person's row shows their face in a circle; the symbol stays until the face has been cut out.</summary>
    void ShowFace(Person person, Border holder)
    {
        if (person.Representative is not { } representative || representative.Item.FaceBoxes is not { } boxes || representative.Face >= boxes.Count) return;
        var face = _thumbnails.Face(representative.Item, boxes[representative.Face], (int)holder.Width);
        if (face == null) return;
        holder.Child = null;
        holder.Background = new ImageBrush(face) { Stretch = Stretch.UniformToFill };
    }

    void RefreshFaces()
    {
        foreach (var (person, holder) in _faceHolders) if (holder.Background is not ImageBrush) ShowFace(person, holder);
    }
}
