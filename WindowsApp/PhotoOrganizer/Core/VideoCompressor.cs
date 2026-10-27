using System.Diagnostics;
using System.Globalization;
using System.IO.Compression;
using System.Net.Http;
using System.Text.Json;

namespace PhotoOrganizer.Core;

/// <summary>
/// Compresses videos with FFmpeg: HEVC (10 bits for HDR, the colour description kept, so HLG and PQ stay HDR), turned
/// upright, brought down to the size asked, sound and the capture date and place copied as they are. On the graphics
/// card when it can (NVIDIA, Intel, AMD), otherwise x265. FFmpeg is the one on the PATH, or downloaded once into the
/// data folder.
/// </summary>
public static class VideoCompressor
{
    /// <summary>A build with x265 and the hardware encoders (BtbN's, the one FFmpeg's site links to for Windows).</summary>
    const string DownloadUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip";

    static string DownloadedFolder => Path.Combine(AppData.Directory, "ffmpeg");

    static string? Find(string name)
    {
        string own = Path.Combine(DownloadedFolder, name);
        if (File.Exists(own)) return own;
        foreach (string folder in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            try
            {
                string candidate = Path.Combine(folder.Trim('"'), name);
                if (folder.Length > 0 && File.Exists(candidate)) return candidate;
            }
            catch (ArgumentException)
            {
            }
        }
        return null;
    }

    public static string? FFmpeg => Find("ffmpeg.exe");
    public static string? FFprobe => Find("ffprobe.exe");
    public static bool Available => FFmpeg != null && FFprobe != null;

    /// <summary>Downloads FFmpeg (about 200 MB) and keeps ffmpeg.exe and ffprobe.exe in the data folder.</summary>
    public static async Task DownloadAsync(IProgress<(long Received, long Total)>? progress, CancellationToken token)
    {
        using var client = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("PhotoOrganizer");
        string zip = Path.Combine(Path.GetTempPath(), $"photoorganizer-ffmpeg-{Guid.NewGuid():N}.zip");
        try
        {
            using (var response = await client.GetAsync(DownloadUrl, HttpCompletionOption.ResponseHeadersRead, token))
            {
                response.EnsureSuccessStatusCode();
                long total = response.Content.Headers.ContentLength ?? 0;
                await using var input = await response.Content.ReadAsStreamAsync(token);
                await using var output = File.Create(zip);
                var buffer = new byte[1 << 16];
                long received = 0;
                int read;
                while ((read = await input.ReadAsync(buffer, token)) > 0)
                {
                    await output.WriteAsync(buffer.AsMemory(0, read), token);
                    received += read;
                    progress?.Report((received, total));
                }
            }
            Directory.CreateDirectory(DownloadedFolder);
            using var archive = ZipFile.OpenRead(zip);
            foreach (string name in new[] { "ffmpeg.exe", "ffprobe.exe" })
            {
                var entry = archive.Entries.FirstOrDefault(e => e.Name.Equals(name, StringComparison.OrdinalIgnoreCase))
                            ?? throw new InvalidDataException(name + " is not in the archive");
                string target = Path.Combine(DownloadedFolder, name);
                entry.ExtractToFile(target + ".part", overwrite: true);
                File.Move(target + ".part", target, overwrite: true);
            }
        }
        finally
        {
            try { File.Delete(zip); } catch (IOException) { }
        }
    }

    // --- Reading a video ------------------------------------------------------------------------------------------

