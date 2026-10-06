using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using PhotoOrganizer.Core;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.UI;

/// <summary>The built-in viewer: a photo with zoom, or a video with playback controls; ← and → go through the grid.</summary>
public sealed class Viewer : DockPanel
{
    readonly TextBlock _title = Ui.Text("", "Secondary");
    readonly TextBlock _counter = Ui.Text("", "Secondary");
    readonly Button _previous, _next, _zoomIn, _zoomOut, _reveal;
    // An animated GIF: its frames, put together, and how long each stays.
    readonly DispatcherTimer _animation = new();
    List<(BitmapSource Frame, TimeSpan Delay)> _frames = [];
    int _frame;
    readonly Grid _stage = new() { ClipToBounds = true };
    // On a canvas, placed by hand: a layout panel would clip a zoomed picture to its own cell before it is moved.
    readonly Canvas _canvas = new();
    readonly Image _image = new() { Stretch = Stretch.Fill };
    readonly TextBlock _message = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, FontSize = 15 };
    readonly VideoPlayer _video;
    readonly Image _videoImage = new() { Stretch = Stretch.Uniform };
    readonly DockPanel _videoPanel = new();
    readonly Slider _position = new() { Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _time = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 4, 0), FontSize = 12 };
    readonly Button _play, _openExternally;
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    List<PhotoItem> _items = [];
    int _index;
    double? _zoom;   // null: fit to the window
    Vector _offset;
    Point? _drag;
    bool _seeking, _movingSlider;

    public event Action? Closed;
    /// <summary>Delete: the file on screen goes to the Recycle Bin.</summary>
    public event Action? DeletePressed;
    /// <summary>A right click on the photo or the video, at this point of the viewer.</summary>
    public event Action<Point>? ContextMenuRequested;

    public Viewer()
    {
        Focusable = true;
        FocusVisualStyle = null;
        var bar = Ui.Bar("Toolbar", new Thickness(0, 0, 0, 1));
        var row = new DockPanel { Margin = new Thickness(10, 4, 10, 4) };
        var back = Ui.IconButton("back", L("Назад к сетке") + " (Esc)", () => Close());
        DockPanel.SetDock(back, Dock.Left);
        row.Children.Add(back);
        _previous = Ui.IconButton("back", "←", () => Step(-1));
        _next = Ui.IconButton("forward", "→", () => Step(1));
        _zoomOut = Ui.IconButton("zoom-out", L("Уменьшить") + " (Ctrl −)", ZoomOut);
        _zoomIn = Ui.IconButton("zoom-in", L("Увеличить") + " (Ctrl +)", ZoomIn);
        _reveal = Ui.IconButton("folder", L("Показать в Проводнике"), () =>
        {
            if (Current is { } item) Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{item.Path}\"") { UseShellExecute = true });
        });
        _counter.Margin = new Thickness(8, 0, 8, 0);
        _counter.VerticalAlignment = VerticalAlignment.Center;
        foreach (var element in new FrameworkElement[] { _next, _previous, _counter, _reveal, _zoomIn, _zoomOut })
        {
            DockPanel.SetDock(element, Dock.Right);
            row.Children.Add(element);
        }
        _title.Margin = new Thickness(8, 0, 8, 0);
        _title.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(_title);
        bar.Child = row;
        SetDock(bar, Dock.Top);
        Children.Add(bar);

        _stage.SetResourceReference(BackgroundProperty, "Window");
        _message.SetResourceReference(TextBlock.ForegroundProperty, "Secondary");
        _canvas.Children.Add(_image);
        _stage.Children.Add(_canvas);
        _stage.Children.Add(_message);
        _stage.SizeChanged += (_, _) => Layout();
        _stage.MouseWheel += (_, e) => SetZoom(CurrentScale() * (e.Delta > 0 ? 1.15 : 1 / 1.15), e.GetPosition(_stage));
        _stage.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount == 2) ToggleZoom(e.GetPosition(_stage));
            else { _drag = e.GetPosition(_stage); _stage.CaptureMouse(); }
        };
        _stage.MouseMove += (_, e) =>
        {
            if (_drag is not { } start || _zoom == null) return;
            var now = e.GetPosition(_stage);
            _offset += now - start;
            _drag = now;
            Layout();
        };
        _stage.MouseLeftButtonUp += (_, _) => { _drag = null; _stage.ReleaseMouseCapture(); };
        _stage.MouseRightButtonUp += (_, e) =>
        {
            if (Current == null) return;
            ContextMenuRequested?.Invoke(e.GetPosition(this));
            e.Handled = true;
        };

        // The video: Windows' own player, our controls.
        _video = new VideoPlayer(Dispatcher);
        _play = Ui.IconButton("pause", L("Пауза / воспроизведение") + " (Space)", TogglePlay);
        _time.SetResourceReference(TextBlock.ForegroundProperty, "Secondary");
        var controls = new DockPanel { Margin = new Thickness(12, 6, 12, 10) };
        DockPanel.SetDock(_play, Dock.Left);
        DockPanel.SetDock(_time, Dock.Right);
        controls.Children.Add(_play);
        controls.Children.Add(_time);
        controls.Children.Add(_position);
        DockPanel.SetDock(controls, Dock.Bottom);
        _videoPanel.Children.Add(controls);
        _videoPanel.Children.Add(_videoImage);
        _videoPanel.Visibility = Visibility.Collapsed;
        _video.Opened += picture =>
        {
            _message.Text = "";
            _videoImage.Source = picture;
            _position.Maximum = Math.Max(_video.Duration.TotalSeconds, 0.1);
            _play.Content = Theme.Glyphs["pause"];
            _timer.Start();
        };
        _video.Failed += () =>
        {
            _videoPanel.Visibility = Visibility.Collapsed;
            _timer.Stop();
            _message.Text = L("Видео не воспроизводится");
            _openExternally!.Visibility = Visibility.Visible;
        };
        _video.Ended += () => _play.Content = Theme.Glyphs["play"];
        _timer.Tick += (_, _) =>
        {
            if (!_seeking)
            {
                _movingSlider = true;
                _position.Value = _video.Position.TotalSeconds;
                _movingSlider = false;
            }
            _time.Text = $"{Clock(_video.Position)} / {Clock(_video.Duration)}";
            _play.Content = Theme.Glyphs[_video.Playing ? "pause" : "play"];
        };
        // A click on the track or a drag of the knob moves the video there at once, showing the frame while dragging.
        _position.PreviewMouseLeftButtonDown += (_, _) => _seeking = true;
        _position.PreviewMouseLeftButtonUp += (_, _) =>
        {
            _video.Position = TimeSpan.FromSeconds(_position.Value);
            _seeking = false;
        };
        _position.ValueChanged += (_, _) =>
        {
            if (!_movingSlider) _video.Position = TimeSpan.FromSeconds(_position.Value);
        };
        _stage.Children.Add(_videoPanel);
        _openExternally = Ui.TextButton(L("Открыть в программе по умолчанию"), () =>
        {
            if (Current is { } item) Process.Start(new ProcessStartInfo(item.Path) { UseShellExecute = true });
        });
        _openExternally.HorizontalAlignment = HorizontalAlignment.Center;
        _openExternally.VerticalAlignment = VerticalAlignment.Center;
        _openExternally.Margin = new Thickness(0, 70, 0, 0);
        _openExternally.Visibility = Visibility.Collapsed;
        _stage.Children.Add(_openExternally);
        Children.Add(_stage);
        _animation.Tick += (_, _) =>
        {
            if (_frames.Count == 0) return;
            _frame = (_frame + 1) % _frames.Count;
            _image.Source = _frames[_frame].Frame;
            _animation.Interval = _frames[_frame].Delay;
        };
    }

    static string Clock(TimeSpan time) => time.TotalHours >= 1 ? time.ToString(@"h\:mm\:ss") : time.ToString(@"m\:ss");

    public PhotoItem? Current => _index >= 0 && _index < _items.Count ? _items[_index] : null;

    public void Show(List<PhotoItem> items, int index)
    {
        _items = items;
        _index = index;
        ShowCurrent();
        Focus();
    }

    public void Step(int delta)
    {
        if (_items.Count == 0) return;
        _index = Math.Clamp(_index + delta, 0, _items.Count - 1);
        ShowCurrent();
    }

    public void Stop()
    {
        _timer.Stop();
        _animation.Stop();
        _frames = [];
        _video.Stop();
        _videoImage.Source = null;
        _openExternally.Visibility = Visibility.Collapsed;
    }

    void Close()
    {
        Stop();
        Closed?.Invoke();
    }

    void ShowCurrent()
    {
        Stop();
        if (Current is not { } item)
        {
            Close();
            return;
        }
        // As on the Mac: where the file is, its date, size and what organizing does with it.
        var info = new List<string> { item.RelativePath.Replace('/', '\\'), item.DateText(true) };
        if (item.PixelWidth > 0) info.Add($"{item.PixelWidth}×{item.PixelHeight}");
        info.Add(Strings.Size(item.FileSize));
        if (item.IsDuplicate) info.Add(L("дубликат"));
        if (item.Tiny) info.Add(L("миниатюра"));
        if (item.DestinationFolder != null) info.Add(item.NeedsMove ? "→ " + item.DestinationFolder.Replace('/', '\\') : L("уже на месте"));
        _title.Text = string.Join("  ·  ", info);
        _title.ToolTip = item.Path;
        _counter.Text = F("%@ из %@", Number(_index + 1), Number(_items.Count));
        _previous.IsEnabled = _index > 0;
        _next.IsEnabled = _index < _items.Count - 1;
        _zoomIn.Visibility = _zoomOut.Visibility = item.Video ? Visibility.Collapsed : Visibility.Visible;
        _image.Source = null;
        _message.Text = "";
        _zoom = null;
        _offset = default;
        if (item.Video)
        {
            _videoPanel.Visibility = Visibility.Visible;
            _position.Value = 0;
            _time.Text = "";
            _message.Text = L("Загрузка…");
            _video.Open(item.Path);
            return;
        }
        _videoPanel.Visibility = Visibility.Collapsed;
        _message.Text = L("Загрузка…");
        string path = item.Path;
        Task.Run(() => Thumbnails.Bitmap(Images.Load(path, 8192))).ContinueWith(task =>
        {
            if (Current?.Path != path) return;
            _image.Source = task.Result;
            _message.Text = task.Result == null ? L("Не удалось открыть файл") : "";
            Layout();
            if (task.Result != null && path.EndsWith(".gif", StringComparison.OrdinalIgnoreCase)) Animate(path);
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    /// <summary>
    /// Plays an animated GIF, as the Mac's viewer does. Each frame of the file is a patch drawn over the ones before;
    /// they are put together here once (on this thread: WPF draws only on it), up to a size that stays reasonable.
    /// </summary>
    void Animate(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var decoder = new GifBitmapDecoder(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
            if (decoder.Frames.Count < 2) return;
            int width = decoder.Frames[0].PixelWidth, height = decoder.Frames[0].PixelHeight;
            if (decoder.Metadata?.GetQuery("/logscrdesc/Width") is ushort w && decoder.Metadata.GetQuery("/logscrdesc/Height") is ushort h) (width, height) = (w, h);
            if (width <= 0 || height <= 0 || (long)width * height * decoder.Frames.Count > 150_000_000 || decoder.Frames.Count > 500) return;
            var frames = new List<(BitmapSource, TimeSpan)>();
            BitmapSource? previous = null;
            foreach (var frame in decoder.Frames)
            {
                var metadata = frame.Metadata as BitmapMetadata;
                T Query<T>(string query, T fallback) => metadata?.GetQuery(query) is T value ? value : fallback;
                var area = new Rect(Query<ushort>("/imgdesc/Left", 0), Query<ushort>("/imgdesc/Top", 0), frame.PixelWidth, frame.PixelHeight);
                int delay = Query<ushort>("/grctlext/Delay", 10);
                int disposal = Query<byte>("/grctlext/Disposal", 0);
                var visual = new DrawingVisual();
                using (var dc = visual.RenderOpen())
                {
                    if (previous != null) dc.DrawImage(previous, new Rect(0, 0, width, height));
                    dc.DrawImage(frame, area);
                }
                var composed = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
                composed.Render(visual);
                composed.Freeze();
                // Browsers show frames said to last under 20 ms for 100 ms; so does this.
                frames.Add((composed, TimeSpan.FromMilliseconds(delay < 2 ? 100 : delay * 10)));
                if (disposal == 2)
                {
                    // Its patch is cleared before the next frame.
                    var cleared = new DrawingVisual();
                    using (var dc = cleared.RenderOpen())
                    {
                        dc.PushClip(new CombinedGeometry(GeometryCombineMode.Exclude, new RectangleGeometry(new Rect(0, 0, width, height)), new RectangleGeometry(area)));
                        dc.DrawImage(composed, new Rect(0, 0, width, height));
                        dc.Pop();
                    }
                    var next = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
                    next.Render(cleared);
                    next.Freeze();
                    previous = next;
                }
                else if (disposal != 3)
                {
                    previous = composed;   // 3: the next frame is drawn over what was there before this one
                }
            }
            if (Current?.Path != path) return;
            _frames = frames;
            _frame = 0;
            _image.Source = frames[0].Item1;
            Layout();
            _animation.Interval = frames[0].Item2;
            _animation.Start();
        }
        catch (Exception e) when (e is IOException or NotSupportedException or ArgumentException or InvalidOperationException
                                    or UnauthorizedAccessException or System.Runtime.InteropServices.COMException or FileFormatException)
        {
            // Shown still, as its first frame.
        }
    }

    /// <summary>
    /// Bitmap pixels per screen pixel that fit the picture in the window — never above 1: a small picture is shown at
    /// its own size, as on the Mac. The stage is measured in device-independent units and the bitmap in pixels, so the
    /// display scaling (125 %, 150 %) is taken into account.
    /// </summary>
    double FitScale()
    {
        if (_image.Source is not BitmapSource source || _stage.ActualWidth <= 0) return 1;
        double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        return Math.Min(1, Math.Min(_stage.ActualWidth * dpi / source.PixelWidth, _stage.ActualHeight * dpi / source.PixelHeight));
    }

    double CurrentScale() => _zoom ?? FitScale();

    /// <summary>A new scale (null: fit the window), keeping the point `at` of the stage over the same spot of the picture.</summary>
    void SetZoom(double? zoom, Point? at = null)
    {
        if (_image.Source == null) return;
        double before = CurrentScale();
        _zoom = zoom == null ? null : Math.Clamp(zoom.Value, 0.05, 16);
        if (_zoom == null)
        {
            _offset = default;
        }
        else
        {
            var anchor = at ?? new Point(_stage.ActualWidth / 2, _stage.ActualHeight / 2);
            var centre = new Point(_stage.ActualWidth / 2 + _offset.X, _stage.ActualHeight / 2 + _offset.Y);
            double ratio = _zoom.Value / before;
            // The picture's centre moves away from the anchor in proportion to the scale.
            var moved = anchor + (centre - anchor) * ratio;
            _offset = new Vector(moved.X - _stage.ActualWidth / 2, moved.Y - _stage.ActualHeight / 2);
        }
        Layout();
    }

    /// <summary>Fit the window ↔ 100 % (a small picture, already at 100 %, doubles), at the point clicked.</summary>
    void ToggleZoom(Point at)
    {
        double fit = FitScale();
        bool fitted = _zoom == null || Math.Abs(_zoom.Value - fit) < 0.001;
        SetZoom(fitted ? (fit < 1 ? 1 : 2) : null, at);
    }

    public void ZoomIn() => SetZoom(CurrentScale() * 1.5);
    public void ZoomOut() => SetZoom(CurrentScale() / 1.5);
    public void ZoomToFit() => SetZoom(null);
    public void ZoomToActualSize() => SetZoom(1);

    void Layout()
    {
        if (_image.Source is not BitmapSource source) return;
        double scale = CurrentScale();
        // The bitmap's pixels at the chosen scale, whatever the display's DPI.
        double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        _image.Width = source.PixelWidth * scale / dpi;
        _image.Height = source.PixelHeight * scale / dpi;
        // Centred, then moved by the drag.
        Canvas.SetLeft(_image, (_stage.ActualWidth - _image.Width) / 2 + _offset.X);
        Canvas.SetTop(_image, (_stage.ActualHeight - _image.Height) / 2 + _offset.Y);
        RenderOptions.SetBitmapScalingMode(_image, BitmapScalingMode.HighQuality);
    }

    void TogglePlay()
    {
        bool playing = _video.Playing;
        if (playing) _video.Pause(); else _video.Play();
        _play.Content = Theme.Glyphs[playing ? "play" : "pause"];
    }

    /// <summary>The viewer's keys; the main window hands them over whatever has the focus. True when used.</summary>
    public bool HandleKey(Key key)
    {
        bool control = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        switch (key)
        {
            case Key.Escape:
            case Key.Up when control:
                Close();
                break;
            case Key.Delete when Current != null: DeletePressed?.Invoke(); break;
            case Key.Left: Step(-1); break;
            case Key.Right: Step(1); break;
            case Key.Space when _videoPanel.Visibility == Visibility.Visible: TogglePlay(); break;
            case Key.OemPlus or Key.Add: ZoomIn(); break;
            case Key.OemMinus or Key.Subtract: ZoomOut(); break;
            default: return false;
        }
        return true;
    }
}
