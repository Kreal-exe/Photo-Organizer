using System.Text.RegularExpressions;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.Core;

/// <summary>
/// What kind of file something is, for organizing by type — told by what the file itself says (its name, its folder,
/// its format and proportions), the way Apple Photos lists its media types: screenshots, screen recordings, pictures
/// from messengers, videos, animations, panoramas, RAW and camera photos.
/// </summary>
public static partial class MediaTypes
{
    [GeneratedRegex(@"^(rpreplay|screenrecording|screen recording|screen_recording|screenrecorder|запись экрана|record_screen)", RegexOptions.IgnoreCase)]
    private static partial Regex ScreenRecordingName();

    [GeneratedRegex(@"^(img|vid|aud|ptt|stk)-\d{8}-wa\d+", RegexOptions.IgnoreCase)]
    private static partial Regex WhatsAppName();

    [GeneratedRegex(@"^(photo|video|file)_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}|^telegram-(cloud|peer)-", RegexOptions.IgnoreCase)]
    private static partial Regex TelegramName();

    [GeneratedRegex(@"^viber[_ ]", RegexOptions.IgnoreCase)]
    private static partial Regex ViberName();

    [GeneratedRegex(@"^pano[_-]", RegexOptions.IgnoreCase)]
    private static partial Regex PanoramaName();

    [GeneratedRegex(@"-(collage|photo_frame|animation|effects|mix|snippet|cinematic|stylized)(\(\d+\))?$|^movie(\(\d+\))?$", RegexOptions.IgnoreCase)]
    private static partial Regex GooglePhotosCreationName();

    /// <summary>
    /// What Google Photos made out of photos rather than a camera took: collages, photo frames, animations, movies,
    /// video snippets and effects ("…-COLLAGE.jpg", "…-PHOTO_FRAME.jpg", "MOVIE.mp4") — told by the names Google Photos
    /// and Google Takeout give them. An edited copy ("…-отредактировано.jpg") is still a photo.
    /// </summary>
    public static bool IsGooglePhotosCreation(PhotoItem item) =>
        GooglePhotosCreationName().IsMatch(Path.GetFileNameWithoutExtension(item.Name).Normalize());

    static readonly HashSet<string> RawExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".dng", ".cr2", ".cr3", ".crw", ".nef", ".nrw", ".arw", ".srf", ".sr2", ".raf", ".orf", ".rw2", ".pef", ".srw", ".x3f", ".3fr", ".erf", ".kdc", ".rwl", ".iiq",
    };

    static bool InFolder(PhotoItem item, string name) =>
        item.CurrentFolder.Split('/').Any(folder => folder.Contains(name, StringComparison.OrdinalIgnoreCase));

    /// <summary>The name of the folder a file goes to when the library is organized by type.</summary>
    public static string TypeFolder(PhotoItem item)
    {
        string baseName = Path.GetFileNameWithoutExtension(item.Name), extension = Path.GetExtension(item.Name);
        if (IsGooglePhotosCreation(item)) return L("Коллажи");
        if (item.IsPicture) return L("Картинки");
        if (Screenshots.IsScreenshot(item)) return L("Скриншоты");
        if (item.Video && ScreenRecordingName().IsMatch(baseName)) return L("Записи экрана");
        if (WhatsAppName().IsMatch(baseName) || InFolder(item, "whatsapp")) return "WhatsApp";
        if (TelegramName().IsMatch(baseName) || InFolder(item, "telegram")) return "Telegram";
        if (ViberName().IsMatch(baseName) || InFolder(item, "viber")) return "Viber";
        if (InFolder(item, "instagram")) return "Instagram";
        if (item.Video) return L("Видео");
        if (extension.Equals(".gif", StringComparison.OrdinalIgnoreCase)) return L("Анимации");
        if (RawExtensions.Contains(extension)) return "RAW";
        if (PanoramaName().IsMatch(baseName)) return L("Панорамы");
        // A panorama is wide and large: a narrow tall strip (a crop, a long picture from a messenger) is not one.
        if (item.PixelHeight > 0 && item.PixelWidth >= 2500 && (double)item.PixelWidth / item.PixelHeight >= 2.5) return L("Панорамы");
        return L("Фото");
    }

    /// <summary>The name of the folder a file goes to when the library is organized by format: JPEG, HEIC, MOV…</summary>
    public static string FormatFolder(PhotoItem item)
    {
        string extension = Path.GetExtension(item.Name).TrimStart('.').ToUpperInvariant();
        return extension switch
        {
            "JPG" or "JPEG" or "JPE" => "JPEG",
            "TIF" or "TIFF" => "TIFF",
            "HEIC" or "HEIF" => "HEIC",
            "" => L("Без расширения"),
            _ => extension,
        };
    }
}
