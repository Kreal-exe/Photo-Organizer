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
    const int MediaAll = 0, MediaPhotos = 1, MediaVideos = 2;

    readonly Thumbnails _thumbnails;
    readonly Sidebar _sidebar;
    readonly PhotoGrid _grid;
    readonly Viewer _viewer = new();
    readonly ContentControl _results = new();
    readonly ContentControl _pages = new();
    readonly TextBlock _title = new() { FontSize = 17, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly TextBlock _path = new() { FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly Button _openButton, _rescanButton, _revealButton, _settingsButton;
    readonly SegmentedControl _grouping, _media;
    readonly TextBox _search = new() { Height = 30, MinWidth = 120, MaxWidth = 300, Padding = new Thickness(26, 0, 6, 0) };
    // The grid follows the search field once typing pauses, not on every key: a library can hold ~100,000 files.
    readonly DispatcherTimer _searchTimer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    readonly CheckBox _solo = new();
    readonly Button _setDate, _accept, _cleanup, _pickAnother, _backToMap;
    readonly TextBlock _analysis = new() { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 280 };
    readonly TextBlock _status = new() { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    readonly Slider _size = new() { Minimum = 110, Maximum = 420, Width = 150, VerticalAlignment = VerticalAlignment.Center };
    readonly Button _organize;
    readonly UIElement _welcome, _library;
    readonly Grid _progressPage = new();
    readonly TextBlock _progressText = new() { HorizontalAlignment = HorizontalAlignment.Center };
    readonly ProgressBar _progressBar = new() { Width = 380, Margin = new Thickness(0, 12, 0, 12) };
    readonly Button _progressCancel;
    readonly DispatcherTimer _regroupTimer = new() { Interval = TimeSpan.FromSeconds(8) };

    string? _root;
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
            Settings.Shared.Set("personAloneOnly", true);
            _sidebar.Select(new Filter(FilterKind.Person, person.Key));
            UpdateGrid();
        };

        // Toolbar: the folder, its buttons, the grouping and the search.
        _openButton = Ui.IconButton("folder", L("Открыть папку") + " (Ctrl+O)", OpenFolder);
        _rescanButton = Ui.IconButton("refresh", L("Пересканировать") + " (F5)", Rescan);
        _revealButton = Ui.IconButton("open-external", L("Показать папку в Проводнике"), RevealRoot);
        _settingsButton = Ui.IconButton("settings", L("Настройки"), ShowSettings);
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
        foreach (var button in new[] { _openButton, _rescanButton, _revealButton }) buttons.Children.Add(button);
        Place(toolbarGrid, titles, 0);
        Place(toolbarGrid, buttons, 1);
        Place(toolbarGrid, _grouping, 2);
        Place(toolbarGrid, searchBox, 3);
        _settingsButton.Margin = new Thickness(6, 0, 0, 0);
        Place(toolbarGrid, _settingsButton, 4);
        var toolbar = Ui.Bar("Toolbar", new Thickness(0, 0, 0, 1));
        toolbar.Child = toolbarGrid;

        // Strip: what kind of files, and the controls of the current view.
        _media = new SegmentedControl([L("Все"), L("Фото"), L("Видео")], 28) { Selected = Settings.Shared.Get("mediaKind", 0) };
        _media.Changed += index => { Settings.Shared.Set("mediaKind", index); UpdateGrid(); };
        _solo.Content = L("Без других людей");
        _solo.ToolTip = L("Показывать только фото, на которых нет никого, кроме этого человека");
        _solo.Click += (_, _) => { Settings.Shared.Set("personAloneOnly", _solo.IsChecked == true); UpdateGrid(); };
        _setDate = Ui.TextButton(L("Задать дату…"), SetDateForSelection);
        _setDate.ToolTip = L("Задать дату выбранным файлам (или всем показанным, если ничего не выбрано)");
        _accept = Ui.TextButton(L("Принять подсказки…"), AcceptSuggestions);
        _accept.ToolTip = L("Дать каждому файлу дату по лучшей подсказке: соседние файлы, имя файла, название папки");
        _cleanup = Ui.TextButton(L("Удалить дубликаты…"), RemoveDuplicates);
        _pickAnother = Ui.TextButton(L("Выделить другой предмет…"), () => { if (_objectExample != null) FindObjectIn(_objectExample); });
        _backToMap = Ui.TextButton(L("К карте"), () => { _placeItems = null; UpdateGrid(); });
        _analysis.SetResourceReference(TextBlock.ForegroundProperty, "Secondary");
        var strip = new DockPanel { Margin = new Thickness(18, 6, 18, 6), LastChildFill = false };
        _media.Margin = new Thickness(0, 0, 12, 0);
        DockPanel.SetDock(_media, Dock.Left);
        strip.Children.Add(_media);
        foreach (var control in new FrameworkElement[] { _backToMap, _solo, _setDate, _accept, _cleanup, _pickAnother })
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
            };
            timer.Start();
        };
        _grid.ZoomRequested += size => _size.Value = size;
        _viewer.Closed += CloseViewer;
        _viewer.ContextMenuRequested += position =>
        {
            if (_viewer.Current is not { } current) return;
            // The menu acts on the selection, so the file on screen becomes the selection.
            _grid.Select(current);
            ItemMenu(_viewer, position);
        };
        _results.Content = _grid;

        _status.SetResourceReference(TextBlock.ForegroundProperty, "Secondary");
        _size.Value = Settings.Shared.Get("thumbnailSize", 190.0);
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
        _progressCancel = Ui.TextButton(L("Отменить"), () => _scanner?.Cancel());
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
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Clamp(Settings.Shared.Get("sidebarWidth", 270.0), 180, 420)), MinWidth = 180, MaxWidth = 420 });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 560 });
        var splitter = new GridSplitter { Width = 1, HorizontalAlignment = HorizontalAlignment.Stretch, ResizeBehavior = GridResizeBehavior.PreviousAndNext, Cursor = Cursors.SizeWE };
        splitter.SetResourceReference(BackgroundProperty, "Separator");
        splitter.DragCompleted += (_, _) => Settings.Shared.Set("sidebarWidth", root.ColumnDefinitions[0].ActualWidth);
        Place(root, _sidebar, 0);
        Place(root, splitter, 1);
        Place(root, content, 2);
        Content = root;

        _regroupTimer.Tick += (_, _) => { if (_analyzer != null && SettingsDialog.GroupsFaces) RegroupPeopleInBackground(); };
        BuildShortcuts();
        ShowWelcome();
        Closing += (_, _) =>
        {
            _closing = true;
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
        buttons.Children.Add(Ui.TextButton(L("Выбрать папку…"), OpenFolder, primary: true));
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
        Bind(Key.F5, ModifierKeys.None, Rescan);
        Bind(Key.R, ModifierKeys.Control, Rescan);
        Bind(Key.Enter, ModifierKeys.Control, Organize);
        Bind(Key.Z, ModifierKeys.Control, Undo);
        Bind(Key.Y, ModifierKeys.Control, Redo);
        Bind(Key.Z, ModifierKeys.Control | ModifierKeys.Shift, Redo);
        Bind(Key.F, ModifierKeys.Control, () => { _search.Focus(); _search.SelectAll(); });
        Bind(Key.F, ModifierKeys.Control | ModifierKeys.Shift, () => SearchByPhoto(null));
        Bind(Key.R, ModifierKeys.Control | ModifierKeys.Shift, RevealRoot);
        Bind(Key.Back, ModifierKeys.Control, TrashSelection);
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
        UpdateUi();
    }

    void OpenFolder()
    {
        if (_busy) return;
        var dialog = new Microsoft.Win32.OpenFolderDialog
        {
            Title = L("Выберите папку с фото и видео"),
            InitialDirectory = _root ?? Settings.Shared.GetString("lastFolder") ?? Environment.GetFolderPath(Environment.SpecialFolder.MyPictures),
        };
        if (dialog.ShowDialog(this) == true) LoadFolder(dialog.FolderName);
    }

    /// <summary>The folder whose scan or recognition was still running when the app was closed last time.</summary>
    public static string? UnfinishedFolder => Settings.Shared.GetString("unfinishedFolder") is { } folder && Directory.Exists(folder) ? folder : null;

    public void LoadFolder(string? folder)
    {
        if (folder == null || !Directory.Exists(folder) || _busy) return;
        StopAnalysis();
        _root = Path.GetFullPath(folder);
        Settings.Shared.Set("lastFolder", _root);
        string name = Path.GetFileName(_root.TrimEnd('\\'));
        _title.Text = name.Length > 0 ? name : _root;
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        _path.Text = _root.StartsWith(home + "\\", StringComparison.OrdinalIgnoreCase) ? "~" + _root[home.Length..] : _root;
        _path.ToolTip = _root;
        Title = $"{_title.Text} — Photo Organizer";
        _undo.Clear();
        _redo.Clear();
        _similarItems = null;
        _objectResults = null;
        _objectStatus = "";
        _objectExample = null;
        _placeItems = null;
        _lastMessage = null;
        StartScan();
    }

    void Rescan()
    {
        if (_root == null || _busy) return;
        StopAnalysis();
        StartScan();
    }

    void RevealRoot()
    {
        if (_root != null) Process.Start(new ProcessStartInfo("explorer.exe", $"\"{_root}\"") { UseShellExecute = true });
    }

    void ShowProgress(string text, bool cancellable)
    {
        _progressText.Text = text;
        _progressBar.IsIndeterminate = true;
        _progressCancel.Visibility = cancellable ? Visibility.Visible : Visibility.Collapsed;
        _pages.Content = _progressPage;
    }

    void StartScan()
    {
        _busy = true;
        CloseViewer();
        ShowProgress(L("Поиск фото и видео…"), cancellable: true);
        // Until the scan and the recognition after it are through, the folder is opened again at the next start, and
        // both go on from where they stopped (ScanCache, RecognitionStore).
        Settings.Shared.Set("unfinishedFolder", _root);
        var scanner = new Scanner(_root!) { DeprioritizedFolders = [Plan.SavedDuplicatesFolderName, Plan.DefaultTinyFolderName] };
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
            Settings.Shared.Set("unfinishedFolder", null);
            if (_plan != null) _pages.Content = _library;
            else
            {
                _root = null;
                ShowWelcome();
            }
            UpdateUi();
            return;
        }
        _objectFilterCounts.Clear();
        var plan = new Plan(_root!, items);
        plan.LoadOptions();
        plan.Rebuild();
        _plan = plan;
        _suggester = null;
        _copySets = [];
        _people = [];
        _pages.Content = _library;
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
            .ContinueWith(_ => AnalysisDone(analyzer), TaskScheduler.FromCurrentSynchronizationContext());
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
        Settings.Shared.Set("unfinishedFolder", null);
        _objectFilterCounts.Clear();   // the labels are complete now
        _analysis.Text = SettingsDialog.GroupsFaces && !FaceEngine.ModelsReady ? L("Модель лиц не загружена — «Настройки»")
            : NudityClassifier.Enabled && !NudityClassifier.Selected.Model.Ready ? L("Модель наготы не загружена — «Настройки»")
            : analyzer.Error ?? "";
        if (_plan == null) return;
        _copySets = SimilarCopies.FindSets(_plan.Items);
        if (SimilarCopies.ShareDates(_copySets) > 0)
        {
            _plan.SortItemsByDate();
            _suggester = null;
        }
        _plan.Rebuild();
        ReloadSidebar();
        UpdateGrid();
        RegroupPeopleInBackground();
    }

    void RegroupPeople(bool update = true)
    {
        _people = _plan != null && SettingsDialog.GroupsFaces ? People.PeopleIn(_plan.Items) : [];
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
        List<Person> people;
        try
        {
            people = await Task.Run(() => People.PeopleIn(items));
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
        long suggested = 0, undated = 0;
        foreach (var item in _plan.Items.Where(i => i.Undated))
        {
            if (Suggester.Best(item) != null) suggested++; else undated++;
        }
        long lesser = _plan.Items.Count(i => i.BetterCopy != null && !i.Tiny);
        var counts = new Dictionary<string, long>
        {
            ["library"] = _plan.Items.Count, ["suggested"] = suggested, ["undated"] = undated,
            ["duplicates"] = _plan.DuplicateItems.Count + lesser, ["tiny"] = _plan.TinyItems.Count,
            ["similar"] = _similarItems?.Count ?? -1, ["located"] = _plan.Items.Count(i => i.HasLocation),
            ["nudity"] = NudityClassifier.Enabled ? ExplicitItems().Count : -1,
        };
        var objectFilters = SavedObjectFilters.Select(q => (q, ObjectFilterCount(q))).ToList();
        _sidebar.Rebuild(true, counts, SettingsDialog.GroupsFaces ? _people : [], objectFilters: objectFilters);
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
        if (!_objectFilterCounts.TryGetValue(query, out long count)) _objectFilterCounts[query] = count = ItemsMatching(_plan.Items, query).Count;
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
        int media = _media.Selected;
        List<PhotoItem> Narrow(IEnumerable<PhotoItem> list)
        {
            var found = Searched(list);
            return media switch
            {
                MediaPhotos => found.Where(i => !i.Video).ToList(),
                MediaVideos => found.Where(i => i.Video).ToList(),
                _ => found,
            };
        }
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
                    sections.Add(new Section(set[0].Name, Count(set.Count - 1, L("копия хуже качеством"), L("копии хуже качеством"), L("копий хуже качеством")), "duplicates", set));
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

        string gridKey = $"{filter}|{media}|{Grouping}|{string.Join(" ", _searchTokens)}";
        _grid.SetSections(sections, filter.Kind == FilterKind.Duplicates, gridKey == _lastGridKey);
        _lastGridKey = gridKey;
        // The strip counts within the selection (and the search), so "Видео 3" means three videos of this view.
        var searched = Searched(baseItems ?? []);
        long videos = searched.Count(i => i.Video);
        _media.SetCounts([searched.Count, searched.Count - videos, videos]);
        UpdateUi();
    }

    void UpdateUi()
    {
        bool hasPlan = _plan != null && !_busy;
        _rescanButton.IsEnabled = _revealButton.IsEnabled = _root != null && !_busy;
        _grouping.IsEnabled = _search.IsEnabled = hasPlan;
        int pending = _plan?.PendingItems.Count ?? 0;
        _organize.IsEnabled = hasPlan && pending > 0;
        _status.Text = _plan == null ? ""
            : _plan.Items.Count == 0 ? L("В этой папке нет фото и видео")
            : _lastMessage ?? (pending > 0 ? F("Будет перемещено %@ из %@", Number(pending), Number(_plan.Items.Count)) : L("Все файлы уже лежат на своих местах"));
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

    void OpenSelection()
    {
        if (_grid.SelectedItems.FirstOrDefault() is { } item) OpenItem(item);
    }

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
            Add(L("Открыть в программе по умолчанию"), () => { foreach (var i in selected.Take(20)) Process.Start(new ProcessStartInfo(i.Path) { UseShellExecute = true }); });
            Add(L("Показать в Проводнике"), () => Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{selected[0].Path}\"") { UseShellExecute = true }));
            Add(L("Скопировать путь"), () => Clipboard.SetText(string.Join(Environment.NewLine, selected.Select(i => i.Path))));
            menu.Items.Add(new Separator());
            if (_sidebar.Selected.Kind != FilterKind.All || inViewer) Add(L("Показать в медиатеке по дате"), () => { CloseViewer(); ShowInLibrary(selected[0]); });
            Add(L("Задать дату…"), SetDateForSelection);
            Add(L("Найти похожие"), () => SearchByPhoto(selected[0].Path, searchWhenReady: true), !selected[0].Video);
            Add(L("Найти этот предмет на других фото…"), () => FindObjectIn(selected[0].Path), !selected[0].Video);
            if (selected[0].Faces is { Count: > 0 }) Add(L("Найти этого человека"), () => SearchByFace(selected[0].Faces![0]));
            menu.Items.Add(new Separator());
            // Files that move away leave the viewer for the grid.
            Add(L("Переместить в папку…"), () => { CloseViewer(); MoveSelectionToFolder(); });
            Add(L("Переместить в Корзину"), () => { CloseViewer(); TrashSelection(); });
        }
        else
        {
            Add(L("Выбрать всё"), _grid.SelectAll);
            if (_grid.ShownItems.Count > 0) Add(L("Переместить показанное в папку…"), MoveShownToFolder);
        }
        menu.PlacementTarget = target;
        menu.Placement = PlacementMode.RelativePoint;
        menu.HorizontalOffset = position.X;
        menu.VerticalOffset = position.Y;
        menu.IsOpen = true;
    }

    /// <summary>Leaves a search or a person for the library, scrolled to the file among the others of its date.</summary>
    void ShowInLibrary(PhotoItem item)
    {
        if (_searchTokens.Length > 0)
        {
            _search.Text = "";
            _searchTokens = [];
        }
        _media.Selected = MediaAll;
        Settings.Shared.Set("mediaKind", MediaAll);
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
        var dialog = new DateDialog(this, items);
        if (dialog.ShowDialog() != true) return;
        if (dialog.Outcome == DateDialog.Remove) ManualDates.SetDate(null, Precision.Day, items);
        else if (dialog.Result() is { } result) ManualDates.SetDate(result.Date, result.Precision, items);
        _lastMessage = null;
        DatesDidChange();
    }

    void AcceptSuggestions()
    {
        var items = _grid.ShownItems;
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
        if (_plan == null || _busy || _plan.PendingItems.Count == 0) return;
        var dialog = new OrganizeDialog(this, _plan, () => { _lastMessage = null; ReloadSidebar(); UpdateGrid(); });
        if (dialog.ShowDialog() == true) RunMoves(progress => Organizer.ApplyPlan(_plan, progress));
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
        RunMoves(progress => Organizer.MoveItemsToFolder(items, folder, _plan.Root, progress));
    }

    void RunMoves(Func<Action<int, int>, OrganizeResult> work)
    {
        _busy = true;
        StopAnalysis();
        CloseViewer();
        ShowProgress(L("Перемещение файлов…"), cancellable: false);
        UpdateUi();
        string root = _plan!.Root;
        Task.Run(() => work((done, total) => Dispatcher.BeginInvoke(() =>
            {
                _progressText.Text = F("Перемещение файлов: %@ из %@", Number(done), Number(total));
                _progressBar.IsIndeterminate = false;
                _progressBar.Maximum = Math.Max(total, 1);
                _progressBar.Value = done;
            })))
            .ContinueWith(task => MoveDone(task.Result, root), TaskScheduler.FromCurrentSynchronizationContext());
    }

    void ApplyMoves(List<MoveRecord> records)
    {
        _plan!.ItemsMoved(records.Select(r => (r.From, r.To)));
        foreach (var record in records) _thumbnails.Forget(record.From);
        _suggester = null;
        _plan.Rebuild();
    }

    void MoveDone(OrganizeResult result, string root)
    {
        _busy = false;
        Organizer.WriteJournal(result, root);
        ApplyMoves(result.Records);
        if (result.Records.Count > 0)
        {
            _undo.Push(result);
            _redo.Clear();
        }
        int n = result.Records.Count;
        _lastMessage = F("Готово: %@ %@. Отменить — ⌘Z", Plural(n, L("перемещён"), L("перемещено"), L("перемещено")), Count(n, L("файл"), L("файла"), L("файлов"))).Replace("⌘Z", "Ctrl+Z");
        _pages.Content = _library;
        ReloadSidebar();
        UpdateGrid();
        ShowErrors(result.Errors, L("Не все файлы удалось переместить"));
        StartAnalysis();
    }

    void Undo() => Revert(_undo, _redo);
    void Redo() => Revert(_redo, _undo);

    void Revert(Stack<OrganizeResult> source, Stack<OrganizeResult> target)
    {
        if (_busy || source.Count == 0 || _plan == null) return;
        var result = source.Pop();
        _busy = true;
        StopAnalysis();
        CloseViewer();
        ShowProgress(L("Возвращаем файлы на место…"), cancellable: false);
        UpdateUi();
        Task.Run(() => Organizer.Revert(result)).ContinueWith(task =>
        {
            _busy = false;
            var (errors, moves) = task.Result;
            ApplyMoves(moves);
            if (moves.Count > 0) target.Push(new OrganizeResult { Records = moves });
            _lastMessage = F("Готово: %@ %@.", Plural(moves.Count, L("перемещён"), L("перемещено"), L("перемещено")), Count(moves.Count, L("файл"), L("файла"), L("файлов")));
            _pages.Content = _library;
            ReloadSidebar();
            UpdateGrid();
            ShowErrors(errors, L("Не все файлы удалось вернуть"));
            StartAnalysis();
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

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct ShFileOperation
    {
        public IntPtr Window;
        public uint Function;
        public string From;
        public string? To;
        public ushort Flags;
        public bool Aborted;
        public IntPtr NameMappings;
        public string? ProgressTitle;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHFileOperation(ref ShFileOperation operation);

    /// <summary>Moves files to the Recycle Bin, where they can be restored from; one shell call for the lot.</summary>
    static void Recycle(IEnumerable<string> paths)
    {
        var operation = new ShFileOperation
        {
            Function = 3,                       // FO_DELETE
            From = string.Join("\0", paths) + "\0\0",
            Flags = 0x40 | 0x10 | 0x400 | 0x4,  // FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT
        };
        SHFileOperation(ref operation);
    }

    void TrashSelection()
    {
        var items = _grid.SelectedItems;
        if (items.Count == 0 || _busy) return;
        if (MessageBox.Show(this, F("Переместить %@ в Корзину?", Count(items.Count, L("файл"), L("файла"), L("файлов"))), L("Переместить в Корзину"),
                            MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK) Trash(items);
    }

    /// <summary>Thousands of duplicates go to the Recycle Bin on a worker, a hundred per shell call, with progress.</summary>
    void Trash(List<PhotoItem> items)
    {
        if (_plan == null || items.Count == 0) return;
        _busy = true;
        CloseViewer();
        ShowProgress(L("Перемещение в Корзину…"), cancellable: false);
        UpdateUi();
        var paths = items.Select(i => i.Path).ToList();
        Task.Run(() =>
        {
            for (int start = 0; start < paths.Count; start += 100)
            {
                Recycle(paths.Skip(start).Take(100));
                int done = Math.Min(start + 100, paths.Count);
                Dispatcher.BeginInvoke(() =>
                {
                    _progressText.Text = F("Перемещение в Корзину: %@ из %@", Number(done), Number(paths.Count));
                    _progressBar.IsIndeterminate = false;
                    _progressBar.Maximum = paths.Count;
                    _progressBar.Value = done;
                });
            }
            // What is no longer there went to the Recycle Bin; the rest could not be moved.
            return paths.Select(path => !File.Exists(path)).ToList();
        }).ContinueWith(task => TrashDone(items, task.IsFaulted ? items.Select(_ => false).ToList() : task.Result),
                        TaskScheduler.FromCurrentSynchronizationContext());
    }

    void TrashDone(List<PhotoItem> items, List<bool> removed)
    {
        _busy = false;
        _pages.Content = _library;
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
                errors.Add(items[i].RelativePath.Replace('/', '\\'));
            }
        }
        RemoveFromLibrary(trashed);
        _lastMessage = F("В Корзине: %@. Вернуть можно из Корзины.", Count(trashed.Count, L("файл"), L("файла"), L("файлов")));
        ReloadSidebar();
        UpdateGrid();
        ShowErrors(errors, L("Не все файлы удалось переместить в Корзину"));
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
        if (victims.Count == 0) return;
        string freed = Strings.Size(victims.Sum(i => i.FileSize));
        string title = tinyView
            ? F("Переместить %@ в Корзину?", Count(victims.Count, L("миниатюра"), L("миниатюры"), L("миниатюр")))
            : F("Переместить %@ в Корзину?", Count(victims.Count, L("дубликат"), L("дубликата"), L("дубликатов")));
        string text = tinyView
            ? F("У каждой миниатюры в папке есть оригинал большего размера — он останется. Освободится %@.", freed)
            : F("В каждом наборе останется один файл: оригинал у точных копий и версия с наибольшим разрешением у пережатых. Освободится %@.", freed);
        if (MessageBox.Show(this, title + "\n\n" + text, L("Переместить в Корзину"), MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK) Trash(victims);
    }

    // --- People and search by face ------------------------------------------------------------------------------

    void RenamePerson(Person person)
    {
        string? name = PromptDialog.Ask(this, L("Как зовут этого человека?"),
            L("Имя запомнится вместе с лицом: человек будет узнан и в других папках. Пустое имя — забыть."), person.Named ? person.DisplayName : "");
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
        var results = await Task.Run(() => Search.Similar(vector, labels, items));
        if (generation != _searchGeneration) return;
        _photoSearch?.SetStatus(results.Count > 0 ? F("Найдено: %@. Результаты — в разделе «Похожие на фото».", Number(results.Count))
                                                  : L("Ничего похожего не нашлось. Попробуйте снять часть галочек."), false);
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
        new SettingsDialog(this).ShowDialog();
        if (_plan == null || _busy) return;
        if (!SettingsDialog.GroupsFaces) _people = [];
        // People were turned on, or the models arrived: look at the photos again (results already found are kept).
        if (AnalysisSettings() != before) StartAnalysis();
        ReloadSidebar();
        UpdateGrid();
    }

    // --- Keys and drops -----------------------------------------------------------------------------------------

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
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

    static string? DroppedFolder(DragEventArgs e) =>
        e.Data.GetDataPresent(DataFormats.FileDrop) ? (e.Data.GetData(DataFormats.FileDrop) as string[])?.FirstOrDefault(Directory.Exists) : null;

    protected override void OnDragOver(DragEventArgs e)
    {
        e.Effects = DroppedFolder(e) != null && !_busy ? DragDropEffects.Link : DragDropEffects.None;
        e.Handled = true;
    }

    protected override void OnDrop(DragEventArgs e)
    {
        if (DroppedFolder(e) is { } folder)
        {
            e.Handled = true;
            LoadFolder(folder);
        }
    }
}
