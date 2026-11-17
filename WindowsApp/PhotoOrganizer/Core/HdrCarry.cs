using System.Buffers.Binary;

namespace PhotoOrganizer.Core;

/// <summary>
/// Carries dynamic HDR metadata from an original video into its compressed version, which no encoder here writes
/// again: HDR Vivid (Honor, Huawei) and HDR10+ (Samsung) as a message in every frame, Dolby Vision (iPhone) as a layer in
/// every frame — how bright each scene is to be shown — and the boxes that announce them in the track's description
/// (cuvv, dvcC). Without them a phone shows the video brighter. The compressed file is written again around the same
/// pictures, nothing encoded: each frame gets what the original's frame shown at the same moment had (an iPhone's
/// frames are stored in another order than they are shown).
/// </summary>
public static class HdrCarry
{
    /// <summary>The boxes of the track's description that announce dynamic HDR.</summary>
    static readonly string[] DescriptionBoxes = ["cuvv", "dvcC", "dvvC", "dvwC"];

    /// <summary>
    /// Writes `output`: `encoded` with the original's dynamic HDR metadata in every frame. Returns how many frames got
    /// it, or an error; `output` is only valid when there is no error.
    /// </summary>
    public static (int Frames, string? Error) Carry(string original, string encoded, string output)
    {
        try
        {
            var source = Movie.Read(original);
            var target = Movie.Read(encoded);
            var sourceVideo = source.VideoTrack() ?? throw new InvalidDataException("no video track in the original");
            var targetVideo = target.VideoTrack() ?? throw new InvalidDataException("no video track in the compressed file");

            // What each frame of the original carries, by the moment it is shown.
            using var sourceFile = File.OpenRead(original);
            var carried = new SortedList<long, List<byte[]>>();
            long sourceStart = sourceVideo.FirstShown;
            for (int i = 0; i < sourceVideo.Samples.Count; i++)
            {
                var sample = sourceVideo.Samples[i];
                var nals = Nals(ReadAt(sourceFile, sample.Offset, sample.Size), sourceVideo.LengthSize)
                    .Where(n => IsCarried(n)).ToList();
                if (nals.Count == 0) continue;
                long moment = (long)Math.Round((sample.Shown - sourceStart) * 1_000_000.0 / sourceVideo.Timescale);
                carried[moment] = nals;
            }
            if (carried.Count == 0) return (0, "the original has no dynamic HDR metadata");

            // Into the compressed frames, by the same moment (within half a frame).
            using var targetFile = File.OpenRead(encoded);
            long targetStart = targetVideo.FirstShown;
            var keys = carried.Keys;
            var newSamples = new byte[targetVideo.Samples.Count][];
            int matched = 0;
            var used = new HashSet<int>();
            for (int i = 0; i < targetVideo.Samples.Count; i++)
            {
                var sample = targetVideo.Samples[i];
                byte[] data = ReadAt(targetFile, sample.Offset, sample.Size);
                long moment = (long)Math.Round((sample.Shown - targetStart) * 1_000_000.0 / targetVideo.Timescale);
                long frame = (long)Math.Round(sample.Duration * 1_000_000.0 / targetVideo.Timescale);
                int at = Nearest(keys, moment);
                if (at >= 0 && Math.Abs(keys[at] - moment) <= Math.Max(frame / 2, 1000))
                {
                    if (!used.Add(at)) return (matched, "two frames of the compressed video fall on one of the original");
                    data = Insert(data, targetVideo.LengthSize, carried.Values[at]);
                    matched++;
                }
                newSamples[i] = data;
            }
            if (matched < targetVideo.Samples.Count * 0.98)
                return (matched, $"only {matched} of {targetVideo.Samples.Count} frames found their original");

            // The announcing boxes, into the compressed track's description.
            var sourceBoxes = sourceVideo.SampleEntry.Children ?? [];
            var targetBoxes = targetVideo.SampleEntry.Children ??= [];
            var extra = sourceBoxes.Where(b => DescriptionBoxes.Contains(b.Type) && targetBoxes.All(t => t.Type != b.Type)).ToList();
            targetBoxes.AddRange(extra);

            target.Write(output, targetVideo, newSamples);
            return (matched, null);
        }
        catch (Exception e) when (e is IOException or InvalidDataException or ArgumentException or EndOfStreamException or IndexOutOfRangeException)
        {
            return (0, e.Message);
        }
    }

