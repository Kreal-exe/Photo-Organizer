using System.Numerics.Tensors;

namespace PhotoOrganizer.Core;

/// <summary>
/// Tells pictures — postcards, memes, drawings, tickets, things saved from messengers and the web — from photographs,
/// with what the analysis already stored, so nothing is looked at again. A logistic regression on the MobileCLIP vector
/// of the whole picture is trained on the library itself: files with a capture date that don't look graphic are
/// photos, files without one that the labels call drawn, printed or written are pictures. It then catches what the
/// labels miss (a colourful postcard of roses is "flowers" to them). A file that knows where it was taken is a photo.
/// What Google Photos made — collages, frames, animations — is a picture by its name alone (see
/// MediaTypes.IsGooglePhotosCreation): made of photos, it looks like one to the model. What a camera took is a photo
/// whatever is in it (a painting on the wall, a document): a capture date of its own, a place, or a camera's name.
/// </summary>
public static partial class Pictures
{
    [System.Text.RegularExpressions.GeneratedRegex(@"^(img|vid|pxl|mvimg)_\d{8}_\d{6}|^\d{8}_\d{6}|^dsc", System.Text.RegularExpressions.RegexOptions.IgnoreCase)]
    private static partial System.Text.RegularExpressions.Regex CameraName();

    const int Dimension = 512;
    const float SureGraphic = 0.03f, SurePhoto = -0.03f;
    const int MinimumExamples = 30, MaximumExamples = 6000, Epochs = 300;
    const double LearningRate = 40, Regularization = 0.0005;
    // A file with a capture date has to look more clearly like a picture: postcards rarely have one, photos do.
    const float Threshold = 0.5f, ThresholdWithDate = 0.7f;

    static bool HasCaptureDate(PhotoItem item) => item.DateSource == DateSource.Exif;

    static bool TakenByCamera(PhotoItem item) =>
        HasCaptureDate(item) || item.HasLocation || CameraName().IsMatch(System.IO.Path.GetFileNameWithoutExtension(item.Name));

    /// <summary>Blocking (a second or two for a large library): the items that are pictures. Apply with Apply on the UI thread.</summary>
    public static HashSet<PhotoItem> Find(IReadOnlyList<PhotoItem> items, CancellationToken token = default)
    {
        var found = Classify(items.Where(i => !MediaTypes.IsGooglePhotosCreation(i)).ToList(), token);
        found.RemoveWhere(TakenByCamera);
        found.UnionWith(items.Where(MediaTypes.IsGooglePhotosCreation));
        return found;
    }

    static HashSet<PhotoItem> Classify(IReadOnlyList<PhotoItem> items, CancellationToken token)
    {
        var candidates = new List<(PhotoItem Item, float[] Vector, float Graphic)>();
        foreach (var item in items)
        {
            if (item.Video || Screenshots.IsScreenshot(item) || Search.PictureVector(item) is not { } vector) continue;
            candidates.Add((item, vector, Labels.GraphicScore(vector)));
        }
        var pictures = candidates.Where(c => c.Graphic > SureGraphic && !HasCaptureDate(c.Item) && !c.Item.HasLocation).ToList();
        var photos = candidates.Where(c => c.Graphic < SurePhoto && HasCaptureDate(c.Item)).ToList();
        if (pictures.Count < MinimumExamples || photos.Count < MinimumExamples)
        {
            // Too few examples to learn from: the labels alone.
            return candidates.Where(c => c.Graphic > SureGraphic && !c.Item.HasLocation).Select(c => c.Item).ToHashSet();
        }
        var random = new Random(1);
        var weights = Train(Sample(pictures, random).Select(c => c.Vector).ToList(), Sample(photos, random).Select(c => c.Vector).ToList(), token);
        if (weights == null) return [];
        return candidates.Where(c => !c.Item.HasLocation && Probability(weights, c.Vector) >= (HasCaptureDate(c.Item) ? ThresholdWithDate : Threshold))
                         .Select(c => c.Item).ToHashSet();
    }

    public static void Apply(IEnumerable<PhotoItem> items, HashSet<PhotoItem> pictures)
    {
        foreach (var item in items) item.IsPicture = pictures.Contains(item);
    }

    static List<T> Sample<T>(List<T> list, Random random) =>
        list.Count <= MaximumExamples ? list : list.OrderBy(_ => random.Next()).Take(MaximumExamples).ToList();

    static float Probability(float[] weights, float[] vector) =>
        1 / (1 + MathF.Exp(-(TensorPrimitives.Dot(weights.AsSpan(0, Dimension), vector) + weights[Dimension])));

    /// <summary>Logistic regression by gradient descent, both classes weighted equally; null when cancelled.</summary>
    static float[]? Train(List<float[]> positive, List<float[]> negative, CancellationToken token)
    {
        var weights = new float[Dimension + 1];
        var gradient = new float[Dimension];
        var examples = positive.Select(v => (v, 1f, 0.5f / positive.Count)).Concat(negative.Select(v => (v, 0f, 0.5f / negative.Count))).ToList();
        for (int epoch = 0; epoch < Epochs; epoch++)
        {
            if (token.IsCancellationRequested) return null;
            Array.Clear(gradient);
            float biasGradient = 0;
            foreach (var (vector, label, weight) in examples)
            {
                float difference = (Probability(weights, vector) - label) * weight;
                TensorPrimitives.MultiplyAdd(vector, difference, gradient, gradient);
                biasGradient += difference;
            }
            for (int i = 0; i < Dimension; i++) weights[i] -= (float)(LearningRate * (gradient[i] + Regularization * weights[i]));
            weights[Dimension] -= (float)(LearningRate * biasGradient);
        }
        return weights;
    }
}
