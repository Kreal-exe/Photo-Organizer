using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.Core;

/// <summary>
/// MobileCLIP's image half: one vector per picture describing what it shows, which gives the labels ("пляж", "собака"),
/// search by photo (pictures with close vectors look alike) and search by object (vectors of parts of pictures). It
/// stands in for what the macOS app takes from Vision, which Windows does not have.
/// </summary>
public sealed class Recognizer : IDisposable
{
    public const int Dimension = 512;
    const int Side = 256;

    public static readonly Model Model = new("objects", "Xenova/mobileclip_s0", ["onnx/vision_model.onnx", "preprocessor_config.json"],
        "MobileCLIP-S0", L("Распознаёт, что изображено на фото, и сравнивает фото по виду: поиск по словам, по фото и по предметам."),
        "Apple Sample Code License", 45_552_000);

    static Recognizer? _shared;
    static readonly Lock SharedLock = new();
    readonly InferenceSession _session;
    readonly Lock _lock = new();

    public bool OnGpu { get; }

    Recognizer()
    {
        string path = Model.File("onnx/vision_model.onnx") ?? throw new InvalidOperationException(L("Модель распознавания объектов не загружена — «Настройки»."));
        (_session, bool gpu) = Onnx.Open(File.ReadAllBytes(path), FaceEngine.UseGpu);
        OnGpu = gpu;
    }

    public static Recognizer Shared
    {
        get
        {
            lock (SharedLock) return _shared ??= new Recognizer();
        }
    }

    public static void Reset()
    {
        lock (SharedLock)
        {
            _shared?.Dispose();
            _shared = null;
        }
    }

    public void Dispose() => _session.Dispose();

    /// <summary>Unit-length vectors of the regions (x, y, w, h in pixels) of the picture, one per region, in one pass.</summary>
    public List<float[]> Embed(RasterImage image, IReadOnlyList<(double X, double Y, double W, double H)> regions)
    {
        var input = new DenseTensor<float>([regions.Count, 3, Side, Side]);
        var buffer = input.Buffer.Span;
        for (int n = 0; n < regions.Count; n++)
        {
            var (rx, ry, rw, rh) = regions[n];
            // As CLIP's preprocessing: the shorter side to 256, then the middle 256×256.
            double scale = Side / Math.Min(rw, rh);
            double left = rx + (rw - Side / scale) / 2, top = ry + (rh - Side / scale) / 2;
            for (int y = 0; y < Side; y++)
            {
                double sy = Math.Clamp(top + (y + 0.5) / scale - 0.5, 0, image.Height - 1);
                int y0 = (int)sy, y1 = Math.Min(image.Height - 1, y0 + 1);
                float fy = (float)(sy - y0);
                for (int x = 0; x < Side; x++)
                {
                    double sx = Math.Clamp(left + (x + 0.5) / scale - 0.5, 0, image.Width - 1);
                    int x0 = (int)sx, x1 = Math.Min(image.Width - 1, x0 + 1);
                    float fx = (float)(sx - x0);
                    for (int c = 0; c < 3; c++)   // red, green, blue from the picture's blue-green-red
                    {
                        int channel = 2 - c;
                        float upper = image.Bgr[(y0 * image.Width + x0) * 3 + channel] * (1 - fx) + image.Bgr[(y0 * image.Width + x1) * 3 + channel] * fx;
                        float lower = image.Bgr[(y1 * image.Width + x0) * 3 + channel] * (1 - fx) + image.Bgr[(y1 * image.Width + x1) * 3 + channel] * fx;
                        buffer[((n * 3 + c) * Side + y) * Side + x] = (upper * (1 - fy) + lower * fy) / 255f;
                    }
                }
            }
        }
        float[] output;
        lock (_lock)
        {
            using var results = _session.Run([NamedOnnxValue.CreateFromTensor("pixel_values", input)]);
            output = results[0].AsTensor<float>().ToArray();
        }
        var vectors = new List<float[]>();
        for (int n = 0; n < regions.Count; n++)
        {
            var vector = output.AsSpan(n * Dimension, Dimension).ToArray();
            float norm = System.Numerics.Tensors.TensorPrimitives.Norm(vector);
            if (norm > 0) System.Numerics.Tensors.TensorPrimitives.Divide(vector, norm, vector);
            vectors.Add(vector);
        }
        return vectors;
    }

    /// <summary>
    /// The whole picture and five overlapping parts of it — the four corners and the middle, each 60 % of the picture —
    /// so that an object that fills only part of a photo still has a vector of its own (the macOS app takes the parts
    /// Vision finds salient; Windows has no such detector).
    /// </summary>
    public static List<(double, double, double, double)> Regions(RasterImage image)
    {
        double w = image.Width, h = image.Height, pw = w * 0.6, ph = h * 0.6;
        return [(0, 0, w, h), (0, 0, pw, ph), (w - pw, 0, pw, ph), (0, h - ph, pw, ph), (w - pw, h - ph, pw, ph), ((w - pw) / 2, (h - ph) / 2, pw, ph)];
    }

    /// <summary>Vectors as half-precision bytes, the way they are stored.</summary>
    public static byte[] Pack(IEnumerable<float[]> vectors)
    {
        var all = vectors.SelectMany(v => v).Select(f => (Half)f).ToArray();
        return System.Runtime.InteropServices.MemoryMarshal.AsBytes(all.AsSpan()).ToArray();
    }

    public static float[] Unpack(byte[] bytes, int index)
    {
        var halves = System.Runtime.InteropServices.MemoryMarshal.Cast<byte, Half>(bytes.AsSpan(index * Dimension * 2, Dimension * 2));
        var vector = new float[Dimension];
        for (int i = 0; i < Dimension; i++) vector[i] = (float)halves[i];
        return vector;
    }

