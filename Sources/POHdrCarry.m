#import "POHdrCarry.h"

// The MP4 (ISO base media / QuickTime) structure, read into boxes and written back. The same as HdrCarry on Windows.

static uint32_t POU32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }
static uint64_t POU64(const uint8_t *p) { return ((uint64_t)POU32(p) << 32) | POU32(p + 4); }
static void POPutU32(NSMutableData *d, uint32_t v) { uint8_t b[4] = {v >> 24, v >> 16, v >> 8, v}; [d appendBytes:b length:4]; }
static void POPutU64(NSMutableData *d, uint64_t v) { POPutU32(d, (uint32_t)(v >> 32)); POPutU32(d, (uint32_t)v); }

static NSException *POBad(NSString *why) {
    return [NSException exceptionWithName:@"POHdrCarry" reason:why userInfo:nil];
}

/// A box: its type, and either its own bytes or the boxes inside it (after `head`, the bytes before them).
@interface POBox : NSObject
@property (nonatomic, copy) NSString *type;
@property (nonatomic, strong) NSData *data;
@property (nonatomic, strong) NSData *head;
@property (nonatomic, strong, nullable) NSMutableArray<POBox *> *children;
@end

@implementation POBox
- (instancetype)initWithType:(NSString *)type {
    if ((self = [super init])) { _type = [type copy]; _data = [NSData data]; _head = [NSData data]; }
    return self;
}
- (long long)size {
    if (!self.children) return 8 + (long long)self.data.length;
    long long size = 8 + (long long)self.head.length;
    for (POBox *child in self.children) size += child.size;
    return size;
}
- (POBox *)child:(NSString *)type {
    for (POBox *child in self.children) if ([child.type isEqualToString:type]) return child;
    return nil;
}
- (void)writeTo:(NSFileHandle *)file {
    long long size = self.size;
    if (size > UINT32_MAX) @throw POBad(@"a box too large");
    NSMutableData *header = [NSMutableData data];
    POPutU32(header, (uint32_t)size);
    [header appendData:[self.type dataUsingEncoding:NSISOLatin1StringEncoding]];
    [file writeData:header];
    if (!self.children) { [file writeData:self.data]; return; }
    [file writeData:self.head];
    for (POBox *child in self.children) [child writeTo:file];
}
@end

static NSSet<NSString *> *POContainers(void) {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSSet setWithArray:@[@"moov", @"trak", @"mdia", @"minf", @"stbl", @"edts", @"dinf", @"mvex"]]; });
    return set;
}
static NSSet<NSString *> *POVisualEntries(void) {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSSet setWithArray:@[@"hvc1", @"hev1", @"dvh1", @"dvhe", @"avc1", @"avc3"]]; });
    return set;
}

static NSMutableArray<POBox *> *POParseBoxes(NSData *data, NSUInteger start, NSUInteger end) {
    const uint8_t *bytes = data.bytes;
    NSMutableArray *boxes = [NSMutableArray array];
    NSUInteger at = start;
    while (at + 8 <= end) {
        uint64_t size = POU32(bytes + at);
        NSUInteger header = 8;
        if (size == 1) { size = POU64(bytes + at + 8); header = 16; }
        else if (size == 0) size = end - at;
        if (size < header || at + size > end) @throw POBad(@"the movie's index is damaged");
        NSString *type = [[NSString alloc] initWithBytes:bytes + at + 4 length:4 encoding:NSISOLatin1StringEncoding];
        NSUInteger bodyStart = at + header, bodyEnd = (NSUInteger)(at + size);
        POBox *box = [[POBox alloc] initWithType:type];
        if ([POContainers() containsObject:type]) {
            box.children = POParseBoxes(data, bodyStart, bodyEnd);
        } else if ([type isEqualToString:@"stsd"]) {
            if (bodyStart + 8 > bodyEnd) @throw POBad(@"the movie's index is damaged");
            box.head = [data subdataWithRange:NSMakeRange(bodyStart, 8)];
            box.children = POParseBoxes(data, bodyStart + 8, bodyEnd);
        } else if ([POVisualEntries() containsObject:type]) {
            if (bodyStart + 78 > bodyEnd) @throw POBad(@"the movie's index is damaged");
            box.head = [data subdataWithRange:NSMakeRange(bodyStart, 78)];
            box.children = POParseBoxes(data, bodyStart + 78, bodyEnd);
        } else {
            box.data = [data subdataWithRange:NSMakeRange(bodyStart, bodyEnd - bodyStart)];
        }
        [boxes addObject:box];
        at = bodyEnd;
    }
    return boxes;
}

