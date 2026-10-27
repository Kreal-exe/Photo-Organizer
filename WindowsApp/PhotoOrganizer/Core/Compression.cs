using System.Buffers.Binary;
using System.Globalization;
using System.Text;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.Core;

/// <summary>
/// What "Сжать…" aims at, the same on both platforms: RAW photos become JPEGs of the size most photos of the library
/// have, with the RAW's highlights kept as an HDR gain map (Ultra HDR / ISO 21496-1); videos become HEVC no larger
/// than a chosen height, at a bitrate that loses nothing visible, HDR (HLG / PQ, 10 bits) kept.
/// </summary>
public static class Compression
{
    /// <summary>The JPEG quality of compressed photos (and of their gain map).</summary>
    public const int JpegQuality = 90;
    /// <summary>How much brighter than white the HDR rendition may go, in stops (8×).</summary>
    public const double MaxHdrStops = 3;
    /// <summary>The gain map is a quarter of the photo across and down, as Ultra HDR writes it.</summary>
    public const int GainMapScale = 4;

    /// <summary>The heights a video may be brought down to: 4K, 1080p, 720p (its shorter side, for a vertical one).</summary>
    public static readonly int[] VideoHeights = [2160, 1080, 720];
    public const int DefaultVideoHeight = 1080;
    /// <summary>"Максимальное", "Высокое", "Экономное": how many bits a video keeps relative to the default.</summary>
    public static readonly double[] VideoQualityFactors = [1.6, 1.0, 0.6];
    public const int DefaultVideoQuality = 1;

    public static bool IsRaw(PhotoItem item) =>
        !item.Video && MetadataReader.RawExtensions.Contains(Path.GetExtension(item.Name).TrimStart('.'));

    /// <summary>The photos made by a camera or a phone the way most of the library is: JPEG and HEIC, not pictures or screenshots.</summary>
    static bool IsOrdinaryPhoto(PhotoItem item)
    {
        if (item.Video || item.IsPicture || item.Tiny || item.PixelWidth <= 0 || item.PixelHeight <= 0 || item.FileSize <= 0) return false;
        string extension = Path.GetExtension(item.Name).TrimStart('.').ToLowerInvariant();
        return extension is "jpg" or "jpeg" or "heic" or "heif" && !MediaTypes.IsGooglePhotosCreation(item) && !Screenshots.IsScreenshot(item);
    }

    /// <summary>
    /// The size most photos of the library have (in megapixels, 12 for an iPhone) and how many bytes they take per
    /// megapixel — what a compressed RAW is made like and what its size is guessed from.
    /// </summary>
    public static (int Megapixels, long BytesPerMegapixel, int Count) TypicalPhoto(IEnumerable<PhotoItem> items)
    {
        var photos = items.Where(IsOrdinaryPhoto).ToList();
        var bySize = photos.GroupBy(i => (int)Math.Round(i.PixelWidth * (double)i.PixelHeight / 1e6))
                           .Where(g => g.Key >= 2)
                           .OrderByDescending(g => g.Count()).ThenByDescending(g => g.Key)
                           .FirstOrDefault();
        if (bySize == null) return (12, 300_000, 0);
        var perMegapixel = bySize.Select(i => i.FileSize / (i.PixelWidth * (double)i.PixelHeight / 1e6)).OrderBy(v => v).ToList();
        return (bySize.Key, (long)perMegapixel[perMegapixel.Count / 2], bySize.Count());
    }

    /// <summary>The size of a photo of `width`×`height` brought to `megapixels`, never larger; even numbers.</summary>
    public static (int Width, int Height) PhotoSize(int width, int height, int megapixels)
    {
        double pixels = (double)width * height, wanted = megapixels * 1e6;
        if (width <= 0 || height <= 0 || wanted >= pixels * 0.97) return (width, height);
        double scale = Math.Sqrt(wanted / pixels);
        // Half or a quarter when about that (48 MP to 12): the exact size phones make, and the sharpest scaling.
        foreach (double exact in new[] { 0.5, 0.25 })
        {
            if (Math.Abs(scale - exact) / exact < 0.05 && width % (int)(1 / exact) == 0 && height % (int)(1 / exact) == 0) scale = exact;
        }
        return (Math.Max(2, (int)Math.Round(width * scale / 2) * 2), Math.Max(2, (int)Math.Round(height * scale / 2) * 2));
    }

