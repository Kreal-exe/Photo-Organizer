using System.Text.RegularExpressions;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.Core;

public enum DateSource
{
    Exif = 0,            // capture date embedded in the file (EXIF for images, container metadata for videos)
    File = 1,            // nothing better than the file system's date, usually when the file was copied: undated
    Name = 2,            // date written in the file name (20220909_145141.mp4)
    Neighbors = 3,       // taken from the shots before and after it in the same numbered series
    Takeout = 4,         // from the .json file Google Takeout puts next to every photo (photoTakenTime)
    Copy = 5,            // taken from another copy of the same picture that has one
    NeighborsMonth = 6,  // the numbered shots before and after it are from the same month
    Manual = 7,          // set by the user in the app (see ManualDates)
}

/// <summary>How much of the date is actually known.</summary>
public enum Precision { Day = 0, Month = 1, Year = 2 }

/// <summary>One image or video file found by the scanner.</summary>
public sealed class PhotoItem
{
    public PhotoItem(string path, string relativePath)
    {
        Path = path;
        RelativePath = relativePath;
        CurrentFolder = FolderOf(relativePath);
    }

    /// <summary>Absolute, with the system's separators.</summary>
    public string Path { get; private set; }
    /// <summary>Relative to the scanned root, always with "/".</summary>
    public string RelativePath { get; private set; }
    /// <summary>The folder the file is in, relative to the root ("" for the root itself).</summary>
    public string CurrentFolder { get; private set; }

    public long FileSize;
    /// <summary>Local wall-clock time of the shot.</summary>
    public DateTime Date = new(1970, 1, 1);
    public DateSource DateSource = DateSource.File;
    public bool HasLocation;
    public double Latitude, Longitude;
    public Precision ManualPrecision = Precision.Day;
    /// <summary>The file system's date (the earlier of creation and modification), kept for suggestions.</summary>
    public DateTime? FileDate;
    /// <summary>0 when the image could not be read.</summary>
    public int PixelWidth, PixelHeight;
    /// <summary>A small copy of another, larger photo of the folder (see SimilarCopies).</summary>
    public bool Tiny;
    public bool Video;
    public double Duration;
    /// <summary>A OneDrive / iCloud placeholder whose contents are not on this PC: never read, never hashed.</summary>
    public bool CloudOnly;
    /// <summary>One 512-byte signed embedding per face; null when not analysed, empty when there are none.</summary>
    public List<byte[]>? Faces;
    /// <summary>(x, y, w, h) of each face, as fractions of the picture.</summary>
    public List<float[]>? FaceBoxes;
    public int? PeopleCount;
    /// <summary>What is in the picture (label identifier → confidence, see Labels); null until analysed.</summary>
    public Dictionary<string, float>? Labels;
    /// <summary>0…1 from the optional nudity model; null when not analysed.</summary>
    public float? NudityScore;
    public ulong? VisualHash;
    /// <summary>The key the file's recognition results are stored under (see RecognitionStore); null until analysed.</summary>
    public string? RecognitionKey;
    /// <summary>On a resized or recompressed copy: the better version of the same picture.</summary>
    public PhotoItem? BetterCopy;
    public bool BestOfCopies;
    public string? ContentHash;
    /// <summary>On every exact copy: the file kept as the original.</summary>
    public PhotoItem? DuplicateOf;
    /// <summary>On the original: its exact copies.</summary>
    public List<PhotoItem>? Duplicates;
    /// <summary>Assigned by the plan, relative to the root, with "/".</summary>
    public string? DestinationFolder;

    public string Name => RelativePath[(RelativePath.LastIndexOf('/') + 1)..];

    public override string ToString() => RelativePath;

    static string FolderOf(string relativePath)
    {
        int slash = relativePath.LastIndexOf('/');
        return slash < 0 ? "" : relativePath[..slash];
    }

    public void MovedTo(string path, string relativePath)
    {
        Path = path;
        RelativePath = relativePath;
        CurrentFolder = FolderOf(relativePath);
    }

    public bool Undated => DateSource == DateSource.File;
    public bool IsDuplicate => DuplicateOf != null;

    /// <summary>Windows folder names ignore letter case.</summary>
    public bool NeedsMove => DestinationFolder != null && !string.Equals(DestinationFolder, CurrentFolder, StringComparison.OrdinalIgnoreCase);

    public Precision Precision => DateSource switch
    {
        DateSource.Manual => ManualPrecision,
        DateSource.NeighborsMonth => Precision.Month,
        _ => Precision.Day,
    };

    public string DateSourceText => DateSource switch
    {
        DateSource.Exif => L("Дата съёмки (из метаданных)"),
        DateSource.Name => L("Дата из имени файла"),
        DateSource.Neighbors => L("Дата по соседним кадрам серии"),
        DateSource.NeighborsMonth => L("Месяц по соседним кадрам серии"),
        DateSource.Manual => L("Дата задана вручную"),
        DateSource.Takeout => L("Дата из Google Takeout (.json)"),
        DateSource.Copy => L("Дата другой копии этого снимка"),
        _ => L("Без даты"),
    };

    public string DateText(bool withTime = false)
    {
        if (Undated) return L("Без даты");
        return Precision switch
        {
            Precision.Year => FormatYear(Date),
            Precision.Month => FormatMonth(Date),
            _ => FormatDay(Date, withTime),
        };
    }

    public static string DateText(DateTime date, Precision precision)
    {
        var probe = new PhotoItem("x", "x") { Date = date, DateSource = DateSource.Manual, ManualPrecision = precision };
        return probe.DateText();
    }

    /// <summary>Date order, then the name in natural order.</summary>
    public static readonly Comparison<PhotoItem> ByDate = (a, b) =>
    {
        int byDate = a.Date.CompareTo(b.Date);
        return byDate != 0 ? byDate : NaturalComparer.Instance.Compare(a.RelativePath, b.RelativePath);
    };
}

/// <summary>Orders "IMG_2" before "IMG_10", ignoring case (Explorer's and Finder's order).</summary>
public sealed partial class NaturalComparer : IComparer<string>
{
    public static readonly NaturalComparer Instance = new();

    [GeneratedRegex(@"(\d+)")]
    private static partial Regex Digits();

    public int Compare(string? x, string? y)
    {
        if (ReferenceEquals(x, y)) return 0;
        if (x == null) return -1;
        if (y == null) return 1;
        var a = Digits().Split(x);
        var b = Digits().Split(y);
        for (int i = 0; i < Math.Min(a.Length, b.Length); i++)
        {
            bool numberA = i % 2 == 1, numberB = i % 2 == 1;
            int result;
            if (numberA && numberB)
            {
                string ta = a[i].TrimStart('0'), tb = b[i].TrimStart('0');
                result = ta.Length != tb.Length ? ta.Length.CompareTo(tb.Length) : string.CompareOrdinal(ta, tb);
            }
            else
            {
                result = string.Compare(a[i], b[i], StringComparison.CurrentCultureIgnoreCase);
            }
            if (result != 0) return result;
        }
        return a.Length.CompareTo(b.Length);
    }
}
