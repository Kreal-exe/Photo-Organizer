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
    readonly Button _previous, _next, _zoomIn, _zoomOut;
    readonly Grid _stage = new() { ClipToBounds = true };
    // On a canvas, placed by hand: a layout panel would clip a zoomed picture to its own cell before it is moved.
    readonly Canvas _canvas = new();
    readonly Image _image = new() { Stretch = Stretch.Fill };
    readonly TextBlock _message = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, FontSize = 15 };
    readonly MediaElement _video = new() { LoadedBehavior = MediaState.Manual, UnloadedBehavior = MediaState.Stop, Stretch = Stretch.Uniform, ScrubbingEnabled = true };
    readonly DockPanel _videoPanel = new();
    readonly Slider _position = new() { Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
    readonly Button _play;
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    List<PhotoItem> _items = [];
    int _index;
    double? _zoom;   // null: fit to the window
    Vector _offset;
    Point? _drag;
    bool _playing, _seeking, _movingSlider;

    public event Action? Closed;
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
        _zoomOut = Ui.IconButton("zoom-out", L("Уменьшить") + " (Ctrl −)", () => SetZoom(CurrentScale() / 1.25));
        _zoomIn = Ui.IconButton("zoom-in", L("Увеличить") + " (Ctrl +)", () => SetZoom(CurrentScale() * 1.25));
        foreach (var button in new[] { _next, _previous, _zoomIn, _zoomOut })
        {
            DockPanel.SetDock(button, Dock.Right);
            row.Children.Add(button);
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
        _stage.MouseWheel += (_, e) => SetZoom(CurrentScale() * (e.Delta > 0 ? 1.15 : 1 / 1.15));
        _stage.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount == 2) SetZoom(_zoom == null ? 1 : null);
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

        _play = Ui.IconButton("pause", L("Пауза / воспроизведение") + " (Space)", TogglePlay);
        var controls = new DockPanel { Margin = new Thickness(12, 6, 12, 10) };
        DockPanel.SetDock(_play, Dock.Left);
        controls.Children.Add(_play);
        controls.Children.Add(_position);
        DockPanel.SetDock(controls, Dock.Bottom);
        _videoPanel.Children.Add(controls);
        _videoPanel.Children.Add(_video);
        _videoPanel.Visibility = Visibility.Collapsed;
        _video.MediaOpened += (_, _) =>
        {
            if (_video.NaturalDuration.HasTimeSpan) _position.Maximum = _video.NaturalDuration.TimeSpan.TotalSeconds;
        };
        _video.MediaFailed += (_, _) =>
        {
            _videoPanel.Visibility = Visibility.Collapsed;
            _message.Text = L("Видео не воспроизводится");
        };
        _video.MediaEnded += (_, _) => { _playing = false; _play.Content = Theme.Glyphs["play"]; };
        _timer.Tick += (_, _) =>
        {
            if (_seeking) return;
            _movingSlider = true;
            _position.Value = _video.Position.TotalSeconds;
            _movingSlider = false;
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
        Children.Add(_stage);
    }

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
        _video.Stop();
        _video.Source = null;
        _playing = false;
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
        _title.Text = $"{item.Name}   ·   {item.DateText(true)}   ·   {_index + 1} / {_items.Count}";
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
            _video.Source = new Uri(item.Path);
            _video.Play();
            _playing = true;
            _play.Content = Theme.Glyphs["pause"];
            _timer.Start();
            return;
        }
        _videoPanel.Visibility = Visibility.Collapsed;
        _message.Text = L("Загрузка…");
        string path = item.Path;
        Task.Run(() => Thumbnails.Bitmap(Images.Load(path, 8192))).ContinueWith(task =>
        {
            if (Current?.Path != path) return;
            _image.Source = task.Result;
            _message.Text = task.Result == null ? L("Файл не читается") : "";
            Layout();
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    /// <summary>
    /// Bitmap pixels per screen pixel that fill the window, small pictures included. The stage is measured in
    /// device-independent units and the bitmap in pixels, so the display scaling (125 %, 150 %) is taken into account.
    /// </summary>
    double FitScale()
    {
        if (_image.Source is not BitmapSource source || _stage.ActualWidth <= 0) return 1;
        double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        return Math.Min(_stage.ActualWidth * dpi / source.PixelWidth, _stage.ActualHeight * dpi / source.PixelHeight);
    }

    double CurrentScale() => _zoom ?? FitScale();

    void SetZoom(double? zoom)
    {
        if (_image.Source == null) return;
        _zoom = zoom == null ? null : Math.Clamp(zoom.Value, 0.05, 16);
        if (_zoom == null) _offset = default;
        Layout();
    }

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
        if (_playing) _video.Pause(); else _video.Play();
        _playing = !_playing;
        _play.Content = Theme.Glyphs[_playing ? "pause" : "play"];
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
            case Key.Left: Step(-1); break;
            case Key.Right: Step(1); break;
            case Key.Space when _videoPanel.Visibility == Visibility.Visible: TogglePlay(); break;
            case Key.OemPlus or Key.Add: SetZoom(CurrentScale() * 1.25); break;
            case Key.OemMinus or Key.Subtract: SetZoom(CurrentScale() / 1.25); break;
            case Key.D0 or Key.NumPad0: SetZoom(1); break;
            case Key.D9 or Key.NumPad9: SetZoom(null); break;
            default: return false;
        }
        return true;
    }
}