typedef struct { long long offset; uint32_t size; long long decoded, shown, duration; } POSample;
typedef struct { long long offset; NSInteger first, count; } POChunk;

@interface POTrack : NSObject
@property (nonatomic, strong) POBox *trak, *stbl, *sampleEntry;
@property (nonatomic) long long timescale, mediaStart;
@property (nonatomic) int lengthSize;
@property (nonatomic) BOOL video;
@property (nonatomic) POSample *samples;
@property (nonatomic) NSInteger sampleCount;
@property (nonatomic) POChunk *chunks;
@property (nonatomic) NSInteger chunkCount;
@end

@implementation POTrack
- (void)dealloc { free(_samples); free(_chunks); }
/// The moment the first frame is shown, in the track's time: the edit's start, or — when the frames are shown later
/// than decoded (an iPhone's, by two frames) and the edit starts at 0 — the earliest frame's moment, as players take it.
- (long long)firstShown {
    long long first = LLONG_MAX;
    for (NSInteger i = 0; i < self.sampleCount; i++)
        if (self.samples[i].shown >= self.mediaStart && self.samples[i].shown < first) first = self.samples[i].shown;
    return first == LLONG_MAX ? self.mediaStart : first;
}
@end

static POTrack *POReadTrack(POBox *trak) {
    POTrack *track = [POTrack new];
    track.trak = trak;
    track.lengthSize = 4;
    POBox *mdia = [trak child:@"mdia"];
    POBox *hdlr = [mdia child:@"hdlr"], *mdhd = [mdia child:@"mdhd"];
    POBox *stbl = [[mdia child:@"minf"] child:@"stbl"];
    if (!mdia || !hdlr || !mdhd || !stbl || hdlr.data.length < 12 || mdhd.data.length < 24) @throw POBad(@"a track without media");
    track.video = memcmp((const uint8_t *)hdlr.data.bytes + 8, "vide", 4) == 0;
    const uint8_t *m = mdhd.data.bytes;
    track.timescale = m[0] == 1 ? POU32(m + 20) : POU32(m + 12);
    // Where the shown part starts: the first edit that is not empty.
    POBox *elst = [[trak child:@"edts"] child:@"elst"];
    if (elst && elst.data.length >= 8) {
        const uint8_t *d = elst.data.bytes;
        int version = d[0];
        NSUInteger count = POU32(d + 4), at = 8, entry = version == 1 ? 20 : 12;
        for (NSUInteger i = 0; i < count && at + entry <= elst.data.length; i++, at += entry) {
            long long mediaTime = version == 1 ? (int64_t)POU64(d + at + 8) : (int32_t)POU32(d + at + 4);
            if (mediaTime >= 0) { track.mediaStart = mediaTime; break; }
        }
    }
    track.stbl = stbl;
    POBox *stsd = [stbl child:@"stsd"];
    if (stsd.children.count == 0) @throw POBad(@"a track without a description");
    track.sampleEntry = stsd.children[0];
    POBox *hvcC = [track.sampleEntry child:@"hvcC"], *avcC = [track.sampleEntry child:@"avcC"];
    if (track.video && hvcC && hvcC.data.length > 21) track.lengthSize = (((const uint8_t *)hvcC.data.bytes)[21] & 3) + 1;
    else if (track.video && avcC && avcC.data.length > 4) track.lengthSize = (((const uint8_t *)avcC.data.bytes)[4] & 3) + 1;

    POBox *stsz = [stbl child:@"stsz"], *stco = [stbl child:@"stco"], *co64 = [stbl child:@"co64"];
    POBox *stsc = [stbl child:@"stsc"], *stts = [stbl child:@"stts"], *ctts = [stbl child:@"ctts"];
    if (!stsz || !(stco || co64) || !stsc || !stts || stsz.data.length < 12) @throw POBad(@"the movie's index is incomplete");
    // Sizes.
    const uint8_t *z = stsz.data.bytes;
    uint32_t fixedSize = POU32(z + 4);
    NSInteger sampleCount = POU32(z + 8);
    if (fixedSize == 0 && stsz.data.length < 12 + 4 * (NSUInteger)sampleCount) @throw POBad(@"the movie's index is damaged");
    // Chunk offsets.
    NSInteger chunkCount = POU32((const uint8_t *)(stco ?: co64).data.bytes + 4);
    if ((stco ?: co64).data.length < 8 + (NSUInteger)chunkCount * (stco ? 4 : 8)) @throw POBad(@"the movie's index is damaged");
    // Samples per chunk.
    const uint8_t *c = stsc.data.bytes;
    NSUInteger runs = POU32(c + 4);
    if (stsc.data.length < 8 + 12 * runs) @throw POBad(@"the movie's index is damaged");
    // Decoding times.
    const uint8_t *t = stts.data.bytes;
    NSUInteger sttsEntries = POU32(t + 4);
    if (stts.data.length < 8 + 8 * sttsEntries) @throw POBad(@"the movie's index is damaged");
    long long *durations = calloc((size_t)MAX(sampleCount, (NSInteger)1), sizeof(long long));
    NSInteger s = 0;
    for (NSUInteger i = 0; i < sttsEntries; i++) {
        uint32_t count = POU32(t + 8 + 8 * i), delta = POU32(t + 12 + 8 * i);
        for (uint32_t k = 0; k < count && s < sampleCount; k++) durations[s++] = delta;
    }
    // The shift to the moment shown: signed whatever the version says (an iPhone writes version 0 with frames shown
    // before they are decoded).
    long long *shifts = calloc((size_t)MAX(sampleCount, (NSInteger)1), sizeof(long long));
    if (ctts && ctts.data.length >= 8) {
        const uint8_t *d = ctts.data.bytes;
        NSUInteger entries = POU32(d + 4);
        s = 0;
        for (NSUInteger i = 0; i < entries && 16 + 8 * i <= ctts.data.length; i++) {
            uint32_t count = POU32(d + 8 + 8 * i);
            int32_t shift = (int32_t)POU32(d + 12 + 8 * i);
            for (uint32_t k = 0; k < count && s < sampleCount; k++) shifts[s++] = shift;
        }
    }
    track.samples = calloc((size_t)MAX(sampleCount, (NSInteger)1), sizeof(POSample));
    track.chunks = calloc((size_t)MAX(chunkCount, (NSInteger)1), sizeof(POChunk));
    track.chunkCount = chunkCount;
    NSInteger sample = 0;
    long long time = 0;
    for (NSInteger chunk = 0; chunk < chunkCount; chunk++) {
        long long offset = stco ? POU32((const uint8_t *)stco.data.bytes + 8 + 4 * chunk) : (long long)POU64((const uint8_t *)co64.data.bytes + 8 + 8 * chunk);
        uint32_t perChunk = 0;
        for (NSUInteger r = 0; r < runs; r++) if (POU32(c + 8 + 12 * r) <= (uint32_t)chunk + 1) perChunk = POU32(c + 12 + 12 * r);
        track.chunks[chunk] = (POChunk){offset, sample, perChunk};
        long long at = offset;
        for (uint32_t k = 0; k < perChunk && sample < sampleCount; k++, sample++) {
            uint32_t size = fixedSize ? fixedSize : POU32(z + 12 + 4 * sample);
            track.samples[sample] = (POSample){at, size, time, time + shifts[sample], durations[sample]};
            at += size;
            time += durations[sample];
        }
    }
    free(durations);
    free(shifts);
    if (sample != sampleCount) @throw POBad(@"the movie's index does not add up");
    track.sampleCount = sampleCount;
    return track;
}