    /// <summary>
    /// Writes `output`: the original with its picture taken from `encoded` — the compressed video track in place of the
    /// original's, everything else the original's own, byte for byte: the sound (with the AAC priming frames its edit list
    /// hides, which FFmpeg drops), Apple's timed metadata tracks (mebx: FFmpeg cannot write them and leaves stubs), the
    /// date, the place, the camera. Returns null when it worked, why not otherwise; `output` is only valid without error.
    /// </summary>
    public static string? Transplant(string original, string encoded, string output)
    {
        try
        {
            var source = Movie.Read(original);
            var target = Movie.Read(encoded);
            if (source.Tracks.Count(t => t.Video) != 1) return "the original has more than one video track";
            var oldVideo = source.VideoTrack()!;
            var newVideo = target.VideoTrack() ?? throw new InvalidDataException("no video track in the compressed file");
            // A fragmented file keeps its samples outside the index, which this does not read.
            if (source.Tracks.Any(t => t.Samples.Count == 0)) return "a track of the original keeps its samples elsewhere (a fragmented file)";
            // The compressed track under the original's number (the metadata tracks point at the video by it), its times
            // in the original's movie time scale.
            var oldTkhd = oldVideo.Trak.Child("tkhd")!.Data;
            var newTkhd = newVideo.Trak.Child("tkhd")!.Data;
            uint id = BinaryPrimitives.ReadUInt32BigEndian(oldTkhd.AsSpan(oldTkhd[0] == 1 ? 20 : 12));
            BinaryPrimitives.WriteUInt32BigEndian(newTkhd.AsSpan(newTkhd[0] == 1 ? 20 : 12), id);
            long from = MovieTimescale(target.Moov), to = MovieTimescale(source.Moov);
            if (from != to)
            {
                if (newTkhd[0] == 1) BinaryPrimitives.WriteUInt64BigEndian(newTkhd.AsSpan(28), (ulong)Rescale((long)BinaryPrimitives.ReadUInt64BigEndian(newTkhd.AsSpan(28)), from, to));
                else BinaryPrimitives.WriteUInt32BigEndian(newTkhd.AsSpan(20), (uint)Rescale(BinaryPrimitives.ReadUInt32BigEndian(newTkhd.AsSpan(20)), from, to));
                if (newVideo.Trak.Child("edts")?.Child("elst") is { } elst)
                {
                    var d = elst.Data;
                    int version = d[0], count = (int)BinaryPrimitives.ReadUInt32BigEndian(d.AsSpan(4)), at = 8;
                    for (int i = 0; i < count; i++, at += version == 1 ? 20 : 12)
                    {
                        if (version == 1) BinaryPrimitives.WriteUInt64BigEndian(d.AsSpan(at), (ulong)Rescale((long)BinaryPrimitives.ReadUInt64BigEndian(d.AsSpan(at)), from, to));
                        else BinaryPrimitives.WriteUInt32BigEndian(d.AsSpan(at), (uint)Rescale(BinaryPrimitives.ReadUInt32BigEndian(d.AsSpan(at)), from, to));
                    }
                }
            }
            source.Moov.Children![source.Moov.Children.IndexOf(oldVideo.Trak)] = newVideo.Trak;
            source.Tracks[source.Tracks.IndexOf(oldVideo)] = newVideo;
            source.Write(output);
            return null;
        }
        catch (Exception e) when (e is IOException or InvalidDataException or ArgumentException or EndOfStreamException or IndexOutOfRangeException or InvalidOperationException or NullReferenceException)
        {
            return e.Message;
        }
    }

    static long MovieTimescale(Box moov)
    {
        var mvhd = moov.Child("mvhd")?.Data ?? throw new InvalidDataException("the movie has no header");
        return BinaryPrimitives.ReadUInt32BigEndian(mvhd.AsSpan(mvhd[0] == 1 ? 20 : 12));
    }

