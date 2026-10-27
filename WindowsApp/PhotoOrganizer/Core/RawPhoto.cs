using System.Buffers.Binary;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace PhotoOrganizer.Core;

/// <summary>
/// Turns a RAW photo into a JPEG of a given size with an HDR gain map (see Compression.UltraHdr). The picture is the one
/// the camera rendered itself — the full-size preview a DNG carries (iPhone ProRAW has one, with Apple's HDR gain map
/// and colour profile), or what Windows' RAW codec makes of other files. The HDR is the camera's own gain map when the
/// preview has one; otherwise, for a linear DNG, it is worked out from the RAW data. The capture date, the place and the
/// camera go along in Exif.
/// </summary>
public static class RawPhoto
{
    public sealed record Result(int Width, int Height, bool Hdr, long Size);

    /// <summary>Writes the compressed photo to `destination`; throws when the file cannot be read.</summary>
    public static Result Compress(string source, string destination, int megapixels)
    {
        byte[] data = File.ReadAllBytes(source);
        var tiff = Tiff.TryRead(data);
        var preview = tiff?.LargestPreview();
        var raw = tiff?.RawImage;
        // The camera's own picture whenever it is large enough for the size asked (a full-size one in older ProRAW, a
        // 12 MP one since iOS 18); the RAW codec's only when a larger photo is wanted.
        byte[]? previewJpeg = preview is { } p
                              && (raw == null || (long)p.Width * p.Height >= Math.Min((long)raw.Width * raw.Height * 0.8, megapixels * 1e6 * 0.97))
            ? data.AsSpan(p.Offset, p.Length).ToArray()
            : null;
        BitmapSource picture = previewJpeg != null ? DecodeJpeg(previewJpeg, megapixels) : DecodeRaw(data, megapixels);
        // Windows' codec gives no more than the preview (it shows the preview of a ProRAW since iOS 18): the camera's
        // own picture and HDR, then.
        if (previewJpeg == null && preview is { } small && (long)picture.PixelWidth * picture.PixelHeight <= (long)small.Width * small.Height)
        {
            previewJpeg = data.AsSpan(small.Offset, small.Length).ToArray();
            picture = DecodeJpeg(previewJpeg, megapixels);
        }
        int width = picture.PixelWidth, height = picture.PixelHeight;

        var encoder = new JpegBitmapEncoder { QualityLevel = Compression.JpegQuality };
        encoder.Frames.Add(BitmapFrame.Create(new FormatConvertedBitmap(picture, PixelFormats.Bgr24, null, 0)));
        byte[] primary = Encode(encoder);
        var segments = new List<byte[]>();
        if (tiff != null && ExifSegment(tiff, width, height) is { } exif) segments.Add(exif);
        // The colours are the preview's (Display P3 on an iPhone): its profile goes along.
        if (previewJpeg != null) segments.AddRange(Compression.SegmentsNamed(previewJpeg, 0xE2, "ICC_PROFILE\0"));

        (byte[] Jpeg, GainMapInfo Info, List<byte[]>? Segments)? gainMap = null;
        try
        {
            if (previewJpeg != null && tiff != null) gainMap = CameraGainMap(previewJpeg, tiff, width, height);
            if (gainMap == null && tiff != null) gainMap = ComputedGainMap(tiff, picture);
        }
        catch (Exception e) when (e is InvalidDataException or IndexOutOfRangeException or ArgumentException or NotSupportedException or FileFormatException)
        {
            // A gain map or RAW data this reader does not know: the photo is kept without HDR.
        }
        byte[] result = gainMap is { } map
            ? Compression.UltraHdr(primary, map.Jpeg, map.Info, segments, map.Segments)
            : Compression.WithSegments(primary, segments);
        File.WriteAllBytes(destination, result);
        return new Result(width, height, gainMap != null, result.Length);
    }

    static byte[] Encode(BitmapEncoder encoder)
    {
        using var stream = new MemoryStream();
        encoder.Save(stream);
        return stream.ToArray();
    }

    /// <summary>A JPEG decoded at the size asked for, as stored (not turned: the Orientation tag goes along), its colours as they are.</summary>
    static BitmapSource DecodeJpeg(byte[] jpeg, int megapixels, int? width = null)
    {
        var image = new BitmapImage();
        image.BeginInit();
        image.StreamSource = new MemoryStream(jpeg);
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
        if (width is { } w) image.DecodePixelWidth = w;
        else
        {
            var frame = BitmapFrame.Create(new MemoryStream(jpeg), BitmapCreateOptions.DelayCreation | BitmapCreateOptions.IgnoreColorProfile, BitmapCacheOption.None);
            image.DecodePixelWidth = Compression.PhotoSize(frame.PixelWidth, frame.PixelHeight, megapixels).Width;
        }
        image.EndInit();
        image.Freeze();
        return image;
    }

