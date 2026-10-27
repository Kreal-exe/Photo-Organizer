namespace PhotoOrganizer.Core;

/// <summary>
/// recognition.bin: what was found in each file (by file key), so that nothing is analysed twice. Kept in memory and
/// appended to; the newest record of a key wins, and the file is rewritten compactly when it has grown stale.
/// </summary>
public sealed class RecognitionStore
{
    // 3 added the text read in the picture. 4: faces and nudity scores of older files are dropped, to be found again —
    // on the graphics card the ViT models gave the same output for every picture (see VitOnnx.LayerNorm). 5: keys hold
    // the time of the last change (AppData.FileKey), and videos are judged by up to five frames.
    const int Version = 5;

    /// <summary>
    /// Null fields were not looked at. Hash: the visual fingerprint (0 when the picture is too plain to have one).
    /// Objects: MobileCLIP vectors of the picture and its parts, half precision. Nudity: model repo → score.
    /// Text: what is written in the picture (empty when nothing is), null when it was not read.
    /// </summary>
    public sealed record Entry(ulong? Hash, byte[]? Faces, float[]? Boxes, int PeopleCount, Dictionary<string, float>? Labels,
                               byte[]? Objects, Dictionary<string, float>? Nudity, string? Text = null);

    static RecognitionStore? _shared;
    static readonly Lock SharedLock = new();
    readonly Dictionary<string, Entry> _entries = [];
    /// <summary>
    /// The same entries by the part of the key every build of the app has read alike: the size and the time of the last
    /// change (see Stable). The first numbers of a key took in bytes past what Windows returns (AppData.FileKey read its
    /// structure 4 bytes off), which differed from one build to another.
    /// </summary>
    readonly Dictionary<string, Entry> _byStable = [];
    readonly string _path;
    readonly Lock _lock = new();
    FileStream? _appender;

    public static RecognitionStore Shared
    {
        get
        {
            lock (SharedLock) return _shared ??= new RecognitionStore();
        }
    }

    RecognitionStore()
    {
        _path = AppData.File("recognition.bin");
        int records = 0;
        long length = 0;
        bool damaged = false;
        try
        {
            byte[] data;
            using (var file = new FileStream(_path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 1 << 20))
            {
                length = file.Length;
                data = new byte[length];
                file.ReadExactly(data);
            }
            int version = data.Length >= 4 ? BitConverter.ToInt32(data, 0) : 0;
            if (version is >= 2 and <= Version)
            {
                // Every record is looked for on its own — a key (its length, then digits and hyphens), then the flag of
                // the fingerprint — and read from there: one record cut short or written wrong no longer takes the
                // ones after it along (a key's length is itself a digit, so reading on from a wrong place never ended).
                var starts = RecordStarts(data);
                // Read on every core (a library of 100 000 files keeps a gigabyte here: one core took 12 seconds, and
                // the duplicates waited for it), then taken in the file's order — a later record of a file replaces
                // an earlier one.
                var read = new (string Key, Entry Entry)?[starts.Count];
                Parallel.For(0, starts.Count, i =>
                {
                    int start = starts[i];
                    try
                    {
                        // A record read whole ends where the next one starts (or the file ends); one read wrong runs
                        // past it, and is left out — each record is read on its own, so the next ones still are.
                        // (A record is a few kilobytes: read within a megabyte, a wrong length fails at once.)
                        using var stream = new MemoryStream(data, start, Math.Min(data.Length - start, 1 << 20), writable: false);
                        using var reader = new BinaryReader(stream);
                        string key = reader.ReadString();
                        var entry = Read(reader, version);
                        int end = start + (int)stream.Position;
                        if (end != data.Length && starts.BinarySearch(end) < 0) throw new InvalidDataException();
                        read[i] = (key, entry);
                    }
                    catch (Exception e) when (e is EndOfStreamException or FormatException or InvalidDataException or ArgumentException or IOException)
                    {
                    }
                });
                foreach (var record in read)
                {
                    if (record is not { } r)
                    {
                        damaged = true;
                        continue;
                    }
                    records++;
                    // Keys without the time of the last change (before 5) are never asked for again: the files are
                    // looked at anew, and their old results dropped.
                    if (HasTime(r.Key)) Add(r.Key, r.Entry);
                }
                // Results of an older version are kept: rewritten in the new format, they are only completed.
                if (version != Version) records = 0;
                if (version < 5) damaged = true;
            }
        }
        catch (Exception e) when (e is IOException or EndOfStreamException or UnauthorizedAccessException)
        {
            // A missing file: nothing is known yet.
        }
        // Written anew only to drop results replaced since, or to start one: never when part of it could not be read —
        // results this reader cannot make out (as it once could not read negative keys) must stay for a better one.
        if (!damaged && (records > _entries.Count * 2 + 100 || !File.Exists(_path) || (records == 0 && length < 1 << 20))) Rewrite();
    }

