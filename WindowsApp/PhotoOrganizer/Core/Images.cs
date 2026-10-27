using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace PhotoOrganizer.Core;

/// <summary>A decoded picture: 3 bytes per pixel, blue-green-red, rows without padding.</summary>
public sealed class RasterImage(int width, int height, byte[] bgr)
{
    public int Width { get; } = width;
    public int Height { get; } = height;
    public byte[] Bgr { get; } = bgr;

    /// <summary>The 9×8 grey picture the visual fingerprint is made from (each cell the average of its area).</summary>
    public byte[] Gray9x8()
    {
        var result = new byte[72];
        for (int row = 0; row < 8; row++)
        {
            int y0 = row * Height / 8, y1 = Math.Max(y0 + 1, (row + 1) * Height / 8);
            for (int column = 0; column < 9; column++)
            {
                int x0 = column * Width / 9, x1 = Math.Max(x0 + 1, (column + 1) * Width / 9);
                long sum = 0, count = 0;
                int stepY = Math.Max(1, (y1 - y0) / 16), stepX = Math.Max(1, (x1 - x0) / 16);
                for (int y = y0; y < y1; y += stepY)
                {
                    for (int x = x0; x < x1; x += stepX)
                    {
                        int at = (y * Width + x) * 3;
                        sum += (Bgr[at] * 29 + Bgr[at + 1] * 150 + Bgr[at + 2] * 77) >> 8;
                        count++;
                    }
                }
                result[row * 9 + column] = (byte)(sum / Math.Max(count, 1));
            }
        }
        return result;
    }
}