    /// <summary>The upright size of a video brought down so that its shorter side is at most `height`; even numbers.</summary>
    public static (int Width, int Height) VideoSize(int width, int height, int maxHeight)
    {
        int shorter = Math.Min(width, height);
        if (shorter <= maxHeight) return (width / 2 * 2, height / 2 * 2);
        double scale = (double)maxHeight / shorter;
        return (Math.Max(2, (int)Math.Round(width * scale / 2) * 2), Math.Max(2, (int)Math.Round(height * scale / 2) * 2));
    }

    /// <summary>
    /// Bits per second HEVC needs to lose nothing visible: 6 Mbit/s for 1080p at 30 frames a second, more for more
    /// pixels and frames, though not in proportion (larger frames and faster ones compress better).
    /// </summary>
    public static long VideoBitrate(int width, int height, double fps, int quality)
    {
        double pixels = Math.Max(1, (double)width * height) / (1920.0 * 1080.0);
        double frames = Math.Clamp(fps > 0 ? fps : 30, 15, 240) / 30.0;
        double factor = VideoQualityFactors[Math.Clamp(quality, 0, VideoQualityFactors.Length - 1)];
        return (long)(6_000_000 * Math.Pow(pixels, 0.75) * Math.Pow(frames, 0.6) * factor);
    }

    /// <summary>The kinds of video by resolution (their shorter side): 4K, 1440p, 1080p, 720p and less.</summary>
    public static string[] ResolutionNames => ["4K", "1440p", "1080p", L("720p и меньше")];

    /// <summary>Which of ResolutionNames a video is: 4K takes most when brought down, 1080p little.</summary>
    public static int ResolutionClass(VideoInfo info) => ResolutionClass(info.Width, info.Height);

    /// <summary>The same for a size: by the shorter side, so that a vertical video is what its horizontal twin is.</summary>
    public static int ResolutionClass(int width, int height)
    {
        int shorter = Math.Min(width, height);
        return shorter >= 2000 ? 0 : shorter >= 1400 ? 1 : shorter >= 1000 ? 2 : 3;
    }

    /// <summary>
    /// What compressing a video does: its new size and bitrate, or null when it would gain too little — already
    /// small enough and at about that bitrate.
    /// </summary>
    public static VideoJob? PlanVideo(VideoInfo info, int maxHeight, int quality)
    {
        if (info.Width <= 0 || info.Height <= 0 || info.Duration <= 0 || info.Kept != null) return null;
        // Compressed by the earlier version, with B-frames: phones play it in jerks. Built again at its own size and its
        // own bitrate, without them (5 % larger), whatever was asked.
        if (info.Stutters)
        {
            long had = info.VideoBitrate > 0 ? info.VideoBitrate : Math.Max(0, info.TotalBitrate - info.AudioBitrate);
            return new VideoJob(info.Width / 2 * 2, info.Height / 2 * 2, had,
                                (long)((had * 1.05 + Math.Max(info.AudioBitrate, 0)) * info.Duration / 8), Rebuild: true);
        }
        var (width, height) = VideoSize(info.Width, info.Height, maxHeight);
        long target = VideoBitrate(width, height, info.Fps, quality);
        long source = info.VideoBitrate > 0 ? info.VideoBitrate : Math.Max(0, info.TotalBitrate - info.AudioBitrate);
        // Never more bits than the video has; and not worth it for a few percent.
        long bitrate = Math.Min(target, (long)(source * 0.9));
        // How much the video weighs against what the quality asked needs at its size and frame rate. HEVC within 1.7
        // times of it is compressed already (by this app or anything else: the encoder runs up to 1.5 times above the
        // plan on busy scenes) — offered apart, to squeeze further only if asked; within 1.15 times, or an older codec
        // within 1.3 times, there is nothing to gain. Under two seconds one key frame is most of the file, and the
        // bitrate says nothing: HEVC that short counts as compressed already.
        double ratio = target > 0 ? (double)source / target : 0;
        // A camera's own HEVC is never "compressed already", whatever its bitrate: an iPhone's 1080p60 at 13.6 Mbit/s
        // (1.5 times the plan) was offered only to "squeeze further" and so skipped — it is to be compressed.
        bool again = info.Codec == "hevc" && (info.Reencoded ? ratio < 1.7 || info.Duration < 2 : info.Duration < 2);
        // Made smaller too: the bits it has against what the smaller size needs — an iPhone screen recording (1290 wide)
        // is HEVC of so few bits that at 1080 it would come out no lighter.
        if (ratio < (again ? 1.15 : 1.3)) return null;
        if (bitrate <= 0) return null;
        long estimate = (long)((bitrate + Math.Max(info.AudioBitrate, 0)) * info.Duration / 8 * 1.01);
        return new VideoJob(width, height, bitrate, estimate, again, Math.Clamp(quality, 0, VideoQualityFactors.Length - 1));
    }