@interface POMovie : NSObject
@property (nonatomic, strong) POBox *ftyp, *moov;
@property (nonatomic, strong) NSMutableArray<POTrack *> *tracks;
@end

@implementation POMovie
+ (POMovie *)read:(NSURL *)url {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingFromURL:url error:NULL];
    if (!file) @throw POBad(@"the video cannot be opened");
    POMovie *movie = [POMovie new];
    movie.tracks = [NSMutableArray array];
    unsigned long long length = [file seekToEndOfFile], position = 0;
    while (position + 8 <= length) {
        [file seekToFileOffset:position];
        NSData *header = [file readDataOfLength:16];
        if (header.length < 8) break;
        const uint8_t *h = header.bytes;
        uint64_t size = POU32(h);
        NSUInteger headerSize = 8;
        if (size == 1) { if (header.length < 16) break; size = POU64(h + 8); headerSize = 16; }
        else if (size == 0) size = length - position;
        if (size < headerSize) @throw POBad(@"the movie's index is damaged");
        NSString *type = [[NSString alloc] initWithBytes:h + 4 length:4 encoding:NSISOLatin1StringEncoding];
        if ([type isEqualToString:@"moov"] || [type isEqualToString:@"ftyp"]) {
            [file seekToFileOffset:position + headerSize];
            NSData *body = [file readDataOfLength:(NSUInteger)(size - headerSize)];
            POBox *box = [[POBox alloc] initWithType:type];
            if ([type isEqualToString:@"moov"]) { box.children = POParseBoxes(body, 0, body.length); movie.moov = box; }
            else { box.data = body; movie.ftyp = box; }
        }
        position += size;
    }
    [file closeFile];
    if (!movie.moov || !movie.ftyp) @throw POBad(@"not an MP4 or MOV");
    for (POBox *trak in movie.moov.children) if ([trak.type isEqualToString:@"trak"]) [movie.tracks addObject:POReadTrack(trak)];
    return movie;
}

