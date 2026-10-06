using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using PhotoOrganizer.Core;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.UI;

public sealed class Section(string title, string detail, string glyph, List<PhotoItem> items, string? actionTitle = null, Action? action = null)
{
    public string Title { get; } = title;
    public string Detail { get; } = detail;
    public string Glyph { get; } = glyph;
    public List<PhotoItem> Items { get; } = items;
    public string? ActionTitle { get; } = actionTitle;
    public Action? Action { get; } = action;
}

/// <summary>
/// The grid of thumbnails in sections ("май 2019 г. · 34 файла"), with a strip of years on the right to jump through
/// time. Drawn by hand — only what is on screen — so that tens of thousands of files scroll smoothly.
/// </summary>
public sealed class PhotoGrid : Grid
{
    const double HeaderHeight = 46, CaptionHeight = 42, Spacing = 18, Inset = 14, RowGap = 8;

    readonly ScrollViewer _scroll = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, CanContentScroll = false, Focusable = false };
    readonly Canvas _canvas;
    readonly TextBlock _placeholder = new() { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, FontSize = 17, FontWeight = FontWeights.Medium, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(60), IsHitTestVisible = false };
    readonly Border _yearBar = new() { CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0), Padding = new Thickness(0, 6, 0, 6) };
    readonly StackPanel _years = new();
    readonly Border _dropHighlight = new() { BorderThickness = new Thickness(3), CornerRadius = new CornerRadius(10), Margin = new Thickness(3), Visibility = Visibility.Collapsed, IsHitTestVisible = false };

    readonly Thumbnails _thumbnails;
    List<Section> _sections = [];
    List<PhotoItem> _flat = [];
    Dictionary<PhotoItem, int> _indexOf = [];
    readonly Dictionary<PhotoItem, Rect> _positions = [];
    readonly List<(double Y, double Height, Section Section)> _headers = [];
    readonly List<(string Year, double Y)> _yearPositions = [];
    // Visual rows top to bottom and the action buttons of the headers, made in Relayout: hit testing, drawing and the
    // arrow keys look things up here instead of going through every file (a library can hold ~100,000).
    readonly List<(double Top, List<PhotoItem> Items)> _rows = [];
    readonly List<(Rect Rect, Section Section)> _actions = [];
    double _yearBarWidth;
    HashSet<PhotoItem> _selected = [];
    PhotoItem? _anchor;
    PhotoItem? _cursor;   // where Shift+arrows have got to; the range runs from the anchor to here
    bool _dragging;
    int _columns = 1;
    double _cell = 190;
    Point? _dragStart;
    PhotoItem? _pressed;

    public double CellSize { get; private set; } = 190;
    public bool ShowsOriginalBadge { get; private set; }
    public bool AcceptsImageDrops { get; set; }
    public bool ShowsNudityScores { get; set; }

    public event Action<PhotoItem>? Activated;
    public event Action? SelectionChanged;
    public event Action<Point>? ContextMenuRequested;
    public event Action<string>? ImageDropped;
    public event Action? DeletePressed;
    public event Action<double>? ZoomRequested;
    /// <summary>Files were dragged out to another app, which may have moved them away.</summary>
    public event Action<List<PhotoItem>>? DraggedOut;

    public PhotoGrid(Thumbnails thumbnails)
    {
        _thumbnails = thumbnails;
        _thumbnails.Loaded += _ => _canvas!.InvalidateVisual();
        _canvas = new Canvas(this);
        _scroll.Content = _canvas;
        _scroll.ScrollChanged += (_, _) => { _canvas.InvalidateVisual(); UpdateYearBar(); };
        _scroll.SizeChanged += (_, _) => Relayout();
        Children.Add(_scroll);
        _placeholder.SetResourceReference(TextBlock.ForegroundProperty, "Secondary");
        Children.Add(_placeholder);
        _yearBar.SetResourceReference(Border.BackgroundProperty, "Toolbar");
        _yearBar.SetResourceReference(Border.BorderBrushProperty, "Separator");
        _yearBar.Child = _years;
        Children.Add(_yearBar);
        _dropHighlight.SetResourceReference(Border.BorderBrushProperty, "Accent");
        Children.Add(_dropHighlight);
        Focusable = true;
        FocusVisualStyle = null;
        AllowDrop = true;
        SetResourceReference(BackgroundProperty, "Window");
    }

    public string Placeholder
    {
        set => _placeholder.Text = value;
    }

    // --- Data -------------------------------------------------------------------------------------------------------

    public void SetSections(List<Section> sections, bool showsOriginalBadge = false, bool keepScroll = false)
    {
        double offset = _scroll.VerticalOffset;
        _sections = sections;
        ShowsOriginalBadge = showsOriginalBadge;
        _flat = sections.SelectMany(s => s.Items).ToList();
        _indexOf = new Dictionary<PhotoItem, int>();
        for (int i = 0; i < _flat.Count; i++) _indexOf.TryAdd(_flat[i], i);
        _selected = _selected.Where(_indexOf.ContainsKey).ToHashSet();
        _yearBarWidth = sections.Select(s => YearOf(s.Title)).Where(y => y != null).Distinct().Skip(1).Any() ? 46 : 0;
        Relayout();
        _scroll.ScrollToVerticalOffset(keepScroll ? offset : 0);
        _placeholder.Visibility = sections.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        SelectionChanged?.Invoke();
    }

    public void SetCellSize(double size)
    {
        CellSize = size;
        Relayout();
    }

    public List<PhotoItem> SelectedItems => _flat.Where(_selected.Contains).ToList();
    public List<PhotoItem> ShownItems => _flat;

    public void SelectAll()
    {
        _selected = _flat.ToHashSet();
        _canvas.InvalidateVisual();
        SelectionChanged?.Invoke();
    }

    /// <summary>Makes this file the selection without scrolling (the viewer's file, for its context menu).</summary>
    public void Select(PhotoItem item)
    {
        _selected = [item];
        _anchor = item;
        _cursor = null;
        _canvas.InvalidateVisual();
        SelectionChanged?.Invoke();
    }

    public void Reveal(PhotoItem item)
    {
        _selected = [item];
        _anchor = item;
        _cursor = null;
        Relayout();
        if (_positions.TryGetValue(item, out var rect)) _scroll.ScrollToVerticalOffset(Math.Max(0, rect.Top - HeaderHeight - 20));
        _canvas.InvalidateVisual();
        SelectionChanged?.Invoke();
    }

    // --- Layout -----------------------------------------------------------------------------------------------------

    static string? YearOf(string title)
    {
        foreach (string word in title.Replace(",", " ").Split(' '))
        {
            if (word.Length == 4 && word.All(char.IsAsciiDigit)) return word;
        }
        return null;
    }

    double YearBarWidth => _yearBarWidth;

    void Relayout()
    {
        double width = _scroll.ViewportWidth > 0 ? _scroll.ViewportWidth : _scroll.ActualWidth;
        if (width <= 0) return;
        double trailing = YearBarWidth > 0 ? YearBarWidth + 18 : Inset;
        double usable = Math.Max(width - Inset - trailing, CellSize);
        _columns = Math.Max(1, (int)((usable + Spacing) / (CellSize + Spacing)));
        // Cells grow to fill the row, as in the macOS app.
        _cell = Math.Floor((usable - (_columns - 1) * Spacing) / _columns);
        _positions.Clear();
        _headers.Clear();
        _yearPositions.Clear();
        _rows.Clear();
        _actions.Clear();
        var years = new HashSet<string>();
        double y = 6;
        foreach (var section in _sections)
        {
            _headers.Add((y, HeaderHeight, section));
            if (ActionRect(section, y, width) is { } action) _actions.Add((action, section));
            if (YearOf(section.Title) is { } year && years.Add(year)) _yearPositions.Add((year, y));
            y += HeaderHeight;
            for (int start = 0; start < section.Items.Count; start += _columns)
            {
                var row = new List<PhotoItem>(_columns);
                for (int column = 0; column < _columns && start + column < section.Items.Count; column++)
                {
                    var item = section.Items[start + column];
                    _positions[item] = new Rect(Inset + column * (_cell + Spacing), y, _cell, _cell);
                    row.Add(item);
                }
                _rows.Add((y, row));
                y += _cell + CaptionHeight + RowGap;
            }
            y += 10;
        }
        _canvas.Height = y + 20;
        _canvas.InvalidateVisual();
        BuildYearBar();
    }

    void BuildYearBar()
    {
        _years.Children.Clear();
        _yearBar.Visibility = YearBarWidth > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (YearBarWidth == 0) return;
        double available = Math.Max(ActualHeight - 60, 22);
        int step = Math.Max(1, (int)Math.Ceiling(_yearPositions.Count * 22 / available));
        for (int i = 0; i < _yearPositions.Count; i += step)
        {
            var (year, y) = _yearPositions[i];
            var text = new TextBlock { Text = year, Width = 46, Height = 22, TextAlignment = TextAlignment.Center, FontSize = 12, Cursor = Cursors.Hand, Padding = new Thickness(0, 3, 0, 0), Tag = year, Background = Brushes.Transparent };
            text.MouseLeftButtonDown += (_, e) => { _scroll.ScrollToVerticalOffset(y); e.Handled = true; };
            _years.Children.Add(text);
        }
        UpdateYearBar();
    }

    void UpdateYearBar()
    {
        string? current = _yearPositions.LastOrDefault(p => p.Y <= _scroll.VerticalOffset + 40).Year ?? _yearPositions.FirstOrDefault().Year;
        foreach (TextBlock text in _years.Children)
        {
            bool now = (string)text.Tag == current;
            text.FontWeight = now ? FontWeights.Bold : FontWeights.Normal;
            text.SetResourceReference(TextBlock.ForegroundProperty, now ? "Accent" : "Secondary");
        }
    }

    protected override void OnRenderSizeChanged(SizeChangedInfo sizeInfo)
    {
        base.OnRenderSizeChanged(sizeInfo);
        BuildYearBar();
    }

    // --- Drawing ----------------------------------------------------------------------------------------------------

    sealed class Canvas(PhotoGrid owner) : FrameworkElement
    {
        protected override void OnRender(DrawingContext dc) => owner.Render(dc);
    }

    static readonly Typeface Regular = new(new FontFamily("Segoe UI Variable Text, Segoe UI"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
    static readonly Typeface Semibold = new(new FontFamily("Segoe UI Variable Text, Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
    static readonly Typeface Icons = new(new FontFamily(Theme.IconFont), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);

    FormattedText Text(string text, Typeface face, double size, Brush brush, double maxWidth = 0, TextTrimming trimming = TextTrimming.CharacterEllipsis)
    {
        var formatted = new FormattedText(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, face, size, brush, VisualTreeHelper.GetDpi(this).PixelsPerDip);
        if (maxWidth > 0)
        {
            formatted.MaxTextWidth = maxWidth;
            formatted.MaxLineCount = 1;
            formatted.Trimming = trimming;
        }
        return formatted;
    }

    Rect? ActionRect(Section section, double y, double canvasWidth)
    {
        if (section.ActionTitle == null) return null;
        double width = Text(section.ActionTitle, Semibold, 12.5, Brushes.White).Width + 26;
        double right = canvasWidth - (YearBarWidth > 0 ? YearBarWidth + 18 : Inset);
        return new Rect(right - width, y + 12, width, 26);
    }

    /// <summary>The first row whose cell or caption reaches below `y` (binary search; rows are top to bottom).</summary>
    int FirstRowReaching(double y)
    {
        int low = 0, high = _rows.Count;
        while (low < high)
        {
            int middle = (low + high) / 2;
            if (_rows[middle].Top + _cell + CaptionHeight < y) low = middle + 1; else high = middle;
        }
        return low;
    }

    void Render(DrawingContext dc)
    {
        double top = _scroll.VerticalOffset, bottom = top + _scroll.ViewportHeight;
        double pixelsPerDip = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        int pixels = (int)(_cell * pixelsPerDip);
        var text = Theme.Brush("Text");
        var secondary = Theme.Brush("Secondary");
        foreach (var (y, height, section) in _headers)
        {
            if (y + height < top || y > bottom) continue;
            dc.DrawText(Text(Theme.Glyphs[section.Glyph], Icons, 16, secondary), new Point(Inset + 2, y + 17));
            Rect? action = null;
            foreach (var (rect, owner) in _actions) if (owner == section) action = rect;
            double limit = (action?.Left ?? _canvas.ActualWidth) - Inset - 200;
            var title = Text(section.Title, Semibold, 16, text, Math.Max(100, limit));
            dc.DrawText(title, new Point(Inset + 30, y + 14));
            dc.DrawText(Text(section.Detail, Regular, 13, secondary), new Point(Inset + 30 + title.WidthIncludingTrailingWhitespace + 10, y + 17));
            if (action is { } button)
            {
                dc.DrawRoundedRectangle(Theme.Brush("Accent"), null, button, 6, 6);
                var label = Text(section.ActionTitle!, Semibold, 12.5, Brushes.White);
                dc.DrawText(label, new Point(button.Left + (button.Width - label.Width) / 2, button.Top + (button.Height - label.Height) / 2));
            }
        }
        for (int r = FirstRowReaching(top); r < _rows.Count && _rows[r].Top <= bottom; r++)
        {
            foreach (var item in _rows[r].Items) DrawCell(dc, item, _positions[item], pixels, text, secondary);
        }
    }

    (string Text, string Brush)? Badge(PhotoItem item)
    {
        if (ShowsNudityScores && item.NudityScore is { } score) return ($"{score * 100:0} %", "BadgePink");
        if (item.Tiny) return (L("Миниатюра"), "BadgePurple");
        if (item.IsDuplicate) return (L("Дубликат"), "BadgeOrange");
        if (item.BetterCopy != null) return (L("Хуже качеством"), "BadgeOrange");
        if (ShowsOriginalBadge && item.BestOfCopies) return (L("Лучшее качество"), "BadgeGreen");
        if (ShowsOriginalBadge && item.Duplicates is { Count: > 0 }) return (L("Оригинал"), "BadgeGreen");
        return null;
    }

    void DrawCell(DrawingContext dc, PhotoItem item, Rect rect, int pixels, Brush text, Brush secondary)
    {
        var clip = new RectangleGeometry(rect, 8, 8);
        dc.DrawGeometry(Theme.Brush("Cell"), null, clip);
        var image = _thumbnails.Get(item, pixels, out bool failed);
        if (image != null)
        {
            // Aspect fill: the middle of the picture fills the square.
            double scale = Math.Max(rect.Width / image.Width, rect.Height / image.Height);
            double w = image.Width * scale, h = image.Height * scale;
            dc.PushClip(clip);
            dc.DrawImage(image, new Rect(rect.X + (rect.Width - w) / 2, rect.Y + (rect.Height - h) / 2, w, h));
            dc.Pop();
        }
        else
        {
            var glyph = Text(Theme.Glyphs[item.Video ? "video" : "photo"], Icons, Math.Max(18, rect.Width / 5), Theme.Brush("Tertiary"));
            dc.DrawText(glyph, new Point(rect.X + (rect.Width - glyph.Width) / 2, rect.Y + (rect.Height - glyph.Height) / 2));
        }
        if (_selected.Contains(item))
        {
            dc.DrawRoundedRectangle(null, new Pen(Theme.Brush("Accent"), 3.5), new Rect(rect.X + 1.5, rect.Y + 1.5, rect.Width - 3, rect.Height - 3), 7, 7);
        }
        else
        {
            dc.DrawGeometry(null, new Pen(Theme.Brush("CellBorder"), 1), clip);
        }
        if (Badge(item) is { } badge) DrawPill(dc, new Point(rect.X + 7, rect.Y + 7), badge.Text, Theme.Brush(badge.Brush));
        if (item.Video && item.Duration > 0)
        {
            var span = TimeSpan.FromSeconds(Math.Round(item.Duration));
            string duration = "▶ " + (span.TotalHours >= 1 ? span.ToString(@"h\:mm\:ss") : span.ToString(@"m\:ss"));
            double width = Text(duration, Semibold, 10.5, Brushes.White).Width + 14;
            DrawPill(dc, new Point(rect.Right - 7 - width, rect.Bottom - 7 - 18), duration, new SolidColorBrush(Color.FromArgb(150, 0, 0, 0)));
        }
        // Caption: the name, then the date and the size.
        var name = Text(item.Name, Regular, 12.5, text, rect.Width + 8);
        name.TextAlignment = TextAlignment.Center;
        dc.DrawText(name, new Point(rect.X - 4, rect.Bottom + 6));
        string size = item.PixelWidth > 0 ? $"{item.PixelWidth}×{item.PixelHeight}" : item.CloudOnly ? L("в облаке") : L("не читается");
        var detail = Text($"{item.DateText()} · {size}", Regular, 11, secondary, rect.Width + 8);
        detail.TextAlignment = TextAlignment.Center;
        dc.DrawText(detail, new Point(rect.X - 4, rect.Bottom + 24));
        _ = failed;
    }

    void DrawPill(DrawingContext dc, Point origin, string label, Brush background)
    {
        var formatted = Text(label, Semibold, 10.5, Brushes.White);
        var rect = new Rect(origin.X, origin.Y, formatted.Width + 14, 18);
        dc.DrawRoundedRectangle(background, null, rect, 9, 9);
        dc.DrawText(formatted, new Point(rect.X + 7, rect.Y + (18 - formatted.Height) / 2));
    }

    // --- Hit testing --------------------------------------------------------------------------------------------

    PhotoItem? ItemAt(Point point)
    {
        int r = FirstRowReaching(point.Y);
        if (r >= _rows.Count || point.Y < _rows[r].Top) return null;
        foreach (var item in _rows[r].Items)
        {
            var rect = _positions[item];
            if (point.X >= rect.Left && point.X <= rect.Right) return item;
        }
        return null;
    }

    Section? ActionAt(Point point)
    {
        foreach (var (rect, section) in _actions) if (rect.Contains(point)) return section;
        return null;
    }

    // --- Mouse and keyboard -------------------------------------------------------------------------------------

    protected override void OnPreviewMouseDown(MouseButtonEventArgs e)
    {
        base.OnPreviewMouseDown(e);
        if (!_canvas.IsMouseOver) return;
        Focus();
        var point = e.GetPosition(_canvas);
        if (e.ChangedButton == MouseButton.Left && e.ClickCount == 1 && ActionAt(point) is { } section)
        {
            section.Action?.Invoke();
            e.Handled = true;
            return;
        }
        var item = ItemAt(point);
        bool control = Keyboard.Modifiers.HasFlag(ModifierKeys.Control), shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        if (e.ChangedButton == MouseButton.Left && e.ClickCount == 2)
        {
            if (item != null) Activated?.Invoke(item);
            e.Handled = true;
            return;
        }
        if (item == null)
        {
            if (e.ChangedButton == MouseButton.Left && !control && !shift)
            {
                _selected.Clear();
                Changed();
            }
            return;
        }
        if (e.ChangedButton == MouseButton.Right)
        {
            if (!_selected.Contains(item))
            {
                _selected = [item];
                _anchor = item;
            }
            Changed();
            return;
        }
        if (e.ChangedButton != MouseButton.Left) return;
        _cursor = null;
        if (shift && _anchor != null && _indexOf.ContainsKey(_anchor))
        {
            int a = Math.Min(_indexOf[_anchor], _indexOf[item]), b = Math.Max(_indexOf[_anchor], _indexOf[item]);
            _selected = _flat.Skip(a).Take(b - a + 1).ToHashSet();
        }
        else if (control)
        {
            if (!_selected.Remove(item)) _selected.Add(item);
            _anchor = item;
        }
        else
        {
            if (!_selected.Contains(item)) _selected = [item];
            _anchor = item;
            _dragStart = point;
            _pressed = item;
        }
        Changed();
    }

    protected override void OnPreviewMouseUp(MouseButtonEventArgs e)
    {
        base.OnPreviewMouseUp(e);
        if (_dragStart != null && _pressed != null && e.ChangedButton == MouseButton.Left && Keyboard.Modifiers == ModifierKeys.None)
        {
            _selected = [_pressed];
            Changed();
        }
        _dragStart = null;
        _pressed = null;
        if (e.ChangedButton == MouseButton.Right && _canvas.IsMouseOver) ContextMenuRequested?.Invoke(e.GetPosition(this));
    }

    protected override void OnPreviewMouseMove(MouseEventArgs e)
    {
        base.OnPreviewMouseMove(e);
        var point = e.GetPosition(_canvas);
        if (_dragStart is { } start && e.LeftButton == MouseButtonState.Pressed && (point - start).Length > 10)
        {
            _dragStart = null;
            _pressed = null;
            var dragged = SelectedItems;
            if (dragged.Count > 0)
            {
                // Files dragged out to File Explorer or another app. Explorer moves them when dropped on the same
                // drive, so afterwards the app looks which ones are gone (as the Mac does).
                var data = new DataObject(DataFormats.FileDrop, dragged.Select(i => i.Path).ToArray());
                _dragging = true;
                try
                {
                    DragDrop.DoDragDrop(this, data, DragDropEffects.Copy | DragDropEffects.Move);
                }
                finally
                {
                    _dragging = false;
                }
                DraggedOut?.Invoke(dragged);
            }
            return;
        }
        _canvas.Cursor = ActionAt(point) != null ? Cursors.Hand : null;
        var hovered = ItemAt(point);
        if (!ReferenceEquals(hovered, _canvas.Tag))
        {
            _canvas.Tag = hovered;
            _canvas.ToolTip = hovered == null ? null : Tooltip(hovered);
        }
    }

    static string Tooltip(PhotoItem item)
    {
        var lines = new List<string> { item.RelativePath.Replace('/', '\\'), $"{item.DateText(true)} — {item.DateSourceText}" };
        if (item.CloudOnly) lines.Add(L("Файлы ещё не загружены из облака: дата взята из файла, на дубликаты не проверялись"));
        if (item.Faces is { Count: > 0 }) lines.Add(F("Лиц на фото: %@", item.Faces.Count));
        if (item.DuplicateOf != null) lines.Add(F("Копия файла %@", item.DuplicateOf.RelativePath.Replace('/', '\\')));
        if (item.DestinationFolder != null) lines.Add(item.NeedsMove ? $"→ {item.DestinationFolder.Replace('/', '\\')}\\" : L("Уже на месте"));
        return string.Join("\n", lines);
    }

    protected override void OnPreviewMouseWheel(MouseWheelEventArgs e)
    {
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
        {
            ZoomRequested?.Invoke(Math.Clamp(CellSize + (e.Delta > 0 ? 20 : -20), 110, 420));
            e.Handled = true;
            return;
        }
        base.OnPreviewMouseWheel(e);
    }

    void Changed()
    {
        _canvas.InvalidateVisual();
        SelectionChanged?.Invoke();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (HandleKey(e.Key)) e.Handled = true;
        else base.OnKeyDown(e);
    }

    /// <summary>The grid's keys; the main window hands them over whatever has the focus. True when used.</summary>
    public bool HandleKey(Key key)
    {
        switch (key)
        {
            case Key.Enter or Key.Space:
                if (SelectedItems.FirstOrDefault() is { } first) Activated?.Invoke(first);
                return true;
            case Key.Delete:
                DeletePressed?.Invoke();
                return true;
            case Key.Home:
                _scroll.ScrollToTop();
                return true;
            case Key.End:
                _scroll.ScrollToBottom();
                return true;
            case Key.PageDown:
                _scroll.PageDown();
                return true;
            case Key.PageUp:
                _scroll.PageUp();
                return true;
            case Key.Left or Key.Right or Key.Up or Key.Down when _flat.Count > 0:
                // From the selected file, or the first one when nothing is selected yet.
                bool extend = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
                var anchor = _anchor != null && _selected.Contains(_anchor) ? _anchor : _flat.FirstOrDefault(_selected.Contains);
                var from = extend && _cursor != null && _indexOf.ContainsKey(_cursor) ? _cursor : anchor;
                int current = from != null && _indexOf.TryGetValue(from, out int i) ? i : -1;
                int target = Math.Clamp(current < 0 ? 0 : Neighbour(current, key), 0, _flat.Count - 1);
                var item = _flat[target];
                if (extend && anchor != null && current >= 0)
                {
                    // Shift+arrows select everything between the anchor and the new position.
                    int a = _indexOf[anchor];
                    _selected = _flat.Skip(Math.Min(a, target)).Take(Math.Abs(a - target) + 1).ToHashSet();
                    _anchor = anchor;
                    _cursor = item;
                }
                else
                {
                    _selected = [item];
                    _anchor = item;
                    _cursor = null;
                }
                ScrollTo(item);
                Changed();
                return true;
        }
        return false;
    }

    /// <summary>Up and down move by visual rows, which restart at every section.</summary>
    int Neighbour(int index, Key key)
    {
        if (key == Key.Left) return index - 1;
        if (key == Key.Right) return index + 1;
        var rect = _positions[_flat[index]];
        int r = FirstRowReaching(rect.Top + 1) + (key == Key.Up ? -1 : 1);
        if (r < 0 || r >= _rows.Count) return index;
        var best = _rows[r].Items.MinBy(item => Math.Abs(_positions[item].Left - rect.Left))!;
        return _indexOf[best];
    }

    void ScrollTo(PhotoItem item)
    {
        var rect = _positions[item];
        if (rect.Top - 10 < _scroll.VerticalOffset) _scroll.ScrollToVerticalOffset(rect.Top - HeaderHeight);
        else if (rect.Bottom + CaptionHeight + 10 > _scroll.VerticalOffset + _scroll.ViewportHeight)
            _scroll.ScrollToVerticalOffset(rect.Bottom + CaptionHeight + 10 - _scroll.ViewportHeight);
    }

    // --- Drops (search by face) -------------------------------------------------------------------------------------

    string? DroppedImage(DragEventArgs e)
    {
        // Never its own files dragged back in: that would start a search by accident.
        if (_dragging || !AcceptsImageDrops || !e.Data.GetDataPresent(DataFormats.FileDrop)) return null;
        return (e.Data.GetData(DataFormats.FileDrop) as string[])?.FirstOrDefault(File.Exists);
    }

    protected override void OnDragEnter(DragEventArgs e)
    {
        if (DroppedImage(e) != null)
        {
            _dropHighlight.Visibility = Visibility.Visible;
            e.Effects = DragDropEffects.Copy;
            e.Handled = true;
        }
    }

    protected override void OnDragOver(DragEventArgs e)
    {
        if (DroppedImage(e) != null)
        {
            e.Effects = DragDropEffects.Copy;
            e.Handled = true;
        }
    }

    protected override void OnDragLeave(DragEventArgs e) => _dropHighlight.Visibility = Visibility.Collapsed;

    protected override void OnDrop(DragEventArgs e)
    {
        _dropHighlight.Visibility = Visibility.Collapsed;
        if (DroppedImage(e) is { } path)
        {
            e.Handled = true;
            ImageDropped?.Invoke(path);
        }
    }
}