    // --- The gain map ---------------------------------------------------------------------------------------------

    /// <summary>
    /// The HDR gain map from the light of each point in the SDR picture and in the HDR one (linear, white = 1): how many
    /// stops brighter the HDR one is, 0 where it is not. The HDR one is first brought to the SDR one's exposure in the
    /// mid-tones, so that only what is brighter than the SDR picture can show — the sky, the sun, lights. Null when
    /// there is nothing brighter worth keeping. The same on both platforms.
    /// </summary>
    public static (byte[] Map, GainMapInfo Info)? GainMap(float[] sdr, float[] hdr)
    {
        var ratios = new List<float>();
        for (int i = 0; i < sdr.Length; i++)
        {
            if (sdr[i] >= 0.05f && sdr[i] <= 0.5f && hdr[i] > 0) ratios.Add(hdr[i] / sdr[i]);
        }
        float exposure = 1;
        if (ratios.Count >= 100)
        {
            ratios.Sort();
            exposure = ratios[ratios.Count / 2];
        }
        if (!(exposure > 0) || float.IsInfinity(exposure)) exposure = 1;
        const float offset = 1f / 64;
        var stops = new float[sdr.Length];
        for (int i = 0; i < sdr.Length; i++)
        {
            float gain = MathF.Log2((Math.Max(hdr[i], 0) / exposure + offset) / (Math.Max(sdr[i], 0) + offset));
            stops[i] = float.IsFinite(gain) ? Math.Clamp(gain, 0, (float)MaxHdrStops) : 0;
        }
        // The brightest 0.1 % sets the top, so that one hot pixel does not flatten the rest.
        var sorted = (float[])stops.Clone();
        Array.Sort(sorted);
        double maxStops = sorted.Length == 0 ? 0 : sorted[Math.Min(sorted.Length - 1, (int)(sorted.Length * 0.999))];
        if (maxStops < 0.1) return null;
        var map = new byte[stops.Length];
        for (int i = 0; i < stops.Length; i++) map[i] = (byte)Math.Round(Math.Clamp(stops[i] / maxStops, 0, 1) * 255);
        return (map, new GainMapInfo(0, maxStops, 1, offset, offset, 0, maxStops));
    }

    /// <summary>
    /// Apple's own gain map (iPhone photos up to iOS 17, and the previews of ProRAW): HDR = SDR × (1 + (headroom − 1) ×
    /// g), g the map's value on a linear scale. The values are turned into ISO 21496-1 ones — log2 of that gain over
    /// log2 of the headroom — so that every viewer applies it the same way.
    /// </summary>
    public static (byte[] Table, GainMapInfo Info) FromAppleGainMap(double headroom)
    {
        double stops = Math.Log2(Math.Max(headroom, 1.0001));
        var table = new byte[256];
        for (int v = 0; v < 256; v++)
        {
            double gain = 1 + (headroom - 1) * SrgbToLinear(v);
            table[v] = (byte)Math.Round(Math.Clamp(Math.Log2(gain) / stops, 0, 1) * 255);
        }
        return (table, new GainMapInfo(0, stops, 1, 0, 0, 0, stops));
    }

