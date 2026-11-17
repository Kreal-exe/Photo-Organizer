using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using PhotoOrganizer.Core;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.UI;

/// <summary>
/// "Сжать…": what compressing the chosen files would give before anything is touched. RAW photos become JPEGs of the
/// size most photos of the library have (offered first), HDR kept; videos come down to a chosen height (1080p unless
/// asked otherwise) at a bitrate that loses nothing visible, HDR kept, and only those that weigh too much for what they
/// show are taken. Sizes after are estimated: photos from a trial compression of two of them, videos from their bitrate.
/// </summary>
public sealed class CompressDialog : Dialog
{
    readonly List<PhotoItem> _raws, _videos;
    readonly (int Megapixels, long BytesPerMegapixel, int Count) _typical;
    readonly int _rawMegapixels;
    readonly CheckBox _photosOn = new(), _videosOn = new();
    readonly ComboBox _megapixels = new() { Width = 340, HorizontalAlignment = HorizontalAlignment.Left };
    readonly ComboBox _height = new() { Width = 220, HorizontalAlignment = HorizontalAlignment.Left };
    // Wide enough for the longest level ("Высокое — разница видна только при покадровом сравнении").
    readonly ComboBox _quality = new() { MinWidth = 460, HorizontalAlignment = HorizontalAlignment.Left };
    readonly TextBlock _photoEstimate = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };
    readonly TextBlock _videoEstimate = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };
    readonly TextBlock _total = new() { TextWrapping = TextWrapping.Wrap, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 4, 0, 6) };
    readonly Button _confirm, _download;
    readonly List<int> _sizes = [];
    readonly Dictionary<PhotoItem, VideoInfo> _probed = [];
    readonly CancellationTokenSource _closing = new();
    // The trial compression: bytes per photo at each size tried.
    readonly Dictionary<int, double> _sampled = [];
    int _probeDone;
    bool _probing;

    public CompressDialog(Window owner, List<PhotoItem> items, IEnumerable<PhotoItem> library) : base(owner, L("Сжать"), 780)
    {
        // Wider by dragging its edge: the rows of resolutions are long, and their lists open under them. Taller too, up
        // to the whole screen (the base keeps a dialog shorter than the screen; this one sizes itself, see Grow).
        ResizeMode = ResizeMode.CanResize;
        MinWidth = 560;
        MinHeight = 360;
        MaxHeight = double.PositiveInfinity;
        _raws = items.Where(i => Compression.IsRaw(i) && !i.CloudOnly).ToList();
        _videos = items.Where(i => i.Video && !i.CloudOnly).ToList();
        // The videos of live photos: short, next to a photo of the same name (IMG_1234.HEIC and .MOV, MVIMG_….jpg and
        // .MP4). Squeezed they lose a little more than the others, for little: apart, and left alone unless ticked.
        var photoNames = library.Where(i => !i.Video).Select(LiveKey).ToHashSet(StringComparer.OrdinalIgnoreCase);
        _live = _videos.Where(v => v.Duration is > 0 and <= 5 && photoNames.Contains(LiveKey(v))).ToHashSet();
        _typical = Compression.TypicalPhoto(library);
        // The largest of the RAW photos: every size up to it is offered (12, 24, 48 MP and the library's own).
        _rawMegapixels = _raws.Count == 0 ? 0 : _raws.Max(i => (int)Math.Round(i.PixelWidth * (double)i.PixelHeight / 1e6));
        Heading(L("Сжать"));
        Note(L("Сжатые файлы занимают место оригиналов: RAW станет JPEG с тем же именем, видео останется под своим именем. Оригиналы уходят в Корзину — их можно вернуть оттуда, пока Корзина не очищена."), "Secondary", 8);

        // Where the originals go: the Recycle Bin, or a folder of one's own — the Bin of a disk holds a part of it, and
        // Windows deletes what does not fit for good, without asking.
        _roots = library.Select(i => i.Root).Where(r => r.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        _originalsFolder = Compressor.OriginalsFolder is { } saved && WhyNotOriginalsFolder(saved, _roots) == null ? saved : null;
        _keepOn.IsChecked = _originalsFolder != null;
        _keepOn.Content = Wrapped(L("Оригиналы — в отдельную папку, а не в Корзину"));
        _keepOn.ToolTip = L("Корзина диска вмещает только часть его объёма (обычно 5 %), а что не помещается, Windows удаляет навсегда. В папке оригиналы лежат, пока вы их не удалите, — в тех же подпапках, что и были.");
        _keepOn.Click += (_, _) =>
        {
            if (_keepOn.IsChecked == true && _originalsFolder == null)
                _originalsFolder = ChooseOriginalsFolder(this, _roots, SuggestedOriginalsFolder(_videos.Concat(_raws)));
            _keepOn.IsChecked = _originalsFolder != null && _keepOn.IsChecked == true;
            UpdateKeep();
        };
        var choose = Ui.TextButton(L("Другая папка…"), () =>
        {
            if (ChooseOriginalsFolder(this, _roots, _originalsFolder ?? SuggestedOriginalsFolder(_videos.Concat(_raws))) is { } folder)
            {
                _originalsFolder = folder;
                _keepOn.IsChecked = true;
                UpdateKeep();
            }
        });
        choose.Margin = new Thickness(10, 0, 0, 0);
        choose.Padding = new Thickness(8, 1, 8, 1);
        choose.VerticalAlignment = VerticalAlignment.Top;
        var keepRow = new DockPanel { Margin = new Thickness(0, 0, 0, 2) };
        DockPanel.SetDock(choose, Dock.Right);
        keepRow.Children.Add(choose);
        keepRow.Children.Add(_keepOn);
        Body.Children.Add(keepRow);
        _keepPath.Margin = new Thickness(24, 0, 0, 14);
        _keepPath.TextWrapping = TextWrapping.Wrap;
        Body.Children.Add(_keepPath);
        UpdateKeep();

        // Photos.
        if (_raws.Count > 0)
        {
            _photosOn.Content = F("RAW-фото: %@ · %@", Number(_raws.Count), Size(_raws.Sum(i => i.FileSize)));
            _photosOn.FontWeight = FontWeights.SemiBold;
            _photosOn.IsChecked = true;
            _photosOn.Click += (_, _) => Update();
            Body.Children.Add(_photosOn);
            var photos = new StackPanel { Margin = new Thickness(24, 6, 0, 16) };
            photos.Children.Add(Label(L("Размер")));
            // As most photos of the library first, then the usual sizes up to the RAW's own.
            foreach (int mp in new[] { _typical.Megapixels, 12, 24, 48 }.Where(mp => mp > 0 && (_rawMegapixels == 0 || mp <= _rawMegapixels)).Distinct())
            {
                _sizes.Add(mp);
                _megapixels.Items.Add(mp == _typical.Megapixels && _typical.Count > 0
                    ? F("%@ МП — как большинство фото в медиатеке (%@)", mp, Number(_typical.Count))
                    : _rawMegapixels > 0 && mp >= _rawMegapixels ? F("%@ МП — как в оригинале", mp) : F("%@ МП", mp));
            }
            if (_sizes.Count == 0)
            {
                _sizes.Add(_rawMegapixels);
                _megapixels.Items.Add(F("%@ МП — как в оригинале", _rawMegapixels));
            }
            _megapixels.SelectedIndex = 0;
            _megapixels.SelectionChanged += (_, _) => { Update(); Sample(); };
            photos.Children.Add(_megapixels);
            var hdr = Ui.Text(L("HDR сохраняется: JPEG с картой яркости (Ultra HDR, ISO 21496-1) — яркие места светятся на HDR-экранах, как в оригинале на iPhone. Дата, место и камера — как в оригинале."), "Hint");
            hdr.TextWrapping = TextWrapping.Wrap;
            hdr.Margin = new Thickness(0, 8, 0, 0);
            photos.Children.Add(hdr);
            photos.Children.Add(_photoEstimate);
            Body.Children.Add(photos);
        }

        // Videos.
        _download = Ui.TextButton(L("Скачать FFmpeg"), DownloadFFmpeg);
        if (_videos.Count > 0)
        {
            _videosOn.Content = F("Видео: %@ · %@", Number(_videos.Count), Size(_videos.Sum(i => i.FileSize)));
            _videosOn.FontWeight = FontWeights.SemiBold;
            _videosOn.IsChecked = true;
            _videosOn.Click += (_, _) => Update();
            Body.Children.Add(_videosOn);
            var videos = new StackPanel { Margin = new Thickness(24, 6, 0, 16) };
            videos.Children.Add(Label(L("Разрешение не больше")));
            foreach (int height in Compression.VideoHeights)
            {
                _height.Items.Add(height == 2160 ? L("4K (2160p)") : height == Compression.DefaultVideoHeight ? F("%@p — рекомендуется", height) : $"{height}p");
            }
            _height.SelectedIndex = Array.IndexOf(Compression.VideoHeights, Settings.Shared.Get("compressVideoHeight", Compression.DefaultVideoHeight)) is >= 0 and var h ? h : 1;
            _height.SelectionChanged += (_, _) => Update();
            videos.Children.Add(_height);
            videos.Children.Add(Label(L("Качество")));
            foreach (string quality in Compression.VideoQualityNames) _quality.Items.Add(quality);
            _quality.SelectedIndex = Math.Clamp(Settings.Shared.Get("compressVideoLevel", Compression.DefaultVideoQuality), 0, Compression.VideoQualityNames.Length - 1);
            _quality.SelectionChanged += (_, _) => Update();
            videos.Children.Add(_quality);
            // Which videos, by their resolution: 4K takes the most, 1080p little — each with what it would give.
            videos.Children.Add(Label(L("Какие видео сжимать")));
            videos.Children.Add(_classes);
            var hdr = Ui.Text(L("HDR сохраняется: HEVC 10 бит с тем же описанием цвета (HLG, PQ), Dolby Vision, HDR Vivid и HDR10+ — в каждом кадре. Без B-кадров, ключевой кадр каждую секунду — плавно на телефоне. Звук, дата и место съёмки — как в оригинале. Видео, которые и так весят немного, не трогаются."), "Hint");
            hdr.TextWrapping = TextWrapping.Wrap;
            hdr.Margin = new Thickness(0, 8, 0, 0);
            videos.Children.Add(hdr);
            videos.Children.Add(_videoEstimate);
            _download.HorizontalAlignment = HorizontalAlignment.Left;
            _download.Margin = new Thickness(0, 8, 0, 0);
            videos.Children.Add(_download);
            Body.Children.Add(videos);
        }
        if (_raws.Count == 0 && _videos.Count == 0)
        {
            Note(L("Среди выбранных файлов нет RAW-фото и видео — сжимать нечего. Обычные JPEG и HEIC уже сжаты."), "Secondary");
        }
        Body.Children.Add(_total);

        _confirm = AddButton(L("Сжать"), Confirm, primary: true);
        AddButton(L("Отмена"), () => DialogResult = false).IsCancel = true;
        Finish();
        Closed += (_, _) =>
        {
            _closing.Cancel();
            // What was read so far stays for the next time (see VideoCompressor.ProbeRemembered).
            Task.Run(VideoCompressor.SaveProbed);
        };
        Loaded += (_, _) =>
        {
            // From here the window keeps the height it has (so it can be dragged taller or maximized); Grow raises
            // it when more rows appear.
            SizeToContent = SizeToContent.Manual;
            SizeChanged += (_, e) =>
            {
                if (e.HeightChanged && Math.Abs(e.NewSize.Height - _grownTo) > 1 && WindowState == WindowState.Normal) _sizedByUser = true;
            };
            Grow();
            Sample();
            Probe();
        };
        Update();
    }

    static TextBlock Label(string text)
    {
        var label = Ui.Text(text, "Secondary");
        label.Margin = new Thickness(0, 6, 0, 4);
        return label;
    }

    readonly CheckBox _keepOn = new() { VerticalAlignment = VerticalAlignment.Top };
    readonly TextBlock _keepPath = Ui.Text("", "Hint");
    readonly List<string> _roots;
    string? _originalsFolder;

    /// <summary>The folder the originals go to; null: the Recycle Bin.</summary>
    public string? OriginalsFolder => _keepOn.IsChecked == true ? _originalsFolder : null;

    void UpdateKeep() =>
        _keepPath.Text = OriginalsFolder is { } folder
            ? F("В «%@», в тех же подпапках: например, %@", folder, Compressor.KeptPath(folder, (_videos.FirstOrDefault() ?? _raws.FirstOrDefault())?.Path ?? Path.Combine(folder, "…")))
            : L("Оригиналы — в Корзину диска, на котором лежат.");

    /// <summary>A folder next to the library, on the disk most of the files are on: "D:\Оригиналы до сжатия".</summary>
    public static string SuggestedOriginalsFolder(IEnumerable<PhotoItem> items)
    {
        string root = items.GroupBy(i => Path.GetPathRoot(i.Path) ?? "", StringComparer.OrdinalIgnoreCase)
                           .OrderByDescending(g => g.Sum(i => i.FileSize)).Select(g => g.Key).FirstOrDefault() is { Length: > 0 } r ? r : "C:\\";
        return Path.Combine(root, L("Оригиналы до сжатия"));
    }

    /// <summary>Why `folder` cannot take the originals: inside the library (they would be read as part of it), or holding it.</summary>
    public static string? WhyNotOriginalsFolder(string folder, IEnumerable<string> roots)
    {
        string f = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder)) + "\\";
        foreach (string root in roots)
        {
            string r = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)) + "\\";
            if (f.StartsWith(r, StringComparison.OrdinalIgnoreCase) || r.StartsWith(f, StringComparison.OrdinalIgnoreCase))
                return F("Папка «%@» — часть медиатеки «%@»: оригиналы попали бы в неё снова. Выберите папку вне медиатеки.", folder, root.TrimEnd('\\'));
        }
        return null;
    }

    /// <summary>Asks for the folder of the originals (created if missing); null when cancelled or not allowed.</summary>
    public static string? ChooseOriginalsFolder(Window owner, IEnumerable<string> roots, string suggested)
    {
        var picker = new Microsoft.Win32.OpenFolderDialog { Title = L("Куда переносить оригиналы"), InitialDirectory = Directory.Exists(suggested) ? suggested : Path.GetPathRoot(suggested) };
        string? chosen = null;
        // The folder suggested is offered as it is, the picker for another one.
        var answer = MessageBox.Show(owner, F("Переносить оригиналы в «%@»? Папка будет создана, оригиналы лягут в неё в тех же подпапках.\n\n«Нет» — выбрать другую папку.", suggested),
                                     L("Куда переносить оригиналы"), MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
        if (answer == MessageBoxResult.Cancel) return null;
        if (answer == MessageBoxResult.Yes) chosen = suggested;
        else if (picker.ShowDialog(owner) == true) chosen = picker.FolderName;
        if (chosen == null) return null;
        if (WhyNotOriginalsFolder(chosen, roots) is { } why)
        {
            MessageBox.Show(owner, why, L("Куда переносить оригиналы"), MessageBoxButton.OK, MessageBoxImage.Warning);
            return null;
        }
        try
        {
            Directory.CreateDirectory(chosen);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            MessageBox.Show(owner, e.Message, L("Куда переносить оригиналы"), MessageBoxButton.OK, MessageBoxImage.Warning);
            return null;
        }
        return chosen;
    }

    public int Megapixels => _sizes.Count == 0 ? 12 : _sizes[Math.Max(0, _megapixels.SelectedIndex)];
    int VideoHeight => Compression.VideoHeights[Math.Max(0, _height.SelectedIndex)];
    int VideoQuality => Math.Max(0, _quality.SelectedIndex);

    /// <summary>The RAW photos to compress, when chosen.</summary>
    public List<PhotoItem> Photos => _photosOn.IsChecked == true ? _raws : [];

    /// <summary>The videos worth compressing with what is chosen (the size, the quality, the resolutions ticked), and how.</summary>
    public List<(PhotoItem Item, VideoInfo Info, VideoJob Job)> Videos =>
        _videosOn.IsChecked != true ? [] : AllJobs().Where(v => IsLive(v.Item) && !v.Job.Rebuild ? _liveOn : v.Job.Again ? _againOn : _classOn[Compression.ResolutionClass(v.Info)]).ToList();

    /// <summary>
    /// Every video worth compressing with the size and quality chosen, whatever its resolution — not those that will not
    /// get a fifth smaller (WontShrinkJobs).
    /// </summary>
    List<(PhotoItem Item, VideoInfo Info, VideoJob Job)> AllJobs() => PlannedJobs().Where(v => v.Why == null).Select(v => (v.Item, v.Info, v.Job)).ToList();

    /// <summary>The videos that will not get a fifth smaller at the quality chosen, each with why (see WontShrink).</summary>
    List<(PhotoItem Item, VideoInfo Info, VideoJob Job, string Why)> WontShrinkJobs() =>
        PlannedJobs().Where(v => v.Why != null && !IsLive(v.Item) && !v.Job.Again).Select(v => (v.Item, v.Info, v.Job, v.Why!)).ToList();

    List<(PhotoItem Item, VideoInfo Info, VideoJob Job, string? Why)> PlannedJobs() =>
        _videos.Where(_probed.ContainsKey)
               .Select(i => (Item: i, Info: _probed[i], Screen: MediaTypes.IsScreenRecording(i)))
               .Select(v => (v.Item, v.Info, v.Screen, Job: Compression.PlanVideo(v.Info, VideoHeight, VideoQuality, v.Screen)))
               .Where(v => v.Job != null)
               .Select(v => (v.Item, v.Info, v.Job!, WontShrink.Reason(v.Item.Path, v.Info, v.Job!, v.Screen)))
               .ToList();

    readonly StackPanel _classes = new();
    /// <summary>The list of videos open under a row, and whether the rows are to be built anew once it closes.</summary>
    Popup? _openList;
    bool _classesStale;
    /// <summary>The resolutions ticked (Compression.ResolutionNames); all of them at first.</summary>
    readonly bool[] _classOn = [true, true, true, true];
    /// <summary>The videos compressed already, squeezed further: only when ticked.</summary>
    bool _againOn;
    /// <summary>The videos of live photos (see the constructor), and whether they are compressed too.</summary>
    readonly HashSet<PhotoItem> _live;
    bool _liveOn;

    /// <summary>
    /// A live photo's video: next to a photo of its name, or — whatever it is called (IMG_5871_HEVC.MOV beside
    /// IMG_5871.HEIC: 359 of them in one library went in with the other videos) — carrying Apple's live photo identifier.
    /// </summary>
    bool IsLive(PhotoItem item) => _live.Contains(item) || (_probed.TryGetValue(item, out var info) && info.LivePhoto);

    static string LiveKey(PhotoItem item) => Path.Combine(Path.GetDirectoryName(item.Path) ?? "", Path.GetFileNameWithoutExtension(item.Name));

    /// <summary>A checkbox for each resolution found: "4K: 1 234 видео · 400 ГБ → 90 ГБ (−78 %)".</summary>
    void UpdateClasses()
    {
        if (_openList is { IsOpen: true })
        {
            _classesStale = true;
            return;
        }
        _classesStale = false;
        var all = AllJobs();
        var found = _probed.Values.Select(Compression.ResolutionClass).ToHashSet();
        _classes.Children.Clear();
        for (int index = 0; index < Compression.ResolutionNames.Length; index++)
        {
            if (!found.Contains(index)) continue;
            int kind = index;
            var jobs = all.Where(v => Compression.ResolutionClass(v.Info) == kind && !v.Job.Again && (v.Job.Rebuild || !IsLive(v.Item))).ToList();
            int compact = _probed.Values.Count(i => Compression.ResolutionClass(i) == kind)
                          - all.Count(v => Compression.ResolutionClass(v.Info) == kind);
            // What is compressed, and apart from it what is only rebuilt without B-frames (it comes out a little larger):
            // together they would read as "−0 %".
            var squeezed = jobs.Where(v => !v.Job.Rebuild).ToList();
            var rebuilt = jobs.Where(v => v.Job.Rebuild).ToList();
            string text = squeezed.Count > 0
                ? F("%@: %@ · %@", Compression.ResolutionNames[kind], Count(squeezed.Count, L("видео"), L("видео"), L("видео")),
                    Compression.Saving(squeezed.Sum(v => v.Item.FileSize), squeezed.Sum(v => v.Job.EstimatedSize)))
                : jobs.Count > 0 ? F("%@: сжимать нечего", Compression.ResolutionNames[kind]) : F("%@: нечего сжимать", Compression.ResolutionNames[kind]);
            if (compact > 0 && jobs.Count > 0) text += " · " + F("ещё %@ и так компактные", Number(compact));
            // Compressed before with B-frames: rebuilt without them, so phones play them smoothly.
            if (rebuilt.Count > 0)
                text += Environment.NewLine + F("В %@ B-кадры (на телефоне идут рывками) — они будут убраны, кадры и HDR останутся те же: %@",
                                                Count(rebuilt.Count, L("видео"), L("видео"), L("видео")),
                                                Compression.Saving(rebuilt.Sum(v => v.Item.FileSize), rebuilt.Sum(v => v.Job.EstimatedSize)));
            var box = new CheckBox { Content = Wrapped(text), IsChecked = _classOn[kind] && jobs.Count > 0, IsEnabled = jobs.Count > 0, Margin = new Thickness(0, 2, 0, 2) };
            box.Click += (_, _) =>
            {
                _classOn[kind] = box.IsChecked == true;
                Update();
            };
            _classes.Children.Add(jobs.Count > 0 ? WithList(box, jobs) : box);
        }
        // The videos of live photos: right under the resolutions, always there (off unless ticked) — at the bottom and
        // only once one was found, it was taken for missing.
        var live = all.Where(v => IsLive(v.Item) && !v.Job.Rebuild).ToList();
        bool stillReading = _probing;
        var liveBox = new CheckBox
        {
            Content = Wrapped(live.Count > 0
                ? F("Видео живых фото: %@ · %@", Count(live.Count, L("видео"), L("видео"), L("видео")),
                    Compression.Saving(live.Sum(v => v.Item.FileSize), live.Sum(v => v.Job.EstimatedSize)))
                  + (stillReading ? " · " + L("ещё ищутся") : "")
                : stillReading ? L("Видео живых фото: ищутся…") : L("Видео живых фото: не найдены")),
            ToolTip = L("Короткие видео живых фото iPhone и Android: рядом лежит фото с тем же именем или в видео есть метка живого фото Apple. Весят они и так немного — без галочки не трогаются."),
            IsChecked = _liveOn && live.Count > 0,
            IsEnabled = live.Count > 0,
            Margin = new Thickness(0, 8, 0, 2),
        };
        liveBox.Click += (_, _) =>
        {
            _liveOn = liveBox.IsChecked == true;
            Update();
        };
        _classes.Children.Add(live.Count > 0 ? WithList(liveBox, live) : liveBox);
        // Compressed already (HEVC near the quality asked): apart, off unless ticked.
        var again = all.Where(v => v.Job.Again && !v.Job.Rebuild && !IsLive(v.Item)).ToList();
        if (again.Count > 0) AddAgainRow(again);
        // What will not get a fifth smaller without loss: shown, with why, and left as it is — never encoded for nothing.
        var wont = WontShrinkJobs();
        if (wont.Count == 0) return;
        var wontBox = new CheckBox
        {
            Content = Wrapped(F("Не сожмутся без потерь: %@ · %@ — останутся как есть", Count(wont.Count, L("видео"), L("видео"), L("видео")),
                                Size(wont.Sum(v => v.Item.FileSize)))),
            ToolTip = L("Эти видео уже записаны так плотно, что без видимых потерь меньше чем на 20 % не уменьшить: их пробовали сжать (на трёх кусках или целиком) или у них слишком мало бит на кадр. Причина каждого — в списке. На более сильном уровне качества их попробуют снова."),
            IsChecked = false,
            IsEnabled = false,
            Margin = new Thickness(0, 6, 0, 2),
        };
        _classes.Children.Add(WithList(wontBox, wont.Select(v => (v.Item, v.Info, v.Job)).ToList(), wont.ToDictionary(v => v.Item, v => v.Why)));
    }

    void AddAgainRow(List<(PhotoItem Item, VideoInfo Info, VideoJob Job)> again)
    {
        var againBox = new CheckBox
        {
            Content = Wrapped(F("Уже сжатые — можно дожать: %@ · %@", Count(again.Count, L("видео"), L("видео"), L("видео")),
                                Compression.Saving(again.Sum(v => v.Item.FileSize), again.Sum(v => v.Job.EstimatedSize)))),
            ToolTip = L("Видео уже в HEVC — так снимает iPhone. Сжатие без видимых потерь уменьшит их на четверть, не больше, а каждое пересжатие чуть портит картинку. Без галочки не трогаются."),
            IsChecked = _againOn,
            Margin = new Thickness(0, 6, 0, 2),
        };
        againBox.Click += (_, _) =>
        {
            _againOn = againBox.IsChecked == true;
            Update();
        };
        _classes.Children.Add(WithList(againBox, again));
    }

    /// <summary>
    /// A row of the resolutions with "Список ▾" after it: a drop-down of its videos, scrolled — the largest first, each
    /// with what it weighs now and what it should weigh, its size and frame rate.
    /// </summary>
    FrameworkElement WithList(CheckBox box, List<(PhotoItem Item, VideoInfo Info, VideoJob Job)> jobs, Dictionary<PhotoItem, string>? notes = null)
    {
        // The text takes what is left and wraps; the button stays in sight on the right.
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(box);
        if (box.Content is TextBlock text)
            row.SizeChanged += (_, _) => text.MaxWidth = Math.Max(120, row.ColumnDefinitions[0].ActualWidth - 30);
        var list = new ListBox { MaxHeight = 360, Width = 620, BorderThickness = new Thickness(0) };
        VirtualizingPanel.SetIsVirtualizing(list, true);
        list.SetResourceReference(BackgroundProperty, "Window");
        list.SetResourceReference(ForegroundProperty, "Text");
        var card = new Border { Padding = new Thickness(8), CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), Child = list };
        card.SetResourceReference(Border.BackgroundProperty, "Window");
        card.SetResourceReference(Border.BorderBrushProperty, "Separator");
        card.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 16, ShadowDepth = 2, Opacity = 0.25 };
        var popup = new Popup { Child = card, StaysOpen = false, AllowsTransparency = true, Placement = PlacementMode.Bottom, PlacementTarget = row };
        // While it is open the rows are not built anew (the videos still being read rebuilt them every 25, and the list
        // went with its row after a second); they are once it closes.
        popup.Opened += (_, _) => _openList = popup;
        popup.Closed += (_, _) =>
        {
            if (_openList == popup) _openList = null;
            if (_classesStale) Update();
        };
        var open = Ui.TextButton(L("Список ▾"), () =>
        {
            list.ItemsSource ??= jobs.OrderByDescending(v => v.Item.FileSize)
                .Select(v => $"{v.Item.Name} — {Size(v.Item.FileSize)}" + (notes == null ? $" → ≈ {Size(v.Job.EstimatedSize)}" : "") + $" · {v.Info.Width}×{v.Info.Height}, "
                             + F("%@ кадр/с", Math.Round(v.Info.Fps)) + (v.Info.Hdr ? " · HDR" : "")
                             + (v.Info.DynamicHdr == "dolby vision" ? " · Dolby Vision" : v.Info.DynamicHdr == "vivid" ? " · HDR Vivid" : v.Info.DynamicHdr == "hdr10+" ? " · HDR10+" : "")
                             + (v.Job.Rebuild ? " · " + L("B-кадры будут убраны") : "")
                             + (notes != null && notes.TryGetValue(v.Item, out string? note) ? " · " + note : ""))
                .ToList();
            popup.IsOpen = !popup.IsOpen;
        });
        open.ToolTip = L("Какие это видео: имя, сколько весит сейчас и сколько будет");
        open.Margin = new Thickness(10, 0, 0, 0);
        open.Padding = new Thickness(8, 1, 8, 1);
        open.VerticalAlignment = VerticalAlignment.Top;
        Grid.SetColumn(open, 1);
        row.Children.Add(open);
        row.Children.Add(popup);
        return row;
    }

    /// <summary>A checkbox's text that wraps rather than running off the window's edge.</summary>
    static TextBlock Wrapped(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap };

    /// <summary>Once the user has dragged the window to a height of their own, Grow leaves it alone.</summary>
    bool _sizedByUser;
    double _grownTo;

    /// <summary>
    /// The window as tall as its content, up to the screen: when rows appear (the videos read), it grows; the user can
    /// still make it any height, up to the whole screen — and once they have, it stays theirs (it used to grow back
    /// with every refresh of the rows, fighting the drag).
    /// </summary>
    void Grow()
    {
        if (!IsLoaded || WindowState != WindowState.Normal || _sizedByUser) return;
        Dispatcher.BeginInvoke(() =>
        {
            if (Content is not ScrollViewer scroll || _sizedByUser) return;
            Body.Measure(new Size(scroll.ViewportWidth > 0 ? scroll.ViewportWidth : ActualWidth, double.PositiveInfinity));
            double chrome = ActualHeight - scroll.ActualHeight;
            double want = Math.Ceiling(Body.DesiredSize.Height + chrome + 2);
            var area = SystemParameters.WorkArea;
            double height = Math.Min(want, area.Height);
            if (height <= ActualHeight + 1) return;
            _grownTo = height;
            Height = height;
            if (Top + height > area.Bottom) Top = Math.Max(area.Top, area.Bottom - height);
        }, System.Windows.Threading.DispatcherPriority.Loaded);
    }

    /// <summary>What the RAW photos are likely to weigh: as the trial said, or as the library's photos of that size do.</summary>
    double BytesPerPhoto(out bool sampled)
    {
        sampled = _sampled.TryGetValue(Megapixels, out double bytes);
        // The gain map adds about a tenth.
        return sampled ? bytes : Megapixels * (double)_typical.BytesPerMegapixel * 1.1;
    }

    void Update()
    {
        long before = 0, after = 0;
        if (_raws.Count > 0)
        {
            double each = BytesPerPhoto(out bool sampled);
            long photosAfter = (long)(each * _raws.Count), photosBefore = _raws.Sum(i => i.FileSize);
            _photoEstimate.Text = F("Станет ≈ %@ — %@ на снимок, %@.", Size(photosAfter), Size((long)each),
                                    sampled ? L("по пробному сжатию") : L("оценка по фото медиатеки, уточняется пробным сжатием…"));
            if (_photosOn.IsChecked == true)
            {
                before += photosBefore;
                after += photosAfter;
            }
        }
        if (_videos.Count > 0)
        {
            _download.Visibility = VideoCompressor.Available ? Visibility.Collapsed : Visibility.Visible;
            if (!VideoCompressor.Available)
            {
                _videoEstimate.Text = L("Для видео нужен FFmpeg — бесплатная программа для работы с видео (около 200 МБ, скачивается один раз).");
            }
            else
            {
                UpdateClasses();
                var jobs = Videos;
                long videosBefore = jobs.Sum(v => v.Item.FileSize), videosAfter = jobs.Sum(v => v.Job.EstimatedSize);
                // The compressing and the rebuilding apart: together they would read as "−0 %".
                var squeezed = jobs.Where(v => !v.Job.Rebuild).ToList();
                var rebuilt = jobs.Where(v => v.Job.Rebuild).ToList();
                string text = squeezed.Count > 0
                    ? F("Сожмутся %@: %@.", Count(squeezed.Count, L("видео"), L("видео"), L("видео")), Compression.Saving(squeezed.Sum(v => v.Item.FileSize), squeezed.Sum(v => v.Job.EstimatedSize)))
                    : jobs.Count > 0 ? "" : L("Нечего сжимать: видео уже не больше этого размера и весят немного.");
                if (rebuilt.Count > 0)
                    text += (text.Length > 0 ? " " : "") + F("Пересоберутся без B-кадров %@: %@.", Count(rebuilt.Count, L("видео"), L("видео"), L("видео")),
                                                              Compression.Saving(rebuilt.Sum(v => v.Item.FileSize), rebuilt.Sum(v => v.Job.EstimatedSize)));
                int special = _probed.Values.Count(i => i.Kept != null);
                int skipped = _probed.Count - AllJobs().Count - special;
                if (jobs.Count > 0 && skipped > 0) text += " " + F("Остальные %@ и так компактные — не трогаются.", Number(skipped));
                // Those that cannot be compressed without losing part of them: how many, and why.
                foreach (var reason in _probed.Values.Where(i => i.Kept != null).GroupBy(i => i.Kept!))
                    text += " " + F("Не сжимаются (%@): %@.", Number(reason.Count()), reason.Key);
                if (_probing) text += " " + F("Проверено %@ из %@…", Number(_probeDone), Number(_videos.Count));
                if (EncoderName() is { } encoder) text += " " + F("Кодирует: %@.", encoder);
                _videoEstimate.Text = text;
                if (_videosOn.IsChecked == true)
                {
                    before += videosBefore;
                    after += videosAfter;
                }
            }
        }
        _total.Text = before > 0 ? F("Итого: %@", Compression.Saving(before, after)) : "";
        Grow();
        // While the videos are being read, only the photos can go.
        _confirm.IsEnabled = !(_probing && _videosOn.IsChecked == true) && (Photos.Count > 0 || (VideoCompressor.Available && Videos.Count > 0));
    }

    /// <summary>Who encodes the videos; null until it has been tried (in the background, while the videos are read).</summary>
    static string? EncoderName() => VideoCompressor.KnownEncoder switch
    {
        null => null,
        "hevc_nvenc" => L("видеокарта NVIDIA"),
        "hevc_qsv" => L("видеокарта Intel"),
        "hevc_amf" => L("видеокарта AMD"),
        _ => L("процессор (x265) — медленно, но качественно"),
    };

    /// <summary>Two RAW photos compressed into a temporary folder at the size chosen, to say how much they will weigh.</summary>
    void Sample()
    {
        if (_raws.Count == 0 || _sampled.ContainsKey(Megapixels)) return;
        int megapixels = Megapixels;
        var token = _closing.Token;
        // Spread over the selection: the first ones are often of one day.
        var trial = new[] { _raws[_raws.Count / 3], _raws[_raws.Count * 2 / 3] }.Distinct().ToList();
        Task.Run(() =>
        {
            string folder = Path.Combine(Path.GetTempPath(), "photoorganizer-trial-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(folder);
            try
            {
                var sizes = new List<long>();
                foreach (var item in trial)
                {
                    if (token.IsCancellationRequested) return (double?)null;
                    try { sizes.Add(RawPhoto.Compress(item.Path, Path.Combine(folder, Guid.NewGuid() + ".jpg"), megapixels).Size); }
                    catch (Exception e) when (e is IOException or InvalidDataException or NotSupportedException or ArgumentException
                                                   or System.Runtime.InteropServices.COMException or FileFormatException) { }
                }
                return sizes.Count > 0 ? sizes.Average() : (double?)null;
            }
            finally
            {
                try { Directory.Delete(folder, true); } catch (IOException) { }
            }
        }, token).ContinueWith(task =>
        {
            if (task.IsCompletedSuccessfully && task.Result is { } bytes && IsLoaded)
            {
                _sampled[megapixels] = bytes;
                Update();
            }
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    /// <summary>Every video read (size, frame rate, bitrate, HDR), several at a time, the estimate growing as it goes.</summary>
    void Probe()
    {
        if (_videos.Count == 0 || !VideoCompressor.Available || _probing) return;
        _probing = true;
        var token = _closing.Token;
        var pending = _videos.Where(v => !_probed.ContainsKey(v)).ToList();
        _probeDone = _probed.Count;
        Update();
        Task.Run(() =>
        {
            _ = VideoCompressor.Encoder;   // tried once, here rather than on the window's thread
            Parallel.ForEach(pending, new ParallelOptions { MaxDegreeOfParallelism = 6, CancellationToken = token }, item =>
            {
                // Read once and remembered: the next time the window opens, only new or changed videos are read.
                var info = VideoCompressor.ProbeRemembered(item.Path);
                int done = Interlocked.Increment(ref _probeDone);
                Dispatcher.BeginInvoke(() =>
                {
                    if (info != null) _probed[item] = info;
                    if (done % 25 == 0) Update();
                });
            });
        }, token).ContinueWith(_ => Dispatcher.BeginInvoke(() =>
        {
            VideoCompressor.SaveProbed();
            _probing = false;
            if (IsLoaded) Update();
        }));
    }

    void DownloadFFmpeg()
    {
        _download.IsEnabled = false;
        var progress = new Progress<(long Received, long Total)>(p =>
            _download.Content = p.Total > 0 ? F("Скачивание: %@ из %@", Size(p.Received), Size(p.Total)) : F("Скачивание: %@", Size(p.Received)));
        VideoCompressor.DownloadAsync(progress, _closing.Token).ContinueWith(task =>
        {
            if (!IsLoaded) return;
            _download.IsEnabled = true;
            _download.Content = L("Скачать FFmpeg");
            if (task.IsFaulted)
            {
                MessageBox.Show(this, task.Exception!.GetBaseException().Message, L("Не удалось скачать FFmpeg"), MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            Update();
            Probe();
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    void Confirm()
    {
        if (_videos.Count > 0)
        {
            Settings.Shared.Set("compressVideoHeight", VideoHeight);
            Settings.Shared.Set("compressVideoLevel", VideoQuality);
        }
        DialogResult = true;
    }
}

/// <summary>
/// The Recycle Bin of a disk cannot hold the originals: what does not fit, Windows deletes for good without asking. The
/// user chooses a folder for them instead, the Bin anyway, or nothing.
/// </summary>
public sealed class BinFullDialog : Dialog
{
    public enum Choice { Cancel, Folder, Bin }

    public Choice Answer { get; private set; } = Choice.Cancel;

    public BinFullDialog(Window owner, string disk, long room, long size) : base(owner, L("Корзина переполнится"), 600)
    {
        Heading(L("Корзина переполнится"));
        Note(F("В Корзине диска %@ осталось места на %@, а оригиналов уйдёт туда %@. Что не поместится, Windows удалит навсегда, ничего не спрашивая, — вернуть это будет нельзя.",
               disk, Size(room), Size(size)), "Secondary");
        Note(L("Оригиналы можно переносить в отдельную папку: они лягут в неё в тех же подпапках и останутся там, пока вы их не удалите."));
        AddButton(L("Переносить в папку…"), () => { Answer = Choice.Folder; DialogResult = true; }, primary: true);
        AddButton(L("Всё равно в Корзину"), () => { Answer = Choice.Bin; DialogResult = true; });
        AddButton(L("Отмена"), () => DialogResult = false).IsCancel = true;
        Finish();
    }
}