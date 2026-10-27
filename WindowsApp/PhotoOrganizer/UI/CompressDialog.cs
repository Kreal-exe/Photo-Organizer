using System.Windows;
using System.Windows.Controls;
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
    readonly ComboBox _quality = new() { Width = 220, HorizontalAlignment = HorizontalAlignment.Left };
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

    public CompressDialog(Window owner, List<PhotoItem> items, IEnumerable<PhotoItem> library) : base(owner, L("Сжать"), 560)
    {
        _raws = items.Where(i => Compression.IsRaw(i) && !i.CloudOnly).ToList();
        _videos = items.Where(i => i.Video && !i.CloudOnly).ToList();
        _typical = Compression.TypicalPhoto(library);
        _rawMegapixels = _raws.Count == 0 ? 0 : _raws.GroupBy(i => (int)Math.Round(i.PixelWidth * (double)i.PixelHeight / 1e6))
                                                     .OrderByDescending(g => g.Count()).First().Key;
        Heading(L("Сжать"));
        Note(L("Сжатые файлы занимают место оригиналов: RAW станет JPEG с тем же именем, видео останется под своим именем. Оригиналы уходят в Корзину — их можно вернуть оттуда, пока Корзина не очищена."), "Secondary", 14);

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
            foreach (string quality in new[] { L("Максимальное"), L("Высокое — без видимых потерь"), L("Экономное") }) _quality.Items.Add(quality);
            _quality.SelectedIndex = Math.Clamp(Settings.Shared.Get("compressVideoQuality", Compression.DefaultVideoQuality), 0, 2);
            _quality.SelectionChanged += (_, _) => Update();
            videos.Children.Add(_quality);
            var hdr = Ui.Text(L("HDR сохраняется: HEVC 10 бит с тем же описанием цвета (HLG, PQ). Звук, дата и место съёмки — как в оригинале. Видео, которые и так весят немного, не трогаются."), "Hint");
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
        Closed += (_, _) => _closing.Cancel();
        Loaded += (_, _) =>
        {
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

    public int Megapixels => _sizes.Count == 0 ? 12 : _sizes[Math.Max(0, _megapixels.SelectedIndex)];
    int VideoHeight => Compression.VideoHeights[Math.Max(0, _height.SelectedIndex)];
    int VideoQuality => Math.Max(0, _quality.SelectedIndex);

    /// <summary>The RAW photos to compress, when chosen.</summary>
    public List<PhotoItem> Photos => _photosOn.IsChecked == true ? _raws : [];

    /// <summary>The videos worth compressing with what is chosen, and how.</summary>
    public List<(PhotoItem Item, VideoInfo Info, VideoJob Job)> Videos =>
        _videosOn.IsChecked != true ? [] :
        _videos.Where(_probed.ContainsKey)
               .Select(i => (Item: i, Info: _probed[i], Job: Compression.PlanVideo(_probed[i], VideoHeight, VideoQuality)))
               .Where(v => v.Job != null)
               .Select(v => (v.Item, v.Info, v.Job!))
               .ToList();

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
                var jobs = Videos;
                long videosBefore = jobs.Sum(v => v.Item.FileSize), videosAfter = jobs.Sum(v => v.Job.EstimatedSize);
                string text = jobs.Count > 0
                    ? F("Сожмутся %@: %@.", Count(jobs.Count, L("видео"), L("видео"), L("видео")), Compression.Saving(videosBefore, videosAfter))
                    : L("Нечего сжимать: видео уже не больше этого размера и весят немного.");
                int skipped = _probed.Count - jobs.Count;
                if (jobs.Count > 0 && skipped > 0) text += " " + F("Остальные %@ и так компактные — не трогаются.", Number(skipped));
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
                var info = VideoCompressor.Probe(item.Path);
                int done = Interlocked.Increment(ref _probeDone);
                Dispatcher.BeginInvoke(() =>
                {
                    if (info != null) _probed[item] = info;
                    if (done % 25 == 0) Update();
                });
            });
        }, token).ContinueWith(_ => Dispatcher.BeginInvoke(() =>
        {
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
            Settings.Shared.Set("compressVideoQuality", VideoQuality);
        }
        DialogResult = true;
    }
}