    /// <summary>The headroom of Apple's gain map from the maker note of the photo (tags 33 and 48), by Apple's formula.</summary>
    public static double AppleHeadroom(double tag33, double tag48)
    {
        double stops = tag33 < 1
            ? (tag48 <= 0.01 ? -20 * tag48 + 1.8 : -0.101 * tag48 + 1.601)
            : (tag48 <= 0.01 ? -70 * tag48 + 3.0 : -0.303 * tag48 + 2.303);
        return Math.Pow(2, Math.Max(stops, 0));
    }

    /// <summary>The light of an sRGB value (0…255) on a linear scale (0…1).</summary>
    public static float SrgbToLinear(int value)
    {
        double v = value / 255.0;
        return (float)(v <= 0.04045 ? v / 12.92 : Math.Pow((v + 0.055) / 1.055, 2.4));
    }

    // --- Ultra HDR ------------------------------------------------------------------------------------------------

    /// <summary>
    /// One JPEG of the SDR picture and its gain map, as Android's Ultra HDR and the ISO 21496-1 gain maps Apple reads:
    /// the gain map JPEG goes after the picture, the Multi-Picture Format index says where, and XMP (hdrgm) and an ISO
    /// 21496-1 segment say how to apply it. Viewers that know nothing of it show the SDR picture. `segments` (Exif, an
    /// ICC profile) go into the picture first, an Exif one instead of any it has; `gainMapSegments` into the gain map.
    /// </summary>
    public static byte[] UltraHdr(byte[] primary, byte[] gainMap, GainMapInfo info, List<byte[]> segments, List<byte[]>? gainMapSegments = null)
    {
        static string N(double v) => v.ToString("0.######", CultureInfo.InvariantCulture);
        string gainMapXmp =
            "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"Photo Organizer\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + "<rdf:Description rdf:about=\"\" xmlns:hdrgm=\"http://ns.adobe.com/hdr-gain-map/1.0/\" hdrgm:Version=\"1.0\""
            + $" hdrgm:GainMapMin=\"{N(info.Min)}\" hdrgm:GainMapMax=\"{N(info.Max)}\" hdrgm:Gamma=\"{N(info.Gamma)}\""
            + $" hdrgm:OffsetSDR=\"{N(info.OffsetSdr)}\" hdrgm:OffsetHDR=\"{N(info.OffsetHdr)}\""
            + $" hdrgm:HDRCapacityMin=\"{N(info.CapacityMin)}\" hdrgm:HDRCapacityMax=\"{N(info.CapacityMax)}\" hdrgm:BaseRenditionIsHDR=\"False\"/>"
            + "</rdf:RDF></x:xmpmeta>";
        var mapSegments = new List<byte[]> { Segment(0xE1, Xmp(gainMapXmp)), Segment(0xE2, IsoGainMapMetadata(info)) };
        if (gainMapSegments != null) mapSegments.AddRange(gainMapSegments);
        byte[] secondary = InsertSegments(gainMap, false, mapSegments);

        string primaryXmp =
            "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"Photo Organizer\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + "<rdf:Description rdf:about=\"\" xmlns:Container=\"http://ns.google.com/photos/1.0/container/\""
            + " xmlns:Item=\"http://ns.google.com/photos/1.0/container/item/\" xmlns:hdrgm=\"http://ns.adobe.com/hdr-gain-map/1.0/\" hdrgm:Version=\"1.0\">"
            + "<Container:Directory><rdf:Seq>"
            + "<rdf:li rdf:parseType=\"Resource\"><Container:Item Item:Semantic=\"Primary\" Item:Mime=\"image/jpeg\"/></rdf:li>"
            + $"<rdf:li rdf:parseType=\"Resource\"><Container:Item Item:Semantic=\"GainMap\" Item:Mime=\"image/jpeg\" Item:Length=\"{secondary.Length}\"/></rdf:li>"
            + "</rdf:Seq></Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>";
        var all = new List<byte[]>(segments)
        {
            Segment(0xE1, Xmp(primaryXmp)),
            Segment(0xE2, Iso(new byte[4])),   // minimum and writer version 0: the metadata itself is in the gain map
        };
        // The Multi-Picture index is written last, once the offset of the gain map is known.
        var mpf = Segment(0xE2, MultiPictureIndex(0, 0, 0));
        all.Add(mpf);
        byte[] first = InsertSegments(primary, true, all);
        int mpfAt = IndexOf(first, mpf) + 4 + 4;   // the marker and length, then "MPF\0": offsets count from there
        var finalMpf = Segment(0xE2, MultiPictureIndex(first.Length, secondary.Length, first.Length - mpfAt));
        Buffer.BlockCopy(finalMpf, 0, first, mpfAt - 8, finalMpf.Length);

        var result = new byte[first.Length + secondary.Length];
        Buffer.BlockCopy(first, 0, result, 0, first.Length);
        Buffer.BlockCopy(secondary, 0, result, first.Length, secondary.Length);
        return result;
    }

