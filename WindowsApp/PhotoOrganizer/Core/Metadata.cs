using System.Buffers.Binary;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace PhotoOrganizer.Core;

/// <summary>What is known about a file without decoding its picture.</summary>
public sealed class Metadata
{
    public int Width, Height;
    public DateTime? Date;
    public double? Latitude, Longitude;
    public double Duration;
    public int Orientation = 1;
}

/// <summary>
/// Reads the capture date, pixel size and place of a photo or video. JPEG, TIFF and the TIFF-based RAW formats are
/// parsed directly (fast, and the EXIF date is read exactly as the camera wrote it); everything else — HEIC, WebP,
/// PNG, videos — goes through the Windows Property System, the same handlers File Explorer uses.
/// </summary>
public static partial class MetadataReader
{
    public static readonly HashSet<string> ImageExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "jpg", "jpeg", "jpe", "jfif", "png", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif", "avif",
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "orf", "rw2", "raf", "srw", "pef", "raw", "x3f",
    };

    public static readonly HashSet<string> VideoExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "mp4", "m4v", "mov", "qt", "avi", "mkv", "3gp", "3g2", "mts", "m2ts", "ts", "wmv", "webm", "mpg", "mpeg", "flv",
    };

    static readonly HashSet<string> TiffBased = new(StringComparer.OrdinalIgnoreCase)
    {
        "tif", "tiff", "dng", "cr2", "nef", "nrw", "arw", "srf", "sr2", "orf", "rw2", "srw", "pef",
    };

    static readonly DateTime Year1990 = new(1990, 1, 1);

    public static string Extension(string path)
    {
        string name = System.IO.Path.GetFileName(path);
        int dot = name.LastIndexOf('.');
        return dot < 0 ? "" : name[(dot + 1)..];
    }

    [GeneratedRegex(@"^\s*(\d{4})[:\-](\d{1,2})[:\-](\d{1,2})(?:[ T](\d{1,2}):(\d{1,2}):(\d{1,2}))?")]
    private static partial Regex ExifDatePattern();

    /// <summary>
    /// "yyyy:MM:dd HH:mm:ss" (EXIF) or "yyyy-MM-ddTHH:mm:ss+zzzz" (QuickTime) as the wall-clock time where the shot was
    /// taken, ignoring any UTC offset: a photo taken at 23:30 on holiday belongs to that day's folder.
    /// </summary>
    public static DateTime? DateFromExifString(string? value)
    {
        if (value == null) return null;
        var m = ExifDatePattern().Match(value);
        if (!m.Success) return null;
        int year = int.Parse(m.Groups[1].Value), month = int.Parse(m.Groups[2].Value), day = int.Parse(m.Groups[3].Value);
        int hour = m.Groups[4].Success ? int.Parse(m.Groups[4].Value) : 0;
        int minute = m.Groups[5].Success ? int.Parse(m.Groups[5].Value) : 0;
        int second = m.Groups[6].Success ? int.Parse(m.Groups[6].Value) : 0;
        if (year < 1900 || year > 2200 || month < 1 || month > 12 || day < 1 || day > 31) return null;
        try
        {
            return new DateTime(year, month, day, Math.Min(hour, 23), Math.Min(minute, 59), Math.Min(second, 59));
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    public static Metadata Read(string path, bool video)
    {
        var meta = new Metadata();
        string extension = Extension(path);
        try
        {
            if (!video && (extension.Equals("jpg", StringComparison.OrdinalIgnoreCase) || extension.Equals("jpeg", StringComparison.OrdinalIgnoreCase)
                           || extension.Equals("jpe", StringComparison.OrdinalIgnoreCase) || extension.Equals("jfif", StringComparison.OrdinalIgnoreCase)))
            {
                if (ReadJpeg(path, meta)) return Finish(meta);
            }
            else if (!video && TiffBased.Contains(extension))
            {
                if (ReadTiffFile(path, meta)) return Finish(meta);
            }
            else if (!video && extension.Equals("png", StringComparison.OrdinalIgnoreCase))
            {
                ReadPngSize(path, meta);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or EndOfStreamException)
        {
        }
        ShellProperties.Read(path, video, meta);
        return Finish(meta);
    }

    static Metadata Finish(Metadata meta)
    {
        // Turned by 90°: shown the other way round.
        if (meta.Orientation is >= 5 and <= 8) (meta.Width, meta.Height) = (meta.Height, meta.Width);
        return meta;
    }

    // --- JPEG -------------------------------------------------------------------------------------------------------

    static bool ReadJpeg(string path, Metadata meta)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 65536);
        using var reader = new BinaryReader(stream);
        if (reader.ReadByte() != 0xFF || reader.ReadByte() != 0xD8) return false;
        bool sawExif = false;
        while (stream.Position < stream.Length)
        {
            int marker;
            do { marker = reader.ReadByte(); } while (marker != 0xFF && stream.Position < stream.Length);
            do { marker = reader.ReadByte(); } while (marker == 0xFF);
            if (marker == 0xD9 || marker == 0xDA) break;   // end of image, or the picture data starts
            if (marker is >= 0xD0 and <= 0xD7 or 0x01) continue;
            int length = (reader.ReadByte() << 8) | reader.ReadByte();
            if (length < 2) return false;
            long next = stream.Position + length - 2;
            if (marker == 0xE1 && !sawExif && length > 8)
            {
                byte[] segment = reader.ReadBytes(length - 2);
                if (segment.Length > 6 && segment[0] == 'E' && segment[1] == 'x' && segment[2] == 'i' && segment[3] == 'f')
                {
                    sawExif = true;
                    ParseTiff(segment.AsSpan(6), meta);
                }
            }
            else if (marker is >= 0xC0 and <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC)
            {
                reader.ReadByte();   // precision
                meta.Height = (reader.ReadByte() << 8) | reader.ReadByte();
                meta.Width = (reader.ReadByte() << 8) | reader.ReadByte();
                return true;
            }
            stream.Position = next;
        }
        return meta.Width > 0;
    }

    static void ReadPngSize(string path, Metadata meta)
    {
        using var stream = File.OpenRead(path);
        Span<byte> head = stackalloc byte[24];
        if (stream.Read(head) < 24 || head[12] != 'I' || head[13] != 'H') return;
        meta.Width = BinaryPrimitives.ReadInt32BigEndian(head[16..]);
        meta.Height = BinaryPrimitives.ReadInt32BigEndian(head[20..]);
    }

    // --- TIFF structure (EXIF blocks, TIFF and RAW files) ----------------------------------------------------------

    static bool ReadTiffFile(string path, Metadata meta)
    {
        using var stream = File.OpenRead(path);
        // The IFDs of a RAW file sit near its start; the rest is the picture.
        int length = (int)Math.Min(stream.Length, 4 << 20);
        byte[] data = new byte[length];
        stream.ReadExactly(data);
        return ParseTiff(data, meta);
    }

    static bool ParseTiff(ReadOnlySpan<byte> data, Metadata meta)
    {
        if (data.Length < 8) return false;
        bool little = data[0] == 'I' && data[1] == 'I';
        if (!little && !(data[0] == 'M' && data[1] == 'M')) return false;
        var tiff = new TiffReader(data.ToArray(), little);
        var main = tiff.Directory(tiff.UInt32(4));
        if (main == null) return false;
        DateTime? date = main.TryGetValue(306, out var dateTime) ? DateFromExifString(tiff.String(dateTime)) : null;
        if (main.TryGetValue(274, out var orientation)) meta.Orientation = (int)tiff.Number(orientation);
        if (meta.Width == 0 && main.TryGetValue(256, out var width) && main.TryGetValue(257, out var height))
        {
            meta.Width = (int)tiff.Number(width);
            meta.Height = (int)tiff.Number(height);
        }
        if (main.TryGetValue(0x8769, out var exifPointer) && tiff.Directory((uint)tiff.Number(exifPointer)) is { } exif)
        {
            foreach (int tag in new[] { 36867, 36868 })
            {
                if (exif.TryGetValue(tag, out var entry) && DateFromExifString(tiff.String(entry)) is { } found)
                {
                    date = found;
                    break;
                }
            }
            // The real image size, where the main directory of a RAW file describes a preview.
            if (exif.TryGetValue(40962, out var w) && exif.TryGetValue(40963, out var h) && tiff.Number(w) > 0)
            {
                meta.Width = (int)tiff.Number(w);
                meta.Height = (int)tiff.Number(h);
            }
        }
        meta.Date = date;
        if (main.TryGetValue(0x8825, out var gpsPointer) && tiff.Directory((uint)tiff.Number(gpsPointer)) is { } gps)
        {
            double? latitude = gps.TryGetValue(2, out var lat) ? tiff.Degrees(lat) : null;
            double? longitude = gps.TryGetValue(4, out var lon) ? tiff.Degrees(lon) : null;
            if (latitude is { } la && longitude is { } lo && (la != 0 || lo != 0) && la <= 90 && lo <= 180)
            {
                if (gps.TryGetValue(1, out var latRef) && tiff.String(latRef).StartsWith('S')) la = -la;
                if (gps.TryGetValue(3, out var lonRef) && tiff.String(lonRef).StartsWith('W')) lo = -lo;
                meta.Latitude = la;
                meta.Longitude = lo;
            }
        }
        return true;
    }

    readonly record struct TiffEntry(int Type, uint Count, int ValueOffset);

    sealed class TiffReader(byte[] data, bool little)
    {
        static readonly Dictionary<int, int> TypeSizes = new() { [1] = 1, [2] = 1, [3] = 2, [4] = 4, [5] = 8, [7] = 1, [9] = 4, [10] = 8 };

        public uint UInt32(int at) => at + 4 > data.Length ? 0
            : little ? BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(at)) : BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(at));

        ushort UInt16(int at) => at + 2 > data.Length ? (ushort)0
            : little ? BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(at)) : BinaryPrimitives.ReadUInt16BigEndian(data.AsSpan(at));

        public Dictionary<int, TiffEntry>? Directory(uint offset)
        {
            if (offset == 0 || offset + 2 > data.Length) return null;
            int count = UInt16((int)offset);
            if (count > 1000) return null;
            var entries = new Dictionary<int, TiffEntry>();
            for (int i = 0; i < count; i++)
            {
                int at = (int)offset + 2 + 12 * i;
                if (at + 12 > data.Length) break;
                int tag = UInt16(at), type = UInt16(at + 2);
                uint n = UInt32(at + 4);
                long size = TypeSizes.GetValueOrDefault(type, 1) * (long)n;
                int valueAt = size > 4 ? (int)UInt32(at + 8) : at + 8;
                entries[tag] = new TiffEntry(type, n, valueAt);
            }
            return entries;
        }

        public double Number(TiffEntry entry) => entry.Type switch
        {
            3 => UInt16(entry.ValueOffset),
            4 or 9 => UInt32(entry.ValueOffset),
            5 => Rational(entry.ValueOffset),
            _ => 0,
        };

        double Rational(int at)
        {
            uint denominator = UInt32(at + 4);
            return denominator == 0 ? 0 : (double)UInt32(at) / denominator;
        }

        public string String(TiffEntry entry)
        {
            if (entry.Type != 2 || entry.ValueOffset < 0 || entry.ValueOffset >= data.Length) return "";
            int length = (int)Math.Min(entry.Count, (uint)(data.Length - entry.ValueOffset));
            string text = Encoding.ASCII.GetString(data, entry.ValueOffset, length);
            int zero = text.IndexOf('\0');
            return zero >= 0 ? text[..zero] : text;
        }

        public double? Degrees(TiffEntry entry)
        {
            if (entry.Type != 5 || entry.Count < 3 || entry.ValueOffset + 24 > data.Length) return null;
            return Rational(entry.ValueOffset) + Rational(entry.ValueOffset + 8) / 60 + Rational(entry.ValueOffset + 16) / 3600;
        }
    }

    // --- Videos ---------------------------------------------------------------------------------------------------

    [GeneratedRegex(@"^\s*([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)")]
    private static partial Regex Iso6709Pattern();

    /// <summary>"+51.2213+006.7877/" — how QuickTime and Android store a video's location.</summary>
    public static (double, double)? ParseIso6709(string? text)
    {
        var m = Iso6709Pattern().Match(text ?? "");
        if (!m.Success) return null;
        double latitude = double.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
        double longitude = double.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture);
        if (Math.Abs(latitude) > 90 || Math.Abs(longitude) > 180 || (latitude == 0 && longitude == 0)) return null;
        return (latitude, longitude);
    }

    static readonly TimeSpan EpochGap = TimeSpan.FromSeconds(2082844800);   // between QuickTime's 1904 and Unix's 1970

    /// <summary>
    /// Older phones counted seconds from 1970 where QuickTime counts from 1904, so their videos claim to be from the
    /// 1930s–50s; shifted by the 66 years between the two epochs they come out right. Dates before 1990 are dropped.
    /// </summary>
    public static DateTime? CleanVideoDate(DateTime? date)
    {
        if (date is not { } d) return null;
        if (d < Year1990 && d + EpochGap > Year1990 && d + EpochGap < DateTime.Now.AddDays(1)) d += EpochGap;
        return d > Year1990 ? d : null;
    }
}