    /// <summary>
    /// How many numbers a file key (AppData.FileKey) holds: four joined by hyphens (three before version 5). A second
    /// hyphen right after one is a minus sign ("…--4436918954398919957"): on a disk whose serial number has its top bit
    /// set every key ends like that.
    /// </summary>
    static int Numbers(string key)
    {
        if (key.Length == 0 || !char.IsAsciiDigit(key[0]) || !char.IsAsciiDigit(key[^1])) return 0;
        int numbers = 1;
        for (int i = 1; i < key.Length; i++)
        {
            if (key[i] != '-') continue;
            if (key[i - 1] == '-') { if (i + 1 >= key.Length || !char.IsAsciiDigit(key[i + 1])) return 0; continue; }
            numbers++;
        }
        return key.Contains("---") ? 0 : numbers;
    }

    static int Numbers(ReadOnlySpan<byte> key) => Numbers(System.Text.Encoding.ASCII.GetString(key));

    static byte[]? Bytes(BinaryReader reader)
    {
        int length = reader.ReadInt32();
        if (length > reader.BaseStream.Length - reader.BaseStream.Position) throw new EndOfStreamException();
        return length < 0 ? null : reader.ReadBytes(length);
    }

    static Dictionary<string, float>? Map(BinaryReader reader)
    {
        int count = reader.ReadInt32();
        if (count < 0) return null;
        if (count > 100_000) throw new InvalidDataException();
        var map = new Dictionary<string, float>(count);
        for (int i = 0; i < count; i++) map[reader.ReadString()] = reader.ReadSingle();
        return map;
    }

    static Entry Read(BinaryReader reader, int version)
    {
        ulong? hash = reader.ReadBoolean() ? reader.ReadUInt64() : null;
        byte[]? faces = Bytes(reader);
        byte[]? boxBytes = Bytes(reader);
        float[]? boxes = boxBytes == null ? null : new float[boxBytes.Length / 4];
        if (boxes != null) Buffer.BlockCopy(boxBytes!, 0, boxes, 0, boxBytes!.Length);
        int people = reader.ReadInt32();
        var labels = Map(reader);
        var objects = Bytes(reader);
        var nudity = Map(reader);
        string? text = version >= 3 && reader.ReadBoolean() ? reader.ReadString() : null;
        return new Entry(hash, faces, boxes, people, labels, objects, nudity, text);
    }

    static void WriteBytes(BinaryWriter writer, byte[]? bytes)
    {
        writer.Write(bytes?.Length ?? -1);
        if (bytes != null) writer.Write(bytes);
    }

    static void WriteMap(BinaryWriter writer, Dictionary<string, float>? map)
    {
        writer.Write(map?.Count ?? -1);
        foreach (var (key, value) in map ?? [])
        {
            writer.Write(key);
            writer.Write(value);
        }
    }

