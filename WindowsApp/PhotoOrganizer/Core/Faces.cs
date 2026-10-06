using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.Core;

/// <summary>A face found in a picture: its box and five points, in pixels of the analysed picture.</summary>
public sealed record Face(float X, float Y, float Width, float Height, (float X, float Y)[] Points, float Score);

/// <summary>
/// Finds the faces in a picture, straightens each one by its eyes, nose and mouth, and turns it into an embedding with the
/// ArcFace model, so that faces of one person can be grouped. Both models run in ONNX Runtime on the graphics card
/// (DirectML: any DirectX 12 card) or, without one, on the processor:
/// - YuNet (OpenCV) finds the faces and five points on each;
/// - the ArcFace ViT-tiny the macOS version runs with MLX, turned into ONNX from its weights (see VitOnnx).
/// </summary>
public sealed class FaceEngine : IDisposable
{
    public const int MinimumFaceSize = 48;        // pixels, shorter side of the box: smaller faces carry too little detail
    public const int MaximumFacesPerImage = 12;
    public const int AnalysisSide = 1280;         // pictures are analysed at most this large
    const int DetectorSide = 640;                 // YuNet's fixed input
    const float ScoreThreshold = 0.6f, NmsThreshold = 0.3f;

    public static readonly Model Detector = new("detector", "opencv/face_detection_yunet", ["face_detection_yunet_2023mar.onnx"],
        "YuNet", L("Находит лица и точки глаз и рта (YuNet, OpenCV)."), "MIT", 232589);
    public static readonly Model Embedder = new("faces", "gaunernst/vit_tiny_patch8_112.arcface_ms1mv3", ["config.json", "model.safetensors"],
        "ArcFace ViT-tiny", L("Превращает лицо в набор чисел, по которому похожие лица собираются в группы (ViT-tiny, 112 px)."),
        L("не указана автором"), 22064736);
    public static readonly Model[] Models = [Detector, Embedder];

    public static bool ModelsReady => Models.All(m => m.Ready);

    // Where ArcFace models expect the eyes, the nose and the mouth corners in a 112×112 crop.
    static readonly (double X, double Y)[] Template =
        [(38.2946, 51.6963), (73.5318, 51.5014), (56.0252, 71.7366), (41.5493, 92.3655), (70.7299, 92.2041)];

    static FaceEngine? _shared;
    static readonly Lock SharedLock = new();

    readonly InferenceSession _detector, _embedder;
    readonly Lock _detectorLock = new(), _embedderLock = new();
    readonly int _inputSize;
    readonly float[] _mean, _std;

    /// <summary>"Видеокарта (DirectML)" or "Процессор": where the models actually run.</summary>
    public string Device { get; }

    public static bool UseGpu
    {
        get => Settings.Shared.Get("useGpu", true);
        set => Settings.Shared.Set("useGpu", value);
    }

    FaceEngine()
    {
        string detectorPath = Detector.File(Detector.Files[0]) ?? throw new InvalidOperationException(L("Модель лиц не загружена — откройте «Настройки»."));
        string embedderFolder = Embedder.Folder ?? throw new InvalidOperationException(L("Модель лиц не загружена — откройте «Настройки»."));
        var info = VitOnnx.Info(embedderFolder);
        (_inputSize, _mean, _std) = (info.InputSize, info.Mean, info.Std);
        bool gpu = UseGpu;
        (_detector, bool detectorOnGpu) = Onnx.Open(File.ReadAllBytes(detectorPath), gpu);
        (_embedder, bool embedderOnGpu) = Onnx.Open(File.ReadAllBytes(Onnx.BuiltVit(embedderFolder, "arcface")), gpu);
        Device = detectorOnGpu && embedderOnGpu ? L("Видеокарта (DirectML)") : L("Процессор");
    }

    /// <summary>The loaded engine; throws when a model is missing.</summary>
    public static FaceEngine Shared
    {
        get
        {
            lock (SharedLock) return _shared ??= new FaceEngine();
        }
    }

