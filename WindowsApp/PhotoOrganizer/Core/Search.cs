using System.Numerics.Tensors;

namespace PhotoOrganizer.Core;

/// <summary>Search by example: by a whole photo, or by one object marked in a photo.</summary>
public static class Search
{
    const int MaximumResults = 300;

    /// <summary>The stored MobileCLIP vectors of a file (the picture, then its parts), or null when it has none.</summary>
    static byte[]? Vectors(PhotoItem item) =>
        item.RecognitionKey is { } key && RecognitionStore.Shared.Get(key)?.Objects is { Length: > 0 } objects ? objects : null;

    public static int CountIndexed(IEnumerable<PhotoItem> items) => items.Count(i => !i.Video && Vectors(i) != null);

    /// <summary>The stored vector of the whole picture, unit length; null when the file has none.</summary>
    public static float[]? PictureVector(PhotoItem item)
    {
        if (Vectors(item) is not { } vectors) return null;
        var vector = Recognizer.Unpack(vectors, 0);
        float norm = TensorPrimitives.Norm(vector);
        if (norm <= 0) return null;
        TensorPrimitives.Divide(vector, norm, vector);
        return vector;
    }

    /// <summary>
    /// Search by object: photos ordered by how close their nearest vector — of the whole picture or one of its parts — is
    /// to the marked object's, closest first.
    /// </summary>
    public static List<PhotoItem> Nearest(float[] query, IEnumerable<PhotoItem> items, int limit = 201)
    {
        var scored = new List<(float Distance, PhotoItem Item)>();
        foreach (var item in items)
        {
            if (item.Video || Vectors(item) is not { } vectors) continue;
            float best = float.MaxValue;
            for (int p = 0; p < Recognizer.Count(vectors); p++)
            {
                float distance = 2 - 2 * TensorPrimitives.Dot(Recognizer.Unpack(vectors, p), query);   // squared distance between unit vectors
                if (distance < best) best = distance;
            }
            scored.Add((best, item));
        }
        return scored.OrderBy(s => s.Distance).Take(limit).Select(s => s.Item).ToList();
    }

    /// <summary>
    /// Search by photo, as on the Mac in two steps: the words (labels) the user kept pick the candidates — the more they
    /// share, the earlier — and then the candidates are ordered by how alike they look (their whole-picture vectors).
    /// </summary>
    public static List<PhotoItem> Similar(float[] example, IReadOnlyCollection<string> labels, IEnumerable<PhotoItem> items)
    {
        var candidates = new List<(float Distance, PhotoItem Item)>();
        foreach (var item in items)
        {
            if (item.Video || item.CloudOnly || Vectors(item) is not { } vectors) continue;   // the comparison needs a still picture
            if (labels.Count > 0 && !labels.Any(l => item.Labels?.ContainsKey(l) == true)) continue;
            candidates.Add((2 - 2 * TensorPrimitives.Dot(Recognizer.Unpack(vectors, 0), example), item));
        }
        return candidates.OrderBy(c => c.Distance).Take(MaximumResults).Select(c => c.Item).ToList();
    }
}