    /// <summary>What a video is; null when FFprobe cannot read it.</summary>
    public static VideoInfo? Probe(string path)
    {
        if (FFprobe is not { } probe) return null;
        string json = Run(probe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", path], TimeSpan.FromSeconds(30), out int code);
        if (code != 0 || json.Length == 0) return null;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            JsonElement? video = null, audio = null;
            foreach (var stream in root.GetProperty("streams").EnumerateArray())
            {
                string type = stream.TryGetProperty("codec_type", out var t) ? t.GetString() ?? "" : "";
                // A cover picture is a "video" stream too.
                bool picture = stream.TryGetProperty("disposition", out var d) && d.TryGetProperty("attached_pic", out var a) && a.GetInt32() == 1;
                if (type == "video" && !picture && video == null) video = stream;
                else if (type == "audio" && audio == null) audio = stream;
            }
            if (video is not { } v) return null;
            int width = Int(v, "width"), height = Int(v, "height");
            // Turned a quarter: the upright picture is the other way round.
            if (Math.Abs(Rotation(v)) % 180 == 90) (width, height) = (height, width);
            double fps = Rate(v, "avg_frame_rate") is > 0 and < 1000 and var average ? average : Rate(v, "r_frame_rate");
            var format = root.GetProperty("format");
            double duration = Double(format, "duration") is > 0 and var d0 ? d0 : Double(v, "duration");
            string pixelFormat = Text(v, "pix_fmt") ?? "";
            return new VideoInfo(width, height, fps, duration,
                                 Long(v, "bit_rate"), audio is { } au ? Long(au, "bit_rate") : 0, Long(format, "bit_rate"),
                                 Text(v, "codec_name") ?? "", Text(v, "color_primaries"), Text(v, "color_transfer"), Text(v, "color_space"),
                                 pixelFormat.Contains("10") || pixelFormat.Contains("12"));
        }
        catch (Exception e) when (e is JsonException or KeyNotFoundException or InvalidOperationException or FormatException)
        {
            return null;
        }
    }

    static string? Text(JsonElement e, string name) => e.TryGetProperty(name, out var p) && p.ValueKind == JsonValueKind.String ? p.GetString() : null;
    static int Int(JsonElement e, string name) => e.TryGetProperty(name, out var p) && p.TryGetInt32(out int v) ? v : 0;
    static long Long(JsonElement e, string name) => long.TryParse(Text(e, name), NumberStyles.Integer, CultureInfo.InvariantCulture, out long v) ? v : 0;
    static double Double(JsonElement e, string name) => double.TryParse(Text(e, name), NumberStyles.Float, CultureInfo.InvariantCulture, out double v) ? v : 0;

