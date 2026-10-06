using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using PhotoOrganizer.Core;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.UI;

/// <summary>
/// The "Search by photo" panel, as on the Mac: drop an example, the app describes it in words (which can be unticked)
/// and finds the files with the same description, ordered by how alike they look. When the example shows a face and
/// people are on, the person can be searched for instead.
/// </summary>
public sealed class PhotoSearchWindow : Window
{
    const int MaximumWords = 10;
    readonly Border _well = new() { Height = 200, CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), AllowDrop = true };
    readonly Image _image = new() { Stretch = Stretch.Uniform, Margin = new Thickness(6) };
    readonly TextBlock _wordsTitle = new() { FontWeight = FontWeights.SemiBold, FontSize = 12, Margin = new Thickness(0, 4, 0, 0), TextWrapping = TextWrapping.Wrap };
    readonly StackPanel _words = new();
    readonly CheckBox _person = new() { Visibility = Visibility.Collapsed, Margin = new Thickness(0, 6, 0, 0) };
    readonly Button _search;
    readonly TextBlock _status = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap };
    RasterImage? _example;
    float[]? _vector;
    byte[]? _face;
    List<string> _labels = [];
    int _generation;

    /// <summary>The example's vector and the words kept, or (when the person is ticked) the face to search for.</summary>
    public event Action<float[], List<string>, byte[]?>? SearchRequested;

    public PhotoSearchWindow(Window owner)
    {
        Owner = owner;
        Title = L("Поиск по фото");
        Width = 360;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        WindowStyle = WindowStyle.ToolWindow;
        Theme.StyleTitleBar(this);
        _well.SetResourceReference(Border.BackgroundProperty, "Cell");
        _well.SetResourceReference(Border.BorderBrushProperty, "Separator");
        var placeholder = Ui.Glyph("photo-search", 40, "Tertiary");
        var wellContent = new Grid();
        wellContent.Children.Add(placeholder);
        wellContent.Children.Add(_image);
        _well.Child = wellContent;
        _well.DragOver += (_, e) => { e.Effects = Dropped(e) != null ? DragDropEffects.Copy : DragDropEffects.None; e.Handled = true; };
        _well.Drop += (_, e) => { if (Dropped(e) is { } path) Load(path); };
        _image.SourceUpdated += (_, _) => placeholder.Visibility = Visibility.Collapsed;
        var hint = new TextBlock { Text = L("Перетащите сюда фото предмета, места или сцены (или вставьте его — ⌘V). Приложение опишет его словами, а потом найдёт в открытой папке файлы с тем же описанием и расставит их по внешнему сходству.").Replace("⌘V", "Ctrl+V") };
        Ui.Styled(hint, "Hint");
        _status.SetResourceReference(TextBlock.ForegroundProperty, "Secondary");
        _person.Content = L("Искать этого человека по лицу");
        _person.Click += (_, _) => _words.IsEnabled = _person.IsChecked != true;
        _search = Ui.TextButton(L("Найти похожие"), Search, primary: true);
        _search.HorizontalAlignment = HorizontalAlignment.Left;
        _search.IsDefault = true;
        var stack = new StackPanel { Margin = new Thickness(16) };
        foreach (var element in new UIElement[] { _well, hint, _wordsTitle, _words, _person, _search, _status })
        {
            ((FrameworkElement)element).Margin = new Thickness(0, 0, 0, 10);
            stack.Children.Add(element);
        }
        Content = stack;
        ShowWords([]);
        CommandBindings.Add(new CommandBinding(ApplicationCommands.Paste, (_, _) => Paste()));
        InputBindings.Add(new KeyBinding(ApplicationCommands.Paste, Key.V, ModifierKeys.Control));
        Closing += (_, e) => { e.Cancel = true; Hide(); };   // kept for the next search, as on the Mac
    }

    static string? Dropped(DragEventArgs e) =>
        e.Data.GetDataPresent(DataFormats.FileDrop) ? (e.Data.GetData(DataFormats.FileDrop) as string[])?.FirstOrDefault(File.Exists) : null;

    void Paste()
    {
        if (Clipboard.ContainsFileDropList() && Clipboard.GetFileDropList().Cast<string>().FirstOrDefault(File.Exists) is { } file)
        {
            Load(file);
            return;
        }
        if (!Clipboard.ContainsImage())
        {
            SetStatus(L("В буфере обмена нет картинки."), false);
            return;
        }
        string path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "photo-organizer-pasted.png");
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(Clipboard.GetImage()));
        using (var stream = File.Create(path)) encoder.Save(stream);
        Load(path);
    }

    void ShowWords(Dictionary<string, float> labels)
    {
        _labels = labels.OrderByDescending(p => p.Value).Take(MaximumWords).Select(p => p.Key).ToList();
        _words.Children.Clear();
        foreach (string label in _labels)
        {
            _words.Children.Add(new CheckBox { Content = $"{Labels.DisplayName(label)} — {labels[label] * 100:0} %", IsChecked = true, Margin = new Thickness(0, 2, 0, 2) });
        }
        bool hasImage = _example != null;
        _wordsTitle.Visibility = hasImage ? Visibility.Visible : Visibility.Collapsed;
        _wordsTitle.Text = _labels.Count > 0 ? L("Искать по словам:") : L("Слов для этого фото не нашлось — сравним со всеми фото по виду.");
        _words.Visibility = _labels.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        _search.IsEnabled = hasImage;
    }

    public void SetStatus(string status, bool busy)
    {
        _status.Text = status;
        _search.IsEnabled = !busy && _example != null;
    }

    /// <summary>Describes the picture and, with `searchWhenReady`, searches straight away.</summary>
    public async void Load(string path, bool searchWhenReady = false)
    {
        int generation = ++_generation;
        SetStatus(L("Описываем фото…"), true);
        if (!Recognizer.Model.Ready)
        {
            SetStatus(L("Модель распознавания объектов не загружена — «Настройки»."), false);
            return;
        }
        bool faces = SettingsDialog.GroupsFaces && FaceEngine.ModelsReady;
        var result = await Task.Run(() =>
        {
            var image = Images.Load(path, FaceEngine.AnalysisSide);
            if (image == null) return default((RasterImage, float[], Dictionary<string, float>, byte[]?)?);
            var small = Images.Downscaled(image, 512);
            var vector = Recognizer.Shared.Embed(small, [(0, 0, small.Width, small.Height)])[0];
            byte[]? face = null;
            if (faces)
            {
                try { face = FaceEngine.Shared.Analyse(image).Embeddings.FirstOrDefault(); }
                catch (Exception) { /* no face search, the rest works */ }
            }
            return (image, vector, Labels.For(vector), face);
        });
        if (generation != _generation) return;
        if (result is not { } loaded)
        {
            SetStatus(L("Этот файл не открывается как изображение."), false);
            return;
        }
        (_example, _vector, var labels, _face) = loaded;
        _image.Source = Thumbnails.Bitmap(_example);
        ((Grid)_well.Child).Children[0].Visibility = Visibility.Collapsed;
        _person.Visibility = _face != null ? Visibility.Visible : Visibility.Collapsed;
        _person.IsChecked = false;
        _words.IsEnabled = true;
        ShowWords(labels);
        SetStatus("", false);
        if (searchWhenReady) Search();
    }

    void Search()
    {
        if (_vector == null) return;
        var chosen = _labels.Where((_, i) => _words.Children[i] is CheckBox { IsChecked: true }).ToList();
        SearchRequested?.Invoke(_vector, chosen, _person.IsChecked == true ? _face : null);
    }
}