    /// <summary>A JPEG with `segments` (Exif, an ICC profile) first, an Exif one instead of any it has.</summary>
    public static byte[] WithSegments(byte[] jpeg, List<byte[]> segments) => segments.Count == 0 ? jpeg : InsertSegments(jpeg, true, segments);

    static byte[] Xmp(string xml) => [.. Encoding.ASCII.GetBytes("http://ns.adobe.com/xap/1.0/\0"), .. Encoding.UTF8.GetBytes(xml)];

    const string IsoName = "urn:iso:std:iso:ts:21496:-1\0";

    static byte[] Iso(byte[] payload) => [.. Encoding.ASCII.GetBytes(IsoName), .. payload];

    /// <summary>ISO 21496-1 gain map metadata: one channel, every value a fraction over a million, big-endian.</summary>
    static byte[] IsoGainMapMetadata(GainMapInfo info)
    {
        const uint denominator = 1_000_000;
        var data = new List<byte>();
        void U16(ushort v) { data.Add((byte)(v >> 8)); data.Add((byte)v); }
        void U32(uint v) { data.Add((byte)(v >> 24)); data.Add((byte)(v >> 16)); data.Add((byte)(v >> 8)); data.Add((byte)v); }
        void Fraction(double v) { U32(unchecked((uint)(int)Math.Round(v * denominator))); U32(denominator); }
        U16(0);   // minimum version
        U16(0);   // writer version
        data.Add((byte)(info.UseBaseColorSpace ? 0x40 : 0));   // single channel; the colour space it applies in
        Fraction(info.CapacityMin);   // base HDR headroom (the base picture is SDR)
        Fraction(info.CapacityMax);   // alternate HDR headroom
        Fraction(info.Min);
        Fraction(info.Max);
        Fraction(info.Gamma);
        Fraction(info.OffsetSdr);     // base offset
        Fraction(info.OffsetHdr);     // alternate offset
        return Iso([.. data]);
    }

