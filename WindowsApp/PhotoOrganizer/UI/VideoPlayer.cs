using System.Runtime.InteropServices.WindowsRuntime;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Windows.Graphics.DirectX;
using Windows.Graphics.Imaging;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage;
using MediaPlayer = Windows.Media.Playback.MediaPlayer;
using VideoFrame = Windows.Media.VideoFrame;

namespace PhotoOrganizer.UI;

/// <summary>
/// Plays a video with Media Foundation — the engine of Windows' own Media Player app — and hands its frames to WPF as a
/// bitmap. WPF's MediaElement goes through the old Windows Media Player instead, which gives up on files it only
/// partly knows: iPhone videos with spatial audio and metadata tracks, among others.
/// </summary>
public sealed class VideoPlayer : IDisposable
{
    readonly Dispatcher _dispatcher;
    readonly MediaPlayer _player = new() { IsVideoFrameServerEnabled = true, AutoPlay = false };
    VideoFrame? _gpuFrame, _cpuFrame;
    byte[] _pixels = [];
    WriteableBitmap? _bitmap;
    int _copying;   // 1 while a frame is on its way to the screen: later ones are skipped meanwhile
    int _generation;

    /// <summary>The picture, once the video is open; replaced when a video of another size is opened.</summary>
    public event Action<ImageSource>? Opened;
    public event Action? Failed;
    public event Action? Ended;

    public VideoPlayer(Dispatcher dispatcher)
    {
        _dispatcher = dispatcher;
        _player.MediaOpened += (_, _) =>
        {
            int generation = _generation;
            _dispatcher.BeginInvoke(() =>
            {
                if (generation != _generation) return;
                var session = _player.PlaybackSession;
                int width = (int)session.NaturalVideoWidth, height = (int)session.NaturalVideoHeight;
                if (width <= 0 || height <= 0)
                {
                    Failed?.Invoke();
                    return;
                }
                // Frames are copied from the graphics card into a bitmap of the video's size (already turned upright).
                _gpuFrame = VideoFrame.CreateAsDirect3D11SurfaceBacked(DirectXPixelFormat.B8G8R8A8UIntNormalized, width, height);
                _cpuFrame = new VideoFrame(BitmapPixelFormat.Bgra8, width, height, BitmapAlphaMode.Ignore);
                _pixels = new byte[width * height * 4];
                _bitmap = new WriteableBitmap(width, height, 96, 96, PixelFormats.Bgr32, null);
                Opened?.Invoke(_bitmap);
                _player.Play();
            });
        };
        _player.MediaFailed += (_, _) => _dispatcher.BeginInvoke(() => Failed?.Invoke());
        _player.MediaEnded += (_, _) => _dispatcher.BeginInvoke(() => Ended?.Invoke());
        _player.VideoFrameAvailable += async (player, _) =>
        {
            if (_gpuFrame is not { } gpu || _cpuFrame is not { } cpu || Interlocked.Exchange(ref _copying, 1) == 1) return;
            int generation = _generation;
            try
            {
                player.CopyFrameToVideoSurface(gpu.Direct3DSurface);
                await gpu.CopyToAsync(cpu);
                cpu.SoftwareBitmap.CopyToBuffer(_pixels.AsBuffer());
                await _dispatcher.InvokeAsync(() =>
                {
                    if (generation != _generation || _bitmap == null) return;
                    _bitmap.WritePixels(new Int32Rect(0, 0, _bitmap.PixelWidth, _bitmap.PixelHeight), _pixels, _bitmap.PixelWidth * 4, 0);
                });
            }
            catch (Exception)
            {
                // A frame lost while switching videos: the next one comes.
            }
            finally
            {
                Interlocked.Exchange(ref _copying, 0);
            }
        };
    }

    public async void Open(string path)
    {
        int generation = ++_generation;
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(path);
            if (generation != _generation) return;
            _player.Source = MediaSource.CreateFromStorageFile(file);
        }
        catch (Exception)
        {
            if (generation == _generation) Failed?.Invoke();
        }
    }

    public void Play() => _player.Play();
    public void Pause() => _player.Pause();

    public bool Playing => _player.PlaybackSession.PlaybackState == MediaPlaybackState.Playing;

    public TimeSpan Duration => _player.PlaybackSession.NaturalDuration;

    public TimeSpan Position
    {
        get => _player.PlaybackSession.Position;
        set => _player.PlaybackSession.Position = value;
    }

    public void Stop()
    {
        _generation++;
        _player.Pause();
        _player.Source = null;
        _gpuFrame = _cpuFrame = null;
        _bitmap = null;
    }

    public void Dispose() => _player.Dispose();
}
