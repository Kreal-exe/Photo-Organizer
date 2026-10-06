namespace PhotoOrganizer.Core;

/// <summary>
/// recognition.bin: what was found in each file (by file key), so that nothing is analysed twice. Kept in memory and
/// appended to; the newest record of a key wins, and the file is rewritten compactly when it has grown stale.
/// </summary>
public sealed class RecognitionStore
{
    const int Version = 2;

    /// <summary>
    /// Null fields were not looked at. Hash: the visual fingerprint (0 when the picture is too plain to have one).
    /// Objects: MobileCLIP vectors of the picture and its parts, half precision. Nudity: model repo → score.
    /// </summary>
    public sealed record Entry(ulong? Hash, byte[]? Faces, float[]? Boxes, int PeopleCount, Dictionary<string, float>? Labels,
                               byte[]? Objects, Dictionary<string, float>? Nudity);

    static RecognitionStore? _shared;
    static readonly Lock SharedLock = new();
    readonly Dictionary<string, Entry> _entries = [];
    readonly string _path;
    readonly Lock _lock = new();
    BinaryWriter? _writer;

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
        try
        {
            using var reader = new BinaryReader(File.OpenRead(_path));
            if (reader.ReadInt32() == Version)
            {
                while (reader.BaseStream.Position < reader.BaseStream.Length)
                {
                    string key = reader.ReadString();
                    _entries[key] = Read(reader);
                    records++;
                }
            }
        }
        catch (Exception e) when (e is IOException or EndOfStreamException or UnauthorizedAccessException)
        {
            // A missing file, or one cut short by a crash: what was read is kept.
        }
        if (records > _entries.Count * 2 + 100 || !File.Exists(_path) || records == 0) Rewrite();
    }

    static byte[]? Bytes(BinaryReader reader)
    {
        int length = reader.ReadInt32();
        return length < 0 ? null : reader.ReadBytes(length);
    }

    static Dictionary<string, float>? Map(BinaryReader reader)
    {
        int count = reader.ReadInt32();
        if (count < 0) return null;
        var map = new Dictionary<string, float>(count);
        for (int i = 0; i < count; i++) map[reader.ReadString()] = reader.ReadSingle();
        return map;
    }

    static Entry Read(BinaryReader reader)
    {
        ulong? hash = reader.ReadBoolean() ? reader.ReadUInt64() : null;
        byte[]? faces = Bytes(reader);
        byte[]? boxBytes = Bytes(reader);
        float[]? boxes = boxBytes == null ? null : new float[boxBytes.Length / 4];
        if (boxes != null) Buffer.BlockCopy(boxBytes!, 0, boxes, 0, boxBytes!.Length);
        int people = reader.ReadInt32();
        return new Entry(hash, faces, boxes, people, Map(reader), Bytes(reader), Map(reader));
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
        lock (_lock) return _entries.GetValueOrDefault(key);
    }

    public void Put(string key, Entry entry)
    {
        lock (_lock)
        {
            _entries[key] = entry;
            try
            {
                _writer ??= new BinaryWriter(new FileStream(_path, FileMode.Append, FileAccess.Write, FileShare.Read));
                Write(_writer, key, entry);
            }
            catch (IOException)
            {
            }
        }
    }

    public void Flush()
    {
        lock (_lock) _writer?.Flush();
    }

    /// <summary>Forgets every remembered result ("Распознать заново").</summary>
    public void Clear()
    {
        lock (_lock)
        {
            _writer?.Dispose();
            _writer = null;
            _entries.Clear();
            Rewrite();
        }
    }
}

/// <summary>
/// Looks at every file once in the background: what is in the picture (labels and MobileCLIP vectors for search), its
/// visual fingerprint (resized copies and thumbnails) and, when turned on, its faces and its nudity score. Results are
/// kept per file, so they survive rescans and moves on the same disk. Videos are judged by a frame.
/// </summary>
public sealed class Analyzer(IReadOnlyList<PhotoItem> items, bool withFaces)
{
    /// <summary>Longest side of the picture handed to the models; they work on far smaller inputs than a full photo.</summary>
    const int AnalysisSide = 512;

    readonly CancellationTokenSource _cancel = new();

    /// <summary>Why something could not be looked at (a model is missing or failed), or null.</summary>
    public string? Error { get; private set; }
    public string? Device { get; private set; }

    public void Cancel() => _cancel.Cancel();