    static void Write(BinaryWriter writer, string key, Entry entry)
    {
        writer.Write(key);
        writer.Write(entry.Hash.HasValue);
        if (entry.Hash is { } hash) writer.Write(hash);
        WriteBytes(writer, entry.Faces);
        byte[]? boxes = null;
        if (entry.Boxes != null)
        {
            boxes = new byte[entry.Boxes.Length * 4];
            Buffer.BlockCopy(entry.Boxes, 0, boxes, 0, boxes.Length);
        }
        WriteBytes(writer, boxes);
        writer.Write(entry.PeopleCount);
        WriteMap(writer, entry.Labels);
        WriteBytes(writer, entry.Objects);
        WriteMap(writer, entry.Nudity);
        writer.Write(entry.Text != null);
        if (entry.Text != null) writer.Write(entry.Text);
    }

    void Rewrite()
    {
        try
        {
            using (var writer = new BinaryWriter(File.Create(_path + ".tmp")))
            {
                writer.Write(Version);
                foreach (var (key, entry) in _entries) Write(writer, key, entry);
            }
            File.Move(_path + ".tmp", _path, overwrite: true);
        }
        catch (IOException)
        {
        }
    }

    public Entry? Get(string key)
    {
        lock (_lock)
        {
            if (_entries.TryGetValue(key, out var entry)) return entry;
            return Stable(key) is { } stable ? _byStable.GetValueOrDefault(stable) : null;
        }
    }

    void Add(string key, Entry entry)
    {
        _entries[key] = entry;
        if (Stable(key) is { } stable) _byStable[stable] = entry;
    }

    /// <summary>A key that holds the time of the last change: four numbers, or three of which the last is negative.</summary>
    static bool HasTime(string key) => Numbers(key) == 4 || (Numbers(key) == 3 && key.Contains("--"));

    /// <summary>The last two numbers of a key with the time (the size and the time of the last change); null otherwise.</summary>
    static string? Stable(string key)
    {
        if (!HasTime(key)) return null;
        // The last number starts after the last hyphen that is not a minus sign; the one before it, likewise.
        int last = key.LastIndexOf('-');
        if (last > 0 && key[last - 1] == '-') last--;
        int before = key.LastIndexOf('-', last - 1);
        return before < 0 ? null : key[(before + 1)..];
    }

    /// <summary>Where records may start: a key's length, the key, then the fingerprint's flag (0 or 1).</summary>
    static List<int> RecordStarts(byte[] data)
    {
        // In pieces on every core, put together in order.
        const int Piece = 16 << 20;
        int pieces = Math.Max(1, (data.Length - 4 + Piece - 1) / Piece);
        var found = new List<int>[pieces];
        Parallel.For(0, pieces, piece =>
        {
            var starts = new List<int>();
            int from = 4 + piece * Piece, to = Math.Min(data.Length, from + Piece);
            for (int i = from; i < to && i + 2 < data.Length; i++)
            {
                int length = data[i];
                if (length is < 5 or >= 64 || i + 1 + length >= data.Length || data[i + 1 + length] > 1) continue;
                if (!char.IsAsciiDigit((char)data[i + 1]) || !char.IsAsciiDigit((char)data[i + length])) continue;
                var key = data.AsSpan(i + 1, length);
                if (key.IndexOfAnyExcept("0123456789-"u8) >= 0 || Numbers(key) is not (3 or 4)) continue;
                starts.Add(i);
            }
            found[piece] = starts;
        });
        return found.SelectMany(s => s).ToList();
    }

    public void Put(string key, Entry entry)
    {
        // The record goes to the file whole and at once: a buffer flushed halfway when the app closed left half a record,
        // after which every record appended later could not be read.
        var record = new MemoryStream();
        using (var writer = new BinaryWriter(record, System.Text.Encoding.UTF8, leaveOpen: true)) Write(writer, key, entry);
        lock (_lock)
        {
            Add(key, entry);
            try
            {
                _appender ??= new FileStream(_path, FileMode.Append, FileAccess.Write, FileShare.Read);
                _appender.Write(record.GetBuffer(), 0, (int)record.Length);
                _appender.Flush();
            }
            catch (IOException)
            {
            }
        }
    }