- (POTrack *)videoTrack {
    for (POTrack *track in self.tracks) if (track.video) return track;
    return nil;
}

static void POSetOffsets(POTrack *track, const long long *offsets, BOOL wide) {
    NSMutableArray *children = track.stbl.children;
    for (NSInteger i = children.count - 1; i >= 0; i--)
        if ([((POBox *)children[i]).type isEqualToString:@"stco"] || [((POBox *)children[i]).type isEqualToString:@"co64"]) [children removeObjectAtIndex:i];
    POBox *box = [[POBox alloc] initWithType:wide ? @"co64" : @"stco"];
    NSMutableData *data = [NSMutableData data];
    POPutU32(data, 0);
    POPutU32(data, (uint32_t)track.chunkCount);
    for (NSInteger i = 0; i < track.chunkCount; i++) { if (wide) POPutU64(data, offsets[i]); else POPutU32(data, (uint32_t)offsets[i]); }
    box.data = data;
    [children addObject:box];
}

/// Writes the movie to `output`: index first, then the data — every track's chunks in the order they were, those of
/// `changed` with its new samples — and the index pointing at where everything now is.
- (void)writeFrom:(NSURL *)input to:(NSURL *)output changed:(POTrack *)changed samples:(NSArray<NSData *> *)newSamples {
    // The changed track's sample sizes.
    POBox *stsz = [changed.stbl child:@"stsz"];
    NSMutableData *sizes = [NSMutableData dataWithData:[stsz.data subdataWithRange:NSMakeRange(0, 4)]];
    POPutU32(sizes, 0);
    POPutU32(sizes, (uint32_t)newSamples.count);
    for (NSData *sample in newSamples) POPutU32(sizes, (uint32_t)sample.length);
    stsz.data = sizes;

    // Every chunk of every track, in the order of the file.
    NSMutableArray<NSArray *> *chunks = [NSMutableArray array];
    for (POTrack *track in self.tracks)
        for (NSInteger i = 0; i < track.chunkCount; i++) [chunks addObject:@[track, @(i)]];
    [chunks sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        long long x = ((POTrack *)a[0]).chunks[[a[1] integerValue]].offset, y = ((POTrack *)b[0]).chunks[[b[1] integerValue]].offset;
        return x < y ? NSOrderedAscending : x > y ? NSOrderedDescending : NSOrderedSame;
    }];
    long long (^chunkSize)(POTrack *, NSInteger) = ^long long(POTrack *track, NSInteger index) {
        POChunk chunk = track.chunks[index];
        long long size = 0;
        for (NSInteger i = chunk.first; i < chunk.first + chunk.count; i++)
            size += track == changed ? (long long)newSamples[i].length : track.samples[i].size;
        return size;
    };
    long long dataSize = 0;
    for (NSArray *c in chunks) dataSize += chunkSize(c[0], [c[1] integerValue]);
    // The chunk offsets, 64-bit wherever the data goes beyond 4 GB: the index's size is settled first.
    BOOL wide = dataSize > (long long)UINT32_MAX - (1LL << 24);
    NSMutableDictionary<NSValue *, NSMutableData *> *offsets = [NSMutableDictionary dictionary];
    for (POTrack *track in self.tracks) {
        NSMutableData *zeros = [NSMutableData dataWithLength:sizeof(long long) * (NSUInteger)MAX(track.chunkCount, (NSInteger)1)];
        offsets[[NSValue valueWithNonretainedObject:track]] = zeros;
        POSetOffsets(track, zeros.bytes, wide);
    }
    long long mdatHeader = dataSize + 8 > UINT32_MAX ? 16 : 8;
    long long start = 8 + (long long)self.ftyp.data.length + self.moov.size + mdatHeader;
    long long position = start;
    for (NSArray *c in chunks) {
        POTrack *track = c[0];
        ((long long *)offsets[[NSValue valueWithNonretainedObject:track]].mutableBytes)[[c[1] integerValue]] = position;
        position += chunkSize(track, [c[1] integerValue]);
    }
    for (POTrack *track in self.tracks) POSetOffsets(track, offsets[[NSValue valueWithNonretainedObject:track]].bytes, wide);

    NSFileHandle *source = [NSFileHandle fileHandleForReadingFromURL:input error:NULL];
    [NSFileManager.defaultManager createFileAtPath:output.path contents:nil attributes:nil];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingToURL:output error:NULL];
    if (!source || !file) @throw POBad(@"the video cannot be written");
    [self.ftyp writeTo:file];
    [self.moov writeTo:file];
    NSMutableData *header = [NSMutableData data];
    if (mdatHeader == 16) {
        POPutU32(header, 1);
        [header appendBytes:"mdat" length:4];
        POPutU64(header, dataSize + 16);
    } else {
        POPutU32(header, (uint32_t)(dataSize + 8));
        [header appendBytes:"mdat" length:4];
    }
    [file writeData:header];
    for (NSArray *c in chunks) {
        POTrack *track = c[0];
        POChunk chunk = track.chunks[[c[1] integerValue]];
        if (track == changed) {
            for (NSInteger i = chunk.first; i < chunk.first + chunk.count; i++) [file writeData:newSamples[i]];
            continue;
        }
        long long remaining = chunkSize(track, [c[1] integerValue]);
        [source seekToFileOffset:chunk.offset];
        while (remaining > 0) {
            NSData *piece = [source readDataOfLength:(NSUInteger)MIN(remaining, (long long)(1 << 20))];
            if (piece.length == 0) @throw POBad(@"the video ends short");
            [file writeData:piece];
            remaining -= piece.length;
        }
    }
    unsigned long long written = [file offsetInFile];
    [file closeFile];
    [source closeFile];
    if (written != (unsigned long long)(start + dataSize)) @throw POBad(@"the rewritten movie does not add up");
}
@end