    /// <summary>What Windows' RAW codec makes of a file without a full-size preview, at the size asked for.</summary>
    static BitmapSource DecodeRaw(byte[] data, int megapixels)
    {
        var decoder = BitmapDecoder.Create(new MemoryStream(data), BitmapCreateOptions.IgnoreColorProfile, BitmapCacheOption.OnLoad);
        BitmapSource frame = decoder.Frames[0];
        var (w, h) = Compression.PhotoSize(frame.PixelWidth, frame.PixelHeight, megapixels);
        if (w == frame.PixelWidth) return frame;
        var scaled = new TransformedBitmap(frame, new ScaleTransform((double)w / frame.PixelWidth, (double)h / frame.PixelHeight));
        scaled.Freeze();
        return scaled;
    }

    /// <summary>
    /// The gain map the camera put in its preview, brought to the new size: as it is when it already says how to apply
    /// it (ISO 21496-1, iOS 18 and later), turned into one that does when it is Apple's own (the headroom in the maker
    /// note, or in the map's XMP). Null when the preview has none.
    /// </summary>
    static (byte[], GainMapInfo, List<byte[]>?)? CameraGainMap(byte[] preview, Tiff tiff, int width, int height)
    {
        if (Compression.SecondPicture(preview) is not { } second) return null;
        byte[] map = preview.AsSpan(second.Offset, second.Length).ToArray();
        string head = Encoding.ASCII.GetString(map, 0, Math.Min(map.Length, 4096));
        bool apple = head.Contains("urn:com:apple:photo:2020:aux:hdrgainmap", StringComparison.Ordinal);
        var iso = Compression.ReadIsoGainMapMetadata(map);
        if (!apple && iso == null) return null;   // a depth map or some other picture

        var frame = BitmapFrame.Create(new MemoryStream(map), BitmapCreateOptions.DelayCreation | BitmapCreateOptions.IgnoreColorProfile, BitmapCacheOption.None);
        // The map keeps its proportion to the picture (Apple's is half of it across and down).
        int previewWidth = BitmapFrame.Create(new MemoryStream(preview), BitmapCreateOptions.DelayCreation, BitmapCacheOption.None).PixelWidth;
        int mapWidth = Math.Max(1, (int)Math.Round((double)frame.PixelWidth * width / Math.Max(1, previewWidth)));
        var decoded = new FormatConvertedBitmap(DecodeJpeg(map, 0, mapWidth), PixelFormats.Gray8, null, 0);
        int w = decoded.PixelWidth, h = decoded.PixelHeight;
        var pixels = new byte[w * h];
        decoded.CopyPixels(pixels, w, 0);

        GainMapInfo info;
        List<byte[]>? extra = null;
        if (iso != null)
        {
            info = iso;
            // Applied in the HDR picture's colours: the map's profile says which.
            if (!iso.UseBaseColorSpace) extra = Compression.SegmentsNamed(map, 0xE2, "ICC_PROFILE\0");
        }
        else
        {
            double headroom = XmpNumber(head, "HDRGainMap:HDRGainMapHeadroom") ?? MakerNoteHeadroom(tiff) ?? 0;
            if (headroom <= 1.01) return null;
            var (table, appleInfo) = Compression.FromAppleGainMap(headroom);
            for (int i = 0; i < pixels.Length; i++) pixels[i] = table[pixels[i]];
            info = appleInfo;
        }
        var encoder = new JpegBitmapEncoder { QualityLevel = Compression.JpegQuality };
        encoder.Frames.Add(BitmapFrame.Create(BitmapSource.Create(w, h, 96, 96, PixelFormats.Gray8, null, pixels, w)));
        return (Encode(encoder), info, extra);
    }

    static double? XmpNumber(string xmp, string name)
    {
        var match = Regex.Match(xmp, Regex.Escape(name) + @"(?:>|="")\s*([0-9.]+)");
        return match.Success && double.TryParse(match.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out double v) ? v : null;
    }

