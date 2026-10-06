using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace PhotoOrganizer.Core;

/// <summary>
/// The text written in a picture — a screenshot, a document, a sign — read by the OCR built into Windows
/// (Windows.Media.Ocr, offline), in Russian and English when those recognisers are installed. Found by the search like
/// the recognised objects.
/// </summary>
public static class PictureText
{
    /// <summary>Reading text is switched on in the settings (on by default).</summary>
    public static bool Enabled
    {
        get => Settings.Shared.Get("readsText", true);
        set => Settings.Shared.Set("readsText", value);
    }

    static readonly string[] Wanted = ["ru", "en-US", "en"];

    /// <summary>The languages there is a recogniser for, Russian first; empty when Windows has none installed.</summary>
    public static IReadOnlyList<Language> Languages { get; } = OcrEngine.AvailableRecognizerLanguages
        .Where(l => Wanted.Any(w => l.LanguageTag.StartsWith(w, StringComparison.OrdinalIgnoreCase)))
        .GroupBy(l => l.LanguageTag[..2]).Select(g => g.First()).OrderBy(l => l.LanguageTag.StartsWith("ru") ? 0 : 1).ToList();

    public static bool Available => Languages.Count > 0;

    // An engine per thread and language: the analysis reads several pictures at once.
    static readonly ThreadLocal<OcrEngine?[]> Engines = new(() => Languages.Select(OcrEngine.TryCreateFromLanguage).ToArray());

    /// <summary>Labels of pictures that usually carry text.</summary>
    static readonly HashSet<string> TextLabels =
    [
        "document", "printed_page", "handwriting", "screenshot", "receipt", "sign", "street_sign", "newspaper", "book",
        "whiteboard", "chart", "diagram", "map", "computer", "laptop", "phone", "television", "storefront", "graffiti",
    ];

    /// <summary>
    /// Whether a picture is worth reading: reading every photo of a large library at full size would take hours, and
    /// most photos have no text. Screenshots (PNG, or a phone screen's proportions) and pictures recognised as
    /// documents, signs, screens… are read.
    /// </summary>
    public static bool Worth(PhotoItem item, IReadOnlyDictionary<string, float>? labels)
    {
        if (item.Video) return false;
        string extension = Path.GetExtension(item.Name).ToLowerInvariant();
        if (extension is ".png" or ".webp" or ".bmp" or ".gif") return true;
        if (item.PixelWidth > 0 && item.PixelHeight > 0)
        {
            double tall = (double)Math.Max(item.PixelWidth, item.PixelHeight) / Math.Min(item.PixelWidth, item.PixelHeight);
            if (tall >= 1.9) return true;   // phone screenshots are about 2.17 : 1, photos 4 : 3 or 16 : 9
        }
        return labels != null && labels.Keys.Any(TextLabels.Contains);
    }

    /// <summary>The text of the picture, lines joined by line breaks; empty when there is none, null when it can't be read.</summary>
    public static string? Read(string path)
    {
        var image = Images.Load(path, (int)OcrEngine.MaxImageDimension);
        if (image == null) return null;
        var bgra = new byte[image.Width * image.Height * 4];
        for (int i = 0, j = 0; i < image.Bgr.Length; i += 3, j += 4)
        {
            bgra[j] = image.Bgr[i];
            bgra[j + 1] = image.Bgr[i + 1];
            bgra[j + 2] = image.Bgr[i + 2];
            bgra[j + 3] = 255;
        }
        using var bitmap = SoftwareBitmap.CreateCopyFromBuffer(bgra.AsBuffer(), BitmapPixelFormat.Bgra8, image.Width, image.Height, BitmapAlphaMode.Ignore);
        var lines = new List<string>();
        foreach (var engine in Engines.Value!)
        {
            if (engine == null) continue;
            var result = engine.RecognizeAsync(bitmap).AsTask().GetAwaiter().GetResult();
            foreach (var line in result.Lines)
            {
                string text = line.Text.Trim();
                if (text.Length > 0 && !lines.Contains(text)) lines.Add(text);
            }
        }
        return string.Join("\n", lines);
    }
}