    public void Flush()
    {
        lock (_lock) _appender?.Flush();
    }

    /// <summary>Forgets every remembered result ("Распознать заново").</summary>
    public void Clear()
    {
        lock (_lock)
        {
            _appender?.Dispose();
            _appender = null;
            _entries.Clear();
            Rewrite();
        }
    }
}

/// <summary>
/// Looks at every file once in the background: what is in the picture (labels and MobileCLIP vectors for search), its
/// visual fingerprint (resized copies and thumbnails) and, when turned on, its faces and its nudity score. Results are
/// kept per file, so they survive rescans and moves on the same disk. Videos are judged by up to five frames.
/// </summary>
public sealed class Analyzer(IReadOnlyList<PhotoItem> items, bool withFaces)
{
    /// <summary>Longest side of the picture handed to the models; they work on far smaller inputs than a full photo.</summary>
    const int AnalysisSide = 512;
    /// <summary>Frames looked at in a video: one for every three seconds, up to this many (as on the Mac).</summary>
    const int MaximumVideoFrames = 5;

    readonly CancellationTokenSource _cancel = new();

    /// <summary>Why something could not be looked at (a model is missing or failed), or null.</summary>
    public string? Error { get; internal set; }
    public string? Device { get; private set; }
    /// <summary>
    /// Called (from the worker) once what was known from before is on the files — their fingerprints included — before
    /// anything new is looked at: look-alike copies can be found then, not only after the whole analysis.
    /// </summary>
    public Action? KnownApplied { get; set; }

    public void Cancel() => _cancel.Cancel();

    public static bool AnalyzesObjects
    {
        get => Settings.Shared.Get("analyzesObjects", true);
        set => Settings.Shared.Set("analyzesObjects", value);
    }

    sealed record Wanted(Recognizer? Recognizer, NudityClassifier? Nudity, FaceEngine? Faces, bool Text);

    static void Apply(PhotoItem item, RecognitionStore.Entry entry, Wanted wanted)
    {
        item.VisualHash = entry.Hash is > 0 ? entry.Hash : null;
        if (wanted.Recognizer != null) item.Labels = entry.Labels;
        if (entry.Text != null) item.Text = entry.Text.ToLowerInvariant().Replace('ё', 'е');
        if (wanted.Nudity != null && entry.Nudity?.TryGetValue(wanted.Nudity.Repo, out float score) == true) item.NudityScore = score;
        if (wanted.Faces == null || entry.Faces == null) return;
        item.Faces = Enumerable.Range(0, entry.Faces.Length / People.Dimension)
                               .Select(i => entry.Faces.AsSpan(i * People.Dimension, People.Dimension).ToArray()).ToList();
        var boxes = entry.Boxes ?? [];
        item.FaceBoxes = Enumerable.Range(0, boxes.Length / 4).Select(i => boxes.AsSpan(i * 4, 4).ToArray()).ToList();
        item.PeopleCount = entry.PeopleCount;
    }

    static bool Complete(PhotoItem item, RecognitionStore.Entry entry, Wanted wanted) =>
        (item.Video || entry.Hash != null)
        && (wanted.Recognizer == null || (entry.Labels != null && (item.Video || entry.Objects != null)))
        && (wanted.Nudity == null || entry.Nudity?.ContainsKey(wanted.Nudity.Repo) == true)
        && (wanted.Faces == null || item.Video || entry.Faces != null)
        && (!wanted.Text || entry.Text != null || !PictureText.Worth(item, entry.Labels));

    T? Load<T>(Func<T> make, string failure) where T : class
    {
        try
        {
            return make();
        }
        catch (Exception e)
        {
            Error ??= e.Message.Length > 0 ? e.Message : failure;
            return null;
        }
    }