    /// <summary>The headroom Apple's maker note gives (tags 33 and 48); null when there is no Apple maker note.</summary>
    static double? MakerNoteHeadroom(Tiff tiff)
    {
        if (tiff.Exif is not { } exif || !exif.Entries.TryGetValue(37500, out var note) || note.Count < 16) return null;
        int at = note.ValueAt;
        var data = tiff.Data;
        if (Encoding.ASCII.GetString(data, at, 9) != "Apple iOS") return null;
        // "Apple iOS\0", a version, "MM", then a directory whose offsets count from the start of the note.
        int count = BinaryPrimitives.ReadUInt16BigEndian(data.AsSpan(at + 14));
        double? tag33 = null, tag48 = null;
        for (int i = 0; i < count && at + 16 + i * 12 + 12 <= data.Length; i++)
        {
            var entry = data.AsSpan(at + 16 + i * 12);
            int tag = BinaryPrimitives.ReadUInt16BigEndian(entry), type = BinaryPrimitives.ReadUInt16BigEndian(entry[2..]);
            if (tag is not (33 or 48) || type is not (5 or 10)) continue;
            int value = at + (int)BinaryPrimitives.ReadUInt32BigEndian(entry[8..]);
            if (value < 0 || value + 8 > data.Length) continue;
            long n = type == 10 ? BinaryPrimitives.ReadInt32BigEndian(data.AsSpan(value)) : BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(value));
            long d = type == 10 ? BinaryPrimitives.ReadInt32BigEndian(data.AsSpan(value + 4)) : BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(value + 4));
            if (d == 0) continue;
            if (tag == 33) tag33 = (double)n / d; else tag48 = (double)n / d;
        }
        return tag33 is { } a && tag48 is { } b ? Compression.AppleHeadroom(a, b) : null;
    }

    /// <summary>A gain map worked out from the RAW data, for a linear DNG whose preview has none; null for other files.</summary>
    static (byte[], GainMapInfo, List<byte[]>?)? ComputedGainMap(Tiff tiff, BitmapSource picture)
    {
        int width = picture.PixelWidth, height = picture.PixelHeight;
        int mapWidth = Math.Max(1, width / Compression.GainMapScale), mapHeight = Math.Max(1, height / Compression.GainMapScale);
        if (LinearLight(tiff, mapWidth, mapHeight) is not { } hdr) return null;
        var bgra = new byte[width * height * 4];
        new FormatConvertedBitmap(picture, PixelFormats.Bgra32, null, 0).CopyPixels(bgra, width * 4, 0);
        if (Compression.GainMap(SdrLight(bgra, width, height, mapWidth, mapHeight), hdr) is not { } map) return null;
        var encoder = new JpegBitmapEncoder { QualityLevel = Compression.JpegQuality };
        encoder.Frames.Add(BitmapFrame.Create(BitmapSource.Create(mapWidth, mapHeight, 96, 96, PixelFormats.Gray8, null, map.Map, mapWidth)));
        return (Encode(encoder), map.Info, null);
    }

    /// <summary>The linear light of the SDR picture, averaged over the cells of the gain map.</summary>
    static float[] SdrLight(byte[] bgra, int width, int height, int mapWidth, int mapHeight)
    {
        var linear = new float[256];
        for (int i = 0; i < 256; i++) linear[i] = Compression.SrgbToLinear(i);
        var sum = new double[mapWidth * mapHeight];
        var count = new int[mapWidth * mapHeight];
        for (int y = 0; y < height; y++)
        {
            int row = Math.Min(mapHeight - 1, y * mapHeight / height) * mapWidth;
            for (int x = 0; x < width; x++)
            {
                int at = (y * width + x) * 4;
                int cell = row + Math.Min(mapWidth - 1, x * mapWidth / width);
                sum[cell] += 0.0722 * linear[bgra[at]] + 0.7152 * linear[bgra[at + 1]] + 0.2126 * linear[bgra[at + 2]];
                count[cell]++;
            }
        }
        var light = new float[sum.Length];
        for (int i = 0; i < light.Length; i++) light[i] = (float)(sum[i] / Math.Max(1, count[i]));
        return light;
    }

    /// <summary>
    /// The light the RAW data records, white-balanced, averaged over the cells of the gain map; null when the RAW data
    /// is not linear RGB (a Bayer mosaic is left to the SDR picture alone).
    /// </summary>
    static float[]? LinearLight(Tiff tiff, int mapWidth, int mapHeight)
    {
        var raw = tiff.RawImage;
        if (raw == null || raw.Photometric != 34892 || raw.SamplesPerPixel != 3 || raw.Compression is not (1 or 7)) return null;
        var ifd = raw.Ifd;
        int width = raw.Width, height = raw.Height;
        ushort[]? table = tiff.Ints(ifd, 50712) is { Length: > 1 } lin ? lin.Select(v => (ushort)Math.Clamp(v, 0, 65535)).ToArray() : null;
        double[] black = tiff.Reals(ifd, 50714) is { Length: > 0 } b ? b : [0];
        double[] white = tiff.Reals(ifd, 50717) is { Length: > 0 } w ? w : [(1 << raw.Bits) - 1];
        double[] neutral = tiff.Reals(tiff.First, 50728) is { Length: 3 } n && n.All(v => v > 0) ? n : [1, 1, 1];
        var scale = new double[3];
        var offset = new double[3];
        for (int c = 0; c < 3; c++)
        {
            double blackLevel = black[Math.Min(c, black.Length - 1)], whiteLevel = white[Math.Min(c, white.Length - 1)];
            scale[c] = 1 / Math.Max(1, whiteLevel - blackLevel) / neutral[c];
            offset[c] = blackLevel;
        }
        // Luminance weights of camera RGB once white-balanced: close enough, the exposure is matched afterwards.
        double[] weight = [0.2126, 0.7152, 0.0722];

        var sum = new double[mapWidth * mapHeight];
        var count = new int[mapWidth * mapHeight];
        var tiles = raw.Tiles();
        Parallel.For(0, tiles.Count, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, Environment.ProcessorCount / 2) }, index =>
        {
            var tile = tiles[index];
            ushort[] samples = raw.Compression == 7
                ? LosslessJpeg.Decode(tiff.Data, tile.Offset, tile.Length, tile.Width * 3, tile.Height)
                : Uncompressed(tiff, tile, raw.Bits);
            // The cells of the map this tile covers, summed here and added to the whole once.
            int CellX(int x) => Math.Min(mapWidth - 1, (int)((long)x * mapWidth / width));
            int CellY(int y) => Math.Min(mapHeight - 1, (int)((long)y * mapHeight / height));
            int right = Math.Min(width, tile.X + tile.Width), bottom = Math.Min(height, tile.Y + tile.Height);
            if (right <= tile.X || bottom <= tile.Y) return;
            int left = CellX(tile.X), top = CellY(tile.Y), across = CellX(right - 1) - left + 1, down = CellY(bottom - 1) - top + 1;
            var localSum = new double[across * down];
            var localCount = new int[across * down];
            for (int imageY = tile.Y; imageY < bottom; imageY++)
            {
                int row = (CellY(imageY) - top) * across;
                int at = (imageY - tile.Y) * tile.Width * 3;
                for (int imageX = tile.X; imageX < right; imageX++, at += 3)
                {
                    double light = 0;
                    for (int c = 0; c < 3; c++)
                    {
                        int value = samples[at + c];
                        if (table != null) value = table[Math.Min(value, table.Length - 1)];
                        light += weight[c] * Math.Max(0, value - offset[c]) * scale[c];
                    }
                    int cell = row + CellX(imageX) - left;
                    localSum[cell] += light;
                    localCount[cell]++;
                }
            }
            lock (sum)
            {
                for (int y = 0; y < down; y++)
                {
                    for (int x = 0; x < across; x++)
                    {
                        sum[(top + y) * mapWidth + left + x] += localSum[y * across + x];
                        count[(top + y) * mapWidth + left + x] += localCount[y * across + x];
                    }
                }
            }
        });
        var result = new float[sum.Length];
        for (int i = 0; i < result.Length; i++) result[i] = (float)(sum[i] / Math.Max(1, count[i]));
        return result;
    }

    static ushort[] Uncompressed(Tiff tiff, Tiff.Tile tile, int bits)
    {
        var samples = new ushort[tile.Width * tile.Height * 3];
        if (bits != 16) throw new InvalidDataException($"{bits}-bit uncompressed RAW");
        for (int i = 0; i < samples.Length && tile.Offset + i * 2 + 1 < tiff.Data.Length; i++) samples[i] = tiff.U16(tile.Offset + i * 2);
        return samples;
    }

    // --- Exif -----------------------------------------------------------------------------------------------------

    static readonly HashSet<ushort> FirstIfdTags = [270, 271, 272, 274, 305, 306, 315, 33432];
    /// <summary>Pointers to other parts of the RAW file, which mean nothing in the JPEG.</summary>
    static readonly HashSet<ushort> Pointers = [34665, 34853, 40965, 330];

    /// <summary>
    /// The Exif APP1 segment for the JPEG: from the RAW's first directory the camera, the time and the orientation;
    /// the whole Exif directory (the capture date, the exposure, Apple's maker note) and the GPS one, as they are, in
    /// the RAW's own byte order. The size is the JPEG's.
    /// </summary>
    public static byte[]? ExifSegment(Tiff tiff, int width, int height)
    {
        var first = tiff.First;
        var exif = tiff.Exif;
        if (exif == null) return null;
        bool apple = tiff.Text(first, 271)?.StartsWith("Apple", StringComparison.Ordinal) == true;
        var firstEntries = first.Entries.Values.Where(e => FirstIfdTags.Contains(e.Tag)).ToList();
        // A maker note can point anywhere in the RAW; Apple's counts from its own start, so it can go along.
        var exifEntries = exif.Entries.Values.Where(e => !Pointers.Contains(e.Tag) && (e.Tag != 37500 || apple) && e.Tag is not (40962 or 40963)).ToList();
        var gpsEntries = tiff.Gps?.Entries.Values.ToList();

        for (int attempt = 0; attempt < 2; attempt++)
        {
            var writer = new TiffWriter(tiff.Little);
            var extraExif = new List<TiffWriter.Field> { TiffWriter.Long(40962, (uint)width), TiffWriter.Long(40963, (uint)height) };
            byte[] bytes = writer.Write(
                firstEntries.Select(e => tiff.Field(e)).ToList(),
                exifEntries.Select(e => tiff.Field(e)).Concat(extraExif).ToList(),
                gpsEntries?.Select(e => tiff.Field(e)).ToList());
            byte[] contents = [.. "Exif\0\0"u8, .. bytes];
            if (contents.Length + 2 <= 0xFFFF) return Compression.Segment(0xE1, contents);
            exifEntries.RemoveAll(e => e.Tag == 37500);   // too long with the maker note
        }
        return null;
    }
}