#pragma mark - The frames

static int PONalType(NSData *nal) { return (((const uint8_t *)nal.bytes)[0] >> 1) & 0x3F; }

static NSMutableArray<NSData *> *PONals(NSData *sample, int lengthSize) {
    NSMutableArray *nals = [NSMutableArray array];
    const uint8_t *bytes = sample.bytes;
    NSUInteger at = 0;
    while (at + lengthSize <= sample.length) {
        NSUInteger length = 0;
        for (int i = 0; i < lengthSize; i++) length = (length << 8) | bytes[at + i];
        at += lengthSize;
        if (length == 0 || at + length > sample.length) @throw POBad(@"a frame of the video cannot be read");
        [nals addObject:[sample subdataWithRange:NSMakeRange(at, length)]];
        at += length;
    }
    return nals;
}

/// A message (SEI) of ITU-T T.35 user data — HDR Vivid, HDR10+ — or of the ambient light, or a Dolby Vision layer (NAL type 62).
static BOOL POIsCarried(NSData *nal) {
    if (nal.length < 3) return NO;
    int type = PONalType(nal);
    if (type == 62) return YES;                                          // Dolby Vision RPU
    if (type != 39) return NO;                                           // prefix SEI
    const uint8_t *b = nal.bytes;
    NSUInteger i = 2;
    int payloadType = 0;
    while (i < nal.length && b[i] == 0xFF) { payloadType += 255; i++; }
    if (i >= nal.length) return NO;
    payloadType += b[i];
    return payloadType == 4 || payloadType == 148;                       // user data registered by ITU-T T.35; the ambient light it was made for
}