/// <summary>The example photo with a frame the user draws around the object to find; everything outside is dimmed.</summary>
public sealed class ObjectPickerDialog : Dialog
{
    readonly RasterImage _picture;
    readonly Canvas _canvas = new() { ClipToBounds = true, Cursor = Cursors.Cross, Background = Brushes.Black };
    readonly Image _image = new() { Stretch = Stretch.Fill };
    readonly Rectangle _frame = new() { StrokeThickness = 3, RadiusX = 4, RadiusY = 4, Visibility = Visibility.Collapsed };
    readonly System.Windows.Shapes.Path _dim = new() { Fill = new SolidColorBrush(Color.FromArgb(166, 0, 0, 0)), IsHitTestVisible = false };
    readonly Button _find;
    Rect? _selection;   // image pixels
    Point? _dragStart;
    Rect _shown;

    public Rect? Selection => _selection;

    public ObjectPickerDialog(Window owner, RasterImage picture, Rect? initial) : base(owner, L("Поиск по объектам"), 680)
    {
        _picture = picture;
        _selection = initial;
        Heading(L("Выделите предмет, который нужно найти"));
        Note(L("Обведите его рамкой, потянув мышью. Чем плотнее рамка, тем точнее поиск: фото ищутся по тому, как выглядит именно этот предмет, а не по словам."));
        double aspect = (double)picture.Height / picture.Width;
        _canvas.Width = 620;
        _canvas.Height = Math.Clamp(620 * aspect, 240, 520);
        _image.Source = Thumbnails.Bitmap(picture);
        _frame.SetResourceReference(Shape.StrokeProperty, "Accent");
        _canvas.Children.Add(_image);
        _canvas.Children.Add(_dim);
        _canvas.Children.Add(_frame);
        _canvas.MouseLeftButtonDown += (_, e) => { _dragStart = ToImage(e.GetPosition(_canvas)); _canvas.CaptureMouse(); };
        _canvas.MouseMove += (_, e) =>
        {
            if (_dragStart is not { } start || e.LeftButton != MouseButtonState.Pressed) return;
            var now = ToImage(e.GetPosition(_canvas));
            _selection = new Rect(start, now);
            Paint();
        };
        _canvas.MouseLeftButtonUp += (_, _) => { _dragStart = null; _canvas.ReleaseMouseCapture(); };
        Body.Children.Add(_canvas);
        _find = AddButton(L("Найти"), () => DialogResult = true, primary: true);
        AddButton(L("Отмена"), () => DialogResult = false).IsCancel = true;
        AddButton(L("Всё фото"), () => { _selection = new Rect(0, 0, picture.Width, picture.Height); Paint(); }, left: true);
        Finish();
        Loaded += (_, _) => Paint();
    }