/// <summary>A TIFF-based file read for its directories: DNG and most camera RAW formats.</summary>
public sealed class Tiff
{
    public sealed class Entry
    {
        public ushort Tag, Type;
        public uint Count;
        /// <summary>Where the value is in the file.</summary>
        public int ValueAt;
    }

    public sealed class Ifd
    {
        public readonly Dictionary<ushort, Entry> Entries = [];
        public readonly List<Ifd> Children = [];
    }

    public sealed record Preview(int Width, int Height, int Offset, int Length);
    public sealed record Tile(int X, int Y, int Width, int Height, int Offset, int Length);

    public sealed class Image(Tiff tiff, Ifd ifd)
    {
        public Ifd Ifd { get; } = ifd;
        public int Width => (int)tiff.Int(Ifd, 256);
        public int Height => (int)tiff.Int(Ifd, 257);
        public int Compression => (int)tiff.Int(Ifd, 259, 1);
        public int Photometric => (int)tiff.Int(Ifd, 262);
        public int SamplesPerPixel => (int)tiff.Int(Ifd, 277, 1);
        public int Bits => (int)tiff.Int(Ifd, 258, 8);

        /// <summary>The tiles (or strips, as tiles the width of the picture) and where their data is.</summary>
        public List<Tile> Tiles()
        {
            var tiles = new List<Tile>();
            if (tiff.Ints(Ifd, 324) is { } offsets && tiff.Ints(Ifd, 325) is { } lengths)
            {
                int tileWidth = (int)tiff.Int(Ifd, 322), tileHeight = (int)tiff.Int(Ifd, 323);
                int across = (Width + tileWidth - 1) / tileWidth;
                for (int i = 0; i < offsets.Length && i < lengths.Length; i++)
                {
                    tiles.Add(new Tile(i % across * tileWidth, i / across * tileHeight, tileWidth, tileHeight, (int)offsets[i], (int)lengths[i]));
                }
            }
            else if (tiff.Ints(Ifd, 273) is { } strips && tiff.Ints(Ifd, 279) is { } stripLengths)
            {
                int rows = (int)tiff.Int(Ifd, 278, Height);
                for (int i = 0; i < strips.Length && i < stripLengths.Length; i++)
                {
                    tiles.Add(new Tile(0, i * rows, Width, Math.Min(rows, Height - i * rows), (int)strips[i], (int)stripLengths[i]));
                }
            }
            return tiles;
        }
    }