    /// <summary>After the models or the device changed.</summary>
    public static void Reset()
    {
        lock (SharedLock)
        {
            _shared?.Dispose();
            _shared = null;
        }
    }

    public void Dispose()
    {
        _detector.Dispose();
        _embedder.Dispose();
    }

    // --- Detection ----------------------------------------------------------------------------------------------------

    /// <summary>Every face in the picture, largest first.</summary>
    public List<Face> Detect(RasterImage image) =>
        Run(image, 0, 0, Math.Max(image.Width, image.Height)).Select(Ordered).OrderByDescending(f => f.Width * f.Height).ToList();

    /// <summary>
    /// The same face found again in a close-up around it. YuNet's input is a fixed 640×640 square, so a large picture is
    /// looked at shrunk and its points come out a few pixels off; in the close-up they are exact, and a few pixels decide
    /// how well the face lines up with ArcFace's template.
    /// </summary>
    public Face Refine(RasterImage image, Face face)
    {
        float side = Math.Max(DetectorSide, Math.Max(face.Width, face.Height) * 2.2f);
        float cx = face.X + face.Width / 2, cy = face.Y + face.Height / 2;
        float left = cx - side / 2, top = cy - side / 2;
        if (side <= DetectorSide)
        {
            // At the picture's own pixels, with the window on the network's 32-pixel grid counted from the picture's corner
            // and never past it: exactly the pixels OpenCV gives the network for the whole picture, so the points agree.
            left = Math.Max(0, MathF.Min(MathF.Floor(left / 32) * 32, MathF.Ceiling((image.Width - side) / 32) * 32));
            top = Math.Max(0, MathF.Min(MathF.Floor(top / 32) * 32, MathF.Ceiling((image.Height - side) / 32) * 32));
        }
        var found = Run(image, left, top, side);
        var best = found.OrderBy(f => MathF.Pow(f.X + f.Width / 2 - cx, 2) + MathF.Pow(f.Y + f.Height / 2 - cy, 2)).FirstOrDefault();
        return best != null && Overlap(best, face) > 0.5f ? Ordered(best) with { Score = face.Score } : face;
    }

    /// <summary>YuNet over the square (left, top, side) of the picture, scaled to its 640×640 input; areas outside stay black.</summary>
    List<Face> Run(RasterImage image, float left, float top, float side)
    {
        float scale = DetectorSide / side;
        var input = new DenseTensor<float>([1, 3, DetectorSide, DetectorSide]);
        var buffer = input.Buffer.Span;
        int plane = DetectorSide * DetectorSide;
        for (int y = 0; y < DetectorSide; y++)
        {
            double sy = top + (y + 0.5) / scale - 0.5;
            if (sy < -0.5 || sy > image.Height - 0.5) continue;
            sy = Math.Clamp(sy, 0, image.Height - 1);
            int y0 = (int)sy, y1 = Math.Min(image.Height - 1, y0 + 1);
            float fy = (float)(sy - y0);
            for (int x = 0; x < DetectorSide; x++)
            {
                double sx = left + (x + 0.5) / scale - 0.5;
                if (sx < -0.5 || sx > image.Width - 0.5) continue;
                sx = Math.Clamp(sx, 0, image.Width - 1);
                int x0 = (int)sx, x1 = Math.Min(image.Width - 1, x0 + 1);
                float fx = (float)(sx - x0);
                for (int c = 0; c < 3; c++)   // blue, green, red: YuNet was trained on OpenCV's channel order
                {
                    float upper = image.Bgr[(y0 * image.Width + x0) * 3 + c] * (1 - fx) + image.Bgr[(y0 * image.Width + x1) * 3 + c] * fx;
                    float lower = image.Bgr[(y1 * image.Width + x0) * 3 + c] * (1 - fx) + image.Bgr[(y1 * image.Width + x1) * 3 + c] * fx;
                    buffer[c * plane + y * DetectorSide + x] = upper * (1 - fy) + lower * fy;
                }
            }
        }
        var faces = new List<Face>();
        lock (_detectorLock)
        {
            using var results = _detector.Run([NamedOnnxValue.CreateFromTensor("input", input)]);
            var outputs = results.ToDictionary(r => r.Name, r => r.AsTensor<float>().ToArray());
            foreach (int stride in new[] { 8, 16, 32 })
            {
                float[] cls = outputs[$"cls_{stride}"], obj = outputs[$"obj_{stride}"], box = outputs[$"bbox_{stride}"], kps = outputs[$"kps_{stride}"];
                int columns = DetectorSide / stride;
                for (int index = 0; index < cls.Length; index++)
                {
                    float score = MathF.Sqrt(Math.Clamp(cls[index], 0, 1) * Math.Clamp(obj[index], 0, 1));
                    if (score < ScoreThreshold) continue;
                    int row = index / columns, column = index % columns;
                    float cx = (column + box[index * 4]) * stride, cy = (row + box[index * 4 + 1]) * stride;
                    float w = MathF.Exp(box[index * 4 + 2]) * stride, h = MathF.Exp(box[index * 4 + 3]) * stride;
                    var points = new (float, float)[5];
                    for (int p = 0; p < 5; p++)
                    {
                        points[p] = (left + (kps[index * 10 + 2 * p] + column) * stride / scale, top + (kps[index * 10 + 2 * p + 1] + row) * stride / scale);
                    }
                    faces.Add(new Face(left + (cx - w / 2) / scale, top + (cy - h / 2) / scale, w / scale, h / scale, points, score));
                }
            }
        }
        return Suppress(faces);
    }