/// The frame with the messages before its picture and the Dolby Vision layer last, as the format wants them.
static NSData *POInsert(NSData *sample, int lengthSize, NSArray<NSData *> *carried) {
    NSMutableArray<NSData *> *nals = PONals(sample, lengthSize);
    NSUInteger firstPicture = nals.count;
    for (NSUInteger i = 0; i < nals.count; i++) if (PONalType(nals[i]) < 32) { firstPicture = i; break; }
    NSMutableArray<NSData *> *ordered = [NSMutableArray array];
    [ordered addObjectsFromArray:[nals subarrayWithRange:NSMakeRange(0, firstPicture)]];
    for (NSData *nal in carried) if (PONalType(nal) == 39) [ordered addObject:nal];
    [ordered addObjectsFromArray:[nals subarrayWithRange:NSMakeRange(firstPicture, nals.count - firstPicture)]];
    for (NSData *nal in carried) if (PONalType(nal) == 62) [ordered addObject:nal];
    NSMutableData *out = [NSMutableData dataWithCapacity:sample.length + 256];
    for (NSData *nal in ordered) {
        for (int i = lengthSize - 1; i >= 0; i--) { uint8_t b = (uint8_t)(nal.length >> (8 * i)); [out appendBytes:&b length:1]; }
        [out appendData:nal];
    }
    return out;
}

static NSData *POReadAt(NSFileHandle *file, long long offset, uint32_t size) {
    [file seekToFileOffset:offset];
    NSData *data = [file readDataOfLength:size];
    if (data.length != size) @throw POBad(@"the video ends short");
    return data;
}

static long long POMicro(long long ticks, long long timescale) { return llround(ticks * 1000000.0 / timescale); }

NSString *PODynamicHdrOf(NSURL *video) {
    @try {
        POMovie *movie = [POMovie read:video];
        POTrack *track = movie.videoTrack;
        if (!track || track.sampleCount == 0) return nil;
        NSFileHandle *file = [NSFileHandle fileHandleForReadingFromURL:video error:NULL];
        if (!file) return nil;
        NSString *kind = nil;
        for (NSData *nal in PONals(POReadAt(file, track.samples[0].offset, track.samples[0].size), track.lengthSize)) {
            if (!POIsCarried(nal)) continue;
            if (PONalType(nal) == 62) { kind = @"dolby vision"; break; }
            // T.35: country code, then the provider — China (0x26) with CUVA 0x0004 is HDR Vivid, the USA (0xB5) with
            // Samsung 0x003C is HDR10+.
            const uint8_t *b = nal.bytes;
            NSUInteger i = 2;
            while (i < nal.length && b[i] == 0xFF) i++;
            if (i >= nal.length || b[i] != 4) continue;                  // the ambient light alone says nothing of these
            i++;
            while (i < nal.length && b[i] == 0xFF) i++;
            i++;
            if (i + 3 > nal.length) continue;
            if (b[i] == 0x26 && b[i + 1] == 0x00 && b[i + 2] == 0x04) kind = @"vivid";
            else if (b[i] == 0xB5 && b[i + 1] == 0x00 && b[i + 2] == 0x3C) kind = @"hdr10+";
        }
        [file closeFile];
        return kind;
    } @catch (NSException *e) {
        return nil;
    }
}