    public static bool AnalyzesObjects
    {
        get => Settings.Shared.Get("analyzesObjects", true);
        set => Settings.Shared.Set("analyzesObjects", value);
    }

    sealed record Wanted(Recognizer? Recognizer, NudityClassifier? Nudity, FaceEngine? Faces);

    static void Apply(PhotoItem item, RecognitionStore.Entry entry, Wanted wanted)
    {
        item.VisualHash = entry.Hash is > 0 ? entry.Hash : null;
        if (wanted.Recognizer != null) item.Labels = entry.Labels;
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
        && (wanted.Faces == null || item.Video || entry.Faces != null);

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
        var store = RecognitionStore.Shared;
        var wanted = new Wanted(
            AnalyzesObjects && Recognizer.Model.Ready ? Load(() => Recognizer.Shared, L("Модель распознавания объектов не запустилась")) : null,
            NudityClassifier.Enabled && NudityClassifier.Selected.Model.Ready ? Load(() => NudityClassifier.Shared, L("Модель распознавания наготы не запустилась")) : null,
            withFaces ? Load(() => FaceEngine.Shared, L("Модель лиц не запустилась")) : null);
        Device = wanted.Recognizer?.OnGpu == true || wanted.Faces?.Device == L("Видеокарта (DirectML)") ? L("Видеокарта (DirectML)") : wanted.Recognizer != null || wanted.Faces != null ? L("Процессор") : null;
        // First what is already known, so that searching works straight away on a folder seen before.
        var todo = new List<(PhotoItem Item, string Key, RecognitionStore.Entry? Old)>();
        foreach (var item in items)
        {
            if (item.CloudOnly || AppData.FileKey(item.Path) is not { } key) continue;   // reading a cloud file would download it
            item.RecognitionKey = key;
            var entry = store.Get(key);
            if (entry != null) Apply(item, entry, wanted);
            if (entry == null || !Complete(item, entry, wanted)) todo.Add((item, key, entry));
        }
        int total = todo.Count, done = 0;
        progress?.Invoke(0, total);
        try
        {
            // Decoding runs on several cores; the models serialise themselves on the graphics card.
            Parallel.ForEach(todo, new ParallelOptions { MaxDegreeOfParallelism = Math.Clamp(Environment.ProcessorCount / 2, 2, 6), CancellationToken = token },
                work => Analyse(work.Item, work.Key, work.Old, wanted, store, () =>
                {
                    int finished = Interlocked.Increment(ref done);
                    if (finished % 5 == 0 || finished == total) progress?.Invoke(finished, total);
                }));
        }
        catch (OperationCanceledException)
        {
        }
        store.Flush();
    }

    void Analyse(PhotoItem item, string key, RecognitionStore.Entry? old, Wanted wanted, RecognitionStore store, Action finished)
    {
        bool needsFaces = wanted.Faces != null && !item.Video && old?.Faces == null;
        var image = item.Video ? Images.VideoFrame(item.Path, AnalysisSide)
                               : Images.Load(item.Path, needsFaces ? FaceEngine.AnalysisSide : AnalysisSide);
        ulong? hash = old?.Hash;
        byte[]? faces = old?.Faces, objects = old?.Objects;
        float[]? boxes = old?.Boxes;
        int people = old?.PeopleCount ?? 0;
        var labels = old?.Labels;
        var nudity = old?.Nudity is { } scores ? new Dictionary<string, float>(scores) : null;
        try
        {
            if (image == null)
            {
                // Unreadable: empty results, so the file is not retried on every launch.
                hash ??= item.Video ? null : 0;
                if (wanted.Recognizer != null) { labels ??= []; if (!item.Video) objects ??= []; }
                if (wanted.Nudity != null) (nudity ??= [])[wanted.Nudity.Repo] = 0;
                if (needsFaces) { faces = []; boxes = []; }
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
            }
            if (wanted.Nudity != null && nudity?.ContainsKey(wanted.Nudity.Repo) != true)
            {
                (nudity ??= [])[wanted.Nudity.Repo] = MathF.Round(wanted.Nudity.Score(image), 3);
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
            var entry = new RecognitionStore.Entry(hash, faces, boxes, people, labels, objects, nudity);
            store.Put(key, entry);
            Apply(item, entry, wanted);
            finished();
        }
    }

    static string L(string text) => Strings.L(text);
}