    /// <summary>Non-maximum suppression: of overlapping boxes, the most certain stays.</summary>
    static List<Face> Suppress(List<Face> faces)
    {
        var kept = new List<Face>();
        foreach (var face in faces.OrderByDescending(f => f.Score))
        {
            if (kept.All(k => Overlap(k, face) <= NmsThreshold)) kept.Add(face);
        }
        return kept;
    }

    static float Overlap(Face a, Face b)
    {
        float left = Math.Max(a.X, b.X), top = Math.Max(a.Y, b.Y);
        float right = Math.Min(a.X + a.Width, b.X + b.Width), bottom = Math.Min(a.Y + a.Height, b.Y + b.Height);
        float intersection = Math.Max(0, right - left) * Math.Max(0, bottom - top);
        return intersection / (a.Width * a.Height + b.Width * b.Height - intersection);
    }

    /// <summary>Eyes and mouth corners left to right in the picture, whichever way the face is turned.</summary>
    static Face Ordered(Face face)
    {
        var p = face.Points;
        var eyes = p[0].X <= p[1].X ? new[] { p[0], p[1] } : [p[1], p[0]];
        var mouth = p[3].X <= p[4].X ? new[] { p[3], p[4] } : [p[4], p[3]];
        return face with { Points = [eyes[0], eyes[1], p[2], mouth[0], mouth[1]] };
    }

    // --- Embedding ----------------------------------------------------------------------------------------------------

    /// <summary>
    /// The similarity transform (rotation, uniform scale, shift) that puts the five points where ArcFace expects them,
    /// least squares; null when they are degenerate. Maps picture coordinates to crop coordinates: [a, -b, tx; b, a, ty].
    /// </summary>
    public static double[]? Alignment((float X, float Y)[] points)
    {
        double sx = points.Average(p => p.X), sy = points.Average(p => p.Y);
        double tx = Template.Average(t => t.X), ty = Template.Average(t => t.Y);
        double dot = 0, cross = 0, norm = 0;
        for (int i = 0; i < 5; i++)
        {
            double px = points[i].X - sx, py = points[i].Y - sy, qx = Template[i].X - tx, qy = Template[i].Y - ty;
            dot += px * qx + py * qy;
            cross += px * qy - py * qx;
            norm += px * px + py * py;
        }
        if (norm < 1) return null;
        double a = dot / norm, b = cross / norm;
        return [a, -b, tx - (a * sx - b * sy), b, a, ty - (b * sx + a * sy)];
    }