    public static int Count(byte[]? bytes) => (bytes?.Length ?? 0) / (Dimension * 2);
}

/// <summary>One of the downloadable nudity models — the same ones the macOS app offers, run here through ONNX.</summary>
public sealed record NudityModel(Model Model, bool CenterCrop);

/// <summary>Scores pictures with a nudity model: the probability (0…1) that the picture is explicit.</summary>
public sealed class NudityClassifier : IDisposable
{
    public static readonly NudityModel[] Models =
    [
        new(new Model("nudity.marqo", "Marqo/nsfw-image-detection-384", ["config.json", "model.safetensors"], "Marqo NSFW 384",
                      L("Маленькая и быстрая (ViT-tiny, 384 px). Хороший выбор по умолчанию."), "Apache-2.0", 22405349), true),
        new(new Model("nudity.falconsai", "Falconsai/nsfw_image_detection", ["config.json", "preprocessor_config.json", "model.safetensors"], "Falconsai NSFW",
                      L("Самая популярная (ViT-base, 224 px). В 15 раз больше и медленнее."), "Apache-2.0", 343225017), false),
        new(new Model("nudity.adamcodd", "AdamCodd/vit-base-nsfw-detector", ["config.json", "preprocessor_config.json", "model.safetensors"], "AdamCodd ViT NSFW",
                      L("Крупная и самая медленная (ViT-base, 384 px), видит мелкие детали."), "Apache-2.0", 344392275), false),
    ];

    public static NudityModel Selected =>
        Models.FirstOrDefault(m => m.Model.Repo == Settings.Shared.GetString("nudityModel")) ?? Models[0];

    public static bool Enabled
    {
        get => Settings.Shared.Get("detectsNudity", false);
        set => Settings.Shared.Set("detectsNudity", value);
    }

    /// <summary>Files scoring at or above this are listed as explicit.</summary>
    public static double Threshold
    {
        get => Math.Clamp(Settings.Shared.Get("nudityThreshold", 0.5), 0.05, 0.99);
        set => Settings.Shared.Set("nudityThreshold", value);
    }

    static NudityClassifier? _shared;
    static readonly Lock SharedLock = new();
    readonly InferenceSession _session;
    readonly Lock _lock = new();
    readonly VitInfo _info;
    readonly int _explicitIndex;
    readonly bool _centerCrop;

    public string Repo { get; }

    NudityClassifier(NudityModel model)
    {
        string folder = model.Model.Folder ?? throw new InvalidOperationException(L("Модель не загружена — откройте «Настройки» и нажмите «Загрузить»."));
        _info = VitOnnx.Info(folder);
        _explicitIndex = Array.FindIndex(_info.Labels, l => l.ToLowerInvariant() is "nsfw" or "porn" or "explicit");
        if (_explicitIndex < 0) throw new InvalidDataException(model.Model.Repo);
        _centerCrop = model.CenterCrop;
        (_session, _) = Onnx.Open(File.ReadAllBytes(Onnx.BuiltVit(folder, model.Model.Key)), FaceEngine.UseGpu);
        Repo = model.Model.Repo;
    }

    /// <summary>The classifier of the chosen model; throws when it is not downloaded.</summary>
    public static NudityClassifier Shared
    {
        get
        {
            lock (SharedLock)
            {
                if (_shared != null && _shared.Repo != Selected.Model.Repo) Reset();
                return _shared ??= new NudityClassifier(Selected);
            }
        }
    }

    public static void Reset()
    {
        lock (SharedLock)
        {
            _shared?.Dispose();
            _shared = null;
        }
    }

    public void Dispose() => _session.Dispose();

    public float Score(RasterImage image)
    {
        int size = _info.InputSize;
        var input = new DenseTensor<float>([1, size, size, 3]);
        var buffer = input.Buffer.Span;
        // Squashed into the square, or filling it with the middle kept, as each model was trained.
        double scaleX = (double)size / image.Width, scaleY = (double)size / image.Height;
        if (_centerCrop) scaleX = scaleY = Math.Max(scaleX, scaleY);
        double left = (image.Width - size / scaleX) / 2, top = (image.Height - size / scaleY) / 2;
        for (int y = 0; y < size; y++)
        {
            double sy = Math.Clamp(top + (y + 0.5) / scaleY - 0.5, 0, image.Height - 1);
            int y0 = (int)sy, y1 = Math.Min(image.Height - 1, y0 + 1);
            float fy = (float)(sy - y0);
            for (int x = 0; x < size; x++)
            {
                double sx = Math.Clamp(left + (x + 0.5) / scaleX - 0.5, 0, image.Width - 1);
                int x0 = (int)sx, x1 = Math.Min(image.Width - 1, x0 + 1);
                float fx = (float)(sx - x0);
                for (int c = 0; c < 3; c++)
                {
                    int channel = 2 - c;
                    float upper = image.Bgr[(y0 * image.Width + x0) * 3 + channel] * (1 - fx) + image.Bgr[(y0 * image.Width + x1) * 3 + channel] * fx;
                    float lower = image.Bgr[(y1 * image.Width + x0) * 3 + channel] * (1 - fx) + image.Bgr[(y1 * image.Width + x1) * 3 + channel] * fx;
                    buffer[(y * size + x) * 3 + c] = ((upper * (1 - fy) + lower * fy) / 255f - _info.Mean[c]) / _info.Std[c];
                }
            }
        }
        float[] logits;
        lock (_lock)
        {
            using var results = _session.Run([NamedOnnxValue.CreateFromTensor("input", input)]);
            logits = results[0].AsTensor<float>().ToArray();
        }
        float max = logits.Max();
        float sum = logits.Sum(l => MathF.Exp(l - max));
        return MathF.Exp(logits[_explicitIndex] - max) / sum;
    }
}