    public readonly byte[] Data;
    public readonly bool Little;
    public Ifd First { get; private set; } = new();
    public Ifd? Exif { get; private set; }
    public Ifd? Gps { get; private set; }
    readonly List<Ifd> _all = [];

    Tiff(byte[] data, bool little)
    {
        Data = data;
        Little = little;
    }

    public static Tiff? TryRead(byte[] data)
    {
        try
        {
            if (data.Length < 8) return null;
            bool little = data[0] == 'I' && data[1] == 'I';
            if (!little && !(data[0] == 'M' && data[1] == 'M')) return null;
            var tiff = new Tiff(data, little);
            if (tiff.U16(2) != 42) return null;
            uint at = tiff.U32(4);
            var seen = new HashSet<uint>();
            bool first = true;
            while (at != 0 && at < data.Length && seen.Add(at) && seen.Count < 8)
            {
                var ifd = tiff.ReadIfd((int)at, out at, 0);
                if (first) tiff.First = ifd;
                first = false;
            }
            if (tiff.First.Entries.ContainsKey(34665)) tiff.Exif = tiff.ReadIfd((int)tiff.Int(tiff.First, 34665), out _, 0, track: false);
            if (tiff.First.Entries.ContainsKey(34853)) tiff.Gps = tiff.ReadIfd((int)tiff.Int(tiff.First, 34853), out _, 0, track: false);
            return tiff;
        }
        catch (Exception e) when (e is IndexOutOfRangeException or ArgumentOutOfRangeException or InvalidDataException)
        {
            return null;
        }
    }

    Ifd ReadIfd(int at, out uint next, int depth, bool track = true)
    {
        var ifd = new Ifd();
        int count = U16(at);
        if (count > 1000) throw new InvalidDataException("not a directory");
        for (int i = 0; i < count; i++)
        {
            int entryAt = at + 2 + i * 12;
            var entry = new Entry { Tag = U16(entryAt), Type = U16(entryAt + 2), Count = U32(entryAt + 4) };
            long size = (long)TypeSize(entry.Type) * entry.Count;
            entry.ValueAt = size <= 4 ? entryAt + 8 : (int)U32(entryAt + 8);
            if (entry.ValueAt < 0 || entry.ValueAt + size > Data.Length) continue;
            ifd.Entries[entry.Tag] = entry;
        }
        next = U32(at + 2 + count * 12);
        if (track) _all.Add(ifd);
        if (depth < 3 && Ints(ifd, 330) is { } children)
        {
            foreach (long child in children)
            {
                if (child > 0 && child < Data.Length) ifd.Children.Add(ReadIfd((int)child, out _, depth + 1));
            }
        }
        return ifd;
    }

    public static int TypeSize(int type) => type switch
    {
        1 or 2 or 6 or 7 => 1,
        3 or 8 => 2,
        4 or 9 or 11 or 13 => 4,
        5 or 10 or 12 => 8,
        _ => 1,
    };

    public ushort U16(int at) => Little ? BinaryPrimitives.ReadUInt16LittleEndian(Data.AsSpan(at)) : BinaryPrimitives.ReadUInt16BigEndian(Data.AsSpan(at));
    public uint U32(int at) => Little ? BinaryPrimitives.ReadUInt32LittleEndian(Data.AsSpan(at)) : BinaryPrimitives.ReadUInt32BigEndian(Data.AsSpan(at));

    public long[]? Ints(Ifd ifd, ushort tag)
    {
        if (!ifd.Entries.TryGetValue(tag, out var e)) return null;
        var values = new long[e.Count];
        for (int i = 0; i < e.Count; i++)
        {
            values[i] = e.Type switch
            {
                1 or 7 => Data[e.ValueAt + i],
                6 => (sbyte)Data[e.ValueAt + i],
                3 => U16(e.ValueAt + i * 2),
                8 => (short)U16(e.ValueAt + i * 2),
                4 or 13 => U32(e.ValueAt + i * 4),
                9 => (int)U32(e.ValueAt + i * 4),
                _ => 0,
            };
        }
        return values;
    }

