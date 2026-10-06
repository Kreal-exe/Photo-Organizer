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