    Point ToImage(Point point)
    {
        double scale = _shown.Width / _picture.Width;
        return new Point(Math.Clamp((point.X - _shown.X) / scale, 0, _picture.Width), Math.Clamp((point.Y - _shown.Y) / scale, 0, _picture.Height));
    }

    void Paint()
    {
        double scale = Math.Min(_canvas.Width / _picture.Width, _canvas.Height / _picture.Height);
        _shown = new Rect((_canvas.Width - _picture.Width * scale) / 2, (_canvas.Height - _picture.Height * scale) / 2, _picture.Width * scale, _picture.Height * scale);
        Canvas.SetLeft(_image, _shown.X);
        Canvas.SetTop(_image, _shown.Y);
        _image.Width = _shown.Width;
        _image.Height = _shown.Height;
        _find.IsEnabled = _selection is { Width: >= 16, Height: >= 16 };
        if (_selection is not { } selection)
        {
            _frame.Visibility = Visibility.Collapsed;
            _dim.Data = null;
            return;
        }
        var box = new Rect(_shown.X + selection.X * scale, _shown.Y + selection.Y * scale, selection.Width * scale, selection.Height * scale);
        _frame.Visibility = Visibility.Visible;
        Canvas.SetLeft(_frame, box.X);
        Canvas.SetTop(_frame, box.Y);
        _frame.Width = box.Width;
        _frame.Height = box.Height;
        _dim.Data = new CombinedGeometry(GeometryCombineMode.Exclude, new RectangleGeometry(_shown), new RectangleGeometry(box));
    }
}