    /// <summary>
    /// The ISO 21496-1 metadata of a gain map JPEG (its APP2 segment), the first channel's; null when there is none or
    /// it is of a kind not handled (an HDR base picture).
    /// </summary>
    public static GainMapInfo? ReadIsoGainMapMetadata(byte[] gainMap)
    {
        foreach (var (at0, length) in AppSegments(gainMap, 0xE2))
        {
            var contents = gainMap.AsSpan(at0, length).ToArray();
            if (contents.Length < IsoName.Length + 5 || Encoding.ASCII.GetString(contents, 0, IsoName.Length) != IsoName) continue;
            int at = IsoName.Length;
            uint U32() { uint v = BinaryPrimitives.ReadUInt32BigEndian(contents.AsSpan(at)); at += 4; return v; }
            int S32() => unchecked((int)U32());
            static double Ratio(double n, uint d) => d == 0 ? 0 : n / d;
            try
            {
                at += 4;   // the versions
                byte flags = contents[at++];
                if ((flags & 0x04) != 0) return null;   // the base picture is the HDR one
                double baseHeadroom, alternateHeadroom, min, max, gamma, baseOffset, alternateOffset;
                if ((flags & 0x08) != 0)
                {
                    // One denominator for everything.
                    uint d = U32();
                    baseHeadroom = Ratio(U32(), d);
                    alternateHeadroom = Ratio(U32(), d);
                    min = Ratio(S32(), d);
                    max = Ratio(S32(), d);
                    gamma = Ratio(U32(), d);
                    baseOffset = Ratio(S32(), d);
                    alternateOffset = Ratio(S32(), d);
                }
                else
                {
                    baseHeadroom = Ratio(U32(), U32());
                    alternateHeadroom = Ratio(U32(), U32());
                    min = Ratio(S32(), U32());
                    max = Ratio(S32(), U32());
                    gamma = Ratio(U32(), U32());
                    baseOffset = Ratio(S32(), U32());
                    alternateOffset = Ratio(S32(), U32());
                }
                if (max <= min || gamma <= 0) return null;
                return new GainMapInfo(min, max, gamma, baseOffset, alternateOffset, baseHeadroom, alternateHeadroom, (flags & 0x40) != 0);
            }
            catch (ArgumentOutOfRangeException)
            {
                return null;
            }
        }
        return null;
    }

    /// <summary>Where the contents of a JPEG's APPn segments of one kind are (after the marker and the length), up to its picture data.</summary>
    public static IEnumerable<(int At, int Length)> AppSegments(byte[] jpeg, byte marker)
    {
        int at = 2;
        while (at + 4 <= jpeg.Length && jpeg[at] == 0xFF && jpeg[at + 1] != 0xDA)
        {
            int length = (jpeg[at + 2] << 8) | jpeg[at + 3];
            if (length < 2 || at + 2 + length > jpeg.Length) yield break;
            if (jpeg[at + 1] == marker) yield return (at + 4, length - 2);
            at += 2 + length;
        }
    }

    /// <summary>Whole APPn segments whose contents start with `name` ("ICC_PROFILE\0"), to copy into another JPEG.</summary>
    public static List<byte[]> SegmentsNamed(byte[] jpeg, byte marker, string name)
    {
        var found = new List<byte[]>();
        foreach (var (at, length) in AppSegments(jpeg, marker))
        {
            if (length >= name.Length && Encoding.ASCII.GetString(jpeg, at, name.Length) == name) found.Add(jpeg.AsSpan(at - 4, length + 4).ToArray());
        }
        return found;
    }

    /// <summary>
    /// The second picture of a JPEG with a Multi-Picture index (a gain map, a depth map…): where it starts and its
    /// length; null when there is none.
    /// </summary>
    public static (int Offset, int Length)? SecondPicture(byte[] jpeg)
    {
        foreach (var (at, length) in AppSegments(jpeg, 0xE2))
        {
            if (length < 16 || Encoding.ASCII.GetString(jpeg, at, 4) != "MPF\0") continue;
            int start = at + 4;   // the TIFF header inside the segment: offsets count from there
            bool little = jpeg[start] == 'I';
            uint U32(int offset) => little ? BinaryPrimitives.ReadUInt32LittleEndian(jpeg.AsSpan(start + offset)) : BinaryPrimitives.ReadUInt32BigEndian(jpeg.AsSpan(start + offset));
            ushort U16(int offset) => little ? BinaryPrimitives.ReadUInt16LittleEndian(jpeg.AsSpan(start + offset)) : BinaryPrimitives.ReadUInt16BigEndian(jpeg.AsSpan(start + offset));
            try
            {
                int ifd = (int)U32(4);
                int count = U16(ifd);
                for (int i = 0; i < count; i++)
                {
                    int entry = ifd + 2 + i * 12;
                    if (U16(entry) != 0xB002 || U32(entry + 4) < 32) continue;
                    int list = (int)U32(entry + 8);
                    int size = (int)U32(list + 16 + 4), offset = (int)U32(list + 16 + 8);
                    if (offset <= 0 || size <= 0 || start + (long)offset + size > jpeg.Length) return null;
                    return (start + offset, size);
                }
            }
            catch (ArgumentOutOfRangeException)
            {
                return null;
            }
        }
        return null;
    }