    public long Int(Ifd ifd, ushort tag, long fallback = 0) => Ints(ifd, tag) is { Length: > 0 } values ? values[0] : fallback;

    public double[]? Reals(Ifd ifd, ushort tag)
    {
        if (!ifd.Entries.TryGetValue(tag, out var e)) return null;
        if (e.Type is not (5 or 10 or 11 or 12)) return Ints(ifd, tag)?.Select(v => (double)v).ToArray();
        var values = new double[e.Count];
        for (int i = 0; i < e.Count; i++)
        {
            int at = e.ValueAt + i * TypeSize(e.Type);
            values[i] = e.Type switch
            {
                5 => U32(at + 4) == 0 ? 0 : (double)U32(at) / U32(at + 4),
                10 => U32(at + 4) == 0 ? 0 : (double)(int)U32(at) / (int)U32(at + 4),
                11 => BitConverter.Int32BitsToSingle((int)U32(at)),
                _ => BitConverter.Int64BitsToDouble(((long)U32(Little ? at + 4 : at) << 32) | U32(Little ? at : at + 4)),
            };
        }
        return values;
    }

    public string? Text(Ifd ifd, ushort tag) =>
        ifd.Entries.TryGetValue(tag, out var e) && e.Type == 2 ? System.Text.Encoding.ASCII.GetString(Data, e.ValueAt, (int)e.Count).TrimEnd('\0') : null;

    /// <summary>An entry as it is in the file, to write elsewhere in the same byte order.</summary>
    public TiffWriter.Field Field(Entry e) => new(e.Tag, e.Type, e.Count, Data.AsSpan(e.ValueAt, (int)(TypeSize(e.Type) * e.Count)).ToArray());

    /// <summary>The full-resolution picture data: the directory not marked as a reduced or extra image.</summary>
    public Image? RawImage
    {
        get
        {
            var candidates = _all.Where(i => Int(i, 254, 0) == 0 && Int(i, 256) > 0 && Int(i, 262) is 32803 or 34892).ToList();
            var best = candidates.OrderByDescending(i => Int(i, 256) * Int(i, 257)).FirstOrDefault();
            return best == null ? null : new Image(this, best);
        }
    }

    /// <summary>The largest JPEG preview in the file (old-style JPEG or a JPEG strip), with where its bytes are.</summary>
    public Preview? LargestPreview()
    {
        Preview? best = null;
        foreach (var ifd in _all)
        {
            int compression = (int)Int(ifd, 259, 1);
            int width = (int)Int(ifd, 256), height = (int)Int(ifd, 257);
            int offset = 0, length = 0;
            if (compression == 7 && Int(ifd, 262) == 6 && Ints(ifd, 273) is { Length: 1 } strip && Ints(ifd, 279) is { Length: 1 } stripLength)
            {
                (offset, length) = ((int)strip[0], (int)stripLength[0]);
            }
            else if (Int(ifd, 513) > 0 && Int(ifd, 514) > 0)
            {
                (offset, length) = ((int)Int(ifd, 513), (int)Int(ifd, 514));
            }
            if (length <= 0 || offset + length > Data.Length || Data[offset] != 0xFF || Data[offset + 1] != 0xD8) continue;
            if (width <= 0 || height <= 0) (width, height) = JpegSize(offset, length);
            if (width <= 0) continue;
            if (best == null || (long)width * height > (long)best.Width * best.Height) best = new Preview(width, height, offset, length);
        }
        return best;
    }

    /// <summary>The size in a JPEG's frame header.</summary>
    (int Width, int Height) JpegSize(int offset, int length)
    {
        int at = offset + 2, end = offset + length;
        while (at + 9 < end && Data[at] == 0xFF)
        {
            byte marker = Data[at + 1];
            int segment = (Data[at + 2] << 8) | Data[at + 3];
            if (marker is >= 0xC0 and <= 0xCF and not 0xC4 and not 0xC8 and not 0xCC)
                return ((Data[at + 7] << 8) | Data[at + 8], (Data[at + 5] << 8) | Data[at + 6]);
            at += 2 + segment;
        }
        return (0, 0);
    }
}

/// <summary>Writes a small TIFF: a first directory, its Exif directory and its GPS one, for an Exif segment.</summary>
public sealed class TiffWriter(bool little)
{
    public sealed record Field(ushort Tag, ushort Type, uint Count, byte[] Value);

    public static Field Long(ushort tag, uint value)
    {
        var bytes = new byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(bytes, value);
        return new Field(tag, 4, 1, bytes);
    }

    readonly MemoryStream _out = new();