    static long Rescale(long value, long from, long to) => (long)Math.Round(value * (double)to / from);

    /// <summary>A message (SEI) of ITU-T T.35 user data — HDR Vivid, HDR10+ — or of the ambient light, or a Dolby Vision layer (NAL type 62).</summary>
    static bool IsCarried(byte[] nal)
    {
        if (nal.Length < 3) return false;
        int type = (nal[0] >> 1) & 0x3F;
        if (type == 62) return true;                                     // Dolby Vision RPU
        if (type != 39) return false;                                    // prefix SEI
        int i = 2, payloadType = 0;
        while (i < nal.Length && nal[i] == 0xFF) { payloadType += 255; i++; }
        if (i >= nal.Length) return false;
        payloadType += nal[i];
        return payloadType is 4 or 148;                                  // user data registered by ITU-T T.35; the ambient light it was made for
    }

    static List<byte[]> Nals(byte[] sample, int lengthSize)
    {
        var nals = new List<byte[]>();
        int at = 0;
        while (at + lengthSize <= sample.Length)
        {
            int length = 0;
            for (int i = 0; i < lengthSize; i++) length = (length << 8) | sample[at + i];
            at += lengthSize;
            if (length <= 0 || at + length > sample.Length) throw new InvalidDataException("a frame of the video cannot be read");
            nals.Add(sample[at..(at + length)]);
            at += length;
        }
        return nals;
    }

    /// <summary>The frame with the messages before its picture and the Dolby Vision layer last, as the format wants them.</summary>
    static byte[] Insert(byte[] sample, int lengthSize, List<byte[]> carried)
    {
        var nals = Nals(sample, lengthSize);
        int firstPicture = nals.FindIndex(n => ((n[0] >> 1) & 0x3F) < 32);
        if (firstPicture < 0) firstPicture = nals.Count;
        var messages = carried.Where(n => ((n[0] >> 1) & 0x3F) == 39).ToList();
        var layers = carried.Where(n => ((n[0] >> 1) & 0x3F) == 62).ToList();
        var ordered = nals.Take(firstPicture).Concat(messages).Concat(nals.Skip(firstPicture)).Concat(layers);
        using var stream = new MemoryStream(sample.Length + carried.Sum(n => n.Length + lengthSize));
        foreach (var nal in ordered)
        {
            for (int i = lengthSize - 1; i >= 0; i--) stream.WriteByte((byte)(nal.Length >> (8 * i)));
            stream.Write(nal);
        }
        return stream.ToArray();
    }

    static int Nearest(IList<long> keys, long value)
    {
        int low = 0, high = keys.Count - 1;
        if (high < 0) return -1;
        while (low < high)
        {
            int mid = (low + high) / 2;
            if (keys[mid] < value) low = mid + 1; else high = mid;
        }
        if (low > 0 && Math.Abs(keys[low - 1] - value) <= Math.Abs(keys[low] - value)) low--;
        return low;
    }

    static byte[] ReadAt(FileStream file, long offset, int size)
    {
        var data = new byte[size];
        file.Position = offset;
        file.ReadExactly(data);
        return data;
    }

    // --- The MP4 structure ------------------------------------------------------------------------------------------

    /// <summary>A box: its type, and either its own bytes or the boxes inside it (after `Head`, the bytes before them).</summary>
    sealed class Box(string type)
    {
        public string Type = type;
        public byte[] Data = [];
        public byte[] Head = [];
        public List<Box>? Children;

        public long Size => 8 + (Children == null ? Data.Length : Head.Length + Children.Sum(c => c.Size));

        public void WriteTo(Stream stream)
        {
            long size = Size;
            if (size > uint.MaxValue) throw new InvalidDataException("a box too large");
            Span<byte> header = stackalloc byte[8];
            BinaryPrimitives.WriteUInt32BigEndian(header, (uint)size);
            System.Text.Encoding.Latin1.GetBytes(Type, header[4..]);
            stream.Write(header);
            if (Children == null)
            {
                stream.Write(Data);
                return;
            }
            stream.Write(Head);
            foreach (var child in Children) child.WriteTo(stream);
        }