    /// <summary>The MP index of two pictures, little-endian: the primary at 0, the gain map at `offset`.</summary>
    static byte[] MultiPictureIndex(int primarySize, int gainMapSize, int offset)
    {
        var data = new byte[4 + 8 + 2 + 3 * 12 + 4 + 32];
        Encoding.ASCII.GetBytes("MPF\0").CopyTo(data, 0);
        const int tiff = 4;   // offsets count from the TIFF header
        "II*\0"u8.CopyTo(data.AsSpan(tiff));
        BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(tiff + 4), 8);
        BinaryPrimitives.WriteUInt16LittleEndian(data.AsSpan(tiff + 8), 3);
        void Entry(int index, ushort tag, ushort type, uint count, uint value)
        {
            int at = tiff + 10 + index * 12;
            BinaryPrimitives.WriteUInt16LittleEndian(data.AsSpan(at), tag);
            BinaryPrimitives.WriteUInt16LittleEndian(data.AsSpan(at + 2), type);
            BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(at + 4), count);
            BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(at + 8), value);
        }
        Entry(0, 0xB000, 7, 4, BinaryPrimitives.ReadUInt32LittleEndian("0100"u8));   // version
        Entry(1, 0xB001, 4, 1, 2);                                                   // number of images
        int entries = 10 + 3 * 12 + 4;
        Entry(2, 0xB002, 7, 32, (uint)entries);                                      // the MP entries
        var list = data.AsSpan(tiff + entries);
        BinaryPrimitives.WriteUInt32LittleEndian(list, 0x030000);           // primary, baseline JPEG
        BinaryPrimitives.WriteUInt32LittleEndian(list[4..], (uint)primarySize);
        BinaryPrimitives.WriteUInt32LittleEndian(list[8..], 0);
        BinaryPrimitives.WriteUInt32LittleEndian(list[16..], 0);
        BinaryPrimitives.WriteUInt32LittleEndian(list[20..], (uint)gainMapSize);
        BinaryPrimitives.WriteUInt32LittleEndian(list[24..], (uint)offset);
        return data;
    }

    /// <summary>An APPn segment: the marker, the length, the contents.</summary>
    public static byte[] Segment(byte marker, byte[] contents)
    {
        if (contents.Length + 2 > 0xFFFF) throw new InvalidDataException("JPEG segment too long");
        var segment = new byte[contents.Length + 4];
        segment[0] = 0xFF;
        segment[1] = marker;
        segment[2] = (byte)((contents.Length + 2) >> 8);
        segment[3] = (byte)(contents.Length + 2);
        contents.CopyTo(segment, 4);
        return segment;
    }

    /// <summary>
    /// `segments` put in a JPEG after its JFIF header (or right after the start); with `replaceExif` an Exif APP1
    /// already there is dropped, the first of `segments` being the one to have instead.
    /// </summary>
    static byte[] InsertSegments(byte[] jpeg, bool replaceExif, List<byte[]> segments)
    {
        if (jpeg.Length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) throw new InvalidDataException("not a JPEG");
        var head = new MemoryStream();
        head.Write(jpeg, 0, 2);
        int at = 2;
        // Keep APP0 (JFIF) first; drop an Exif APP1 being replaced.
        while (at + 4 <= jpeg.Length && jpeg[at] == 0xFF && (jpeg[at + 1] == 0xE0 || jpeg[at + 1] == 0xE1))
        {
            int length = (jpeg[at + 2] << 8) | jpeg[at + 3];
            bool isExif = jpeg[at + 1] == 0xE1 && at + 10 <= jpeg.Length && Encoding.ASCII.GetString(jpeg, at + 4, 4) == "Exif";
            if (jpeg[at + 1] == 0xE0) head.Write(jpeg, at, length + 2);
            else if (!(isExif && replaceExif)) break;
            at += length + 2;
        }
        foreach (var segment in segments) head.Write(segment);
        head.Write(jpeg, at, jpeg.Length - at);
        return head.ToArray();
    }

    static int IndexOf(byte[] data, byte[] part)
    {
        for (int i = 0; i + part.Length <= data.Length; i++)
        {
            if (data.AsSpan(i, part.Length).SequenceEqual(part)) return i;
        }
        return -1;
    }

    /// <summary>"1,2 ГБ → 300 МБ (−75 %)".</summary>
    public static string Saving(long before, long after)
    {
        string text = $"{Size(before)} → {Size(after)}";
        if (before <= 0) return text;
        double percent = after * 100.0 / before - 100;
        // Larger (a rebuild without B-frames): said so, not "−0 %".
        return text + (percent >= 0.5 ? $" (+{percent:0} %)" : $" (−{Math.Max(0, -percent):0} %)");
    }
}

