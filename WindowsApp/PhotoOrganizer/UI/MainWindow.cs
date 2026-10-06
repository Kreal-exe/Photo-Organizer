using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using PhotoOrganizer.Core;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.UI;

/// <summary>The main window: the toolbar, the sidebar, the grid (or the viewer) and the bar with "Organize into Folders".</summary>
public sealed class MainWindow : Window
{
    /// <summary>What the strip shows: everything ticked, or one kind alone (MediaAll + 1 + a kind).</summary>
    const int MediaAll = 0;
    /// <summary>The kinds of file, in the order of the strip: each ticked — in the library and organized — or not.</summary>
    const int KindPhotos = 0, KindVideos = 1, KindPictures = 2, KindCollages = 3;
    static readonly string[] KindKeys = ["organizesPhotos", "organizesVideos", "organizesPictures", "organizesCollages"];

    readonly Thumbnails _thumbnails;
    readonly Sidebar _sidebar;
    readonly PhotoGrid _grid;
    readonly Viewer _viewer = new();
    readonly ContentControl _results = new();
    readonly ContentControl _pages = new();
    readonly TextBlock _title = new() { FontSize = 17, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly TextBlock _path = new() { FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly Button _openButton, _addFolderButton, _rescanButton, _revealButton, _settingsButton, _sidebarButton;
    readonly SegmentedControl _grouping, _media;
    readonly TextBox _search = new() { Height = 30, MinWidth = 120, MaxWidth = 300, Padding = new Thickness(26, 0, 6, 0) };
    // The grid follows the search field once typing pauses, not on every key: a library can hold ~100,000 files.
    readonly DispatcherTimer _searchTimer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    readonly CheckBox _solo = new();
    /// <summary>The kind of a file in the strip — the same one organizing goes by (see Plan).</summary>
    static int KindOf(PhotoItem item) =>
        MediaTypes.IsGooglePhotosCreation(item) ? KindCollages : item.IsPicture ? KindPictures : item.Video ? KindVideos : KindPhotos;

    /// <summary>Which kinds are ticked: in the library under "Все", and organized. Shared with organizing (Plan).</summary>
    static bool[] Included() => KindKeys.Select(key => Settings.Shared.Get(key, true)).ToArray();

    bool[] _included = Included();

    /// <summary>Whether a file is shown and counted: only the ticked kinds.</summary>
    bool Shown(PhotoItem item) => _included[KindOf(item)];
    readonly Button _setDate, _accept, _cleanup, _byFolders, _pickAnother, _backToMap, _arrange;
    readonly TextBlock _analysis = new() { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 280 };
    readonly TextBlock _status = new() { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    readonly Slider _size = new() { Minimum = 110, Maximum = 420, Width = 150, VerticalAlignment = VerticalAlignment.Center };
    readonly Button _organize;
    readonly UIElement _welcome, _library;
    readonly Grid _progressPage = new();
    // "Отпустите, чтобы открыть папку" over the window while folders are dragged over it, as on the Mac.
    readonly Border _dropOverlay = new() { Visibility = Visibility.Collapsed, IsHitTestVisible = false, BorderThickness = new Thickness(3) };
    // The sidebar is folded away until a folder is open, and can be folded by hand (Ctrl+Alt+S), as on the Mac.
    ColumnDefinition _sidebarColumn = null!;
    GridSplitter _splitter = null!;
    bool _sidebarHidden;
    readonly TextBlock _progressText = new() { HorizontalAlignment = HorizontalAlignment.Center };
    readonly ProgressBar _progressBar = new() { Width = 380, Margin = new Thickness(0, 12, 0, 12) };
    readonly Button _progressCancel;
    /// <summary>Stops a copy run between two files ("Остановить" on the progress page); what was copied stays, undoable.</summary>
    CancellationTokenSource? _copyCancel;
    readonly DispatcherTimer _regroupTimer = new() { Interval = TimeSpan.FromSeconds(8) };

    // The library's folders: one, or several organized together. The first is where things go unless another
    // destination is chosen when organizing (_destination).
    List<string> _roots = [];
    string? _destination;
    string? _root => _roots.Count > 0 ? _roots[0] : null;
    Plan? _plan;
    Scanner? _scanner;
    Analyzer? _analyzer;
    Suggester? _suggester;
    List<Person> _people = [];
    List<List<PhotoItem>> _copySets = [];
    List<PhotoItem>? _similarItems;   // the last search by photo (or by a person's face); null before any
    string _similarTitle = "";
    List<PhotoItem>? _objectResults;
    string _objectStatus = "";
    string? _objectExample;
    List<PhotoItem>? _placeItems;     // the photos of a pin or a cluster chosen on the map
    readonly MapView _map = new();
    PhotoSearchWindow? _photoSearch;
    int _searchGeneration;
    CancellationTokenSource? _clipDownload;
    readonly Stack<OrganizeResult> _undo = new(), _redo = new();
    bool _busy, _closing;
    string? _lastMessage;
    string[] _searchTokens = [];
    string? _lastGridKey;

    public MainWindow()
    {
        Title = "Photo Organizer";
        Icon = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri("pack://application:,,,/PhotoOrganizer;component/AppIcon.ico"));
        Theme.StyleTitleBar(this);
        AllowDrop = true;
        MinWidth = 760;   // 180 + 1 + 560 and the frame
        MinHeight = 480;
        _thumbnails = new Thumbnails(Dispatcher);
        _sidebar = new Sidebar(_thumbnails);
        _grid = new PhotoGrid(_thumbnails);
        RestorePlacement();

        _sidebar.FilterSelected += _ => { CloseViewer(); _placeItems = null; UpdateGrid(); };
        _sidebar.RenamePerson += RenamePerson;
        _sidebar.AddObjectFilter += AddObjectFilterMenu;
        _sidebar.RemoveObjectFilter += RemoveObjectFilter;
        _sidebar.PersonAlone += person =>
        {
            CloseViewer();
            Settings.Shared.Set("personAloneOnly", true);
            _sidebar.Select(new Filter(FilterKind.Person, person.Key));
            UpdateGrid();
        };

        // Toolbar: the folder, its buttons, the grouping and the search.
        _openButton = Ui.IconButton("folder", L("Открыть папку") + " (Ctrl+O)", OpenFolder);
        _addFolderButton = Ui.IconButton("folder-add", L("Добавить ещё папку — разобрать несколько папок вместе") + " (Ctrl+Shift+O)", AddFolder);
        _rescanButton = Ui.IconButton("refresh", L("Пересканировать") + " (F5)", Rescan);
        _revealButton = Ui.IconButton("open-external", L("Показать папку в Проводнике"), RevealRoot);
        _settingsButton = Ui.IconButton("settings", L("Настройки"), ShowSettings);
        _sidebarButton = Ui.IconButton("sidebar", L("Показать или скрыть боковую панель") + " (Ctrl+Alt+S)", () => ToggleSidebar());
        _grouping = new SegmentedControl([L("По годам"), L("По месяцам"), L("По дням")]) { Selected = Grouping, ToolTip = L("Как делить фото на разделы в окне: по годам, месяцам или дням. На раскладку файлов по папкам не влияет.") };
        _grouping.Changed += index => { Settings.Shared.Set("gridGrouping", index); UpdateGrid(); };
        _search.TextChanged += (_, _) =>
        {
            _searchTimer.Stop();
            _searchTimer.Start();
        };
        _searchTimer.Tick += (_, _) =>
        {
            _searchTimer.Stop();
            var tokens = Labels.SearchTokens(_search.Text);
            if (tokens.SequenceEqual(_searchTokens)) return;
            _searchTokens = tokens;
            if (_results.Content == _viewer) CloseViewer();
            UpdateGrid();
        };
        _search.ToolTip = L("Поиск по тому, что на снимке, и по имени файла: «море», «собака», «документ»");
        var searchBox = new Grid { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0) };
        searchBox.Children.Add(_search);
        var magnifier = Ui.Glyph("search", 13, "Tertiary");
        magnifier.HorizontalAlignment = HorizontalAlignment.Left;
        magnifier.Margin = new Thickness(9, 0, 0, 0);
        // The magnifying glass lists what was recognised most often, as the macOS search field does.
        magnifier.Cursor = Cursors.Hand;
        magnifier.Background = Brushes.Transparent;
        magnifier.Width = 24;
        magnifier.MouseLeftButtonUp += (_, _) => SearchSuggestions(magnifier);
        searchBox.Children.Add(magnifier);
        var placeholder = Ui.Text(L("Что на снимке или имя файла"), "Secondary");
        placeholder.Margin = new Thickness(28, 0, 0, 0);
        placeholder.VerticalAlignment = VerticalAlignment.Center;
        placeholder.IsHitTestVisible = false;
        placeholder.SetResourceReference(TextBlock.ForegroundProperty, "Tertiary");
        _search.TextChanged += (_, _) => placeholder.Visibility = _search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        searchBox.Children.Add(placeholder);
        _path.SetResourceReference(TextBlock.ForegroundProperty, "Secondary");
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) };
        titles.Children.Add(_title);
        titles.Children.Add(_path);
        var toolbarGrid = new Grid { Margin = new Thickness(18, 8, 10, 8) };
        toolbarGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 80 });
        toolbarGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        toolbarGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        toolbarGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MaxWidth = 310 });
        toolbarGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 14, 0) };
        foreach (var button in new[] { _sidebarButton, _openButton, _addFolderButton, _rescanButton, _revealButton }) buttons.Children.Add(button);
        // A click on the title lists the library's folders, to show one or take it out.
        _title.Cursor = Cursors.Hand;
        _title.MouseLeftButtonUp += (_, _) => FoldersMenu();
        _path.Cursor = Cursors.Hand;
        _path.MouseLeftButtonUp += (_, _) => FoldersMenu();
        Place(toolbarGrid, titles, 0);
        Place(toolbarGrid, buttons, 1);
        Place(toolbarGrid, _grouping, 2);
        Place(toolbarGrid, searchBox, 3);
        _settingsButton.Margin = new Thickness(6, 0, 0, 0);
        Place(toolbarGrid, _settingsButton, 4);
        var toolbar = Ui.Bar("Toolbar", new Thickness(0, 0, 0, 1));
        toolbar.Child = toolbarGrid;

        // Strip: what kind of files, and the controls of the current view.
        // "Все", then each kind with its checkbox: ticked, it is in the library and organized; clicked, it is shown alone.
        _media = new SegmentedControl([L("Медиа"), L("Фото"), L("Видео"), L("Картинки"), L("Коллажи")], 28, checkableFrom: 1)
        {
            Selected = Math.Clamp(Settings.Shared.Get("mediaKind", 0), 0, 4),
        };
        _media.SetToolTips([L("Все отмеченные виды файлов"), L("Фотографии"), L("Видео"), L("Открытки, мемы, рисунки, документы — то, что не фотография"),
                            L("Коллажи, рамки, анимации, фильмы и эффекты, которые сделал Google Фото")],
                           L("Отмечено — в медиатеке и раскладывается; без галочки — скрыто и остаётся на месте"));
        _media.Changed += index => { Settings.Shared.Set("mediaKind", index); UpdateGrid(); };
        _media.Ticked += (index, on) =>
        {
            int kind = index - 1;
            Settings.Shared.Set(KindKeys[kind], on);
            _included = Included();
            if (_plan != null)
            {
                _plan.OrganizesPhotos = _included[KindPhotos];
                _plan.OrganizesVideos = _included[KindVideos];
                _plan.OrganizesPictures = _included[KindPictures];
                _plan.OrganizesCollages = _included[KindCollages];
                _plan.Rebuild();
            }
            _objectFilterCounts.Clear();
            ReloadSidebar();
            UpdateGrid();
        };
        _solo.Content = L("Без других людей");
        _solo.ToolTip = L("Показывать только фото, на которых нет никого, кроме этого человека");
        _solo.Click += (_, _) => { Settings.Shared.Set("personAloneOnly", _solo.IsChecked == true); UpdateGrid(); };
        _setDate = Ui.TextButton(L("Задать дату…"), SetDateForSelection);
        _setDate.ToolTip = L("Задать дату выбранным файлам (или всем показанным, если ничего не выбрано)");
        _accept = Ui.TextButton(L("Принять подсказки…"), AcceptSuggestions);
        _accept.ToolTip = L("Дать каждому файлу дату по лучшей подсказке: соседние файлы, имя файла, название папки");
        _cleanup = Ui.TextButton(L("Удалить дубликаты…"), RemoveDuplicates);
        _cleanup.ToolTip = L("Переместить в Корзину все копии, оставив в каждом наборе оригинал или файл лучшего качества");
        _byFolders = Ui.TextButton(L("Дубликаты по папкам…"), RemoveDuplicatesByFolder);
        _byFolders.ToolTip = L("Для одинаковых фото в разных папках выбрать, какая папка останется");
        _arrange = Ui.TextButton(L("Разложить…"), ArrangeShown);
        _arrange.ToolTip = L("Сложить показанные файлы в одну папку — всё вместе или по годам, месяцам, дням");
        _pickAnother = Ui.TextButton(L("Выделить другой предмет…"), () => { if (_objectExample != null) FindObjectIn(_objectExample); });
        _backToMap = Ui.TextButton(L("К карте"), () => { _placeItems = null; UpdateGrid(); });
        // With the map's symbol before the title, as on the Mac.
        var backToMapContent = new StackPanel { Orientation = Orientation.Horizontal };
        var mapGlyph = Ui.Glyph("map", 13, "Text");
        mapGlyph.Margin = new Thickness(0, 0, 6, 0);
        backToMapContent.Children.Add(mapGlyph);
        backToMapContent.Children.Add(new TextBlock { Text = L("К карте"), VerticalAlignment = VerticalAlignment.Center });
        _backToMap.Content = backToMapContent;
        _analysis.SetResourceReference(TextBlock.ForegroundProperty, "Secondary");
        var strip = new DockPanel { Margin = new Thickness(18, 6, 18, 6), LastChildFill = false };
        _media.Margin = new Thickness(0, 0, 12, 0);
        DockPanel.SetDock(_media, Dock.Left);
        strip.Children.Add(_media);
        // In the Mac's order: the view's own action, the way back to the map, the clean-up, then the person and dates controls.
        foreach (var control in new FrameworkElement[] { _arrange, _pickAnother, _backToMap, _cleanup, _byFolders, _solo, _setDate, _accept })
        {
            control.Margin = new Thickness(0, 0, 10, 0);
            control.VerticalAlignment = VerticalAlignment.Center;
            control.Visibility = Visibility.Collapsed;
            DockPanel.SetDock(control, Dock.Left);
            strip.Children.Add(control);
        }
        DockPanel.SetDock(_analysis, Dock.Right);
        strip.Children.Add(_analysis);
        var stripBar = Ui.Bar("Toolbar", new Thickness(0, 0, 0, 1));
        stripBar.Child = strip;

        _grid.Activated += OpenItem;
        _grid.ContextMenuRequested += position => ItemMenu(_grid, position);
        _grid.ImageDropped += path =>
        {
            if (_sidebar.Selected.Kind == FilterKind.ObjectSearch) FindObjectIn(path);
            else SearchByPhoto(path, searchWhenReady: true);
        };
        _map.ItemsSelected += items => { _placeItems = items; UpdateGrid(); };
        _grid.DeletePressed += TrashSelection;
        _grid.DraggedOut += items =>
        {
            // Explorer finishes a move after the drop; files no longer there leave the library.
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };
            timer.Tick += (_, _) =>
            {
                timer.Stop();
                var gone = items.Where(i => !File.Exists(i.Path)).ToList();
                if (gone.Count == 0 || _plan == null || _busy) return;
                RemoveFromLibrary(gone);
                _lastMessage = F("Перенесено из папки: %@.", Count(gone.Count, L("файл"), L("файла"), L("файлов")));
                ReloadSidebar();
                UpdateGrid();
                RegroupCopies();
            };
            timer.Start();
        };
        _grid.ZoomRequested += size => _size.Value = size;
        _viewer.Closed += CloseViewer;
        _viewer.DeletePressed += TrashSelection;
        _viewer.ContextMenuRequested += position =>
        {
            if (_viewer.Current is not { } current) return;
            // The menu acts on the selection, so the file on screen becomes the selection.
            _grid.Select(current);
            ItemMenu(_viewer, position);
        };
        _results.Content = _grid;

        _status.SetResourceReference(TextBlock.ForegroundProperty, "Secondary");
        _size.Value = Settings.Shared.Get("thumbnailSize", DefaultThumbnailSize);
        _size.ToolTip = L("Размер миниатюр в сетке");
        _size.ValueChanged += (_, _) =>
        {
            Settings.Shared.Set("thumbnailSize", _size.Value);
            _grid.SetCellSize(_size.Value);
        };
        _grid.SetCellSize(_size.Value);
        // A plain bordered button, as on the Mac.
        _organize = Ui.TextButton(L("Разложить по папкам"), Organize);
        _organize.ToolTip = "Ctrl+Enter";
        var bottom = new DockPanel { Margin = new Thickness(18, 8, 18, 8) };
        DockPanel.SetDock(_organize, Dock.Right);
        _size.Margin = new Thickness(16, 0, 16, 0);
        DockPanel.SetDock(_size, Dock.Right);
        bottom.Children.Add(_organize);
        bottom.Children.Add(_size);
        bottom.Children.Add(_status);
        var bottomBar = Ui.Bar("Toolbar", new Thickness(0, 1, 0, 0));
        bottomBar.Child = bottom;

        var library = new DockPanel();
        DockPanel.SetDock(stripBar, Dock.Top);
        DockPanel.SetDock(bottomBar, Dock.Bottom);
        library.Children.Add(stripBar);
        library.Children.Add(bottomBar);
        library.Children.Add(_results);
        _library = library;

        _welcome = WelcomePage();
        _progressCancel = Ui.TextButton(L("Отменить"), () =>
        {
            _scanner?.Cancel();
            _copyCancel?.Cancel();
        });
        var progress = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        _progressText.SetResourceReference(TextBlock.ForegroundProperty, "Secondary");
        progress.Children.Add(_progressText);
        progress.Children.Add(_progressBar);
        _progressCancel.HorizontalAlignment = HorizontalAlignment.Center;
        progress.Children.Add(_progressCancel);
        _progressPage.Children.Add(progress);

        var content = new DockPanel();
        DockPanel.SetDock(toolbar, Dock.Top);
        content.Children.Add(toolbar);
        content.Children.Add(_pages);

        var root = new Grid();
        // The sidebar can't be dragged away to nothing (the width is saved), and both columns fit the window's minimum width.
        _sidebarColumn = new ColumnDefinition { Width = new GridLength(Math.Clamp(Settings.Shared.Get("sidebarWidth", 270.0), 180, 420)), MinWidth = 180, MaxWidth = 420 };
        root.ColumnDefinitions.Add(_sidebarColumn);
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 560 });
        _splitter = new GridSplitter { Width = 1, HorizontalAlignment = HorizontalAlignment.Stretch, ResizeBehavior = GridResizeBehavior.PreviousAndNext, Cursor = Cursors.SizeWE };
        _splitter.SetResourceReference(BackgroundProperty, "Separator");
        _splitter.DragCompleted += (_, _) => Settings.Shared.Set("sidebarWidth", _sidebarColumn.ActualWidth);
        Place(root, _sidebar, 0);
        Place(root, _splitter, 1);
        Place(root, content, 2);
        var dropTitle = new TextBlock { Text = L("Отпустите, чтобы открыть папку"), FontSize = 20, FontWeight = FontWeights.SemiBold,
                                        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        _dropOverlay.Child = dropTitle;
        _dropOverlay.SetResourceReference(Border.BackgroundProperty, "Window");
        _dropOverlay.SetResourceReference(Border.BorderBrushProperty, "Accent");
        Grid.SetColumnSpan(_dropOverlay, 3);
        root.Children.Add(_dropOverlay);
        Content = root;

        _regroupTimer.Tick += (_, _) => { if (_analyzer != null && SettingsDialog.GroupsFaces) RegroupPeopleInBackground(); };
        BuildShortcuts();
        ShowWelcome();
        Closing += (_, _) =>
        {
            _closing = true;
            _viewer.Stop();   // Windows' player runs outside the window: without this its sound outlives it
            SavePlacement();
            StopAnalysis();
            _scanner?.Cancel();
            RecognitionStore.Shared.Flush();
        };
    }

    static void Place(Grid grid, UIElement element, int column)
    {
        Grid.SetColumn(element, column);
        grid.Children.Add(element);
    }

    UIElement WelcomePage()
    {
        var panel = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(40) };
        panel.Children.Add(Ui.Glyph("library", 64));
        var title = new TextBlock { Text = L("Перетащите сюда папку с фото и видео"), FontSize = 24, FontWeight = FontWeights.SemiBold, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 16, 0, 8) };
        panel.Children.Add(title);
        var subtitle = new TextBlock
        {
            Text = L("Фото и видео будут отсортированы по дате съёмки и разложены по папкам.\nДубликаты и миниатюры найдутся автоматически — до вашего подтверждения ничего не перемещается."),
            TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 640,
        };
        subtitle.SetResourceReference(TextBlock.ForegroundProperty, "Secondary");
        panel.Children.Add(subtitle);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 20, 0, 0) };
        var choose = Ui.TextButton(L("Выбрать папку…"), OpenFolder, primary: true);
        choose.IsDefault = true;
        buttons.Children.Add(choose);
        panel.Children.Add(buttons);
        return panel;
    }

    // --- Window placement ---------------------------------------------------------------------------------------

    void RestorePlacement()
    {
        var area = SystemParameters.WorkArea;
        double[]? saved = Settings.Shared.Get<double[]?>("windowPlacement", null);
        if (saved is { Length: 5 } && saved[2] >= MinWidth && saved[3] >= MinHeight
            && saved[0] < area.Right - 100 && saved[1] < area.Bottom - 100 && saved[0] + saved[2] > area.Left + 100 && saved[1] >= area.Top - 10)
        {
            (Left, Top, Width, Height) = (saved[0], saved[1], Math.Min(saved[2], area.Width), Math.Min(saved[3], area.Height));
            WindowStartupLocation = WindowStartupLocation.Manual;
            if (saved[4] == 1) WindowState = WindowState.Maximized;
            return;
        }
        // The first time: most of the screen, never more than fits.
        Width = Math.Min(1320, area.Width * 0.9);
        Height = Math.Min(860, area.Height * 0.9);
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
    }

    void SavePlacement()
    {
        var bounds = RestoreBounds;
        if (bounds.IsEmpty) return;
        Settings.Shared.Set("windowPlacement", new[] { bounds.Left, bounds.Top, bounds.Width, bounds.Height, WindowState == WindowState.Maximized ? 1 : 0 });
    }

    // --- Shortcuts and the menu --------------------------------------------------------------------------------

    void BuildShortcuts()
    {
        void Bind(Key key, ModifierKeys modifiers, Action action)
        {
            var command = new RoutedCommand();
            CommandBindings.Add(new CommandBinding(command, (_, _) => action()));
            InputBindings.Add(new KeyBinding(command, key, modifiers));
        }
        Bind(Key.O, ModifierKeys.Control, OpenFolder);
        Bind(Key.O, ModifierKeys.Control | ModifierKeys.Shift, AddFolder);
        Bind(Key.F5, ModifierKeys.None, Rescan);
        Bind(Key.R, ModifierKeys.Control, Rescan);
        Bind(Key.Enter, ModifierKeys.Control, Organize);
        Bind(Key.Z, ModifierKeys.Control, Undo);
        Bind(Key.Y, ModifierKeys.Control, Redo);
        Bind(Key.Z, ModifierKeys.Control | ModifierKeys.Shift, Redo);
        Bind(Key.F, ModifierKeys.Control, () => { _search.Focus(); _search.SelectAll(); });
        Bind(Key.F, ModifierKeys.Control | ModifierKeys.Shift, () => SearchByPhoto(null));
        Bind(Key.R, ModifierKeys.Control | ModifierKeys.Shift, RevealRoot);
        // Not while typing in the search field: there Ctrl+Backspace deletes a word.
        Bind(Key.Back, ModifierKeys.Control, () => { if (!_search.IsKeyboardFocused) TrashSelection(); });
        Bind(Key.C, ModifierKeys.Control, () => { if (!_search.IsKeyboardFocused) CopySelection(); });
        Bind(Key.S, ModifierKeys.Control | ModifierKeys.Alt, () => ToggleSidebar());
        // In the viewer, as ⌘0 and ⌘9 on the Mac: the actual size, or the whole picture.
        // In the grid Ctrl+0 brings the thumbnails back to their usual size.
        Bind(Key.D0, ModifierKeys.Control, ZoomReset);
        Bind(Key.NumPad0, ModifierKeys.Control, ZoomReset);
        Bind(Key.D9, ModifierKeys.Control, () => { if (_results.Content == _viewer) _viewer.ZoomToFit(); });
        Bind(Key.NumPad9, ModifierKeys.Control, () => { if (_results.Content == _viewer) _viewer.ZoomToFit(); });
        Bind(Key.A, ModifierKeys.Control, () => { if (!_search.IsKeyboardFocused) _grid.SelectAll(); });
        Bind(Key.D, ModifierKeys.Control, SetDateForSelection);
        Bind(Key.M, ModifierKeys.Control, MoveSelectionToFolder);
        Bind(Key.M, ModifierKeys.Control | ModifierKeys.Shift, MoveShownToFolder);
        Bind(Key.OemComma, ModifierKeys.Control, ShowSettings);
        Bind(Key.Down, ModifierKeys.Control, OpenSelection);
        Bind(Key.OemPlus, ModifierKeys.Control, () => Zoom(1));
        Bind(Key.Add, ModifierKeys.Control, () => Zoom(1));
        Bind(Key.OemMinus, ModifierKeys.Control, () => Zoom(-1));
        Bind(Key.Subtract, ModifierKeys.Control, () => Zoom(-1));
        Bind(Key.D1, ModifierKeys.Control, () => SetGrouping(0));
        Bind(Key.D2, ModifierKeys.Control, () => SetGrouping(1));
        Bind(Key.D3, ModifierKeys.Control, () => SetGrouping(2));
    }

    void SetGrouping(int index)
    {
        _grouping.Selected = index;
        Settings.Shared.Set("gridGrouping", index);
        UpdateGrid();
    }

    const double DefaultThumbnailSize = 190;

    void ZoomReset()
    {
        if (_results.Content == _viewer) _viewer.ZoomToActualSize();
        else _size.Value = DefaultThumbnailSize;
    }

    void Zoom(int direction)
    {
        // In the viewer Ctrl+ and Ctrl− zoom the picture, as its buttons say.
        if (_results.Content == _viewer)
        {
            _viewer.HandleKey(direction > 0 ? Key.Add : Key.Subtract);
            return;
        }
        _size.Value = Math.Clamp(_size.Value + 30 * direction, _size.Minimum, _size.Maximum);
    }

    // --- Folder and scanning ------------------------------------------------------------------------------------

    void ShowWelcome()
    {
        _pages.Content = _welcome;
        _title.Text = "Photo Organizer";
        _path.Text = "";
        _sidebar.Rebuild(false, [], []);
        ShowSidebar();
        UpdateUi();
    }

    /// <summary>Shown with a library (unless folded by hand); never on the welcome page, which has nothing to list.</summary>
    void ShowSidebar()
    {
        bool shown = !_sidebarHidden && _pages.Content != _welcome;
        _sidebar.Visibility = _splitter.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        _sidebarColumn.MinWidth = shown ? 180 : 0;
        _sidebarColumn.Width = shown ? new GridLength(Math.Clamp(Settings.Shared.Get("sidebarWidth", 270.0), 180, 420)) : new GridLength(0);
        _sidebarButton.IsEnabled = _pages.Content != _welcome;
    }

    void ToggleSidebar()
    {
        if (_pages.Content == _welcome) return;
        _sidebarHidden = !_sidebarHidden;
        ShowSidebar();
    }

    /// <summary>A scan can be left for another folder; moving or copying files can't.</summary>
    bool BusyWithFiles => _busy && _scanner == null;

    /// <summary>Stops the scan without going back to what was shown before it: something else takes over.</summary>
    void AbandonScan()
    {
        if (_scanner == null) return;
        _scanner.Cancel();
        _scanner = null;   // ScanDone ignores a scanner that is no longer the current one
        _busy = false;
    }

    /// <summary>The folder to open for a dropped or given path: the folder itself, or the one a file is in.</summary>
    public static string? FolderOf(string path) =>
        Directory.Exists(path) ? path : File.Exists(path) ? Path.GetDirectoryName(path) : null;

    void OpenFolder()
    {
        if (BusyWithFiles) return;
        var dialog = new Microsoft.Win32.OpenFolderDialog
        {
            Title = L("Выберите папку с фото и видео (можно несколько)"),
            InitialDirectory = _root ?? Settings.Shared.GetString("lastFolder") ?? Environment.GetFolderPath(Environment.SpecialFolder.MyPictures),
            Multiselect = true,
        };
        if (dialog.ShowDialog(this) == true) LoadFolders(dialog.FolderNames);
    }

    /// <summary>Another folder into the library: several folders are scanned and organized together.</summary>
    void AddFolder()
    {
        if (BusyWithFiles) return;
        if (_roots.Count == 0)
        {
            OpenFolder();
            return;
        }
        var dialog = new Microsoft.Win32.OpenFolderDialog
        {
            Title = L("Добавить папку к разбору"),
            InitialDirectory = Path.GetDirectoryName(_roots[^1]) ?? _roots[^1],
            Multiselect = true,
        };
        if (dialog.ShowDialog(this) == true) LoadFolders(_roots.Concat(dialog.FolderNames), keepDestination: true);
    }

    /// <summary>The library's folders, with "show" and "take out of the library" for each.</summary>
    void FoldersMenu()
    {
        if (BusyWithFiles || (_roots.Count == 0 && RecentFolderSets.Count == 0)) return;
        var menu = new ContextMenu { PlacementTarget = _title, Placement = PlacementMode.Bottom };
        foreach (string root in _roots)
        {
            var item = new MenuItem { Header = DisplayPath(root) };
            var reveal = new MenuItem { Header = L("Показать в Проводнике") };
            string target = root;
            reveal.Click += (_, _) => Process.Start(new ProcessStartInfo("explorer.exe", $"\"{target}\"") { UseShellExecute = true });
            item.Items.Add(reveal);
            if (_roots.Count > 1)
            {
                var remove = new MenuItem { Header = L("Убрать из разбора") };
                remove.Click += (_, _) => LoadFolders(_roots.Where(r => r != target).ToList(), keepDestination: true);
                item.Items.Add(remove);
            }
            menu.Items.Add(item);
        }
        if (_roots.Count > 0)
        {
            menu.Items.Add(new Separator());
            var add = new MenuItem { Header = L("Добавить папку…") };
            add.Click += (_, _) => AddFolder();
            menu.Items.Add(add);
        }
        // The folder sets opened before, as File › Open Recent on the Mac.
        var recent = new MenuItem { Header = L("Открыть недавние") };
        foreach (var set in RecentFolderSets)
        {
            var item = new MenuItem { Header = string.Join("  ·  ", set.Select(DisplayPath)) };
            item.Click += (_, _) => LoadFolders(set);
            recent.Items.Add(item);
        }
        if (recent.Items.Count > 0) recent.Items.Add(new Separator());
        var clear = new MenuItem { Header = L("Очистить меню"), IsEnabled = recent.Items.Count > 0 };
        clear.Click += (_, _) => Settings.Shared.Set("recentFolderSets", null);
        recent.Items.Add(clear);
        if (menu.Items.Count > 0) menu.Items.Add(new Separator());
        menu.Items.Add(recent);
        menu.IsOpen = true;
    }

    /// <summary>Up to ten folder sets opened before, the latest first (only those still there).</summary>
    static List<List<string>> RecentFolderSets =>
        (Settings.Shared.GetObject<List<List<string>>>("recentFolderSets") ?? []).Where(set => set.Count > 0 && set.All(Directory.Exists)).ToList();

    static void RememberRecent(List<string> roots)
    {
        var sets = Settings.Shared.GetObject<List<List<string>>>("recentFolderSets") ?? [];
        sets.RemoveAll(set => set.SequenceEqual(roots, StringComparer.OrdinalIgnoreCase));
        sets.Insert(0, roots);
        Settings.Shared.Set("recentFolderSets", sets.Take(10).ToList());
    }

    static string DisplayPath(string path)
    {
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return path.StartsWith(home + "\\", StringComparison.OrdinalIgnoreCase) ? "~" + path[home.Length..] : path;
    }

    /// <summary>The folders whose scan or recognition was still running when the app was closed last time.</summary>
    public static List<string> UnfinishedFolders =>
        (Settings.Shared.GetObject<List<string>>("unfinishedFolders") ?? (Settings.Shared.GetString("unfinishedFolder") is { } one ? [one] : []))
        .Where(Directory.Exists).ToList();

    public void LoadFolder(string? folder)
    {
        if (folder != null) LoadFolders([folder]);
    }

    /// <summary>Opens a library of one or more folders (folders inside another one of them are left out).</summary>
    public void LoadFolders(IEnumerable<string> folders, bool keepDestination = false)
    {
        var roots = Scanner.Normalized(folders.Select(FolderOf).OfType<string>());
        if (roots.Count == 0 || BusyWithFiles) return;
        // A scan still running is left for the folders asked for now, as on the Mac.
        AbandonScan();
        StopAnalysis();
        // What can be undone stays while the same folders are open (a rescan, a folder added back).
        if (!roots.SequenceEqual(_roots, StringComparer.OrdinalIgnoreCase))
        {
            _undo.Clear();
            _redo.Clear();
        }
        _roots = roots;
        if (!keepDestination || (_destination != null && !Directory.Exists(_destination))) _destination = null;
        Settings.Shared.Set("lastFolder", _roots[0]);
        RememberRecent(_roots);
        string name = Path.GetFileName(_roots[0].TrimEnd('\\'));
        if (name.Length == 0) name = _roots[0];
        _title.Text = _roots.Count == 1 ? name : F("%@ и ещё %@", name, Count(_roots.Count - 1, L("папка"), L("папки"), L("папок")));
        // One folder: where it is (its parent), as the Mac's subtitle; several: all of them.
        _path.Text = _roots.Count == 1 ? DisplayPath(Path.GetDirectoryName(_roots[0]) ?? _roots[0]) : string.Join("  ·  ", _roots.Select(DisplayPath));
        _path.ToolTip = string.Join("\n", _roots) + "\n\n" + L("Щёлкните, чтобы показать папки или убрать одну из разбора");
        Title = $"{_title.Text} — Photo Organizer";
        // The search was for the folder that was open.
        _search.Text = "";
        _searchTokens = [];
        _lastMessage = null;
        StartScan();
    }

    void Rescan()
    {
        if (_root == null || _busy) return;
        StopAnalysis();
        StartScan();
    }

    /// <summary>Results of searches and a chosen map place belong to the files scanned before: forgotten with them.</summary>
    void ForgetResults()
    {
        _similarItems = null;
        _objectResults = null;
        _objectStatus = "";
        _objectExample = null;
        _placeItems = null;
    }

    void RevealRoot()
    {
        string? folder = _plan?.Root ?? _root;
        if (folder != null) Process.Start(new ProcessStartInfo("explorer.exe", $"\"{folder}\"") { UseShellExecute = true });
    }

    void ShowProgress(string text, bool cancellable)
    {
        _progressText.Text = text;
        _progressBar.IsIndeterminate = true;
        _progressCancel.Visibility = cancellable ? Visibility.Visible : Visibility.Collapsed;
        _progressCancel.Content = L("Отменить");
        _pages.Content = _progressPage;
    }

    void StartScan()
    {
        ForgetResults();
        _busy = true;
        CloseViewer();
        ShowProgress(L("Поиск фото и видео…"), cancellable: true);
        // Until the scan and the recognition after it are through, the folder is opened again at the next start, and
        // both go on from where they stopped (ScanCache, RecognitionStore).
        Settings.Shared.Set("unfinishedFolders", _roots);
        var scanner = new Scanner(_roots) { DeprioritizedFolders = [Plan.SavedDuplicatesFolderName, Plan.DefaultTinyFolderName] };
        _scanner = scanner;
        UpdateUi();
        Task.Run(() => scanner.Scan((phase, done, total) => Dispatcher.BeginInvoke(() => ScanProgress(scanner, phase, done, total))))
            .ContinueWith(task => ScanDone(scanner, task.IsFaulted ? null : task.Result), TaskScheduler.FromCurrentSynchronizationContext());
    }

    void ScanProgress(Scanner scanner, ScanPhase phase, int done, int total)
    {
        if (scanner != _scanner) return;
        if (phase == ScanPhase.Enumerating)
        {
            _progressText.Text = F("Поиск фото и видео… найдено %@", Number(done));
            return;
        }
        _progressText.Text = F(phase == ScanPhase.Metadata ? "Чтение дат и размеров: %@ из %@" : "Поиск дубликатов: %@ из %@", Number(done), Number(total));
        _progressBar.IsIndeterminate = false;
        _progressBar.Maximum = Math.Max(total, 1);
        _progressBar.Value = done;
    }

    void ScanDone(Scanner scanner, List<PhotoItem>? items)
    {
        if (scanner != _scanner) return;
        _scanner = null;
        _busy = false;
        if (items == null)   // cancelled
        {
            if (_closing) return;
            Settings.Shared.Set("unfinishedFolders", null);
            Settings.Shared.Set("unfinishedFolder", null);
            if (_plan != null)
            {
                _pages.Content = _library;
                ShowSidebar();
            }
            else
            {
                _roots = [];
                ShowWelcome();
            }
            UpdateUi();
            return;
        }
        _objectFilterCounts.Clear();
        var plan = new Plan(scanner.Root, items, scanner.Roots);
        if (_destination != null) plan.SetDestination(_destination);
        plan.LoadOptions();
        plan.Rebuild();
        _plan = plan;
        _suggester = null;
        _copySets = [];
        _people = [];
        _pages.Content = _library;
        ShowSidebar();
        ReloadSidebar();
        UpdateGrid();
        StartAnalysis();
    }

    // --- Recognition --------------------------------------------------------------------------------------------

    void StopAnalysis()
    {
        _analyzer?.Cancel();
        _analyzer = null;
        _regroupTimer.Stop();
        _analysis.Text = "";
    }

    void StartAnalysis()
    {
        StopAnalysis();
        if (_plan == null) return;
        if (Analyzer.AnalyzesObjects && !Recognizer.Model.Ready)
        {
            DownloadObjectModel();
            return;
        }
        bool withFaces = SettingsDialog.GroupsFaces && FaceEngine.ModelsReady;
        var analyzer = new Analyzer(_plan.Items.ToList(), withFaces);
        _analyzer = analyzer;
        _analysis.Text = L("Распознавание…");
        Task.Run(() => analyzer.Run((done, total) => Dispatcher.BeginInvoke(() =>
            {
                if (analyzer == _analyzer && total > 0) _analysis.Text = F("Распознавание: %@ из %@", Number(done), Number(total)) + (analyzer.Device is { } device ? $" · {device}" : "");
            })))
            .ContinueWith(task =>
            {
                if (task.Exception?.GetBaseException() is { } e) analyzer.Error ??= e.Message;
                AnalysisDone(analyzer);
            }, TaskScheduler.FromCurrentSynchronizationContext());
        if (withFaces) _regroupTimer.Start();
    }

    /// <summary>
    /// What is in the pictures is recognised by MobileCLIP (45 MB), fetched from Hugging Face the first time a folder is
    /// opened — on the Mac the same comes with the system. The analysis starts when it has arrived.
    /// </summary>
    async void DownloadObjectModel()
    {
        if (_clipDownload != null) return;
        _clipDownload = new CancellationTokenSource();
        _analysis.Text = L("Загрузка модели распознавания…");
        var progress = new Progress<(long Received, long Total)>(p =>
            _analysis.Text = $"{L("Загрузка модели распознавания…")} {Strings.Size(p.Received)} / {Strings.Size(p.Total)}");
        try
        {
            await HuggingFace.DownloadAsync(Recognizer.Model, progress, _clipDownload.Token);
            _clipDownload = null;
            Recognizer.Reset();
            StartAnalysis();
        }
        catch (Exception e)
        {
            _clipDownload = null;
            _analysis.Text = e is OperationCanceledException ? "" : L("Модель распознавания объектов не загружена — «Настройки».");
            // Faces and the rest still work.
            Analyzer.AnalyzesObjects = Analyzer.AnalyzesObjects;
            if (_plan != null && e is not OperationCanceledException) StartAnalysisWithoutObjects();
        }
    }

    void StartAnalysisWithoutObjects()
    {
        bool objects = Analyzer.AnalyzesObjects;
        Analyzer.AnalyzesObjects = false;
        try { StartAnalysis(); }
        finally { Analyzer.AnalyzesObjects = objects; }
    }

    void AnalysisDone(Analyzer analyzer)
    {
        if (analyzer != _analyzer || _closing) return;
        _analyzer = null;
        _regroupTimer.Stop();
        Settings.Shared.Set("unfinishedFolders", null);
        Settings.Shared.Set("unfinishedFolder", null);
        _objectFilterCounts.Clear();   // the labels are complete now
        _analysis.Text = SettingsDialog.GroupsFaces && !FaceEngine.ModelsReady ? L("Модель лиц не загружена — «Настройки»")
            : NudityClassifier.Enabled && !NudityClassifier.Selected.Model.Ready ? L("Модель наготы не загружена — «Настройки»")
            : analyzer.Error ?? "";
        if (_plan == null) return;
        ReloadSidebar();
        UpdateGrid();
        FindCopiesInBackground();
        RegroupPeopleInBackground();
        ClassifyPicturesInBackground();
    }

    /// <summary>Pictures told from photographs with what the analysis stored (see Pictures): a second or two, on a worker.</summary>
    async void ClassifyPicturesInBackground()
    {
        var plan = _plan;
        if (plan == null) return;
        var items = plan.Items.ToList();
        HashSet<PhotoItem> pictures;
        try
        {
            pictures = await Task.Run(() => Pictures.Find(items));
        }
        catch (Exception e) when (e is IOException or InvalidOperationException or InvalidDataException)
        {
            return;
        }
        if (plan != _plan || _closing || _busy) return;
        Pictures.Apply(plan.Items, pictures);
        _objectFilterCounts.Clear();   // counted by what is shown, which depends on the kinds
        plan.Rebuild();
        ReloadSidebar();
        UpdateGrid();
    }

    /// <summary>
    /// Resized and recompressed copies: the candidates are compared pixel by pixel, which reads the files, so it runs
    /// on a worker; the result is applied here.
    /// </summary>
    async void FindCopiesInBackground()
    {
        var plan = _plan!;
        var items = plan.Items.ToList();
        string status = _analysis.Text;
        _analysis.Text = L("Поиск похожих копий…");
        List<List<PhotoItem>> sets;
        try
        {
            sets = await Task.Run(() => SimilarCopies.FindSets(items));
        }
        catch (Exception)
        {
            sets = [];
        }
        if (plan != _plan || _closing || _busy) return;
        if (_analysis.Text == L("Поиск похожих копий…")) _analysis.Text = status;
        SimilarCopies.Mark(plan.Items, sets);
        _copySets = sets;
        if (SimilarCopies.ShareDates(_copySets) > 0)
        {
            plan.SortItemsByDate();
            _suggester = null;
        }
        plan.Rebuild();
        ReloadSidebar();
        UpdateGrid();
    }

    /// <summary>
    /// After files left the library (to the Recycle Bin, dragged away): the sets of look-alikes are found again, as
    /// the Mac does, instead of only dropping the files that went. A running analysis does it when it ends.
    /// </summary>
    void RegroupCopies()
    {
        if (_plan == null || _analyzer != null || _busy) return;
        FindCopiesInBackground();
    }

    void RegroupPeople(bool update = true)
    {
        _people = _plan != null && SettingsDialog.GroupsFaces ? People.PeopleIn(_plan.Items, _people) : [];
        if (!update) return;
        ReloadSidebar();
        if (_sidebar.Selected.Kind == FilterKind.Person) UpdateGrid();
    }

    bool _regrouping, _regroupAgain;

    /// <summary>
    /// Groups the faces on a worker, as the Mac does: with tens of thousands of faces it takes seconds, and the
    /// window must not freeze for that every few seconds while the analysis runs.
    /// </summary>
    async void RegroupPeopleInBackground()
    {
        if (_plan == null || !SettingsDialog.GroupsFaces)
        {
            RegroupPeople();
            return;
        }
        if (_regrouping)
        {
            _regroupAgain = true;
            return;
        }
        _regrouping = true;
        var plan = _plan;
        var items = plan.Items.ToList();
        var previous = _people;
        List<Person> people;
        try
        {
            people = await Task.Run(() => People.PeopleIn(items, previous));
        }
        finally
        {
            _regrouping = false;
        }
        if (plan != _plan || _closing) return;
        _people = people;
        ReloadSidebar();
        if (_sidebar.Selected.Kind == FilterKind.Person) UpdateGrid();
        if (_regroupAgain)
        {
            _regroupAgain = false;
            RegroupPeopleInBackground();
        }
    }

    // --- Sidebar and grid ---------------------------------------------------------------------------------------

    Suggester Suggester => _suggester ??= new Suggester(_plan!.Items);

    void ReloadSidebar()
    {
        if (_plan == null)
        {
            _sidebar.Rebuild(false, [], []);
            return;
        }
        // Counted as shown: only the ticked kinds (the library and the type rows count everything).
        _included = Included();
        var shown = _plan.Items.Where(Shown).ToList();
        long suggested = 0, undated = 0;
        foreach (var item in shown.Where(i => i.Undated))
        {
            if (Suggester.Best(item) != null) suggested++; else undated++;
        }
        long lesser = shown.Count(i => i.BetterCopy != null && !i.Tiny);
        var counts = new Dictionary<string, long>
        {
            ["library"] = _plan.Items.Count, ["suggested"] = suggested, ["undated"] = undated,
            ["duplicates"] = _plan.DuplicateItems.Count(Shown) + lesser, ["tiny"] = _plan.TinyItems.Count(Shown),
            ["similar"] = _similarItems?.Count(Shown) ?? -1, ["located"] = shown.Count(i => i.HasLocation),
            ["screenshots"] = shown.Count(Screenshots.IsScreenshot), ["videos"] = shown.Count(i => i.Video),
            ["nudity"] = NudityClassifier.Enabled ? ExplicitItems().Count(Shown) : -1,
        };
        var objectFilters = SavedObjectFilters.Select(q => (q, ObjectFilterCount(q))).ToList();
        // Every other type found gets a row of its own.
        var found = _plan.Items.GroupBy(MediaTypes.TypeFolder).ToDictionary(g => g.Key, g => (long)g.Count());
        var types = new[] { "Записи экрана", "WhatsApp", "Telegram", "Viber", "Instagram", "Анимации", "Панорамы", "RAW", "Картинки", "Коллажи" }
            .Select(key => L(key)).Where(found.ContainsKey).Select(name => (name, found[name])).ToList();
        _sidebar.Rebuild(true, counts, SettingsDialog.GroupsFaces ? _people : [], objectFilters: objectFilters,
                         personCount: person => person.Items.Count(Shown), types: types);
    }

    static int Grouping => Math.Clamp(Settings.Shared.Get("gridGrouping", 1), 0, 2);

    /// <summary>The files the search field lets through (all of them when it is empty).</summary>
    List<PhotoItem> Searched(IEnumerable<PhotoItem> items) => _searchTokens.Length == 0 ? items.ToList()
        : items.Where(i => Labels.Matches(i, _searchTokens)).ToList();

    // Counts of the saved object filters. Recounted after an analysis, a scan, a move or a change of the filters, not on
    // every refresh of the sidebar: each count goes through the whole library.
    readonly Dictionary<string, long> _objectFilterCounts = [];
    int _objectFilterItems = -1;

    long ObjectFilterCount(string query)
    {
        if (_plan == null) return 0;
        if (_objectFilterItems != _plan.Items.Count || _analyzer != null)
        {
            _objectFilterCounts.Clear();
            _objectFilterItems = _plan.Items.Count;
        }
        if (!_objectFilterCounts.TryGetValue(query, out long count)) _objectFilterCounts[query] = count = ItemsMatching(_plan.Items.Where(Shown), query).Count;
        return count;
    }

    static List<PhotoItem> ItemsMatching(IEnumerable<PhotoItem> items, string query)
    {
        var tokens = Labels.SearchTokens(query);
        return tokens.Length == 0 ? [] : items.Where(i => Labels.Matches(i, tokens)).ToList();
    }

    /// <summary>Files the nudity model scored at or above the threshold, most confident first.</summary>
    List<PhotoItem> ExplicitItems() =>
        _plan!.Items.Where(i => i.NudityScore >= NudityClassifier.Threshold).OrderByDescending(i => i.NudityScore).ToList();

    Person? PersonWithKey(string? key) => _people.FirstOrDefault(p => p.Key == key);

    /// <summary>The files the sidebar selection stands for; null for the duplicates, which are a list of sets.</summary>
    List<PhotoItem>? ItemsFor(Filter filter) => filter.Kind switch
    {
        FilterKind.All => _plan!.Items,
        FilterKind.Undated => _plan!.Items.Where(i => i.Undated && Suggester.Best(i) == null).ToList(),
        FilterKind.Suggested => _plan!.Items.Where(i => i.Undated && Suggester.Best(i) != null).ToList(),
        FilterKind.Person => PersonWithKey(filter.Key) is { } person
            ? (Settings.Shared.Get("personAloneOnly", false) ? person.SoloItems : person.Items) : [],
        FilterKind.Similar => _similarItems ?? [],
        FilterKind.ObjectSearch => _objectResults ?? [],
        FilterKind.Object => ItemsMatching(_plan!.Items, filter.Key ?? ""),
        FilterKind.Map => _placeItems ?? _plan!.Items.Where(i => i.HasLocation).ToList(),
        FilterKind.Screenshots => _plan!.Items.Where(Screenshots.IsScreenshot).ToList(),
        FilterKind.Videos => _plan!.Items.Where(i => i.Video).ToList(),
        FilterKind.Type => _plan!.Items.Where(i => MediaTypes.TypeFolder(i) == filter.Key).ToList(),
        FilterKind.Nudity => ExplicitItems(),
        FilterKind.Tiny => _plan!.TinyItems,
        _ => null,
    };

    /// <summary>
    /// Sections by year, month or day. A file whose date is known less precisely than that goes into a section of its
    /// own ("2019") instead of a made-up month or day, and undated files close the list.
    /// </summary>
    static List<Section> SectionsByDate(List<PhotoItem> items)
    {
        int grouping = Grouping;
        var sections = new List<Section>();
        var current = new List<PhotoItem>();
        var undated = new List<PhotoItem>();
        string? currentKey = null, currentTitle = null;
        void Flush()
        {
            if (current.Count == 0) return;
            sections.Add(new Section(currentTitle!, FilesDetail(current.Count), "calendar", current.ToList()));
            current.Clear();
        }
        foreach (var item in items)
        {
            if (item.Undated)
            {
                undated.Add(item);
                continue;
            }
            int level = Math.Max(2 - grouping, (int)item.Precision);   // 0 day, 1 month, 2 year
            var date = item.Date;
            string key = level == 2 ? $"{date.Year}" : level == 1 ? $"{date.Year}-{date.Month}" : $"{date.Year}-{date.Month}-{date.Day}";
            if (key != currentKey)
            {
                Flush();
                currentKey = key;
                string title = Capitalized(level == 2 ? FormatYear(date) : level == 1 ? FormatMonth(date) : FormatDayLong(date));
                if (level > 2 - grouping) title += level == 2 ? L(" — месяц неизвестен") : L(" — день неизвестен");
                currentTitle = title;
            }
            current.Add(item);
        }
        Flush();
        if (undated.Count > 0) sections.Add(new Section(L("Без даты"), FilesDetail(undated.Count), "calendar-warning", undated));
        return sections;
    }

    /// <summary>Undated files grouped by the folder they are in, so that a whole folder can be dated at once.</summary>
    static List<Section> SectionsByFolder(List<PhotoItem> items) =>
        items.GroupBy(i => i.CurrentFolder).OrderBy(g => g.Key, NaturalComparer.Instance)
             .Select(g => new Section(g.Key.Length > 0 ? g.Key.Replace('/', '\\') : L("Корневая папка"), FilesDetail(g.Count()), "folder",
                                      g.OrderBy(i => i.Name, NaturalComparer.Instance).ToList()))
             .ToList();

    /// <summary>The undated files grouped by the rule that suggests their date, each group with a button that confirms it.</summary>
    List<Section> SectionsBySuggestion(List<PhotoItem> items)
    {
        var groups = new Dictionary<string, (Suggestion Rule, List<PhotoItem> Files)>();
        var order = new List<string>();
        foreach (var item in items)
        {
            if (Suggester.Best(item) is not { } best) continue;
            string where = best.Kind == SuggestionKind.FolderName ? item.CurrentFolder : "";
            string key = $"{(int)best.Kind}|{best.DateText}|{(int)best.Precision}|{where}";
            if (!groups.ContainsKey(key))
            {
                groups[key] = (best, []);
                order.Add(key);
            }
            groups[key].Files.Add(item);
        }
        return order.OrderBy(k => groups[k].Rule.Date).ThenBy(k => k, StringComparer.Ordinal).Select(k =>
        {
            var (rule, files) = groups[k];
            string why = rule.Kind switch
            {
                SuggestionKind.FolderName => F("лежат в папке «%@»", files[0].CurrentFolder.Split('/')[^1]),
                SuggestionKind.Neighbors => L("соседние кадры той же серии"),
                SuggestionKind.FileName => L("год в имени файла"),
                _ => rule.Reason,
            };
            return new Section($"{rule.DateText} — {why}", FilesDetail(files.Count), "calendar-clock", files, L("Подтвердить"), () => ConfirmSuggestions(files));
        }).ToList();
    }

    void UpdateGrid()
    {
        if (_plan == null)
        {
            _grid.SetSections([]);
            return;
        }
        var filter = _sidebar.Selected;
        // "Все": the ticked kinds; one kind: that kind alone, ticked or not. A type row of the sidebar shows all of its type.
        int media = _media.Selected;
        _included = Included();
        bool[] included = filter.Kind == FilterKind.Type ? [true, true, true, true] : _included;
        List<PhotoItem> Narrow(IEnumerable<PhotoItem> list) =>
            Searched(list).Where(i => media == MediaAll ? included[KindOf(i)] : KindOf(i) == media - 1).ToList();
        var baseItems = ItemsFor(filter);
        var items = baseItems != null ? Narrow(baseItems) : [];
        var sections = new List<Section>();
        string placeholder = "";
        switch (filter.Kind)
        {
            case FilterKind.All:
            case FilterKind.Person:
            case FilterKind.Object:
            case FilterKind.Map:
            case FilterKind.Screenshots:
            case FilterKind.Type:
            case FilterKind.Videos:
                sections = SectionsByDate(items);
                if (filter.Kind == FilterKind.All && _plan.Items.Count == 0) placeholder = L("В этой папке нет фото и видео");
                break;
            case FilterKind.Undated:
                sections = SectionsByFolder(items);
                placeholder = L("У всех файлов есть дата или подсказка — см. «Предполагаемые даты».");
                break;
            case FilterKind.Suggested:
                sections = SectionsBySuggestion(items);
                placeholder = L("Предположений не осталось.");
                break;
            case FilterKind.Similar:
                if (items.Count > 0) sections.Add(new Section(_similarTitle.Length > 0 ? _similarTitle : L("Похожие на фото — самые похожие в начале"), FilesDetail(items.Count), "photo-search", items));
                placeholder = _similarItems != null ? L("Ничего похожего не нашлось. Перетащите сюда другое фото.")
                                                    : L("Перетащите сюда фото предмета, места или человека — приложение найдёт похожие в этой папке.");
                break;
            case FilterKind.ObjectSearch:
                if (items.Count > 0)
                {
                    string title = _objectStatus.Length > 0 ? F("Этот предмет — самые похожие в начале (%@)", _objectStatus) : L("Этот предмет — самые похожие в начале");
                    sections.Add(new Section(title, FilesDetail(items.Count), "viewfinder", items));
                }
                placeholder = _objectStatus.Length > 0 && _objectResults is not { Count: > 0 } ? _objectStatus
                    : L("Перетащите сюда фото с предметом, выделите его рамкой — и приложение найдёт фото, где он есть. Или щёлкните фото правой кнопкой → «Найти этот предмет на других фото…».");
                break;
            case FilterKind.Nudity:
                if (items.Count > 0) sections.Add(new Section(F("Оценка модели %.0f %% и выше — проверьте глазами", (NudityClassifier.Threshold * 100).ToString("0")), FilesDetail(items.Count), "explicit", items));
                break;
            case FilterKind.Tiny:
                if (items.Count > 0) sections.Add(new Section(L("Уменьшенные копии других фото"), FilesDetail(items.Count), "thumbnails", items));
                break;
            case FilterKind.Duplicates:
                var shown = new List<PhotoItem>();
                // Resized or recompressed versions of one picture: the best one, then the lesser ones.
                foreach (var set in _copySets)
                {
                    if (Narrow(set).Count == 0) continue;
                    shown.AddRange(set);
                    sections.Add(new Section(set[0].Name, Count(set.Count - 1, L("копия хуже качеством"), L("копии хуже качеством"), L("копий хуже качеством")), "similar", set));
                }
                // One section per set: the kept original followed by its exact copies.
                foreach (var item in _plan.Items.Where(i => i.Duplicates is { Count: > 0 }))
                {
                    var set = new List<PhotoItem> { item };
                    set.AddRange(item.Duplicates!);
                    if (Narrow(set).Count == 0) continue;
                    shown.AddRange(set);
                    sections.Add(new Section(item.Name, Count(item.Duplicates!.Count, L("копия"), L("копии"), L("копий")), "duplicates", set));
                }
                baseItems = shown;
                items = Narrow(shown);
                placeholder = L("Дубликатов нет");
                break;
        }
        bool undatedView = filter.Kind is FilterKind.Undated or FilterKind.Suggested;
        // Nothing found because of the search, not because the view is empty: say so, and where else to look.
        if (_searchTokens.Length > 0 && items.Count == 0 && baseItems is { Count: > 0 })
        {
            placeholder = F("Ничего не найдено по запросу «%@».", _search.Text.Trim())
                + (filter.Kind != FilterKind.All ? " " + L("Поиск идёт только в выбранном разделе — выберите «Медиатека», чтобы искать везде.") : "")
                + (_analyzer != null ? " " + L("Распознавание ещё идёт — найдётся больше, когда оно закончится.") : "");
        }
        _grid.Placeholder = placeholder;
        _grid.AcceptsImageDrops = filter.Kind is FilterKind.Similar or FilterKind.ObjectSearch;
        _grid.ShowsNudityScores = filter.Kind == FilterKind.Nudity;
        bool mapView = filter.Kind == FilterKind.Map && _placeItems == null;
        if (_results.Content != _viewer) _results.Content = mapView ? _map : _grid;
        if (mapView) _map.SetItems(items);
        _backToMap.Visibility = filter.Kind == FilterKind.Map && _placeItems != null ? Visibility.Visible : Visibility.Collapsed;
        _pickAnother.Visibility = filter.Kind == FilterKind.ObjectSearch && _objectExample != null ? Visibility.Visible : Visibility.Collapsed;
        _solo.Visibility = filter.Kind == FilterKind.Person ? Visibility.Visible : Visibility.Collapsed;
        _solo.IsChecked = Settings.Shared.Get("personAloneOnly", false);
        _setDate.Visibility = undatedView && items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        _accept.Visibility = undatedView && items.Any(i => Suggester.Best(i) != null) ? Visibility.Visible : Visibility.Collapsed;
        _cleanup.Visibility = filter.Kind is FilterKind.Duplicates or FilterKind.Tiny && items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        _cleanup.Content = filter.Kind == FilterKind.Tiny ? L("Удалить миниатюры…") : L("Удалить дубликаты…");
        _cleanup.ToolTip = filter.Kind == FilterKind.Tiny ? L("Переместить в Корзину все миниатюры, у которых есть оригинал большего размера")
                                                          : L("Переместить в Корзину все копии, оставив в каждом наборе оригинал или файл лучшего качества");
        _byFolders.Visibility = filter.Kind == FilterKind.Duplicates && _plan.Items.Any(i => i.Duplicates is { Count: > 0 })
            ? Visibility.Visible : Visibility.Collapsed;
        _arrange.Visibility = filter.Kind is FilterKind.Screenshots or FilterKind.Type or FilterKind.Videos or FilterKind.Person or FilterKind.Object && items.Count > 0
            ? Visibility.Visible : Visibility.Collapsed;

        string gridKey = $"{filter}|{media}|{string.Concat(_included.Select(on => on ? '1' : '0'))}|{Grouping}|{string.Join(" ", _searchTokens)}";
        _grid.SetSections(sections, filter.Kind == FilterKind.Duplicates, gridKey == _lastGridKey);
        _lastGridKey = gridKey;
        // The strip counts within the selection (and the search), so "Видео 3" means three videos of this view.
        var searched = Searched(baseItems ?? []);
        var kinds = new long[4];
        foreach (var item in searched) kinds[KindOf(item)]++;
        _media.SetTicked([false, .. _included]);
        _media.SetCounts([Enumerable.Range(0, 4).Where(k => included[k]).Sum(k => kinds[k]), .. kinds]);
        UpdateUi();
    }

    void UpdateUi()
    {
        bool hasPlan = _plan != null && !_busy;
        _rescanButton.IsEnabled = _revealButton.IsEnabled = _root != null && !_busy;
        _grouping.IsEnabled = _search.IsEnabled = hasPlan;
        int pending = _plan?.PendingItems.Count ?? 0;
        // Something to do: files to put in place, or only duplicates to remove ("Удалить дубликаты").
        _organize.IsEnabled = hasPlan && (pending > 0 || _plan!.DuplicatesToRemove.Count > 0);
        // What organizing would do comes first, as on the Mac; the last message while there is nothing to do.
        _status.Text = _plan == null ? ""
            : _plan.Items.Count == 0 ? L("В этой папке нет фото и видео")
            : pending > 0 ? F(_plan.CopiesFiles ? "Будет скопировано %@ из %@" : "Будет перемещено %@ из %@", Number(pending), Number(_plan.Items.Count))
            : _lastMessage ?? L("Все файлы уже лежат на своих местах");
    }

    // --- Viewer -------------------------------------------------------------------------------------------------

    void OpenItem(PhotoItem item)
    {
        var shown = _grid.ShownItems;
        int index = shown.IndexOf(item);
        if (index < 0) return;
        _results.Content = _viewer;
        _viewer.Show(shown, index);
    }

    /// <summary>The selected file, or the first one shown when nothing is selected (Ctrl+↓, as ⌘↓ on the Mac).</summary>
    void OpenSelection()
    {
        if ((_grid.SelectedItems.FirstOrDefault() ?? _grid.ShownItems.FirstOrDefault()) is { } item) OpenItem(item);
    }

    /// <summary>Ctrl+C: the selected files to the clipboard, to paste in File Explorer or another app.</summary>
    void CopySelection()
    {
        var files = _results.Content == _viewer && _viewer.Current is { } current ? [current] : _grid.SelectedItems;
        if (files.Count == 0) return;
        var list = new System.Collections.Specialized.StringCollection();
        list.AddRange(files.Select(i => i.Path).ToArray());
        Clipboard.SetFileDropList(list);
    }

    /// <summary>File Explorer with these files selected — one window per folder.</summary>
    static void Reveal(IEnumerable<string> paths)
    {
        foreach (var folder in paths.GroupBy(p => Path.GetDirectoryName(p) ?? "", StringComparer.OrdinalIgnoreCase).Take(10))
        {
            if (SHParseDisplayName(folder.Key, IntPtr.Zero, out var folderId, 0, out _) != 0) continue;
            var ids = new List<IntPtr>();
            try
            {
                foreach (string path in folder) if (SHParseDisplayName(path, IntPtr.Zero, out var id, 0, out _) == 0) ids.Add(id);
                if (ids.Count > 0) SHOpenFolderAndSelectItems(folderId, (uint)ids.Count, ids.ToArray(), 0);
            }
            finally
            {
                foreach (var id in ids) Marshal.FreeCoTaskMem(id);
                Marshal.FreeCoTaskMem(folderId);
            }
        }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHParseDisplayName(string name, IntPtr bindContext, out IntPtr idList, uint attributesIn, out uint attributesOut);

    [DllImport("shell32.dll")]
    static extern int SHOpenFolderAndSelectItems(IntPtr folder, uint count, IntPtr[] items, uint flags);

    void CloseViewer()
    {
        if (_results.Content != _viewer) return;
        _viewer.Stop();
        var current = _viewer.Current;
        _results.Content = _grid;
        if (current != null && _grid.ShownItems.Contains(current)) Dispatcher.BeginInvoke(() => _grid.Reveal(current), DispatcherPriority.Loaded);
        _grid.Focus();
    }

    // --- Context menu -------------------------------------------------------------------------------------------

    /// <summary>The menu of the selected files, for the grid and for the viewer (there for the file on screen).</summary>
    void ItemMenu(UIElement target, Point position)
    {
        bool inViewer = target == _viewer;
        var selected = _grid.SelectedItems;
        // Searches start from one example, and "where is it in the library" is about one file.
        bool one = selected.Count == 1, example = one && !selected[0].Video;
        var menu = new ContextMenu();
        void Add(string title, Action action, bool enabled = true)
        {
            var item = new MenuItem { Header = title, IsEnabled = enabled };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        if (selected.Count > 0)
        {
            if (!inViewer) Add(L("Открыть"), OpenSelection);
            Add(L("Открыть в программе по умолчанию"), () => { foreach (var i in selected) Process.Start(new ProcessStartInfo(i.Path) { UseShellExecute = true }); });
            Add(L("Показать в Проводнике"), () => Reveal(selected.Select(i => i.Path)));
            Add(L("Скопировать путь"), () => Clipboard.SetText(string.Join(Environment.NewLine, selected.Select(i => i.Path))));
            menu.Items.Add(new Separator());
            // Only for a copy or a thumbnail: other files have no original to show.
            if (selected.Count == 1 && OriginalOf(selected[0]) is { } original) Add(L("Показать оригинал"), () => { CloseViewer(); ShowInLibrary(original); });
            // Greyed in the library itself, which is where it would lead.
            Add(L("Показать в медиатеке по дате"), () => { CloseViewer(); ShowInLibrary(selected[0]); }, one && (_sidebar.Selected.Kind != FilterKind.All || inViewer));
            Add(L("Задать дату…"), SetDateForSelection, !_busy);
            Add(L("Найти похожие"), () => SearchByPhoto(selected[0].Path, searchWhenReady: true), example);
            Add(L("Найти этот предмет на других фото…"), () => FindObjectIn(selected[0].Path), example);
            if (one && selected[0].Faces is { Count: > 0 }) Add(L("Найти этого человека"), () => SearchByFace(selected[0].Faces![0]));
            menu.Items.Add(new Separator());
            // Files that move away leave the viewer for the grid.
            Add(L("Переместить в папку…"), () => { CloseViewer(); MoveSelectionToFolder(); }, !_busy);
            Add(L("Переместить в Корзину"), TrashSelection, !_busy);
        }
        else
        {
            Add(L("Выбрать всё"), _grid.SelectAll);
            if (_grid.ShownItems.Count > 0) Add(L("Переместить показанное в папку…"), MoveShownToFolder, !_busy);
        }
        menu.PlacementTarget = target;
        menu.Placement = PlacementMode.RelativePoint;
        menu.HorizontalOffset = position.X;
        menu.VerticalOffset = position.Y;
        menu.IsOpen = true;
    }

    /// <summary>Leaves a search or a person for the library, scrolled to the file among the others of its date.</summary>
    /// <summary>
    /// The file `item` is a copy of: the original of an exact copy, the best version of a look-alike (for a thumbnail,
    /// its larger version); null for anything else.
    /// </summary>
    static PhotoItem? OriginalOf(PhotoItem item)
    {
        var original = item.DuplicateOf ?? item.BetterCopy;
        // An exact copy of a lesser copy: the best version, not the lesser one.
        return original?.BetterCopy ?? original;
    }

    void ShowInLibrary(PhotoItem item)
    {
        if (_searchTokens.Length > 0)
        {
            _search.Text = "";
            _searchTokens = [];
        }
        // Under "Все" if its kind is ticked, else among its own kind.
        int kind = KindOf(item);
        _media.Selected = Included()[kind] ? MediaAll : MediaAll + 1 + kind;
        Settings.Shared.Set("mediaKind", _media.Selected);
        _sidebar.Select(new Filter(FilterKind.All));
        UpdateGrid();
        Dispatcher.BeginInvoke(() => _grid.Reveal(item), DispatcherPriority.Loaded);
    }

    // --- Dates --------------------------------------------------------------------------------------------------

    void DatesDidChange()
    {
        _suggester = null;
        _plan!.SortItemsByDate();
        _plan.Rebuild();
        ReloadSidebar();
        UpdateGrid();
    }

    void ConfirmSuggestions(List<PhotoItem> files)
    {
        foreach (var item in files)
        {
            if (Suggester.Best(item) is { } best) ManualDates.SetDate(best.Date, best.Precision, [item]);
        }
        _lastMessage = F("Дата подтверждена: %@.", FilesDetail(files.Count));
        DatesDidChange();
    }

    void SetDateForSelection()
    {
        if (_plan == null) return;
        var items = _grid.SelectedItems.Count > 0 ? _grid.SelectedItems : _grid.ShownItems;
        if (items.Count == 0) return;
        // Suggestions every chosen file shares, so that one click can date a whole folder; the file date only for one file.
        var suggestions = Suggester.SuggestionsFor(items[0])
            .Where(candidate => (items.Count == 1 || candidate.Kind != SuggestionKind.FileDate)
                                && items.Skip(1).All(item => Suggester.SuggestionsFor(item).Any(other => other.SameAs(candidate))))
            .ToList();
        var dialog = new DateDialog(this, items, suggestions);
        if (dialog.ShowDialog() != true) return;
        if (dialog.Outcome == DateDialog.Remove) ManualDates.SetDate(null, Precision.Day, items);
        else if (dialog.Result() is { } result) ManualDates.SetDate(result.Date, result.Precision, items);
        _lastMessage = null;
        DatesDidChange();
    }

    void AcceptSuggestions()
    {
        // The selected files, or all those shown, as on the Mac.
        var items = _grid.SelectedItems.Count > 0 ? _grid.SelectedItems : _grid.ShownItems;
        var dated = items.Select(i => (Item: i, Best: Suggester.Best(i))).Where(p => p.Best != null).ToList();
        if (dated.Count == 0) return;
        var lines = new List<string>();
        foreach (var (kind, name) in new[] { (SuggestionKind.Neighbors, L("по соседним файлам")), (SuggestionKind.FileName, L("по имени файла")), (SuggestionKind.FolderName, L("по названию папки")) })
        {
            int n = dated.Count(p => p.Best!.Kind == kind);
            if (n > 0) lines.Add($"• {name}: {FilesDetail(n)}");
        }
        if (items.Count > dated.Count) lines.Add(F("• без подсказки, останутся без даты: %@", FilesDetail(items.Count - dated.Count)));
        string message = F("Дать дату %@ по подсказкам?", Count(dated.Count, L("файлу"), L("файлам"), L("файлам"))) + "\n\n" + string.Join("\n", lines)
            + L("\n\nДата из папки или от соседей — догадка: год (или месяц) будет указан без дня. Её можно поменять в любой момент, сами файлы не изменяются.");
        if (MessageBox.Show(this, message, L("Принять подсказки…").TrimEnd('…'), MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
        foreach (var (item, best) in dated) ManualDates.SetDate(best!.Date, best.Precision, [item]);
        _lastMessage = F("Дата подтверждена: %@.", FilesDetail(dated.Count));
        DatesDidChange();
    }

    // --- Organizing and moving ----------------------------------------------------------------------------------

    void Organize()
    {
        if (_plan == null || _busy) return;
        // For organizing by person: files in which exactly one named person was recognised.
        var names = new Dictionary<PhotoItem, string>();
        var crowded = new HashSet<PhotoItem>();
        foreach (var person in _people.Where(p => p.Named))
        {
            foreach (var item in person.Items)
            {
                if (crowded.Contains(item)) continue;
                if (!names.TryAdd(item, person.DisplayName))
                {
                    names.Remove(item);
                    crowded.Add(item);
                }
            }
        }
        _plan.PersonNames = names;
        _plan.Rebuild();
        var dialog = new OrganizeDialog(this, _plan, () => { _lastMessage = null; ReloadSidebar(); UpdateGrid(); });
        bool confirmed = dialog.ShowDialog() == true;
        // The destination chosen stays for this library (until another folder set is opened).
        _destination = string.Equals(_plan.Root, _root, StringComparison.OrdinalIgnoreCase) ? null : _plan.Root;
        // Duplicates go to the Recycle Bin once the rest is in place ("Удалить дубликаты").
        var duplicates = _plan.DuplicatesToRemove;
        if (confirmed) RunMoves(progress => Organizer.ApplyPlan(_plan, progress), copying: _plan.CopiesFiles, then: () => TrashDuplicates(duplicates));
    }

    string? AskFolder(List<PhotoItem> items)
    {
        string suggested = _sidebar.Selected.Kind == FilterKind.Person ? PersonWithKey(_sidebar.Selected.Key)?.DisplayName ?? "" : "";
        string? name = PromptDialog.Ask(this, F("Переместить %@ в папку", Count(items.Count, L("файл"), L("файла"), L("файлов"))),
            F("Папка будет создана внутри «%@»; можно указать вложенную: «Люди/Мама».", Path.GetFileName(_root!.TrimEnd('\\'))), suggested);
        return name == null ? null : Plan.SanitizedFolderPath(name);
    }

    void MoveSelectionToFolder() => MoveToFolder(_grid.SelectedItems);
    void MoveShownToFolder() => MoveToFolder(_grid.ShownItems);

    void MoveToFolder(List<PhotoItem> items)
    {
        if (_busy || _plan == null || items.Count == 0) return;
        if (AskFolder(items) is not { } folder) return;
        // Put there by hand: organizing by date leaves the folder alone from now on.
        _plan.KeepFolder(folder);
        RunMoves(progress => Organizer.MoveItemsToFolder(items, folder, _plan.Root, progress));
    }

    /// <summary>
    /// "Разложить…" of a section — screenshots, videos, a person, an object: everything shown into one folder named
    /// after it, together or by year, month or day inside. The folder is kept out of organizing by date afterwards.
    /// </summary>
    void ArrangeShown()
    {
        if (_busy || _plan == null) return;
        var items = _grid.ShownItems.ToList();
        if (items.Count == 0) return;
        var filter = _sidebar.Selected;
        string name = filter.Kind switch
        {
            FilterKind.Screenshots => L("Скриншоты"),
            FilterKind.Type => filter.Key ?? "",
            FilterKind.Videos => L("Видео"),
            FilterKind.Person => PersonWithKey(filter.Key)?.DisplayName ?? "",
            _ => filter.Key ?? "",
        };
        var dialog = new ArrangeDialog(this, items, name, _plan.Root);
        if (dialog.ShowDialog() != true) return;
        var layout = dialog.Layout;
        var plan = _plan;
        if (dialog.Copies)
        {
            // Into any folder, an archive by years elsewhere included: its folders are filled up, nothing is replaced.
            string destination = dialog.Destination;
            string folder = Plan.SanitizedFolderPath(dialog.FolderName) ?? "";
            if (folder.Length > 0 && string.Equals(destination.TrimEnd('\\'), plan.Root.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) plan.KeepFolder(folder);
            var existing = Organizer.IntoExistingYearFolders(destination);
            bool skip = dialog.SkipCopies;
            var cancel = _copyCancel = new CancellationTokenSource();
            RunMoves(progress => Organizer.CopyItems(items, destination,
                                                     item => existing(plan.SectionFolder(item, folder, layout).Trim('/')), progress, skip, cancel.Token),
                     copying: true, stoppable: true);
            return;
        }
        if (Plan.SanitizedFolderPath(dialog.FolderName) is not { } kept) return;
        plan.KeepFolder(kept);
        RunMoves(progress => Organizer.MoveItems(items, plan.Root, item => plan.SectionFolder(item, kept, layout), progress));
    }

    /// <summary>The duplicates organizing removes: only those whose original (or best version) is still there on the disk.</summary>
    void TrashDuplicates(List<PhotoItem> duplicates)
    {
        var doomed = duplicates.ToHashSet();
        var safe = duplicates.Where(item =>
        {
            var keeper = item.DuplicateOf ?? item.BetterCopy;
            if (keeper != null && doomed.Contains(keeper)) keeper = keeper.BetterCopy is { } best && !doomed.Contains(best) ? best : null;
            return keeper != null && StillThere(keeper) && File.Exists(item.Path);
        }).ToList();
        if (safe.Count > 0) Trash(safe);
    }

    void RunMoves(Func<Action<int, int>, OrganizeResult> work, bool copying = false, bool stoppable = false, Action? then = null)
    {
        _busy = true;
        StopAnalysis();
        CloseViewer();
        ShowProgress(copying ? L("Копирование файлов…") : L("Перемещение файлов…"), cancellable: stoppable);
        _progressCancel.Content = stoppable ? L("Остановить") : L("Отменить");
        UpdateUi();
        string root = _plan!.Root;
        Task.Run(() => work((done, total) => Dispatcher.BeginInvoke(() =>
            {
                _progressText.Text = F(copying ? "Копирование файлов: %@ из %@" : "Перемещение файлов: %@ из %@", Number(done), Number(total));
                _progressBar.IsIndeterminate = false;
                _progressBar.Maximum = Math.Max(total, 1);
                _progressBar.Value = done;
            })))
            .ContinueWith(task => { MoveDone(task.Result, root); then?.Invoke(); }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    void ApplyMoves(List<MoveRecord> records)
    {
        _objectFilterCounts.Clear();
        _plan!.ItemsMoved(records.Select(r => (r.From, r.To)));
        foreach (var record in records) _thumbnails.Forget(record.From);
        _suggester = null;
        _plan.Rebuild();
    }

    /// <summary>Whether `path` lies in one of the library's folders (so that a rescan finds it).</summary>
    bool InLibrary(string path) =>
        _roots.Any(r => path.StartsWith(r.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase));

    void MoveDone(OrganizeResult result, string root)
    {
        _busy = false;
        Organizer.WriteJournal(result, root);
        if (result.IsCopy)
        {
            CopyDone(result);
            return;
        }
        ApplyMoves(result.Records);
        if (result.Records.Count > 0)
        {
            _undo.Push(result);
            _redo.Clear();
        }
        int n = result.Records.Count;
        // The way back only when there is something to undo.
        _lastMessage = n > 0
            ? F("Готово: %@ %@. Отменить — ⌘Z", Plural(n, L("перемещён"), L("перемещено"), L("перемещено")), Count(n, L("файл"), L("файла"), L("файлов"))).Replace("⌘Z", "Ctrl+Z")
            : F("Готово: %@ %@.", Plural(n, L("перемещён"), L("перемещено"), L("перемещено")), Count(n, L("файл"), L("файла"), L("файлов")));
        _pages.Content = _library;
        ReloadSidebar();
        UpdateGrid();
        ShowErrors(result.Errors, L("Не все файлы удалось переместить"));
        StartAnalysis();
    }

    /// <summary>
    /// The originals did not move, so the library in memory stays as it is; copies made inside the library's folders
    /// are picked up by a rescan.
    /// </summary>
    void CopyDone(OrganizeResult result)
    {
        _copyCancel = null;
        if (result.Records.Count > 0)
        {
            _undo.Push(result);
            _redo.Clear();
        }
        int n = result.Records.Count;
        _lastMessage = n > 0
            ? F("Готово: %@ %@. Отменить — ⌘Z", Plural(n, L("скопирован"), L("скопировано"), L("скопировано")), Count(n, L("файл"), L("файла"), L("файлов"))).Replace("⌘Z", "Ctrl+Z")
            : F("Готово: %@ %@.", Plural(n, L("скопирован"), L("скопировано"), L("скопировано")), Count(n, L("файл"), L("файла"), L("файлов")));
        if (result.AlreadyCopied > 0) _lastMessage += ". " + F("Пропущено — уже есть в папке назначения или это другой вариант того же снимка: %@.", Number(result.AlreadyCopied));
        if (result.Stopped) _lastMessage = L("Копирование остановлено.") + " " + _lastMessage;
        _pages.Content = _library;
        ShowErrors(result.Errors, L("Не все файлы удалось скопировать"));
        if (result.Records.Any(r => InLibrary(r.To)))
        {
            Rescan();
            return;
        }
        UpdateUi();
        StartAnalysis();
    }

    void Undo() => Revert(_undo, _redo);
    void Redo() => Revert(_redo, _undo);

    void Revert(Stack<OrganizeResult> source, Stack<OrganizeResult> target)
    {
        if (BusyWithFiles || source.Count == 0 || _plan == null) return;
        // A scan running meanwhile is stopped, as on the Mac, and done again once the files are back.
        bool rescan = _scanner != null;
        AbandonScan();
        var result = source.Pop();
        _busy = true;
        StopAnalysis();
        CloseViewer();
        ShowProgress(L("Возвращаем файлы на место…"), cancellable: false);
        UpdateUi();
        Task.Run(() => Organizer.Revert(result)).ContinueWith(task =>
        {
            _busy = false;
            var (errors, moves, recycled) = task.Result;
            if (result.IsCopy)
            {
                // Copies went to the Recycle Bin, the originals were never touched: nothing to redo.
                _lastMessage = F("Копии перемещены в Корзину: %@.", Count(recycled, L("файл"), L("файла"), L("файлов")));
                _pages.Content = _library;
                ShowErrors(errors, L("Не все копии удалось убрать"));
                if (rescan || result.Records.Any(r => InLibrary(r.To)))
                {
                    Rescan();
                    return;
                }
                UpdateUi();
                StartAnalysis();
                return;
            }
            ApplyMoves(moves);
            if (moves.Count > 0) target.Push(new OrganizeResult { Records = moves });
            _lastMessage = F("Готово: %@ %@.", Plural(moves.Count, L("перемещён"), L("перемещено"), L("перемещено")), Count(moves.Count, L("файл"), L("файла"), L("файлов")));
            _pages.Content = _library;
            ReloadSidebar();
            UpdateGrid();
            ShowErrors(errors, L("Не все файлы удалось вернуть"));
            if (rescan) Rescan();
            else StartAnalysis();
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    void ShowErrors(List<string> errors, string title)
    {
        if (errors.Count == 0) return;
        string text = string.Join("\n", errors.Take(12));
        if (errors.Count > 12) text += F("\n… и ещё %@", Number(errors.Count - 12));
        MessageBox.Show(this, text, title, MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    // --- Recycle Bin --------------------------------------------------------------------------------------------

    static void Recycle(IEnumerable<string> paths) => Organizer.Recycle(paths);

    /// <summary>
    /// The selected files to the Recycle Bin, without asking, as on the Mac: they can be restored from there. In the
    /// viewer it is the file on screen, and the viewer goes on to the next one.
    /// </summary>
    void TrashSelection()
    {
        if (_busy || _plan == null) return;
        if (_results.Content == _viewer)
        {
            if (_viewer.Current is { } current) Trash([current]);
            return;
        }
        Trash(_grid.SelectedItems);
    }

    /// <summary>
    /// A few files go to the Recycle Bin at once; thousands of duplicates on a worker, a hundred per shell call. The
    /// library stays on screen meanwhile, with the progress in the status line.
    /// </summary>
    void Trash(List<PhotoItem> items, List<string>? folders = null)
    {
        if (_plan == null || items.Count == 0) return;
        // More than the Recycle Bin holds: Windows would delete the rest for good without asking — said first.
        foreach (var disk in items.GroupBy(i => Path.GetPathRoot(i.Path) ?? "", StringComparer.OrdinalIgnoreCase))
        {
            long size = disk.Sum(i => i.FileSize);
            if (Organizer.RecycleBinRoom(disk.Key) is { } room && size > room
                && MessageBox.Show(this, F("В Корзине диска %@ осталось места на %@, а удаляется %@. То, что не поместится, Windows удалит навсегда — вернуть это из Корзины будет нельзя (или вытеснит из Корзины удалённое раньше).\n\nПродолжить? Можно отменить и удалять частями, очищая Корзину между ними.",
                                     disk.Key.TrimEnd('\\'), Strings.Size(room), Strings.Size(size)),
                                   L("Корзина переполнится"), MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK)
            {
                return;
            }
        }
        // Folders that go whole take the files inside them along.
        folders ??= [];
        var paths = folders.Concat(items.Select(i => i.Path)
                                        .Where(path => !folders.Any(f => path.StartsWith(f.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase))))
                           .ToList();
        if (paths.Count <= 20)
        {
            Mouse.OverrideCursor = Cursors.Wait;
            try { Recycle(paths); }
            finally { Mouse.OverrideCursor = null; }
            TrashDone(items, items.Select(i => !File.Exists(i.Path)).ToList());
            return;
        }
        _busy = true;
        UpdateUi();
        _status.Text = L("Перемещение в Корзину…");
        Task.Run(() =>
        {
            for (int start = 0; start < paths.Count; start += 100)
            {
                Recycle(paths.Skip(start).Take(100));
                int done = Math.Min(start + 100, paths.Count);
                Dispatcher.BeginInvoke(() => _status.Text = F("Перемещение в Корзину: %@ из %@", Number(done), Number(paths.Count)));
            }
            // What is no longer there went to the Recycle Bin; the rest could not be moved.
            return items.Select(i => !File.Exists(i.Path)).ToList();
        }).ContinueWith(task => TrashDone(items, task.IsFaulted ? items.Select(_ => false).ToList() : task.Result),
                        TaskScheduler.FromCurrentSynchronizationContext());
    }

    void TrashDone(List<PhotoItem> items, List<bool> removed)
    {
        _busy = false;
        // The viewer stays where it was: on the file that came after the one that went to the Recycle Bin.
        int viewerIndex = _results.Content == _viewer && _viewer.Current is { } shown ? _grid.ShownItems.IndexOf(shown) : -1;
        var trashed = new List<PhotoItem>();
        var errors = new List<string>();
        for (int i = 0; i < items.Count; i++)
        {
            if (removed[i])
            {
                trashed.Add(items[i]);
                _thumbnails.Forget(items[i].Path);
            }
            else
            {
                errors.Add($"{items[i].RelativePath.Replace('/', '\\')}: {Organizer.WhyNotRecycled(items[i].Path)}");
            }
        }
        RemoveFromLibrary(trashed);
        _lastMessage = F("В Корзине: %@. Вернуть можно из Корзины.", Count(trashed.Count, L("файл"), L("файла"), L("файлов")));
        ReloadSidebar();
        UpdateGrid();
        if (viewerIndex >= 0)
        {
            var left = _grid.ShownItems;
            if (left.Count == 0) CloseViewer();
            else if (trashed.Count > 0) _viewer.Show(left, Math.Min(viewerIndex, left.Count - 1));
        }
        ShowErrors(errors, L("Не все файлы удалось переместить в Корзину"));
        if (trashed.Count > 0) RegroupCopies();
    }

    /// <summary>
    /// Whether the file that stays for a copy is still the one the scan saw: there, and of the same size. Only then
    /// does the copy go to the Recycle Bin — never the last version of a picture.
    /// </summary>
    static bool StillThere(PhotoItem keeper)
    {
        var info = new FileInfo(keeper.Path);
        return info.Exists && info.Length == keeper.FileSize;
    }

    /// <summary>Takes files that are gone (to the Recycle Bin, or moved away by another app) out of every list.</summary>
    void RemoveFromLibrary(List<PhotoItem> removed)
    {
        var gone = removed.ToHashSet();
        foreach (var item in removed) _thumbnails.Forget(item.Path);
        _plan!.RemoveItems(removed);
        _copySets = _copySets.Select(s => s.Where(i => !gone.Contains(i)).ToList()).Where(s => s.Count > 1).ToList();
        foreach (var item in _plan.Items.Where(i => i.BetterCopy != null && gone.Contains(i.BetterCopy)))
        {
            item.BetterCopy = null;
            item.Tiny = false;
        }
        _similarItems = _similarItems?.Where(i => !gone.Contains(i)).ToList();
        _objectResults = _objectResults?.Where(i => !gone.Contains(i)).ToList();
        _placeItems = _placeItems?.Where(i => !gone.Contains(i)).ToList();
        foreach (var person in _people)
        {
            person.Items = person.Items.Where(i => !gone.Contains(i)).ToList();
            person.SoloItems = person.SoloItems.Where(i => !gone.Contains(i)).ToList();
        }
        _suggester = null;
        _plan.Rebuild();
    }

    void RemoveDuplicates()
    {
        if (_plan == null || _busy) return;
        bool tinyView = _sidebar.Selected.Kind == FilterKind.Tiny;
        // Only copies whose better version stays.
        var victims = tinyView
            ? _plan.TinyItems.Where(i => i.BetterCopy != null || i.DuplicateOf != null).ToList()
            : _plan.Items.Where(i => i.DuplicateOf != null || (i.BetterCopy != null && !i.Tiny)).ToList();
        // Never the last copy of anything: a file whose better version is itself going away stays, and so does one
        // whose original is no longer on the disk.
        var doomed = victims.ToHashSet();
        victims = victims.Where(i =>
        {
            var keeper = i.DuplicateOf ?? i.BetterCopy;
            if (keeper != null && doomed.Contains(keeper)) keeper = keeper.BetterCopy is { } best && !doomed.Contains(best) ? best : null;
            return keeper != null && StillThere(keeper);
        }).ToList();
        if (victims.Count == 0) return;
        string freed = Strings.Size(victims.Sum(i => i.FileSize));
        string title = tinyView
            ? F("Переместить %@ в Корзину?", Count(victims.Count, L("миниатюра"), L("миниатюры"), L("миниатюр")))
            : F("Переместить %@ в Корзину?", Count(victims.Count, L("дубликат"), L("дубликата"), L("дубликатов")));
        // The Mac's wording, and buttons that say what they do.
        string text = tinyView
            ? F("У каждой миниатюры в папке есть оригинал большего размера — он останется. Освободится %@. Файлы попадут в Корзину, откуда их можно вернуть.", freed)
            : F("В каждом наборе останется один файл: оригинал у точных копий и версия с наибольшим разрешением (при равном — с большим размером файла) у похожих. Освободится %@. Файлы попадут в Корзину, откуда их можно вернуть.", freed);
        if (ConfirmDialog.Ask(this, title, text, L("Переместить в Корзину"))) Trash(victims);
    }

    /// <summary>Exact copies cleaned up folder by folder: for each group of folders the user picks the one that stays.</summary>
    void RemoveDuplicatesByFolder()
    {
        if (_plan == null || _busy) return;
        var sets = _plan.Items.Where(i => i.Duplicates is { Count: > 0 }).Select(i => new List<PhotoItem> { i }.Concat(i.Duplicates!).ToList()).ToList();
        if (sets.Count == 0) return;
        var dialog = new FolderDuplicatesDialog(this, sets);
        if (dialog.ShowDialog() == true && dialog.Victims() is { Count: > 0 } victims) Trash(victims, dialog.FoldersToRemove());
    }

    // --- People and search by face ------------------------------------------------------------------------------

    void RenamePerson(Person person)
    {
        string? name = PromptDialog.Ask(this, L("Как зовут этого человека?"),
            L("Имя запомнится вместе с лицом: человек будет узнан и в других папках. Пустое имя — забыть."), person.Named ? person.DisplayName : "", person.DisplayName);
        if (name == null) return;
        People.SetName(name, person);
        var selected = _sidebar.Selected;
        RegroupPeople(update: false);
        if (selected.Kind == FilterKind.Person && selected.Key == person.Key && name.Trim().Length > 0
            && _people.FirstOrDefault(p => p.DisplayName == name.Trim()) is { } renamed)
        {
            _sidebar.Select(new Filter(FilterKind.Person, renamed.Key));
        }
        ReloadSidebar();
        UpdateGrid();
    }

    // --- Search by photo, by object and by face -----------------------------------------------------------------

    /// <summary>The search-by-photo panel, with the example described in words; with `searchWhenReady` it searches at once.</summary>
    void SearchByPhoto(string? path, bool searchWhenReady = false)
    {
        if (_photoSearch == null)
        {
            _photoSearch = new PhotoSearchWindow(this);
            _photoSearch.SearchRequested += (vector, labels, face) =>
            {
                if (face != null) SearchByFace(face);
                else FindSimilar(vector, labels);
            };
        }
        _photoSearch.Show();
        _photoSearch.Activate();
        if (path != null) _photoSearch.Load(path, searchWhenReady);
    }

    void ShowSimilar(List<PhotoItem> results, string title)
    {
        _similarItems = results;
        _similarTitle = title;
        if (_results.Content == _viewer) CloseViewer();
        _sidebar.Select(new Filter(FilterKind.Similar));
        ReloadSidebar();
        UpdateGrid();
    }

    async void FindSimilar(float[] vector, List<string> labels)
    {
        if (_plan == null || _busy)
        {
            _photoSearch?.SetStatus(L("Сначала откройте папку с фото."), false);
            return;
        }
        int generation = ++_searchGeneration;
        _photoSearch?.SetStatus(L("Подбираем кандидатов по словам…"), true);
        var items = _plan.Items.ToList();
        var (results, indexed, photos) = await Task.Run(() => (Search.Similar(vector, labels, items), Search.CountIndexed(items), items.Count(i => !i.Video)));
        if (generation != _searchGeneration) return;
        // Only files already analysed can be found: how many are not yet is said.
        string status = results.Count > 0 ? F("Найдено: %@. Результаты — в разделе «Похожие на фото».", Number(results.Count))
                                          : L("Ничего похожего не нашлось. Попробуйте снять часть галочек.");
        if (indexed < photos) status += " " + Capitalized(F("подготовлено %@ из %@ фото — остальные ещё анализируются, повторите поиск позже", Number(indexed), Number(photos))) + ".";
        _photoSearch?.SetStatus(status, false);
        ShowSimilar(results, "");
    }

    /// <summary>The photos someone with this face is in, most alike first — shown with the results of search by photo.</summary>
    async void SearchByFace(byte[] face)
    {
        if (_plan == null) return;
        var items = _plan.Items.ToList();
        var found = await Task.Run(() => People.ItemsWithFace(items, face));
        ShowSimilar(found.Select(f => f.Item).ToList(), L("Этот человек — самые похожие в начале"));
    }

    /// <summary>Opens the example for the user to frame the object, then searches.</summary>
    async void FindObjectIn(string path)
    {
        if (_plan == null) return;
        var picture = await Task.Run(() => Images.Load(path, 1600));
        if (picture == null)
        {
            System.Media.SystemSounds.Beep.Play();
            return;
        }
        var picker = new ObjectPickerDialog(this, picture, null);
        if (picker.ShowDialog() != true || picker.Selection is not { } rect) return;
        if (!Recognizer.Model.Ready)
        {
            _objectStatus = L("Модель распознавания объектов не загружена — «Настройки».");
            _sidebar.Select(new Filter(FilterKind.ObjectSearch));
            UpdateGrid();
            return;
        }
        _objectExample = path;
        _objectResults = null;
        _objectStatus = L("Ищем…");
        _sidebar.Select(new Filter(FilterKind.ObjectSearch));
        if (_results.Content == _viewer) CloseViewer();
        UpdateGrid();
        int generation = ++_searchGeneration;
        var items = _plan.Items.ToList();
        var (results, indexed, photos) = await Task.Run(() =>
        {
            // The frame, a little wider, as the query.
            double margin = 0.04;
            var region = (Math.Max(0, rect.X - rect.Width * margin), Math.Max(0, rect.Y - rect.Height * margin),
                          Math.Min(picture.Width, rect.Width * (1 + 2 * margin)), Math.Min(picture.Height, rect.Height * (1 + 2 * margin)));
            var query = Recognizer.Shared.Embed(picture, [region])[0];
            // The example photo itself would always come first.
            var found = Search.Nearest(query, items).Where(i => !string.Equals(i.Path, path, StringComparison.OrdinalIgnoreCase)).ToList();
            return (found, Search.CountIndexed(items), items.Count(i => !i.Video));
        });
        if (generation != _searchGeneration) return;
        _objectResults = results;
        _objectStatus = indexed == 0 ? L("Фото ещё анализируются — поиск по предметам заработает, когда анализ пройдёт хотя бы часть папки.")
            : indexed < photos ? F("подготовлено %@ из %@ фото — остальные ещё анализируются, повторите поиск позже", Number(indexed), Number(photos)) : "";
        UpdateGrid();
    }

    // --- Search words and object filters ------------------------------------------------------------------------

    /// <summary>What was recognised most often in this folder: (name, files) pairs, most frequent first.</summary>
    List<(string Name, int Count)> CommonLabelNames(int limit)
    {
        var counts = new Dictionary<string, int>();
        foreach (var item in _plan?.Items ?? [])
        {
            // Synonymous labels count once per file.
            foreach (string name in (item.Labels?.Keys ?? Enumerable.Empty<string>()).Select(Labels.DisplayName).Distinct())
                counts[name] = counts.GetValueOrDefault(name) + 1;
        }
        return counts.OrderByDescending(p => p.Value).ThenBy(p => p.Key, NaturalComparer.Instance).Take(limit).Select(p => (p.Key, p.Value)).ToList();
    }

    /// <summary>Lists what was recognised most often, because the recogniser knows a fixed set of words the user can't guess.</summary>
    void SearchSuggestions(FrameworkElement anchor)
    {
        var common = CommonLabelNames(30);
        if (common.Count == 0) return;
        var menu = new ContextMenu { PlacementTarget = anchor, Placement = PlacementMode.Bottom };
        menu.Items.Add(new MenuItem { Header = L("Чаще всего на снимках"), IsEnabled = false });
        foreach (var (name, count) in common)
        {
            var item = new MenuItem { Header = $"{name} — {Number(count)}" };
            item.Click += (_, _) => _search.Text = name;
            menu.Items.Add(item);
        }
        menu.IsOpen = true;
    }

    static List<string> SavedObjectFilters => Settings.Shared.GetList("objectFilters");

    void AddObjectFilter(string query)
    {
        query = query.Trim();
        if (query.Length == 0) return;
        var filters = SavedObjectFilters;
        if (!filters.Contains(query)) filters.Add(query);
        Settings.Shared.Set("objectFilters", filters);
        CloseViewer();
        ReloadSidebar();
        _sidebar.Select(new Filter(FilterKind.Object, query));
        UpdateGrid();
    }

    /// <summary>The "+" offers what was actually recognised in this folder, most frequent first, plus free text.</summary>
    void AddObjectFilterMenu(FrameworkElement anchor)
    {
        var menu = new ContextMenu { PlacementTarget = anchor, Placement = PlacementMode.Bottom };
        var saved = SavedObjectFilters;
        foreach (var (name, count) in CommonLabelNames(40).Where(c => !saved.Contains(c.Name)))
        {
            var item = new MenuItem { Header = $"{name} — {Number(count)}" };
            item.Click += (_, _) => AddObjectFilter(name);
            menu.Items.Add(item);
        }
        if (menu.Items.Count > 0) menu.Items.Add(new Separator());
        var other = new MenuItem { Header = L("Другое…") };
        other.Click += (_, _) =>
        {
            if (PromptDialog.Ask(this, L("Новый фильтр по объектам"),
                    L("Слова, как в поиске: «собака», «море закат». Фильтр покажет файлы, где распознано всё перечисленное.")) is { } query) AddObjectFilter(query);
        };
        menu.Items.Add(other);
        menu.IsOpen = true;
    }

    void RemoveObjectFilter(string query)
    {
        var filters = SavedObjectFilters;
        filters.Remove(query);
        Settings.Shared.Set("objectFilters", filters);
        bool wasSelected = _sidebar.Selected == new Filter(FilterKind.Object, query);
        ReloadSidebar();
        if (wasSelected) UpdateGrid();
    }

    // --- Settings -----------------------------------------------------------------------------------------------

    /// <summary>What the analysis depends on: when none of it changes in the settings, a running analysis goes on.</summary>
    static string AnalysisSettings() => string.Join("|", SettingsDialog.GroupsFaces, FaceEngine.ModelsReady, Analyzer.AnalyzesObjects,
        Recognizer.Model.Ready, NudityClassifier.Enabled, NudityClassifier.Selected.Model.Repo, NudityClassifier.Selected.Model.Ready, FaceEngine.UseGpu);

    void ShowSettings()
    {
        string before = AnalysisSettings();
        var dialog = new SettingsDialog(this);
        dialog.ShowDialog();
        if (_plan == null || _busy) return;
        if (!SettingsDialog.GroupsFaces) _people = [];
        // People were turned on, or the models arrived: look at the photos again (results already found are kept).
        // After "Распознать заново" everything is looked at anew.
        if (AnalysisSettings() != before || dialog.ResultsCleared)
        {
            _objectFilterCounts.Clear();
            StartAnalysis();
        }
        ReloadSidebar();
        UpdateGrid();
    }

    // --- Keys and drops -----------------------------------------------------------------------------------------

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        // Esc stops what the progress page shows, as its button does.
        if (e.Key == Key.Escape && _pages.Content == _progressPage && _progressCancel.Visibility == Visibility.Visible)
        {
            _scanner?.Cancel();
            _copyCancel?.Cancel();
            e.Handled = true;
            return;
        }
        if (e.Key == Key.Escape && _results.Content == _viewer)
        {
            CloseViewer();
            e.Handled = true;
            return;
        }
        if (e.Key == Key.Up && Keyboard.Modifiers == ModifierKeys.Control && _results.Content == _viewer)
        {
            CloseViewer();
            e.Handled = true;
            return;
        }
        // Arrows, Enter, Space and Delete belong to the viewer or the grid wherever the focus is (a button of the
        // toolbar would otherwise take them), unless something is being typed.
        bool typing = Keyboard.FocusedElement is TextBox or ComboBox or ComboBoxItem;
        if (!typing && _pages.Content == _library && (Keyboard.Modifiers & (ModifierKeys.Control | ModifierKeys.Alt)) == 0)
        {
            if (_results.Content == _viewer ? _viewer.HandleKey(e.Key) : _results.Content == _grid && _grid.HandleKey(e.Key))
            {
                e.Handled = true;
                return;
            }
        }
        base.OnPreviewKeyDown(e);
    }

    /// <summary>The folders dropped: a dropped file stands for the folder it is in, as on the Mac.</summary>
    List<string> DroppedFolders(DragEventArgs e) =>
        !_grid.Dragging && e.Data.GetDataPresent(DataFormats.FileDrop)
            ? ((e.Data.GetData(DataFormats.FileDrop) as string[]) ?? []).Select(FolderOf).OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase).ToList() : [];

    protected override void OnDragOver(DragEventArgs e)
    {
        // Pictures dropped on the search pages go to the grid, which takes them itself.
        bool accepted = !e.Handled && DroppedFolders(e).Count > 0 && !BusyWithFiles;
        if (e.Handled) return;
        e.Effects = accepted ? DragDropEffects.Link : DragDropEffects.None;
        _dropOverlay.Visibility = accepted ? Visibility.Visible : Visibility.Collapsed;
        e.Handled = true;
    }

    protected override void OnDragLeave(DragEventArgs e)
    {
        base.OnDragLeave(e);
        // Moving from one part of the window to another leaves only that part.
        var point = e.GetPosition(this);
        if (point.X > 0 && point.Y > 0 && point.X < ActualWidth && point.Y < ActualHeight) return;
        _dropOverlay.Visibility = Visibility.Collapsed;
    }

    /// <summary>Folders dropped on the window: opened together, or — onto an open library — added to it.</summary>
    protected override void OnDrop(DragEventArgs e)
    {
        _dropOverlay.Visibility = Visibility.Collapsed;
        if (e.Handled) return;
        var folders = DroppedFolders(e);
        if (folders.Count == 0) return;
        e.Handled = true;
        if (_plan != null && _roots.Count > 0) LoadFolders(_roots.Concat(folders), keepDestination: true);
        else LoadFolders(folders);
    }
}