    static double Rate(JsonElement e, string name)
    {
        var parts = (Text(e, name) ?? "").Split('/');
        return parts.Length == 2 && double.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out double n)
               && double.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out double d) && d > 0 ? n / d : 0;
    }

    static int Rotation(JsonElement stream)
    {
        if (stream.TryGetProperty("side_data_list", out var list))
        {
            foreach (var side in list.EnumerateArray())
            {
                if (side.TryGetProperty("rotation", out var r) && r.TryGetDouble(out double degrees)) return (int)Math.Round(degrees);
            }
        }
        if (stream.TryGetProperty("tags", out var tags) && int.TryParse(Text(tags, "rotate"), out int rotate)) return rotate;
        return 0;
    }

    // --- Encoding -------------------------------------------------------------------------------------------------

    static string? _encoder;

    /// <summary>The encoder once it has been tried (see Encoder, which takes a moment the first time); null before.</summary>
    public static string? KnownEncoder => _encoder;

    /// <summary>The HEVC encoder to use: the graphics card's when it works with 10 bits, otherwise x265.</summary>
    public static string Encoder
    {
        get
        {
            if (_encoder != null) return _encoder;
            string chosen = "libx265";
            if (FFmpeg is { } ffmpeg)
            {
                foreach (string candidate in new[] { "hevc_nvenc", "hevc_qsv", "hevc_amf" })
                {
                    Run(ffmpeg, ["-hide_banner", "-v", "error", "-f", "lavfi", "-i", "color=c=gray:s=320x240:d=0.2", "-pix_fmt", "p010le",
                                 "-c:v", candidate, "-profile:v", "main10", "-f", "null", "-"], TimeSpan.FromSeconds(20), out int code);
                    if (code == 0)
                    {
                        chosen = candidate;
                        break;
                    }
                }
            }
            return _encoder = chosen;
        }
    }

    /// <summary>
    /// Writes the compressed video to `destination` (the source's container: MOV or MP4). `progress` gets 0…1. Returns
    /// null when it worked, what went wrong otherwise; the half-written file is removed.
    /// </summary>
    public static string? Compress(string source, string destination, VideoInfo info, VideoJob job, Action<double>? progress, CancellationToken token)
    {
        if (FFmpeg is not { } ffmpeg) return "FFmpeg not found";
        bool tenBit = info.TenBit || info.Hdr;
        string encoder = Encoder;
        string extension = Path.GetExtension(source).ToLowerInvariant();
        var args = new List<string> { "-hide_banner", "-nostdin", "-y", "-v", "error", "-i", source,
                                      "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0", "-map_metadata:s:v", "0:s:v:0",
                                      "-vf", $"scale={job.Width}:{job.Height}:flags=lanczos,format={(tenBit ? "p010le" : "yuv420p")}",
                                      "-c:v", encoder };
        string rate = (job.Bitrate / 1000).ToString(CultureInfo.InvariantCulture) + "k";
        string maxRate = (job.Bitrate * 3 / 2 / 1000).ToString(CultureInfo.InvariantCulture) + "k";
        string buffer = (job.Bitrate * 3 / 1000).ToString(CultureInfo.InvariantCulture) + "k";
        args.AddRange(encoder switch
        {
            "hevc_nvenc" => ["-preset", "p6", "-tune", "hq", "-rc", "vbr", "-multipass", "fullres", "-spatial-aq", "1", "-temporal-aq", "1"],
            "hevc_qsv" => ["-preset", "slower", "-look_ahead", "1"],
            "hevc_amf" => ["-quality", "quality", "-rc", "vbr_peak"],
            _ => ["-preset", "medium"],
        });
        args.AddRange(["-b:v", rate, "-maxrate", maxRate, "-bufsize", buffer, "-profile:v", tenBit ? "main10" : "main"]);
        // The colour description, so that HDR stays HDR (and SDR is not taken for something else).
        if (info.Primaries is { } primaries && primaries != "unknown") args.AddRange(["-color_primaries", primaries]);
        if (info.Transfer is { } transfer && transfer != "unknown") args.AddRange(["-color_trc", transfer]);
        if (info.Matrix is { } matrix && matrix != "unknown") args.AddRange(["-colorspace", matrix]);
        args.AddRange(["-tag:v", "hvc1", "-c:a", "copy", "-movflags", "+use_metadata_tags+faststart",
                       "-f", extension is ".mp4" or ".m4v" ? "mp4" : "mov", "-progress", "pipe:1", "-nostats", destination]);

        var start = new ProcessStartInfo(ffmpeg)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (string arg in args) start.ArgumentList.Add(arg);
        string errors = "";
        try
        {
            using var process = Process.Start(start)!;
            try { process.PriorityClass = ProcessPriorityClass.BelowNormal; } catch (InvalidOperationException) { }
            var stderr = process.StandardError.ReadToEndAsync();
            using (token.Register(() => { try { process.Kill(); } catch (InvalidOperationException) { } }))
            {
                string? line;
                while ((line = process.StandardOutput.ReadLine()) != null)
                {
                    if (line.StartsWith("out_time_us=", StringComparison.Ordinal) && long.TryParse(line[12..], out long micro) && info.Duration > 0)
                    {
                        progress?.Invoke(Math.Clamp(micro / 1e6 / info.Duration, 0, 1));
                    }
                }
                process.WaitForExit();
            }
            errors = stderr.Result.Trim();
            if (token.IsCancellationRequested) return Fail("cancelled");
            if (process.ExitCode != 0) return Fail(errors.Length > 0 ? errors.Split('\n').Last().Trim() : $"FFmpeg exit code {process.ExitCode}");
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or IOException)
        {
            return Fail(e.Message);
        }
        // What came out must be the whole video.
        if (Probe(destination) is not { } result || Math.Abs(result.Duration - info.Duration) > Math.Max(1, info.Duration * 0.02))
        {
            return Fail("the compressed video is incomplete");
        }
        return null;

        string Fail(string why)
        {
            try { File.Delete(destination); } catch (IOException) { }
            return why;
        }
    }

    static string Run(string exe, IEnumerable<string> args, TimeSpan timeout, out int exitCode)
    {
        var start = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (string arg in args) start.ArgumentList.Add(arg);
        try
        {
            using var process = Process.Start(start)!;
            var output = process.StandardOutput.ReadToEndAsync();
            var error = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(timeout))
            {
                try { process.Kill(); } catch (InvalidOperationException) { }
                exitCode = -1;
                return "";
            }
            exitCode = process.ExitCode;
            _ = error.Result;
            return output.Result;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or IOException)
        {
            exitCode = -1;
            return "";
        }
    }
}