    /// <summary>Blocking; run it on a worker. `progress(done, total)` is called from worker threads.</summary>
    public void Run(Action<int, int>? progress)
    {
        var token = _cancel.Token;
        RecognitionStore store;
        try
        {
            store = RecognitionStore.Shared;
        }
        catch (Exception e)
        {
            // Shown in the status line instead of the analysis ending silently with nothing found.
            Error = e.Message;
            return;
        }
        var wanted = new Wanted(
            AnalyzesObjects && Recognizer.Model.Ready ? Load(() => Recognizer.Shared, L("Модель распознавания объектов не запустилась")) : null,
            NudityClassifier.Enabled && NudityClassifier.Selected.Model.Ready ? Load(() => NudityClassifier.Shared, L("Модель распознавания наготы не запустилась")) : null,
            withFaces ? Load(() => FaceEngine.Shared, L("Модель лиц не запустилась")) : null,
            PictureText.Available);
        Device = wanted.Recognizer?.OnGpu == true || wanted.Faces?.Device == L("Видеокарта (DirectML)") ? L("Видеокарта (DirectML)") : wanted.Recognizer != null || wanted.Faces != null ? L("Процессор") : null;
        // First what is already known, so that searching works straight away on a folder seen before.
        // The count is of all the files, those looked at before included, so that opening the folder again (or a few
        // files moved) goes on from where it was instead of seeming to start over.
        var todo = new List<(PhotoItem Item, string Key, RecognitionStore.Entry? Old)>();
        int total = items.Count, done = 0;
        foreach (var item in items)
        {
            if (token.IsCancellationRequested) return;
            if (++done % 500 == 0) progress?.Invoke(done - todo.Count, total);
            if (item.CloudOnly || AppData.FileKey(item.Path, modified: true) is not { } key) continue;   // reading a cloud file would download it
            item.RecognitionKey = key;
            var entry = store.Get(key);
            if (entry != null) Apply(item, entry, wanted);
            if (entry == null || !Complete(item, entry, wanted)) todo.Add((item, key, entry));
        }
        done = total - todo.Count;
        progress?.Invoke(done, total);
        KnownApplied?.Invoke();
        try
        {
            // Decoding runs on most cores, the models on the graphics card several pictures at a time (see OnnxPool):
            // enough workers to keep both busy, a couple of cores left for the window.
            Parallel.ForEach(todo, new ParallelOptions { MaxDegreeOfParallelism = Math.Clamp(Environment.ProcessorCount - 2, 2, 14), CancellationToken = token },
                work =>
                {
                    // One file that cannot be read must not end the whole analysis (it did, silently, for the rest).
                    try
                    {
                        Analyse(work.Item, work.Key, work.Old, wanted, store, () =>
                        {
                            int finished = Interlocked.Increment(ref done);
                            if (finished % 5 == 0 || finished == total) progress?.Invoke(finished, total);
                        });
                    }
                    catch (Exception e) when (e is not OperationCanceledException)
                    {
                        Error ??= $"{work.Item.Name}: {e.Message}";
                        int finished = Interlocked.Increment(ref done);
                        if (finished % 5 == 0 || finished == total) progress?.Invoke(finished, total);
                    }
                });
        }
        catch (OperationCanceledException)
        {
        }
        store.Flush();
    }