/// <summary>The Windows Property System: dates, sizes and places of any file Explorer has a handler for.</summary>
static class ShellProperties
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct PropertyKey(Guid format, uint id)
    {
        public Guid FormatId = format;
        public uint PropertyId = id;
    }

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    struct PropVariant
    {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(8)] public long Long;
        [FieldOffset(8)] public uint UInt;
        [FieldOffset(8)] public ushort UShort;
        [FieldOffset(8)] public double Double;
        [FieldOffset(8)] public IntPtr Pointer;
        [FieldOffset(8)] public uint VectorCount;
        [FieldOffset(16)] public IntPtr VectorPointer;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        void SetValue(ref PropertyKey key, ref PropVariant value);
        void Commit();
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    static extern int SHGetPropertyStoreFromParsingName(string path, IntPtr bindContext, int flags, ref Guid riid,
                                                         [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);

    [DllImport("ole32.dll")]
    static extern int PropVariantClear(ref PropVariant value);

    static readonly Guid Photo = new("14B81DA1-0135-4D31-96D9-6CBFC9671A99");
    static readonly Guid Image = new("6444048F-4C8B-11D1-8B70-080036B11A03");
    static readonly Guid VideoProperties = new("64440491-4C8B-11D1-8B70-080036B11A03");
    static readonly Guid Audio = new("64440490-4C8B-11D1-8B70-080036B11A03");
    static readonly Guid Media = new("2E4B640D-5019-46D8-8881-55414CC5CAA0");

    static PropertyKey DateTaken = new(Photo, 36867);
    static PropertyKey Orientation = new(Photo, 274);
    static PropertyKey ImageWidth = new(Image, 3);
    static PropertyKey ImageHeight = new(Image, 4);
    static PropertyKey FrameWidth = new(VideoProperties, 3);
    static PropertyKey FrameHeight = new(VideoProperties, 4);
    static PropertyKey VideoOrientation = new(VideoProperties, 99);
    static PropertyKey Duration = new(Audio, 3);
    static PropertyKey DateEncoded = new(Media, 100);
    static PropertyKey Latitude = new(new Guid("8727CFFF-4868-4EC6-AD5B-81B98521D1AB"), 100);
    static PropertyKey LatitudeRef = new(new Guid("029C0252-5B86-46C7-ACA0-2769FFC8E3D4"), 100);
    static PropertyKey Longitude = new(new Guid("C4C4DBB2-B593-466B-BBDA-D03D27D5E43A"), 100);
    static PropertyKey LongitudeRef = new(new Guid("33DCF22B-28D5-464C-8035-1EE9EFD25278"), 100);

    const ushort VT_UI2 = 18, VT_UI4 = 19, VT_UI8 = 21, VT_LPWSTR = 31, VT_FILETIME = 64, VT_R8 = 5, VT_VECTOR = 0x1000;

    public static void Read(string path, bool video, Metadata meta)
    {
        var iid = typeof(IPropertyStore).GUID;
        // GPS_BESTEFFORT: whatever the handler can give, without failing on a slow or partly broken file.
        if (SHGetPropertyStoreFromParsingName(path, IntPtr.Zero, 0x40, ref iid, out var store) != 0 || store == null) return;
        try
        {
            if (video)
            {
                if (Get(store, FrameWidth) is { } w && w.Type == VT_UI4) meta.Width = (int)w.UInt;
                if (Get(store, FrameHeight) is { } h && h.Type == VT_UI4) meta.Height = (int)h.UInt;
                if (Get(store, VideoOrientation) is { } o && o.Type == VT_UI4 && (o.UInt == 90 || o.UInt == 270))
                {
                    (meta.Width, meta.Height) = (meta.Height, meta.Width);
                }
                if (Get(store, Duration) is { } d && d.Type == VT_UI8) meta.Duration = d.Long / 1e7;
                // The container's creation time is UTC; shown in local time, as on the camera's clock.
                if (meta.Date == null && Get(store, DateEncoded) is { } e && e.Type == VT_FILETIME)
                {
                    meta.Date = MetadataReader.CleanVideoDate(FromFileTime(e.Long));
                }
            }
            else
            {
                if (meta.Width == 0 && Get(store, ImageWidth) is { } w && w.Type == VT_UI4) meta.Width = (int)w.UInt;
                if (meta.Height == 0 && Get(store, ImageHeight) is { } h && h.Type == VT_UI4) meta.Height = (int)h.UInt;
                if (Get(store, Orientation) is { } o && o.Type == VT_UI2) meta.Orientation = o.UShort;
                // Windows turns the EXIF wall-clock time into UTC as if it were this PC's local time; back to local gives
                // the camera's clock again.
                if (meta.Date == null && Get(store, DateTaken) is { } t && t.Type == VT_FILETIME) meta.Date = FromFileTime(t.Long);
            }
            if (meta.Latitude == null && Degrees(store, Latitude) is { } latitude && Degrees(store, Longitude) is { } longitude
                && (latitude != 0 || longitude != 0) && latitude <= 90 && longitude <= 180)
            {
                meta.Latitude = Text(store, LatitudeRef)?.StartsWith('S') == true ? -latitude : latitude;
                meta.Longitude = Text(store, LongitudeRef)?.StartsWith('W') == true ? -longitude : longitude;
            }
        }
        catch (Exception exception) when (exception is COMException or InvalidCastException or ArgumentException)
        {
        }
        finally
        {
            Marshal.ReleaseComObject(store);
        }
    }

    static DateTime? FromFileTime(long fileTime)
    {
        try
        {
            return fileTime <= 0 ? null : DateTime.FromFileTimeUtc(fileTime).ToLocalTime();
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    /// <summary>A copy of the simple value; strings and vectors are read by their own helpers before clearing.</summary>
    static PropVariant? Get(IPropertyStore store, PropertyKey key)
    {
        if (store.GetValue(ref key, out var value) != 0) return null;
        var copy = value;
        if ((value.Type & VT_VECTOR) != 0 || value.Type == VT_LPWSTR)
        {
            PropVariantClear(ref value);
            return null;
        }
        return copy.Type == 0 ? null : copy;
    }

    static string? Text(IPropertyStore store, PropertyKey key)
    {
        if (store.GetValue(ref key, out var value) != 0) return null;
        try
        {
            return value.Type == VT_LPWSTR ? Marshal.PtrToStringUni(value.Pointer) : null;
        }
        finally
        {
            PropVariantClear(ref value);
        }
    }

    static double? Degrees(IPropertyStore store, PropertyKey key)
    {
        if (store.GetValue(ref key, out var value) != 0) return null;
        try
        {
            if (value.Type != (VT_VECTOR | VT_R8) || value.VectorCount < 3) return null;
            double[] parts = new double[3];
            Marshal.Copy(value.VectorPointer, parts, 0, 3);
            return parts[0] + parts[1] / 60 + parts[2] / 3600;
        }
        finally
        {
            PropVariantClear(ref value);
        }
    }
}