    public byte[] Write(List<Field> first, List<Field> exif, List<Field>? gps)
    {
        // Values written little-endian here (Long) are turned to the file's order.
        exif = exif.Select(Ordered).ToList();
        first = first.Select(Ordered).ToList();
        _out.Write(little ? "II*\0"u8 : "MM\0*"u8);
        WriteU32(8);
        var firstAll = first.Where(f => f.Tag is not (34665 or 34853)).ToList();
        firstAll.Add(new Field(34665, 4, 1, new byte[4]));
        if (gps != null) firstAll.Add(new Field(34853, 4, 1, new byte[4]));
        int exifPointer = WriteIfd(firstAll, 34665);
        int gpsPointer = gps != null ? FieldAt(34853) : -1;
        int exifAt = (int)_out.Length;
        Patch(exifPointer, (uint)exifAt);
        WriteIfd(exif, 0);
        if (gps != null)
        {
            Patch(gpsPointer, (uint)_out.Length);
            WriteIfd(gps, 0);
        }
        return _out.ToArray();
    }

    readonly Dictionary<ushort, int> _fieldAt = [];
    int FieldAt(ushort tag) => _fieldAt[tag];

    Field Ordered(Field f)
    {
        // Only fields made here (Long) are little-endian whatever the order; copied ones are in the file's own.
        if (f.Tag is 40962 or 40963 && f.Type == 4 && !little)
        {
            uint value = BinaryPrimitives.ReadUInt32LittleEndian(f.Value);
            var bytes = new byte[4];
            BinaryPrimitives.WriteUInt32BigEndian(bytes, value);
            return f with { Value = bytes };
        }
        return f;
    }

    /// <summary>Writes a directory and its values; returns where the value of `pointerTag` is, to fill in later.</summary>
    int WriteIfd(List<Field> fields, ushort pointerTag)
    {
        fields = fields.OrderBy(f => f.Tag).ToList();
        int start = (int)_out.Length;
        int dataAt = start + 2 + fields.Count * 12 + 4;
        if (dataAt % 2 == 1) dataAt++;
        var data = new MemoryStream();
        int pointer = -1;
        WriteU16((ushort)fields.Count);
        foreach (var field in fields)
        {
            WriteU16(field.Tag);
            WriteU16(field.Type);
            WriteU32(field.Count);
            _fieldAt[field.Tag] = (int)_out.Length;
            if (field.Tag == pointerTag) pointer = (int)_out.Length;
            if (field.Value.Length <= 4)
            {
                _out.Write(field.Value);
                for (int i = field.Value.Length; i < 4; i++) _out.WriteByte(0);
            }
            else
            {
                WriteU32((uint)(dataAt + data.Length));
                data.Write(field.Value);
                if (data.Length % 2 == 1) data.WriteByte(0);
            }
        }
        WriteU32(0);
        while (_out.Length < dataAt) _out.WriteByte(0);
        data.Position = 0;
        data.CopyTo(_out);
        return pointer;
    }

    void Patch(int at, uint value)
    {
        long end = _out.Length;
        _out.Position = at;
        WriteU32(value);
        _out.Position = end;
    }

    void WriteU16(ushort v)
    {
        Span<byte> b = stackalloc byte[2];
        if (little) BinaryPrimitives.WriteUInt16LittleEndian(b, v); else BinaryPrimitives.WriteUInt16BigEndian(b, v);
        _out.Write(b);
    }

    void WriteU32(uint v)
    {
        Span<byte> b = stackalloc byte[4];
        if (little) BinaryPrimitives.WriteUInt32LittleEndian(b, v); else BinaryPrimitives.WriteUInt32BigEndian(b, v);
        _out.Write(b);
    }
}

/// <summary>Lossless JPEG (ITU T.81 process 14), what DNG compresses RAW data with.</summary>
public static class LosslessJpeg
{
    /// <summary>The samples of one tile, row after row, `samplesPerRow` to a row (every component of every pixel).</summary>
    public static ushort[] Decode(byte[] data, int offset, int length, int samplesPerRow, int rows)
    {
        var output = new ushort[samplesPerRow * rows];
        int at = offset + 2, end = offset + length;
        var tables = new (byte[] Lengths, byte[] Symbols)?[4];
        int precision = 0, frameWidth = 0, frameHeight = 0, components = 0, predictor = 1, transform = 0, restart = 0;
        var componentTable = new int[4];
        while (at + 4 <= end)
        {
            if (data[at] != 0xFF) { at++; continue; }
            byte marker = data[at + 1];
            if (marker == 0xFF) { at++; continue; }
            int size = (data[at + 2] << 8) | data[at + 3];
            int body = at + 4;
            switch (marker)
            {
                case 0xC3:
                    precision = data[body];
                    frameHeight = (data[body + 1] << 8) | data[body + 2];
                    frameWidth = (data[body + 3] << 8) | data[body + 4];
                    components = data[body + 5];
                    break;
                case 0xC4:
                    for (int p = body; p < at + 2 + size;)
                    {
                        int id = data[p] & 3;
                        var lengths = data.AsSpan(p + 1, 16).ToArray();
                        int total = lengths.Sum(l => l);
                        tables[id] = (lengths, data.AsSpan(p + 17, total).ToArray());
                        p += 17 + total;
                    }
                    break;
                case 0xDD:
                    restart = (data[body] << 8) | data[body + 1];
                    break;
                case 0xDA:
                    int count = data[body];
                    for (int c = 0; c < count && c < 4; c++) componentTable[c] = data[body + 2 + c * 2] >> 4;
                    predictor = data[body + 1 + count * 2];
                    transform = data[body + 3 + count * 2] & 15;
                    DecodeScan(data, at + 2 + size, end, output, samplesPerRow, rows, precision, frameWidth, frameHeight, components,
                               predictor, transform, restart, componentTable, tables);
                    return output;
            }
            at += 2 + size;
        }
        throw new InvalidDataException("no lossless JPEG scan");
    }