/// <summary>What ffprobe or AVFoundation says of a video, upright (a vertical one is taller than wide).</summary>
public sealed record VideoInfo(int Width, int Height, double Fps, double Duration, long VideoBitrate, long AudioBitrate, long TotalBitrate,
                               string Codec, string? Primaries, string? Transfer, string? Matrix, bool TenBit, int Rotation = 0,
                               string? Kept = null, bool Stutters = false, double NominalFps = 0, string? DynamicHdr = null, bool FlatTimestamps = false,
                               bool Reencoded = false)
{
    // Kept: why the video is not compressed at all (a 3D video, a second video track) — compressing would lose part of it.
    // FlatTimestamps: the frames are stored out of order (B-frames) but the file says they are shown in the order
    // stored (no ctts): players show them out of order, in jerks. The timestamps are made afresh from the order the
    // frames are decoded in, which is the right one.
    /// <summary>
    /// Frames at varying intervals: the stream states another rate than it has (an iPhone marks such a video 120, an
    /// older one 24 for intervals of 1/24 and 1/30 s). An encoder working to a bitrate shares it out by the stated rate.
    /// </summary>
    public bool VariableRate => NominalFps > 0 && Fps > 0 && Math.Abs(NominalFps - Fps) > Fps * 0.1;

    /// <summary>HLG or PQ: what an iPhone and most cameras record HDR in.</summary>
    public bool Hdr => Transfer is "arib-std-b67" or "smpte2084";
}

/// <summary>
/// How a gain map is applied (ISO 21496-1, in stops): HDR = (SDR + OffsetSdr) × 2^(Min + g^(1/Gamma) × (Max − Min)) −
/// OffsetHdr, shown in full on a screen with CapacityMax stops of headroom, not at all with CapacityMin.
/// </summary>
public sealed record GainMapInfo(double Min, double Max, double Gamma, double OffsetSdr, double OffsetHdr, double CapacityMin, double CapacityMax,
                                 bool UseBaseColorSpace = true);

/// <summary>How far a video's compression is: 0…1, times real time, frames a second, bytes written, on the graphics card.</summary>
public sealed record VideoProgress(double Fraction, double Speed, double Fps, long Bytes, bool OnCard);

/// <summary>A video to compress: its new size and bitrate, and how large it should come out.</summary>
/// <summary>Again: the video is compressed already (HEVC near the quality asked); it can be squeezed further, if asked.</summary>
/// <summary>The size a video is made, the bitrate it is encoded to, and what it should come out at.</summary>
/// Rebuild: a video the earlier version compressed with B-frames (VideoInfo.Stutters), built again as a camera builds it,
/// at its own size and almost without loss; it replaces the old one even if it comes out larger.
public sealed record VideoJob(int Width, int Height, long Bitrate, long EstimatedSize, bool Again = false, int Quality = 1, bool Rebuild = false);