        public Box? Child(string type) => Children?.FirstOrDefault(c => c.Type == type);
    }

    static readonly HashSet<string> Containers = ["moov", "trak", "mdia", "minf", "stbl", "edts", "dinf", "mvex"];
    static readonly HashSet<string> VisualEntries = ["hvc1", "hev1", "dvh1", "dvhe", "avc1", "avc3"];

    static List<Box> ParseBoxes(byte[] data, int start, int end)
    {
        var boxes = new List<Box>();
        int at = start;
        while (at + 8 <= end)
        {
            long size = BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(at));
            int header = 8;
            if (size == 1) { size = (long)BinaryPrimitives.ReadUInt64BigEndian(data.AsSpan(at + 8)); header = 16; }
            else if (size == 0) size = end - at;
            if (size < header || at + size > end) throw new InvalidDataException("the movie's index is damaged");
            string type = System.Text.Encoding.Latin1.GetString(data, at + 4, 4);
            int bodyStart = at + header, bodyEnd = (int)(at + size);
            var box = new Box(type);
            if (Containers.Contains(type))
            {
                box.Children = ParseBoxes(data, bodyStart, bodyEnd);
            }
            else if (type == "stsd")
            {
                box.Head = data[bodyStart..(bodyStart + 8)];
                box.Children = ParseBoxes(data, bodyStart + 8, bodyEnd);
            }
            else if (VisualEntries.Contains(type))
            {
                box.Head = data[bodyStart..(bodyStart + 78)];
                box.Children = ParseBoxes(data, bodyStart + 78, bodyEnd);
            }
            else
            {
                box.Data = data[bodyStart..bodyEnd];
            }
            boxes.Add(box);
            at = bodyEnd;
        }
        return boxes;
    }

    sealed record Sample(long Offset, int Size, long Decoded, long Shown, long Duration);

    sealed class Track
    {
        public Box Trak = null!, Stbl = null!, SampleEntry = null!;
        /// <summary>The file the track's samples are in.</summary>
        public string Path = "";
        public long Timescale, MediaStart;
        /// <summary>
        /// The moment the first frame is shown, in the track's time: the edit's start, or — when the frames are shown
        /// later than decoded (an iPhone's, by two frames) and the edit starts at 0 — the earliest frame's moment, as
        /// players take it.
        /// </summary>
        public long FirstShown => Samples.Where(s => s.Shown >= MediaStart).Select(s => s.Shown).DefaultIfEmpty(MediaStart).Min();
        public int LengthSize = 4;
        public bool Video;
        public List<Sample> Samples = [];
        /// <summary>The chunks: where each starts and which samples it holds.</summary>
        public List<(long Offset, int First, int Count)> Chunks = [];
    }

    sealed class Movie
    {
        public Box Ftyp = null!, Moov = null!;
        public List<Track> Tracks = [];

        public Track? VideoTrack() => Tracks.FirstOrDefault(t => t.Video);

        public static Movie Read(string path)
        {
            using var file = File.OpenRead(path);
            var movie = new Movie();
            long position = 0, length = file.Length;
            var header = new byte[16];
            while (position + 8 <= length)
            {
                file.Position = position;
                file.ReadExactly(header, 0, 8);
                long size = BinaryPrimitives.ReadUInt32BigEndian(header);
                int headerSize = 8;
                if (size == 1) { file.ReadExactly(header, 8, 8); size = (long)BinaryPrimitives.ReadUInt64BigEndian(header.AsSpan(8)); headerSize = 16; }
                else if (size == 0) size = length - position;
                string type = System.Text.Encoding.Latin1.GetString(header, 4, 4);
                if (type is "moov" or "ftyp")
                {
                    var body = new byte[size - headerSize];
                    file.ReadExactly(body);
                    var box = new Box(type);
                    if (type == "moov") box.Children = ParseBoxes(body, 0, body.Length); else box.Data = body;
                    if (type == "moov") movie.Moov = box; else movie.Ftyp = box;
                }
                position += size;
            }
            if (movie.Moov == null || movie.Ftyp == null) throw new InvalidDataException("not an MP4 or MOV");
            foreach (var trak in movie.Moov.Children!.Where(b => b.Type == "trak"))
            {
                var track = ReadTrack(trak);
                track.Path = path;
                movie.Tracks.Add(track);
            }
            return movie;
        }

        static Track ReadTrack(Box trak)
        {
            var track = new Track { Trak = trak };
            var mdia = trak.Child("mdia") ?? throw new InvalidDataException("a track without media");
            var hdlr = mdia.Child("hdlr")!.Data;
            track.Video = System.Text.Encoding.ASCII.GetString(hdlr, 8, 4) == "vide";
            var mdhd = mdia.Child("mdhd")!.Data;
            track.Timescale = mdhd[0] == 1 ? BinaryPrimitives.ReadUInt32BigEndian(mdhd.AsSpan(20)) : BinaryPrimitives.ReadUInt32BigEndian(mdhd.AsSpan(12));
            // Where the shown part starts: the first edit that is not empty.
            if (trak.Child("edts")?.Child("elst") is { } elst)
            {
                var d = elst.Data;
                int version = d[0], count = (int)BinaryPrimitives.ReadUInt32BigEndian(d.AsSpan(4)), at = 8;
                for (int i = 0; i < count; i++)
                {
                    long mediaTime = version == 1 ? BinaryPrimitives.ReadInt64BigEndian(d.AsSpan(at + 8)) : BinaryPrimitives.ReadInt32BigEndian(d.AsSpan(at + 4));
                    at += version == 1 ? 20 : 12;
                    if (mediaTime >= 0) { track.MediaStart = mediaTime; break; }
                }
            }
            var stbl = track.Stbl = mdia.Child("minf")!.Child("stbl")!;
            var stsd = stbl.Child("stsd")!;
            track.SampleEntry = stsd.Children![0];
            if (track.Video && track.SampleEntry.Child("hvcC") is { } hvcC && hvcC.Data.Length > 21) track.LengthSize = (hvcC.Data[21] & 3) + 1;
            else if (track.Video && track.SampleEntry.Child("avcC") is { } avcC && avcC.Data.Length > 4) track.LengthSize = (avcC.Data[4] & 3) + 1;

            // Sizes.
            var stsz = stbl.Child("stsz")!.Data;
            int fixedSize = (int)BinaryPrimitives.ReadUInt32BigEndian(stsz.AsSpan(4)), sampleCount = (int)BinaryPrimitives.ReadUInt32BigEndian(stsz.AsSpan(8));
            var sizes = new int[sampleCount];
            for (int i = 0; i < sampleCount; i++) sizes[i] = fixedSize != 0 ? fixedSize : (int)BinaryPrimitives.ReadUInt32BigEndian(stsz.AsSpan(12 + 4 * i));
            // Chunk offsets.
            var offsets = new List<long>();
            if (stbl.Child("stco") is { } stco)
            {
                int n = (int)BinaryPrimitives.ReadUInt32BigEndian(stco.Data.AsSpan(4));
                for (int i = 0; i < n; i++) offsets.Add(BinaryPrimitives.ReadUInt32BigEndian(stco.Data.AsSpan(8 + 4 * i)));
            }
            else if (stbl.Child("co64") is { } co64)
            {
                int n = (int)BinaryPrimitives.ReadUInt32BigEndian(co64.Data.AsSpan(4));
                for (int i = 0; i < n; i++) offsets.Add((long)BinaryPrimitives.ReadUInt64BigEndian(co64.Data.AsSpan(8 + 8 * i)));
            }
            // Samples per chunk.
            var stsc = stbl.Child("stsc")!.Data;
            int entries = (int)BinaryPrimitives.ReadUInt32BigEndian(stsc.AsSpan(4));
            var runs = new List<(int FirstChunk, int PerChunk)>();
            for (int i = 0; i < entries; i++)
                runs.Add(((int)BinaryPrimitives.ReadUInt32BigEndian(stsc.AsSpan(8 + 12 * i)), (int)BinaryPrimitives.ReadUInt32BigEndian(stsc.AsSpan(12 + 12 * i))));
            // Decoding times and the shift to the moment shown.
            var deltas = new List<long>();
            var stts = stbl.Child("stts")!.Data;
            int sttsEntries = (int)BinaryPrimitives.ReadUInt32BigEndian(stts.AsSpan(4));
            for (int i = 0; i < sttsEntries; i++)
            {
                int count = (int)BinaryPrimitives.ReadUInt32BigEndian(stts.AsSpan(8 + 8 * i));
                long delta = BinaryPrimitives.ReadUInt32BigEndian(stts.AsSpan(12 + 8 * i));
                for (int k = 0; k < count; k++) deltas.Add(delta);
            }
            var shifts = new long[sampleCount];
            if (stbl.Child("ctts") is { } ctts)
            {
                int cttsEntries = (int)BinaryPrimitives.ReadUInt32BigEndian(ctts.Data.AsSpan(4)), s = 0;
                for (int i = 0; i < cttsEntries; i++)
                {
                    int count = (int)BinaryPrimitives.ReadUInt32BigEndian(ctts.Data.AsSpan(8 + 8 * i));
                    // Signed whatever the version says: an iPhone writes version 0 with frames shown before they are decoded.
                    long shift = BinaryPrimitives.ReadInt32BigEndian(ctts.Data.AsSpan(12 + 8 * i));
                    for (int k = 0; k < count && s < sampleCount; k++) shifts[s++] = shift;
                }
            }
            int sample = 0;
            long time = 0;
            for (int chunk = 0; chunk < offsets.Count; chunk++)
            {
                int perChunk = runs.Last(r => r.FirstChunk <= chunk + 1).PerChunk;
                track.Chunks.Add((offsets[chunk], sample, perChunk));
                long at = offsets[chunk];
                for (int k = 0; k < perChunk && sample < sampleCount; k++, sample++)
                {
                    long delta = sample < deltas.Count ? deltas[sample] : 0;
                    track.Samples.Add(new Sample(at, sizes[sample], time, time + shifts[sample], delta));
                    at += sizes[sample];
                    time += delta;
                }
            }
            if (track.Samples.Count != sampleCount) throw new InvalidDataException("the movie's index does not add up");
            return track;
        }

        /// <summary>
        /// Writes the movie to `output`: index first, then the data — every track's chunks (from the file each track is
        /// in), those of `changed` with its new samples — and the index pointing at where everything now is.
        /// </summary>
        public void Write(string output, Track? changed = null, byte[][]? newSamples = null)
        {
            if (changed != null && newSamples != null)
            {
                // The changed track's sample sizes.
                var stsz = changed.Stbl.Child("stsz")!;
                var sizes = new byte[12 + 4 * newSamples.Length];
                Array.Copy(stsz.Data, sizes, 8);
                BinaryPrimitives.WriteUInt32BigEndian(sizes.AsSpan(4), 0);
                BinaryPrimitives.WriteUInt32BigEndian(sizes.AsSpan(8), (uint)newSamples.Length);
                for (int i = 0; i < newSamples.Length; i++) BinaryPrimitives.WriteUInt32BigEndian(sizes.AsSpan(12 + 4 * i), (uint)newSamples[i].Length);
                stsz.Data = sizes;
            }
            else
            {
                changed = null;
            }

            // Every chunk of every track: in the order of the file when they are all from one, otherwise interleaved by
            // the moment each starts (sound next to its picture, for a player reading the file as it comes).
            var all = Tracks.SelectMany(t => t.Chunks.Select((c, index) => (Track: t, Index: index, c.Offset, c.First, c.Count)));
            var chunks = (Tracks.Select(t => t.Path).Distinct(StringComparer.OrdinalIgnoreCase).Count() == 1
                ? all.OrderBy(c => c.Offset)
                : all.OrderBy(c => c.Count > 0 ? c.Track.Samples[c.First].Decoded / (double)c.Track.Timescale : 0).ThenBy(c => c.Track.Video ? 0 : 1)).ToList();
            long dataSize = chunks.Sum(c => c.Track == changed
                ? Enumerable.Range(c.First, c.Count).Sum(i => (long)newSamples![i].Length)
                : Enumerable.Range(c.First, c.Count).Sum(i => (long)c.Track.Samples[i].Size));
            // The chunk offsets, 64-bit wherever the data goes beyond 4 GB.
            foreach (var track in Tracks) SetOffsets(track, new long[track.Chunks.Count], dataSize > uint.MaxValue - (1L << 24));
            long mdatHeader = dataSize + 8 > uint.MaxValue ? 16 : 8;
            long start = 8 + Ftyp.Data.Length + Moov.Size + mdatHeader;
            var newOffsets = Tracks.ToDictionary(t => t, t => new long[t.Chunks.Count]);
            long position = start;
            foreach (var c in chunks)
            {
                newOffsets[c.Track][c.Index] = position;
                position += c.Track == changed
                    ? Enumerable.Range(c.First, c.Count).Sum(i => (long)newSamples![i].Length)
                    : Enumerable.Range(c.First, c.Count).Sum(i => (long)c.Track.Samples[i].Size);
            }
            foreach (var track in Tracks) SetOffsets(track, newOffsets[track], dataSize > uint.MaxValue - (1L << 24));

            var sources = Tracks.Select(t => t.Path).Distinct(StringComparer.OrdinalIgnoreCase)
                                .ToDictionary(p => p, p => File.OpenRead(p), StringComparer.OrdinalIgnoreCase);
            try
            {
                WriteData(output, chunks, changed, newSamples, sources, start, dataSize, mdatHeader);
            }
            finally
            {
                foreach (var stream in sources.Values) stream.Dispose();
            }
        }

        void WriteData(string output, List<(Track Track, int Index, long Offset, int First, int Count)> chunks, Track? changed, byte[][]? newSamples,
                       Dictionary<string, FileStream> sources, long start, long dataSize, long mdatHeader)
        {
            using var file = new FileStream(output, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20);
            Ftyp.WriteTo(file);
            Moov.WriteTo(file);
            Span<byte> header = stackalloc byte[16];
            if (mdatHeader == 16)
            {
                BinaryPrimitives.WriteUInt32BigEndian(header, 1);
                System.Text.Encoding.ASCII.GetBytes("mdat", header[4..]);
                BinaryPrimitives.WriteUInt64BigEndian(header[8..], (ulong)(dataSize + 16));
                file.Write(header);
            }
            else
            {
                BinaryPrimitives.WriteUInt32BigEndian(header, (uint)(dataSize + 8));
                System.Text.Encoding.ASCII.GetBytes("mdat", header[4..]);
                file.Write(header[..8]);
            }
            var buffer = new byte[1 << 20];
            foreach (var c in chunks)
            {
                if (c.Track == changed)
                {
                    for (int i = c.First; i < c.First + c.Count; i++) file.Write(newSamples![i]);
                    continue;
                }
                long remaining = Enumerable.Range(c.First, c.Count).Sum(i => (long)c.Track.Samples[i].Size);
                var source = sources[c.Track.Path];
                source.Position = c.Offset;
                while (remaining > 0)
                {
                    int read = source.Read(buffer, 0, (int)Math.Min(buffer.Length, remaining));
                    if (read <= 0) throw new EndOfStreamException();
                    file.Write(buffer, 0, read);
                    remaining -= read;
                }
            }
            if (file.Position != start + dataSize) throw new InvalidDataException("the rewritten movie does not add up");
        }

        static void SetOffsets(Track track, long[] offsets, bool wide)
        {
            var stbl = track.Stbl;
            stbl.Children!.RemoveAll(b => b.Type is "stco" or "co64");
            var box = new Box(wide ? "co64" : "stco");
            var data = new byte[8 + offsets.Length * (wide ? 8 : 4)];
            BinaryPrimitives.WriteUInt32BigEndian(data.AsSpan(4), (uint)offsets.Length);
            for (int i = 0; i < offsets.Length; i++)
            {
                if (wide) BinaryPrimitives.WriteUInt64BigEndian(data.AsSpan(8 + 8 * i), (ulong)offsets[i]);
                else BinaryPrimitives.WriteUInt32BigEndian(data.AsSpan(8 + 4 * i), (uint)offsets[i]);
            }
            box.Data = data;
            stbl.Children.Add(box);
        }
    }
}
