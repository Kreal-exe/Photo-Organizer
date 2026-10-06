using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using PhotoOrganizer.Core;

namespace PhotoOrganizer.UI;

/// <summary>
/// Thumbnails from the Windows shell — the ones File Explorer shows, from its own cache, for every format Windows can
/// open (JPEG, HEIC, RAW, videos…) — and face pictures cut from the photos. Made on a few background threads, newest
/// request first, and kept in memory.
/// </summary>
public sealed class Thumbnails
{
    const long CacheLimit = 400L * 1024 * 1024;

    readonly Dispatcher _dispatcher;
    readonly Dictionary<string, ImageSource?> _cache = [];
    readonly LinkedList<string> _order = [];
    readonly HashSet<string> _pending = [];
    readonly ConcurrentStack<(string Key, string Path, Func<ImageSource?> Work)> _queue = new();
    // The keys of each file's pictures, so that a moved or deleted file is forgotten without going through them all.
    readonly Dictionary<string, List<string>> _keysOfPath = new(StringComparer.OrdinalIgnoreCase);
    readonly SemaphoreSlim _signal = new(0);
    long _bytes;

    /// <summary>Raised on the interface thread with the key of a picture that has arrived.</summary>
    public event Action<string>? Loaded;

    public Thumbnails(Dispatcher dispatcher)
    {
        _dispatcher = dispatcher;
        for (int i = 0; i < 4; i++)
        {
            var thread = new Thread(Work) { IsBackground = true, Name = "Thumbnails" };
            thread.SetApartmentState(ApartmentState.STA);   // shell extensions expect it
            thread.Start();
        }
    }

    void Work()
    {
        while (true)
        {
            _signal.Wait();
            if (!_queue.TryPop(out var job)) continue;
            ImageSource? image = null;
            try { image = job.Work(); }
            catch (Exception) { /* an unreadable file shows the placeholder */ }
            _dispatcher.BeginInvoke(() => Deliver(job.Key, job.Path, image), DispatcherPriority.Background);
        }
    }

    /// <summary>What an entry costs the cache; a failed one a little, so that they too are let go eventually.</summary>
    static long Cost(ImageSource? image) => image is BitmapSource bitmap ? (long)bitmap.PixelWidth * bitmap.PixelHeight * 4 : 1024;

    void Deliver(string key, string path, ImageSource? image)
    {
        if (!_pending.Remove(key)) return;   // forgotten while it was being made
        _cache[key] = image;
        _order.AddLast(key);
        if (!_keysOfPath.TryGetValue(path, out var keys)) _keysOfPath[path] = keys = [];
        keys.Add(key);
        _bytes += Cost(image);
        while (_bytes > CacheLimit && _order.First is { } oldest)
        {
            _order.RemoveFirst();
            if (_cache.Remove(oldest.Value, out var old)) _bytes -= Cost(old);
        }
        Loaded?.Invoke(key);
    }

    static int Bucket(int pixels) => pixels <= 192 ? 192 : pixels <= 320 ? 320 : pixels <= 512 ? 512 : 768;

    public static string Key(PhotoItem item, int pixels) => $"{Bucket(pixels)}|{item.Path}";

    /// <summary>The thumbnail when it is in memory; null while it is being made (Loaded is raised when it is).</summary>
    public ImageSource? Get(PhotoItem item, int pixels, out bool failed)
    {
        string key = Key(item, pixels);
        failed = false;
        if (_cache.TryGetValue(key, out var image))
        {
            failed = image == null;
            return image;
        }
        if (_pending.Add(key))
        {
            string path = item.Path;
            int side = Bucket(pixels);
            bool cloud = item.CloudOnly;
            Enqueue(key, path, () => Images.ShellThumbnail(path, side, cloud) ?? (cloud ? null : Decoded(path, side)));
        }
        return null;
    }

    /// <summary>A square picture of the face at `box` (fractions of the picture), a little wider than the face itself.</summary>
    public ImageSource? Face(PhotoItem item, float[] box, int pixels)
    {
        // By size too: the sidebar's slider makes faces larger, and a small crop would be blown up blurred.
        string key = $"face|{Bucket(pixels)}|{item.Path}|{string.Join(",", box)}";
        if (_cache.TryGetValue(key, out var image)) return image;
        if (_pending.Add(key))
        {
            string path = item.Path;
            Enqueue(key, path, () => FaceCrop(path, box, Bucket(pixels)));
        }
        return null;
    }

    public void Forget(string path)
    {
        if (!_keysOfPath.Remove(path, out var keys)) return;
        foreach (string key in keys)
        {
            if (_cache.Remove(key, out var old)) _bytes -= Cost(old);
        }
    }

    void Enqueue(string key, string path, Func<ImageSource?> work)
    {
        _queue.Push((key, path, work));
        _signal.Release();
    }

    static ImageSource? Decoded(string path, int side) => Bitmap(Images.Load(path, side));

    static ImageSource? FaceCrop(string path, float[] box, int pixels)
    {
        var image = Images.Load(path, 1280);
        if (image == null) return null;
        // The detector's box hugs the face from brow to chin; a square 1.6 times larger takes in the head.
        double side = Math.Max(box[2] * image.Width, box[3] * image.Height) * 1.6;
        double cx = (box[0] + box[2] / 2) * image.Width, cy = (box[1] + box[3] / 2) * image.Height;
        int left = (int)Math.Max(0, cx - side / 2), top = (int)Math.Max(0, cy - side / 2);
        int right = (int)Math.Min(image.Width, cx + side / 2), bottom = (int)Math.Min(image.Height, cy + side / 2);
        int w = right - left, h = bottom - top;
        if (w < 4 || h < 4) return null;
        var pixels3 = new byte[w * h * 3];
        for (int y = 0; y < h; y++) Buffer.BlockCopy(image.Bgr, ((top + y) * image.Width + left) * 3, pixels3, y * w * 3, w * 3);
        BitmapSource crop = BitmapSource.Create(w, h, 96, 96, PixelFormats.Bgr24, null, pixels3, w * 3);
        double scale = Math.Min(1, pixels * 2.0 / Math.Max(w, h));
        if (scale < 1) crop = new TransformedBitmap(crop, new ScaleTransform(scale, scale));
        var result = new WriteableBitmap(crop);
        result.Freeze();
        return result;
    }

    public static BitmapSource? Bitmap(RasterImage? image)
    {
        if (image == null) return null;
        var bitmap = BitmapSource.Create(image.Width, image.Height, 96, 96, PixelFormats.Bgr24, null, image.Bgr, image.Width * 3);
        bitmap.Freeze();
        return bitmap;
    }
}