    void Analyse(PhotoItem item, string key, RecognitionStore.Entry? old, Wanted wanted, RecognitionStore store, Action finished)
    {
        // Looked at before, only the text is new: the picture is read for it alone.
        if (old != null && wanted.Text && old.Text == null && Complete(item, old, wanted with { Text = false }))
        {
            string read;
            try
            {
                read = PictureText.Read(item.Path) ?? "";
            }
            catch (Exception e)
            {
                // Nothing remembered: tried again next time.
                Error ??= e.Message;
                finished();
                return;
            }
            var completed = old with { Text = read };
            store.Put(key, completed);
            Apply(item, completed, wanted);
            finished();
            return;
        }
        bool needsFaces = wanted.Faces != null && !item.Video && old?.Faces == null;
        // A video: frames spread over it; labels are of any of them, the nudity score the highest.
        var frames = item.Video
            ? Images.VideoFrames(item.Path, AnalysisSide, item.Duration, item.PixelWidth, item.PixelHeight, MaximumVideoFrames) : [];
        var image = item.Video ? frames.FirstOrDefault()
                               : Images.Load(item.Path, needsFaces ? FaceEngine.AnalysisSide : AnalysisSide);
        ulong? hash = old?.Hash;
        byte[]? faces = old?.Faces, objects = old?.Objects;
        float[]? boxes = old?.Boxes;
        int people = old?.PeopleCount ?? 0;
        var labels = old?.Labels;
        var nudity = old?.Nudity is { } scores ? new Dictionary<string, float>(scores) : null;
        string? text = old?.Text;
        try
        {
            if (image == null)
            {
                // Unreadable: empty results, so the file is not retried on every launch.
                hash ??= item.Video ? null : 0;
                if (wanted.Recognizer != null) { labels ??= []; if (!item.Video) objects ??= []; }
                if (wanted.Nudity != null) (nudity ??= [])[wanted.Nudity.Repo] = 0;
                if (needsFaces) { faces = []; boxes = []; }
                if (wanted.Text) text ??= "";
                return;
            }
            if (!item.Video && hash == null) hash = SimilarCopies.VisualHash(image.Gray9x8()) ?? 0;
            if (wanted.Recognizer != null && (labels == null || (!item.Video && objects == null)))
            {
                // The vectors come from the analysis-sized picture, whatever size the faces needed.
                var small = Math.Max(image.Width, image.Height) > AnalysisSide * 1.5 ? Images.Downscaled(image, AnalysisSide) : image;
                var vectors = wanted.Recognizer.Embed(small, item.Video ? [(0, 0, small.Width, small.Height)] : Recognizer.Regions(small));
                labels = Labels.For(vectors[0]);
                if (!item.Video) objects = Recognizer.Pack(vectors);
                foreach (var frame in frames.Skip(1))
                {
                    foreach (var (label, confidence) in Labels.For(wanted.Recognizer.Embed(frame, [(0, 0, frame.Width, frame.Height)])[0]))
                        labels[label] = Math.Max(confidence, labels.GetValueOrDefault(label));
                }
            }
            if (wanted.Nudity != null && nudity?.ContainsKey(wanted.Nudity.Repo) != true)
            {
                float score = wanted.Nudity.Score(image);
                foreach (var frame in frames.Skip(1)) score = Math.Max(score, wanted.Nudity.Score(frame));
                (nudity ??= [])[wanted.Nudity.Repo] = MathF.Round(score, 3);
            }
            // Text is read from the picture at full size (OCR needs it), only where text is likely.
            if (wanted.Text && text == null && PictureText.Worth(item, labels))
            {
                try
                {
                    text = PictureText.Read(item.Path) ?? "";
                }
                catch (Exception e)
                {
                    // Nothing remembered: tried again next time.
                    Error ??= e.Message;
                }
            }
            if (needsFaces)
            {
                try
                {
                    var (embeddings, faceBoxes, count) = wanted.Faces!.Analyse(image);
                    faces = embeddings.SelectMany(e => e).ToArray();
                    boxes = faceBoxes.SelectMany(b => b).ToArray();
                    people = count;
                }
                catch (Exception e)
                {
                    Error ??= e.Message;
                    faces = [];
                    boxes = [];
                }
            }
        }
        catch (Exception e)
        {
            // A model failing on one file must not stop the rest; the first reason is shown.
            Error ??= e.Message;
        }
        finally
        {
            var entry = new RecognitionStore.Entry(hash, faces, boxes, people, labels, objects, nudity, text);
            store.Put(key, entry);
            Apply(item, entry, wanted);
            finished();
        }
    }

    static string L(string text) => Strings.L(text);
}
