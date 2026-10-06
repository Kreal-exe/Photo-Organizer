using System.Text.RegularExpressions;

namespace PhotoOrganizer.Core;

/// <summary>
/// Tells screenshots from photos by what the file itself says, without looking at the picture: the name the system
/// gave it ("Screenshot 2024-…", "Снимок экрана…", "Screenshot_20240101-…"), a folder of screenshots, or a PNG — which
/// cameras never write — the size of a phone, tablet or computer screen (iPhones name screenshots IMG_1234.PNG).
/// </summary>
public static partial class Screenshots
{
    [GeneratedRegex(@"^(screenshot|screen shot|screen_shot|screencap|снимок экрана|скриншот|скрин|scr_|scrn_)|screenshot", RegexOptions.IgnoreCase)]
    private static partial Regex ScreenshotName();

    static readonly HashSet<string> Folders = new(StringComparer.OrdinalIgnoreCase)
    {
        "screenshots", "screen shots", "screenshot", "скриншоты", "снимки экрана", "screencaps",
    };

    /// <summary>Screens, as width × height in either orientation: phones, tablets, laptops and monitors.</summary>
    static readonly HashSet<(int, int)> ScreenSizes = BuildSizes(
        // iPhone
        (640, 960), (640, 1136), (750, 1334), (828, 1792), (1080, 1920), (1125, 2436), (1170, 2532), (1179, 2556), (1206, 2622),
        (1242, 2208), (1242, 2688), (1284, 2778), (1290, 2796), (1320, 2868),
        // Android
        (720, 1280), (720, 1600), (1080, 2160), (1080, 2220), (1080, 2280), (1080, 2340), (1080, 2400), (1080, 2408), (1440, 2560),
        (1440, 2960), (1440, 3040), (1440, 3088), (1440, 3120), (1440, 3200), (1260, 2800), (1220, 2712), (1256, 2760),
        // iPad
        (1536, 2048), (1620, 2160), (1640, 2360), (1668, 2224), (1668, 2388), (1488, 2266), (2048, 2732), (2064, 2752),
        // Computers
        (1280, 800), (1366, 768), (1440, 900), (1536, 864), (1680, 1050), (1920, 1080), (1920, 1200), (2560, 1080), (2560, 1440),
        (2560, 1600), (2880, 1800), (2940, 1912), (3024, 1964), (3456, 2234), (3840, 2160), (5120, 2880));

    static HashSet<(int, int)> BuildSizes(params (int, int)[] sizes)
    {
        var set = new HashSet<(int, int)>();
        foreach (var (a, b) in sizes)
        {
            set.Add((a, b));
            set.Add((b, a));
        }
        return set;
    }

    public static bool IsScreenshot(PhotoItem item)
    {
        if (item.Video) return false;
        if (ScreenshotName().IsMatch(Path.GetFileNameWithoutExtension(item.Name))) return true;
        foreach (string folder in item.CurrentFolder.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            if (Folders.Contains(folder)) return true;
        }
        if (!item.Name.EndsWith(".png", StringComparison.OrdinalIgnoreCase) || item.PixelWidth <= 0 || item.PixelHeight <= 0) return false;
        if (ScreenSizes.Contains((item.PixelWidth, item.PixelHeight))) return true;
        // Phones keep getting new screens: anything as tall as a phone is one too.
        double tall = (double)Math.Max(item.PixelWidth, item.PixelHeight) / Math.Min(item.PixelWidth, item.PixelHeight);
        return tall >= 1.9 && Math.Min(item.PixelWidth, item.PixelHeight) >= 600;
    }
}