/// <summary>Decodes pictures with the Windows Imaging Component — the codecs Windows itself uses (JPEG, PNG, HEIC, RAW…).</summary>
public static class Images
{
    /// <summary>
    /// Whether a picture carries HDR: a JPEG or HEIC with a gain map (Apple's, or the ISO 21496-1 one of Ultra HDR), or
    /// a PNG or AVIF that says its colours are PQ or HLG. Found by the marks those write near the start of the file.
    /// </summary>
    public static bool IsHdr(string path)
    {
        try
        {
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 16);
            var head = new byte[Math.Min(file.Length, 4 << 20)];
            int read = 0;
            while (read < head.Length)
            {
                int n = file.Read(head, read, head.Length - read);
                if (n <= 0) break;
                read += n;
            }
            var data = head.AsSpan(0, read);
            if (data.Length < 12) return false;
            if (data[0] == 0xFF && data[1] == 0xD8)   // JPEG: Ultra HDR's XMP, the ISO gain map, Apple's gain map
                return data.IndexOf("hdrgm:Version"u8) >= 0 || data.IndexOf("urn:iso:std:iso:ts:21496"u8) >= 0 || data.IndexOf("HDRGainMap"u8) >= 0;
            if (data.Slice(4, 4).SequenceEqual("ftyp"u8))   // HEIC, AVIF: an auxiliary gain map, or PQ/HLG colours (nclx transfer 16/18)
            {
                if (data.IndexOf("urn:com:apple:photo:2020:aux:hdrgainmap"u8) >= 0 || data.IndexOf("urn:iso:std:iso:ts:21496"u8) >= 0) return true;
                int colr = data.IndexOf("colrnclx"u8);
                return colr >= 0 && colr + 12 <= data.Length && data[colr + 11] is 16 or 18;
            }
            if (data[1] == 'P' && data[2] == 'N' && data[3] == 'G')   // PNG: a cICP chunk with PQ or HLG
            {
                int cicp = data.IndexOf("cICP"u8);
                return cicp >= 0 && cicp + 6 <= data.Length && data[cicp + 5] is 16 or 18;
            }
            return false;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>The picture at most `side` pixels along its longer edge, turned upright; null when it can't be decoded.</summary>
    public static RasterImage? Load(string path, int side)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.IgnoreColorProfile | BitmapCreateOptions.DelayCreation,
                                               BitmapCacheOption.None);
            var frame = decoder.Frames[0];
            int width = frame.PixelWidth, height = frame.PixelHeight;
            int orientation = Orientation(frame) ?? MetadataReader.Read(path, video: false).Orientation;
            if (orientation is >= 5 and <= 8 && AlreadyTurned(path, width, height)) orientation = 1;
            BitmapSource source = frame;
            if (Math.Max(width, height) > side)
            {
                // Decoding straight at the smaller size: JPEG decoders do it at a fraction of the cost.
                stream.Position = 0;
                var scaled = new BitmapImage();
                scaled.BeginInit();
                scaled.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
                scaled.CacheOption = BitmapCacheOption.OnLoad;
                scaled.StreamSource = stream;
                if (width >= height) scaled.DecodePixelWidth = side; else scaled.DecodePixelHeight = side;
                scaled.EndInit();
                source = scaled;
            }
            source = Upright(source, orientation);
            var converted = new FormatConvertedBitmap(source, PixelFormats.Bgr24, null, 0);
            int w = converted.PixelWidth, h = converted.PixelHeight;
            var pixels = new byte[w * h * 3];
            converted.CopyPixels(pixels, w * 3, 0);
            return new RasterImage(w, h, pixels);
        }
        catch (Exception e) when (e is IOException or NotSupportedException or ArgumentException or InvalidOperationException
                                    or UnauthorizedAccessException or OverflowException or System.Runtime.InteropServices.COMException
                                    or FileFormatException)
        {
            return null;
        }
    }

    /// <summary>What a sample becomes: as it is (0…255), on a 0…1 scale, or normalized with a mean and a deviation.</summary>
    public enum SampleValue { Raw, Unit, Normalized }

    /// <summary>
    /// The pixels a model is given: the picture sampled bilinearly at `width`×`height` from (left, top), `scaleX` and
    /// `scaleY` output pixels to a picture's pixel, into `output` from `offset` — planes one after another (channel,
    /// row, column), or `interleaved` (row, column, channel). `channels` names, for each output channel, the picture's
    /// (0 blue, 1 green, 2 red). With `blankOutside` what falls outside the picture is left as it is, otherwise the
    /// edge is repeated. The positions and weights of a row and a column are worked out once, not for every pixel:
    /// this ran for every model and every picture, and kept the processor busy while the graphics card waited.
    /// </summary>
    public static unsafe void Sample(RasterImage image, double left, double top, double scaleX, double scaleY, int width, int height,
                                     Span<float> output, int offset, bool interleaved, int[] channels, SampleValue value,
                                     float[]? mean = null, float[]? std = null, bool blankOutside = false)
    {
        int w = image.Width, h = image.Height, count = channels.Length, plane = width * height;
        var x0s = new int[width];
        var x1s = new int[width];
        var fxs = new float[width];
        var inside = new bool[width];
        for (int x = 0; x < width; x++)
        {
            double sx = left + (x + 0.5) / scaleX - 0.5;
            inside[x] = !blankOutside || (sx >= -0.5 && sx <= w - 0.5);
            sx = Math.Clamp(sx, 0, w - 1);
            int x0 = (int)sx;
            x0s[x] = x0 * 3;
            x1s[x] = Math.Min(w - 1, x0 + 1) * 3;
            fxs[x] = (float)(sx - x0);
        }
        fixed (byte* bgr = image.Bgr)
        fixed (float* target = output)
        {
            for (int y = 0; y < height; y++)
            {
                double sy = top + (y + 0.5) / scaleY - 0.5;
                if (blankOutside && (sy < -0.5 || sy > h - 0.5)) continue;
                sy = Math.Clamp(sy, 0, h - 1);
                int y0 = (int)sy, y1 = Math.Min(h - 1, y0 + 1);
                float fy = (float)(sy - y0);
                byte* upperRow = bgr + (long)y0 * w * 3, lowerRow = bgr + (long)y1 * w * 3;
                for (int x = 0; x < width; x++)
                {
                    if (!inside[x]) continue;
                    float fx = fxs[x];
                    int a = x0s[x], b = x1s[x];
                    for (int c = 0; c < count; c++)
                    {
                        int channel = channels[c];
                        float upper = upperRow[a + channel] * (1 - fx) + upperRow[b + channel] * fx;
                        float lower = lowerRow[a + channel] * (1 - fx) + lowerRow[b + channel] * fx;
                        float v = upper * (1 - fy) + lower * fy;
                        v = value switch
                        {
                            SampleValue.Unit => v / 255f,
                            SampleValue.Normalized => (v / 255f - mean![c]) / std![c],
                            _ => v,
                        };
                        target[interleaved ? offset + (y * width + x) * count + c : offset + c * plane + y * width + x] = v;
                    }
                }
            }
        }
    }

    /// <summary>A smaller copy, at most `side` pixels along its longer edge (each pixel the average of its area).</summary>
    public static RasterImage Downscaled(RasterImage image, int side)
    {
        double scale = (double)side / Math.Max(image.Width, image.Height);
        if (scale >= 1) return image;
        var source = BitmapSource.Create(image.Width, image.Height, 96, 96, PixelFormats.Bgr24, null, image.Bgr, image.Width * 3);
        var scaled = new TransformedBitmap(source, new ScaleTransform(scale, scale));
        int w = scaled.PixelWidth, h = scaled.PixelHeight;
        var pixels = new byte[w * h * 3];
        scaled.CopyPixels(pixels, w * 3, 0);
        return new RasterImage(w, h, pixels);
    }

    /// <summary>
    /// The EXIF orientation (1 = upright) as WIC reports it; null when it can't tell, and the file's own EXIF is read instead.
    /// </summary>
    public static int? Orientation(BitmapFrame frame)
    {
        try
        {
            if (frame.Metadata is BitmapMetadata metadata && metadata.GetQuery("System.Photo.Orientation") is { } value)
            {
                return Convert.ToInt32(value, System.Globalization.CultureInfo.InvariantCulture);
            }
        }
        catch (Exception e) when (e is NotSupportedException or InvalidOperationException or ArgumentException
                                    or System.Runtime.InteropServices.COMException)
        {
        }
        return null;
    }

    /// <summary>
    /// Some decoders turn the picture themselves — the HEIF one applies the rotation stored in the file, which iPhones
    /// also write as EXIF orientation — and turning it again would put it on its side. The thumbnail File Explorer shows
    /// is upright, so when the decoded picture already has its proportions, it is already turned.
    /// </summary>
    static bool AlreadyTurned(string path, int width, int height)
    {
        if (Math.Abs(width - height) < Math.Max(width, height) / 20) return false;   // square: nothing to tell by
        var thumbnail = ShellThumbnail(path, 96);
        if (thumbnail == null || Math.Abs(thumbnail.PixelWidth - thumbnail.PixelHeight) < 4) return false;
        return thumbnail.PixelWidth > thumbnail.PixelHeight == width > height;
    }

    /// <summary>Turns and mirrors the picture the way its EXIF orientation says it should be shown.</summary>
    public static BitmapSource Upright(BitmapSource source, int orientation)
    {
        if (orientation is < 2 or > 8) return source;
        var transform = new TransformGroup();
        if (orientation is 2 or 4 or 5 or 7) transform.Children.Add(new ScaleTransform(-1, 1));
        // Applied in order: the mirror first, then the turn (clockwise). 5 is a transpose, 7 a transverse.
        double angle = orientation switch { 3 or 4 => 180, 6 or 7 => 90, 5 or 8 => 270, _ => 0 };
        if (angle != 0) transform.Children.Add(new RotateTransform(angle));
        var result = new TransformedBitmap(source, transform);
        result.Freeze();
        return result;
    }

    // --- The shell's thumbnails ------------------------------------------------------------------------------------

    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory
    {
        [PreserveSig] int GetImage(NativeSize size, int flags, out IntPtr bitmap);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct NativeSize(int width, int height)
    {
        public int Width = width, Height = height;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    static extern int SHCreateItemFromParsingName(string path, IntPtr bindContext, ref Guid riid,
                                                  [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory factory);

    [DllImport("gdi32.dll")]
    static extern bool DeleteObject(IntPtr handle);

    const int BiggerSizeOk = 0x1, ThumbnailOnly = 0x8, InCacheOnly = 0x10;

    /// <summary>
    /// The thumbnail File Explorer shows — from its own cache, for every format Windows can open (JPEG, HEIC, RAW,
    /// videos…). Null when there is none; with `cacheOnly`, only one that exists already (a cloud file is never fetched).
    /// </summary>
    public static BitmapSource? ShellThumbnail(string path, int side, bool cacheOnly = false)
    {
        var iid = typeof(IShellItemImageFactory).GUID;
        if (SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out var factory) != 0 || factory == null) return null;
        try
        {
            int flags = BiggerSizeOk | ThumbnailOnly | (cacheOnly ? InCacheOnly : 0);
            if (factory.GetImage(new NativeSize(side, side), flags, out var bitmap) != 0 || bitmap == IntPtr.Zero) return null;
            try
            {
                var source = Imaging.CreateBitmapSourceFromHBitmap(bitmap, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                // Copied out of the GDI bitmap, and opaque: the shell hands back premultiplied pixels WPF would misread.
                var frozen = new WriteableBitmap(new FormatConvertedBitmap(source, PixelFormats.Bgr32, null, 0));
                frozen.Freeze();
                return frozen;
            }
            finally
            {
                DeleteObject(bitmap);
            }
        }
        finally
        {
            Marshal.ReleaseComObject(factory);
        }
    }

    /// <summary>
    /// Frames spread over a video, as the Mac analyses it: one for every three seconds, up to `count`, each from the
    /// middle of its stretch. Media Foundation decodes them; when it can't (or gives them on their side), the frame
    /// File Explorer shows stands for the whole video. Empty when there is none.
    /// </summary>
    public static List<RasterImage> VideoFrames(string path, int side, double duration, int width, int height, int count)
    {
        count = Math.Clamp((int)Math.Ceiling(duration / 3), 1, count);
        var frames = new List<RasterImage>();
        if (count > 1 && width > 0 && height > 0)
        {
            try
            {
                var file = Windows.Storage.StorageFile.GetFileFromPathAsync(path).AsTask().GetAwaiter().GetResult();
                var clip = Windows.Media.Editing.MediaClip.CreateFromFileAsync(file).AsTask().GetAwaiter().GetResult();
                var properties = clip.GetVideoEncodingProperties();
                int naturalWidth = (int)properties.Width, naturalHeight = (int)properties.Height;
                // A turned video is decoded as stored: the shell's frame is upright, so it is used instead.
                if (naturalWidth > 0 && naturalHeight > 0 && naturalWidth > naturalHeight == width > height)
                {
                    var composition = new Windows.Media.Editing.MediaComposition();
                    composition.Clips.Add(clip);
                    double scale = Math.Min(1, (double)side / Math.Max(naturalWidth, naturalHeight));
                    int w = Math.Max(1, (int)(naturalWidth * scale)), h = Math.Max(1, (int)(naturalHeight * scale));
                    for (int frame = 0; frame < count; frame++)
                    {
                        var time = TimeSpan.FromSeconds(duration * (frame + 0.5) / count);
                        using var stream = composition.GetThumbnailAsync(time, w, h, Windows.Media.Editing.VideoFramePrecision.NearestKeyFrame)
                                                      .AsTask().GetAwaiter().GetResult();
                        var decoder = Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream).AsTask().GetAwaiter().GetResult();
                        var data = decoder.GetPixelDataAsync(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Ignore,
                                                             new Windows.Graphics.Imaging.BitmapTransform(), Windows.Graphics.Imaging.ExifOrientationMode.RespectExifOrientation,
                                                             Windows.Graphics.Imaging.ColorManagementMode.DoNotColorManage).AsTask().GetAwaiter().GetResult();
                        byte[] bgra = data.DetachPixelData();
                        int pw = (int)decoder.OrientedPixelWidth, ph = (int)decoder.OrientedPixelHeight;
                        if (bgra.Length < pw * ph * 4) continue;
                        var bgr = new byte[pw * ph * 3];
                        for (int i = 0, j = 0; j < bgr.Length; i += 4, j += 3)
                        {
                            bgr[j] = bgra[i];
                            bgr[j + 1] = bgra[i + 1];
                            bgr[j + 2] = bgra[i + 2];
                        }
                        frames.Add(new RasterImage(pw, ph, bgr));
                    }
                }
            }
            catch (Exception)
            {
                // Media Foundation has no decoder for it, or the file is gone: the shell's frame below.
                frames.Clear();
            }
        }
        if (frames.Count == 0 && VideoFrame(path, side) is { } shown) frames.Add(shown);
        return frames;
    }

    /// <summary>A frame of a video, as Windows shows it in File Explorer; null when it has none.</summary>
    public static RasterImage? VideoFrame(string path, int side)
    {
        if (ShellThumbnail(path, side) is not { } bitmap) return null;
        var converted = new FormatConvertedBitmap(bitmap, PixelFormats.Bgr24, null, 0);
        var pixels = new byte[converted.PixelWidth * converted.PixelHeight * 3];
        converted.CopyPixels(pixels, converted.PixelWidth * 3, 0);
        return new RasterImage(converted.PixelWidth, converted.PixelHeight, pixels);
    }
}