    sealed class Huffman
    {
        // Indexed by the next 16 bits: the code's length (high byte) and its symbol (low byte).
        public readonly ushort[] Lookup = new ushort[65536];

        public Huffman(byte[] lengths, byte[] symbols)
        {
            int code = 0, k = 0;
            for (int length = 1; length <= 16; length++)
            {
                for (int i = 0; i < lengths[length - 1]; i++)
                {
                    int first = code << (16 - length), span = 1 << (16 - length);
                    for (int j = 0; j < span; j++) Lookup[first + j] = (ushort)((length << 8) | symbols[k]);
                    k++;
                    code++;
                }
                code <<= 1;
            }
        }
    }

    ref struct Bits(byte[] data, int at, int end)
    {
        ulong _buffer;
        int _count;
        int _at = at;

        void Fill()
        {
            while (_count <= 56)
            {
                int b = 0;
                if (_at < end)
                {
                    b = data[_at];
                    if (b != 0xFF) _at++;
                    else if (_at + 1 < end && data[_at + 1] == 0x00) _at += 2;   // a stuffed 0xFF
                    else b = 0;   // a marker: zeros from here on (a restart is skipped by Restart)
                }
                _buffer |= (ulong)b << (56 - _count);
                _count += 8;
            }
        }

        public int Peek16()
        {
            if (_count < 16) Fill();
            return (int)(_buffer >> 48);
        }

        public void Skip(int n)
        {
            _buffer <<= n;
            _count -= n;
        }

        public int Read(int n)
        {
            if (n == 0) return 0;
            if (_count < n) Fill();
            int value = (int)(_buffer >> (64 - n));
            Skip(n);
            return value;
        }

        /// <summary>Past the next restart marker, with the bits left over thrown away.</summary>
        public void Restart()
        {
            _buffer = 0;
            _count = 0;
            while (_at + 1 < end && !(data[_at] == 0xFF && data[_at + 1] is >= 0xD0 and <= 0xD7)) _at++;
            _at += 2;
        }
    }

    static void DecodeScan(byte[] data, int at, int end, ushort[] output, int samplesPerRow, int rows, int precision, int width, int height,
                           int components, int predictor, int transform, int restart, int[] componentTable, (byte[] Lengths, byte[] Symbols)?[] tables)
    {
        var huffman = new Huffman[components];
        for (int c = 0; c < components; c++)
        {
            var table = tables[componentTable[c]] ?? throw new InvalidDataException("no Huffman table");
            huffman[c] = new Huffman(table.Lengths, table.Symbols);
        }
        var bits = new Bits(data, at, end);
        int rowSamples = width * components;
        var previous = new int[rowSamples];
        var current = new int[rowSamples];
        int initial = 1 << (precision - transform - 1);
        int mask = (1 << precision) - 1;
        long written = 0, total = (long)samplesPerRow * rows;
        // Restart intervals of whole rows (what DNG writers use): each starts as the first row does.
        if (restart > 0 && restart % width != 0) throw new InvalidDataException("restart interval inside a row");
        int rowsPerInterval = restart / Math.Max(1, width);
        bool firstRow = true;
        for (int y = 0; y < height; y++)
        {
            if (rowsPerInterval > 0 && y > 0 && y % rowsPerInterval == 0)
            {
                bits.Restart();
                firstRow = true;
            }
            for (int x = 0; x < width; x++)
            {
                for (int c = 0; c < components; c++)
                {
                    int code = huffman[c].Lookup[bits.Peek16()];
                    int length = code >> 8;
                    if (length == 0) throw new InvalidDataException("bad Huffman code");
                    bits.Skip(length);
                    int ssss = code & 0xFF;
                    int diff;
                    if (ssss == 0) diff = 0;
                    else if (ssss == 16) diff = 32768;
                    else
                    {
                        diff = bits.Read(ssss);
                        if (diff < (1 << (ssss - 1))) diff -= (1 << ssss) - 1;
                    }
                    int i = x * components + c;
                    int prediction;
                    if (firstRow && x == 0) prediction = initial;
                    else if (firstRow) prediction = current[i - components];
                    else if (x == 0) prediction = previous[i];
                    else
                    {
                        int a = current[i - components], b = previous[i], cc = previous[i - components];
                        prediction = predictor switch
                        {
                            1 => a,
                            2 => b,
                            3 => cc,
                            4 => a + b - cc,
                            5 => a + ((b - cc) >> 1),
                            6 => b + ((a - cc) >> 1),
                            7 => (a + b) >> 1,
                            _ => a,
                        };
                    }
                    int value = (prediction + diff) & mask;
                    current[i] = value;
                    if (written < total) output[written++] = (ushort)(value << transform);
                }
            }
            (previous, current) = (current, previous);
            firstRow = false;
        }
    }
}