    /// <summary>One int8 embedding (512 bytes) per face, in the order given.</summary>
    public List<byte[]> Embed(RasterImage image, IReadOnlyList<Face> faces)
    {
        if (faces.Count == 0) return [];
        int size = _inputSize;
        var input = new DenseTensor<float>([faces.Count, size, size, 3]);
        var buffer = input.Buffer.Span;
        for (int n = 0; n < faces.Count; n++)
        {
            var m = Alignment(faces[n].Points)!;
            // The inverse of the similarity transform: where each pixel of the crop comes from.
            double det = m[0] * m[4] - m[1] * m[3];
            double ia = m[4] / det, ib = -m[1] / det, ic = -m[3] / det, id = m[0] / det;
            for (int y = 0; y < size; y++)
            {
                for (int x = 0; x < size; x++)
                {
                    double dx = x - m[2], dy = y - m[5];
                    double sx = ia * dx + ib * dy, sy = ic * dx + id * dy;
                    int x0 = (int)Math.Floor(sx), y0 = (int)Math.Floor(sy);
                    float fx = (float)(sx - x0), fy = (float)(sy - y0);
                    int cx0 = Math.Clamp(x0, 0, image.Width - 1), cx1 = Math.Clamp(x0 + 1, 0, image.Width - 1);
                    int cy0 = Math.Clamp(y0, 0, image.Height - 1), cy1 = Math.Clamp(y0 + 1, 0, image.Height - 1);
                    int at = ((n * size + y) * size + x) * 3;
                    for (int c = 0; c < 3; c++)   // the crop is red-green-blue, as the model was trained
                    {
                        int channel = 2 - c;
                        float top = image.Bgr[(cy0 * image.Width + cx0) * 3 + channel] * (1 - fx) + image.Bgr[(cy0 * image.Width + cx1) * 3 + channel] * fx;
                        float bottom = image.Bgr[(cy1 * image.Width + cx0) * 3 + channel] * (1 - fx) + image.Bgr[(cy1 * image.Width + cx1) * 3 + channel] * fx;
                        buffer[at + c] = (top * (1 - fy) + bottom * fy - _mean[c] * 255) / (_std[c] * 255);
                    }
                }
            }
        }
        float[] vectors;
        lock (_embedderLock)
        {
            using var results = _embedder.Run([NamedOnnxValue.CreateFromTensor("input", input)]);
            vectors = results[0].AsTensor<float>().ToArray();
        }
        int dimension = vectors.Length / faces.Count;
        var embeddings = new List<byte[]>();
        for (int n = 0; n < faces.Count; n++)
        {
            var vector = vectors.AsSpan(n * dimension, dimension);
            float norm = MathF.Sqrt(System.Numerics.Tensors.TensorPrimitives.SumOfSquares(vector) + 1e-12f);
            var bytes = new byte[dimension];
            for (int i = 0; i < dimension; i++) bytes[i] = (byte)(sbyte)Math.Clamp(MathF.Round(vector[i] / norm * 127), -127, 127);
            embeddings.Add(bytes);
        }
        return embeddings;
    }

    /// <summary>The embeddings, the boxes as fractions of the picture and the number of people, for one picture.</summary>
    public (List<byte[]> Embeddings, List<float[]> Boxes, int PeopleCount) Analyse(RasterImage image)
    {
        var faces = Detect(image);
        var usable = faces.Where(f => Math.Min(f.Width, f.Height) >= MinimumFaceSize)
                          .Take(MaximumFacesPerImage).Select(f => Refine(image, f))
                          .Where(f => Alignment(f.Points) != null).ToList();
        var embeddings = Embed(image, usable);
        var boxes = usable.Select(f => new[] { f.X / image.Width, f.Y / image.Height, f.Width / image.Width, f.Height / image.Height }).ToList();
        return (embeddings, boxes, faces.Count);
    }
}