BOOL POHasFlatTimestamps(NSURL *video) {
    @try {
        POTrack *track = [POMovie read:video].videoTrack;
        if (!track || track.sampleCount < 10) return NO;
        for (NSInteger i = 0; i < track.sampleCount; i++) if (track.samples[i].shown != track.samples[i].decoded) return NO;
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
}

NSInteger POCarryHdr(NSURL *original, NSURL *encoded, NSURL *output, NSString **error) {
    @try {
        POMovie *source = [POMovie read:original], *target = [POMovie read:encoded];
        POTrack *sourceVideo = source.videoTrack, *targetVideo = target.videoTrack;
        if (!sourceVideo) @throw POBad(@"no video track in the original");
        if (!targetVideo) @throw POBad(@"no video track in the compressed file");

        // What each frame of the original carries, by the moment it is shown.
        NSFileHandle *sourceFile = [NSFileHandle fileHandleForReadingFromURL:original error:NULL];
        if (!sourceFile) @throw POBad(@"the video cannot be opened");
        long long sourceStart = sourceVideo.firstShown;
        NSMutableDictionary<NSNumber *, NSArray<NSData *> *> *carried = [NSMutableDictionary dictionary];
        for (NSInteger i = 0; i < sourceVideo.sampleCount; i++) {
            POSample sample = sourceVideo.samples[i];
            NSMutableArray *nals = [NSMutableArray array];
            for (NSData *nal in PONals(POReadAt(sourceFile, sample.offset, sample.size), sourceVideo.lengthSize))
                if (POIsCarried(nal)) [nals addObject:nal];
            if (nals.count == 0) continue;
            carried[@(POMicro(sample.shown - sourceStart, sourceVideo.timescale))] = nals;
        }
        [sourceFile closeFile];
        if (carried.count == 0) @throw POBad(@"the original has no dynamic HDR metadata");
        NSArray<NSNumber *> *keys = [carried.allKeys sortedArrayUsingSelector:@selector(compare:)];
        long long *moments = malloc(sizeof(long long) * keys.count);
        for (NSUInteger i = 0; i < keys.count; i++) moments[i] = keys[i].longLongValue;

        // Into the compressed frames, by the same moment (within half a frame).
        NSFileHandle *targetFile = [NSFileHandle fileHandleForReadingFromURL:encoded error:NULL];
        if (!targetFile) { free(moments); @throw POBad(@"the video cannot be opened"); }
        long long targetStart = targetVideo.firstShown;
        NSMutableArray<NSData *> *newSamples = [NSMutableArray arrayWithCapacity:targetVideo.sampleCount];
        NSMutableSet<NSNumber *> *used = [NSMutableSet set];
        NSInteger matched = 0;
        for (NSInteger i = 0; i < targetVideo.sampleCount; i++) {
            POSample sample = targetVideo.samples[i];
            NSData *data = POReadAt(targetFile, sample.offset, sample.size);
            long long moment = POMicro(sample.shown - targetStart, targetVideo.timescale);
            long long frame = POMicro(sample.duration, targetVideo.timescale);
            // The nearest of the original's moments.
            NSUInteger low = 0, high = keys.count - 1;
            while (low < high) { NSUInteger mid = (low + high) / 2; if (moments[mid] < moment) low = mid + 1; else high = mid; }
            if (low > 0 && llabs(moments[low - 1] - moment) <= llabs(moments[low] - moment)) low--;
            if (llabs(moments[low] - moment) <= MAX(frame / 2, 1000LL)) {
                if ([used containsObject:@(low)]) { free(moments); @throw POBad(@"two frames of the compressed video fall on one of the original"); }
                [used addObject:@(low)];
                data = POInsert(data, targetVideo.lengthSize, carried[keys[low]]);
                matched++;
            }
            [newSamples addObject:data];
        }
        [targetFile closeFile];
        free(moments);
        if (matched < targetVideo.sampleCount * 0.98)
            @throw POBad([NSString stringWithFormat:@"only %ld of %ld frames found their original", (long)matched, (long)targetVideo.sampleCount]);

        // The announcing boxes, into the compressed track's description.
        for (POBox *box in sourceVideo.sampleEntry.children) {
            if (![@[@"cuvv", @"dvcC", @"dvvC", @"dvwC"] containsObject:box.type]) continue;
            if (![targetVideo.sampleEntry child:box.type]) [targetVideo.sampleEntry.children addObject:box];
        }
        [target writeFrom:encoded to:output changed:targetVideo samples:newSamples];
        if (error) *error = nil;
        return matched;
    } @catch (NSException *e) {
        [NSFileManager.defaultManager removeItemAtURL:output error:NULL];
        if (error) *error = e.reason ?: @"the HDR metadata could not be carried over";
        return 0;
    }
}
