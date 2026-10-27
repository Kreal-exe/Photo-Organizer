using System.Diagnostics;
using static PhotoOrganizer.Core.Strings;
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
            int videoTracks = 0;
            foreach (var stream in root.GetProperty("streams").EnumerateArray())
            {
                string type = stream.TryGetProperty("codec_type", out var t) ? t.GetString() ?? "" : "";
                // A cover picture is a "video" stream too.
                bool picture = stream.TryGetProperty("disposition", out var d) && d.TryGetProperty("attached_pic", out var a) && a.GetInt32() == 1;
                if (type == "video" && !picture)
                {
                    videoTracks++;
                    video ??= stream;
                }
                else if (type == "audio" && audio == null)
                {
                    audio = stream;
                }
            }
            if (video is not { } v) return null;
            // What compressing would lose: the second eye of a 3D video (two views in one stream), another video track
            // (the depth of a Cinematic video). Such videos are left as they are, saying why.
            string? kept = Text(v, "view_ids_available") is { } views && views.Contains(',') ? L("пространственное (3D) видео — при сжатии пропал бы второй глаз")
                : videoTracks > 1 ? L("несколько видеодорожек (например, глубина Киноэффекта) — при сжатии они пропали бы") : null;
            int width = Int(v, "width"), height = Int(v, "height"), rotation = Rotation(v);
            // Turned a quarter: the upright picture is the other way round.
            if (Math.Abs(rotation) % 180 == 90) (width, height) = (height, width);
            double fps = Rate(v, "avg_frame_rate") is > 0 and < 1000 and var average ? average : Rate(v, "r_frame_rate");
            // The rate the file states (120 for an iPhone video with 30 real frames a second). Some files state their
            // time base instead (90 000): that is no frame rate — the real one is taken.
            double nominal = Rate(v, "r_frame_rate") is > 0 and <= 240 and var stated ? stated : fps;
            var format = root.GetProperty("format");
            double duration = Double(format, "duration") is > 0 and var d0 ? d0 : Double(v, "duration");
            string pixelFormat = Text(v, "pix_fmt") ?? "";
            // Compressed by the earlier version of this app: HEVC that FFmpeg wrote, with B-frames — jerky on phones.
            var tags = format.TryGetProperty("tags", out var t0) && t0.ValueKind == JsonValueKind.Object ? t0 : (JsonElement?)null;
            // Written by FFmpeg (this app, or another tool): encoded again after the camera.
            bool reencoded = tags is { } formatTags && Text(formatTags, "encoder") is { } encoder && encoder.StartsWith("Lavf", StringComparison.Ordinal);
            bool stutters = Text(v, "codec_name") == "hevc" && Int(v, "has_b_frames") > 0 && reencoded;
            // HDR with dynamic metadata — Dolby Vision (iPhone), HDR Vivid (Honor, Huawei), HDR10+ (Samsung): how bright
            // each scene is shown, which no encoder here writes again; HdrCarry puts it back into the compressed file.
            string? dynamic = Text(v, "color_transfer") is "arib-std-b67" or "smpte2084" ? DynamicHdr(path) : null;
            bool flat = Int(v, "has_b_frames") > 0 && FlatTimestamps(path);
            return new VideoInfo(width, height, fps, duration,
                                 Long(v, "bit_rate"), audio is { } au ? Long(au, "bit_rate") : 0, Long(format, "bit_rate"),
                                 Text(v, "codec_name") ?? "", Text(v, "color_primaries"), Text(v, "color_transfer"), Text(v, "color_space"),
                                 pixelFormat.Contains("10") || pixelFormat.Contains("12"), rotation, kept, stutters, nominal, dynamic, flat, reencoded);
        }
        catch (Exception e) when (e is JsonException or KeyNotFoundException or InvalidOperationException or FormatException)
        {
            return null;
        }
    }

    /// <summary>
    /// Whether the first frames are all marked shown at the moment they are decoded (pts = dts) — in a video with
    /// B-frames that cannot be: the moments are wrong (see VideoInfo.FlatTimestamps).
    /// </summary>
    static bool FlatTimestamps(string path)
    {
        if (FFprobe is not { } probe) return false;
        string output = Run(probe, ["-v", "error", "-select_streams", "v:0", "-read_intervals", "%+#60",
                                    "-show_entries", "packet=pts,dts", "-of", "csv=p=0", path], TimeSpan.FromSeconds(30), out _);
        var lines = output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Where(l => l.Length > 0).ToList();
        return lines.Count >= 10 && lines.All(l => l.Split(',') is { Length: >= 2 } p && p[0] == p[1]);
    }

    /// <summary>"dolby vision", "vivid" or "hdr10+" when the first frame carries dynamic HDR metadata of that kind; null otherwise.</summary>
    static string? DynamicHdr(string path)
    {
        if (FFprobe is not { } probe) return null;
        string output = Run(probe, ["-v", "error", "-select_streams", "v:0", "-show_frames", "-read_intervals", "%+#1",
                                    "-show_entries", "frame_side_data=side_data_type", "-of", "csv=p=0", path], TimeSpan.FromSeconds(30), out _);
        return output.Contains("Dolby Vision", StringComparison.OrdinalIgnoreCase) ? "dolby vision"
             : output.Contains("Vivid", StringComparison.OrdinalIgnoreCase) ? "vivid"
             : output.Contains("SMPTE2094-40", StringComparison.OrdinalIgnoreCase) || output.Contains("HDR10+", StringComparison.OrdinalIgnoreCase) ? "hdr10+" : null;
    }

    /// <summary>What Probe found, by file, while the file stays the same size and date (video-info.json).</summary>
    sealed record ProbedFile(long Size, long Written, VideoInfo Info);

    static readonly Lazy<System.Collections.Concurrent.ConcurrentDictionary<string, ProbedFile>> Probed = new(() =>
    {
        try
        {
            if (File.Exists(ProbedPath) && JsonSerializer.Deserialize<Dictionary<string, ProbedFile>>(File.ReadAllText(ProbedPath)) is { } saved)
                return new(saved, StringComparer.OrdinalIgnoreCase);
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException or NotSupportedException)
        {
        }
        return new(StringComparer.OrdinalIgnoreCase);
    });
    // 2: 3D videos and videos of several video tracks are told (VideoInfo.Kept); what was read before is read again.
    // 4: the videos the earlier version compressed with B-frames are told (VideoInfo.Stutters), and the stated frame rate.
    // 6: videos with dynamic HDR metadata are told (VideoInfo.DynamicHdr), to carry it over.
    // 7: videos whose frames are marked shown in the order stored, though reordered (FlatTimestamps).
    static string ProbedPath => AppData.File("video-info-8.json");
    static int _probedChanged;

    /// <summary>
    /// Probe, remembered: a video read once is not read again until it changes, so the compress window knows the
    /// library's videos at once the next time. SaveProbed writes what was learned.
    /// </summary>
    public static VideoInfo? ProbeRemembered(string path)
    {
        long size, written;
        try
        {
            var file = new FileInfo(path);
            size = file.Length;
            written = file.LastWriteTimeUtc.Ticks;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
        if (Probed.Value.TryGetValue(path, out var known) && known.Size == size && known.Written == written) return known.Info;
        var info = Probe(path);
        if (info == null) return null;
        Probed.Value[path] = new ProbedFile(size, written, info);
        Interlocked.Exchange(ref _probedChanged, 1);
        return info;
    }

    public static void SaveProbed()
    {
        if (Interlocked.Exchange(ref _probedChanged, 0) == 0) return;
        try
        {
            AppData.WriteAtomically(ProbedPath, JsonSerializer.Serialize(new Dictionary<string, ProbedFile>(Probed.Value)));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
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
    /// Writes the compressed video to `destination` (the source's container: MOV or MP4). `progress` gets how far it is
    /// and how fast. Returns null when it worked, what went wrong otherwise; the half-written file is removed.
    /// With NVIDIA everything is done on the graphics card — decoding, scaling, encoding — and a turned video keeps its
    /// turn as a mark in the file instead of having its pixels turned (that took the processor: 4K came down 40 %
    /// faster); anything the card cannot decode is done the usual way.
    /// </summary>
    /// <summary>
    /// The moments the frames are shown at, in order, with how long each stays: the frames from the start the edit list
    /// sets (frames before it are marked with a moment below zero). Null when the file can't be read.
    /// </summary>
    static List<(double At, double For)>? Moments(string path)
    {
        if (FFprobe is not { } probe) return null;
        string output = Run(probe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time,duration_time", "-of", "csv=p=0", path],
                            TimeSpan.FromMinutes(5), out int code);
        if (code != 0) return null;
        var moments = new List<(double, double)>();
        foreach (string line in output.Split('\n'))
        {
            string[] parts = line.Trim().TrimEnd(',').Split(',');
            if (parts.Length == 0 || parts[0].Length == 0) continue;
            if (!double.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out double at)) return null;
            double lasts = parts.Length > 1 && double.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out double d) ? d : 0;
            if (at >= -0.0001) moments.Add((at, lasts));
        }
        moments.Sort((a, b) => a.Item1.CompareTo(b.Item1));
        return moments;
    }

    /// <summary>
    /// When the video's picture ends: the last frame's moment plus how long it stays — a last frame that stays far
    /// longer than the one before (an iPhone video trimmed in Photos, 1.5 s) counted as long as that one, the way the
    /// encoding cuts it (see the setts filter in Encode).
    /// </summary>
    static double PictureEnd(List<(double At, double For)> moments)
    {
        if (moments.Count == 0) return 0;
        var (at, lasts) = moments[^1];
        double before = moments.Count > 1 ? moments[^2].For : 0;
        if (before > 0 && lasts > 4 * before) lasts = before;
        return at + lasts;
    }

    public static string? Compress(string source, string destination, VideoInfo info, VideoJob job, Action<VideoProgress>? progress, CancellationToken token)
    {
        if (FFmpeg is null) return "FFmpeg not found";
        if (info.Kept is { } why) return why;
        string? error = null;
        // Some 8-bit iPhone videos (spatial ones, of two layers) stop NVIDIA's 8-bit encoder short; 10-bit HEVC (Main 10,
        // which every device that plays HEVC plays) takes them.
        foreach (bool tenBit in info.TenBit || info.Hdr ? [true] : new[] { false, true })
        {
            if (Encoder == "hevc_nvenc" && info.Rotation % 90 == 0)
            {
                error = Encode(source, destination, info, job, onCard: true, tenBit, progress, token);
                if (error == null || token.IsCancellationRequested) return error;
            }
            error = Encode(source, destination, info, job, onCard: false, tenBit, progress, token);
            if (error == null || token.IsCancellationRequested) return error;
        }
        return error;
    }

    static string? Encode(string source, string destination, VideoInfo info, VideoJob job, bool onCard, bool tenBit, Action<VideoProgress>? progress, CancellationToken token)
    {
        string ffmpeg = FFmpeg!;
        string encoder = Encoder;
        string extension = Path.GetExtension(source).ToLowerInvariant();
        string format = extension is ".mp4" or ".m4v" ? "mp4" : "mov";
        bool turned = Math.Abs(info.Rotation) % 180 == 90;
        var args = new List<string> { "-hide_banner", "-nostdin", "-y", "-v", "error" };
        // Frames stored out of order but marked shown in the order stored: the moments are made afresh from the order
        // they are decoded in (the right one), a frame apart.
        string retime = info.FlatTimestamps && info.Fps > 0 ? $"setpts=N/({info.Fps.ToString("0.###", CultureInfo.InvariantCulture)}*TB)," : "";
        if (onCard)
        {
            // Decoded and scaled on the card at the size the frames are stored at (job's sizes are upright).
            int width = turned ? job.Height : job.Width, height = turned ? job.Width : job.Height;
            args.AddRange(["-hwaccel", "cuda", "-hwaccel_output_format", "cuda", "-noautorotate", "-i", source,
                           "-vf", $"{retime}scale_cuda={width}:{height}:interp_algo=lanczos:format={(tenBit ? "p010le" : "nv12")}"]);
        }
        else
        {
            args.AddRange(["-i", source, "-vf", $"{retime}scale={job.Width}:{job.Height}:flags=lanczos,format={(tenBit ? "p010le" : "yuv420p")}"]);
        }
        args.AddRange(["-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0", "-map_metadata:s:v", "0:s:v:0", "-c:v", encoder]);
        // To a bitrate, as before — the plan's for a compressing (what looked like the original even frame by frame), the
        // video's own for a rebuild (the same file without B-frames: 5 % larger, VMAF 99 against it on 24 videos).
        long original = info.VideoBitrate > 0 ? info.VideoBitrate : Math.Max(job.Bitrate, info.TotalBitrate - info.AudioBitrate);
        long target = job.Rebuild ? original : job.Bitrate;
        // The encoder shares the bitrate out by the stated frame rate: for frames at varying intervals (an iPhone states
        // 120 for 30 real ones) it would give each a quarter of its share — the budget is scaled by how many there are.
        if (info.NominalFps > 0 && info.Fps > 0) target = (long)(target * Math.Clamp(info.NominalFps / info.Fps, 1, 4));
        target = Math.Max(target, 500_000);
        string rate = (target / 1000).ToString(CultureInfo.InvariantCulture) + "k";
        string maxRate = (target * 3 / 2 / 1000).ToString(CultureInfo.InvariantCulture) + "k";
        string buffer = (target * 3 / 1000).ToString(CultureInfo.InvariantCulture) + "k";
        // Built as a camera builds it: no B-frames (frames that wait for later ones) and a key frame every second. With
        // B-frames and a key frame every four seconds, phones played it in jerks; the computer smoothly.
        string keyEvery = Math.Max(1, (int)Math.Round(info.Fps > 0 ? info.Fps : 30)).ToString(CultureInfo.InvariantCulture);
        args.AddRange(encoder switch
        {
            // A rebuild at the fastest preset: the card's encoder is the limit (1 200 frames a second, three videos at once).
            "hevc_nvenc" when job.Rebuild => ["-preset", "p1", "-tune", "hq", "-rc", "vbr", "-b:v", rate, "-maxrate", maxRate, "-bufsize", buffer,
                                              "-bf", "0", "-g", keyEvery],
            "hevc_nvenc" => ["-preset", "p6", "-tune", "hq", "-rc", "vbr", "-b:v", rate, "-maxrate", maxRate, "-bufsize", buffer,
                             "-multipass", "fullres", "-spatial-aq", "1", "-temporal-aq", "1", "-bf", "0", "-g", keyEvery],
            "hevc_qsv" => ["-preset", "slower", "-b:v", rate, "-maxrate", maxRate, "-bufsize", buffer, "-bf", "0", "-g", keyEvery],
            "hevc_amf" => ["-quality", "quality", "-rc", "vbr_peak", "-b:v", rate, "-maxrate", maxRate, "-bf", "0", "-g", keyEvery],
            _ => ["-preset", "medium", "-b:v", rate, "-x265-params", $"vbv-maxrate={target * 3 / 2 / 1000}:vbv-bufsize={target * 3 / 1000}:bframes=0:keyint={keyEvery}"],
        });
        args.AddRange(["-profile:v", tenBit ? "main10" : "main"]);
        // Every frame at its own moment: the encoder in the source's time base. In one of a frame a second (a video
        // stated 24 with frames 1/30 s apart) frames that met on one tick were dropped — 50 of 549.
        args.AddRange(["-fps_mode", "passthrough", "-enc_time_base:v", "demux"]);
        // The colour description, so that HDR stays HDR (and SDR is not taken for something else).
        if (info.Primaries is { } primaries && primaries != "unknown") args.AddRange(["-color_primaries", primaries]);
        if (info.Transfer is { } transfer && transfer != "unknown") args.AddRange(["-color_trc", transfer]);
        if (info.Matrix is { } matrix && matrix != "unknown") args.AddRange(["-colorspace", matrix]);
        // A turn is written afterwards (FFmpeg drops it on the way through the card): into another file first.
        bool mark = onCard && info.Rotation != 0;
        string encoded = mark ? destination + ".turn" : destination;
        // An iPhone video trimmed in Photos (or shot in some modes) gives its last frame a long duration (1.5 s) that only
        // the original's edit list cuts off; FFmpeg leaves the edit list behind, so the video would run on, frozen. The
        // frame keeps the duration of the one before it — the moments the frames are shown at stay as they were.
        args.AddRange(["-bsf:v", "setts=duration='if(gt(DURATION,4*PREV_INDURATION)*gt(PREV_INDURATION,0),PREV_INDURATION,DURATION)'"]);
        args.AddRange(["-tag:v", "hvc1", "-c:a", "copy", "-movflags", "+use_metadata_tags+faststart",
                       "-f", format, "-progress", "pipe:1", "-nostats", encoded]);

        var start = new ProcessStartInfo(ffmpeg)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (string arg in args) start.ArgumentList.Add(arg);
        try
        {
            using var process = Process.Start(start)!;
            try { process.PriorityClass = ProcessPriorityClass.BelowNormal; } catch (InvalidOperationException) { }
            var stderr = process.StandardError.ReadToEndAsync();
            using (token.Register(() => { try { process.Kill(); } catch (InvalidOperationException) { } }))
            {
                // FFmpeg reports a block of key=value lines every half second, closed by "progress=…".
                double speed = 0, fps = 0;
                long bytes = 0, micro = 0;
                string? line;
                while ((line = process.StandardOutput.ReadLine()) != null)
                {
                    int equals = line.IndexOf('=');
                    if (equals <= 0) continue;
                    string key = line[..equals], value = line[(equals + 1)..].Trim();
                    switch (key)
                    {
                        case "out_time_us": long.TryParse(value, out micro); break;
                        case "total_size": long.TryParse(value, out bytes); break;
                        case "fps": double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out fps); break;
                        case "speed": double.TryParse(value.TrimEnd('x'), NumberStyles.Float, CultureInfo.InvariantCulture, out speed); break;
                        case "progress":
                            if (info.Duration > 0) progress?.Invoke(new VideoProgress(Math.Clamp(micro / 1e6 / info.Duration, 0, 1), speed, fps, bytes, onCard));
                            break;
                    }
                }
                process.WaitForExit();
            }
            string errors = stderr.Result.Trim();
            if (token.IsCancellationRequested) return Fail("cancelled");
            if (process.ExitCode != 0) return Fail(errors.Length > 0 ? errors.Split('\n').Last().Trim() : $"FFmpeg exit code {process.ExitCode}");
            if (mark)
            {
                // The turn the video had, written as a mark into the container (a copy: a moment).
                Run(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-v", "error",
                             "-display_rotation:v:0", info.Rotation.ToString(CultureInfo.InvariantCulture), "-i", encoded,
                             "-map", "0", "-c", "copy", "-map_metadata", "0", "-movflags", "+use_metadata_tags+faststart", "-f", format, destination],
                    TimeSpan.FromMinutes(10), out int code);
                TryDelete(encoded);
                if (code != 0) return Fail("the turn of the video could not be written");
            }
            if (info.DynamicHdr != null)
            {
                // The original's dynamic HDR metadata into every frame (FFmpeg's encoders drop it): the phone shows the
                // video as bright as the original, scene by scene.
                var (_, carryError) = HdrCarry.Carry(source, destination, destination + ".hdr");
                if (carryError != null) return Fail("the HDR metadata could not be carried over: " + carryError);
                File.Move(destination + ".hdr", destination, overwrite: true);
            }
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or IOException or UnauthorizedAccessException)
        {
            return Fail(e.Message);
        }
        // What came out must be the whole video, turned as it was. The length is compared by the frames shown, not by
        // what the container says: a file whose last frame stays 0.5 s (written by an earlier version of this app, the
        // edit list that cut it lost) says 9.26 s where its picture, and the new file, run 8.7.
        var result = Probe(destination);
        var was = Moments(source);
        var now = result != null ? Moments(destination) : null;
        if (result == null || was == null || now == null) return Fail("the compressed video could not be read back");
        double wasEnd = PictureEnd(was), nowEnd = PictureEnd(now);
        if (Math.Abs(nowEnd - wasEnd) > Math.Max(1, wasEnd * 0.02)
            || (result.Width > result.Height) != (info.Width > info.Height) || result.DynamicHdr != info.DynamicHdr)
        {
            return Fail("the compressed video is incomplete");
        }
        // A rebuild replaces a file whose original is gone: every frame there, none of them waiting for a later one.
        if (job.Rebuild)
        {
            var differences = new List<string>();
            if (Math.Abs(nowEnd - wasEnd) > 0.1)
                differences.Add($"runs {nowEnd.ToString("0.###", CultureInfo.InvariantCulture)} s instead of {wasEnd.ToString("0.###", CultureInfo.InvariantCulture)} s");
            if (result.Stutters) differences.Add("still has B-frames");
            if (result.Rotation != info.Rotation) differences.Add($"rotation {result.Rotation} instead of {info.Rotation}");
            if (result.Transfer != info.Transfer) differences.Add($"transfer {result.Transfer} instead of {info.Transfer}");
            if (result.TenBit != info.TenBit) differences.Add(result.TenBit ? "10-bit instead of 8-bit" : "8-bit instead of 10-bit");
            if (now.Count != was.Count) differences.Add($"{now.Count} frames instead of {was.Count}");
            else
            {
                // Every frame at the moment it was at (a thousandth of a second: the time bases differ).
                int moved = 0;
                for (int i = 0; i < was.Count; i++) if (Math.Abs(now[i].At - was[i].At) > 0.002) moved++;
                if (moved > 0) differences.Add($"{moved} frames at other moments");
            }
            if (differences.Count > 0) return Fail("the rebuilt video is not the same as the old one: " + string.Join(", ", differences));
        }
        return null;

        string Fail(string why)
        {
            TryDelete(destination);
            TryDelete(destination + ".turn");
            TryDelete(destination + ".hdr");
            return why;
        }
    }

    static void TryDelete(string path)
    {
        try { File.Delete(path); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
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
