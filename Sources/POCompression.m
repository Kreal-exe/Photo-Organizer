#import "POCompression.h"
#import "POMediaTypes.h"
#import "POScreenshots.h"
#import "POStrings.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <VideoToolbox/VideoToolbox.h>

const NSInteger POCompressionDefaultVideoHeight = 1080;
const NSInteger POCompressionDefaultVideoQuality = 1;
/// The JPEG quality of compressed photos and of their gain map.
static const double POJpegQuality = 0.9;
/// How much brighter than white a worked-out HDR rendition may go, in stops (8×).
static const double POMaxHdrStops = 3;
/// A worked-out gain map is a quarter of the photo across and down, as Ultra HDR writes it.
static const NSInteger POGainMapScale = 4;

NSArray<NSNumber *> *POCompressionVideoHeights(void) {
    return @[@2160, @1080, @720];
}

BOOL POIsRawItem(POPhotoItem *item) {
    return !item.isVideo && [PORawExtensions() containsObject:item.url.pathExtension.lowercaseString];
}

NSString *POByteSize(long long bytes) {
    return [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleFile];
}

NSString *POCompressionSaving(long long before, long long after) {
    NSString *text = [NSString stringWithFormat:@"%@ → %@", POByteSize(before), POByteSize(after)];
    if (before <= 0) return text;
    return [text stringByAppendingFormat:@" (−%.0f %%)", MAX(0, 100 - after * 100.0 / before)];
}

#pragma mark - Sizes

/// The photos made by a camera or a phone the way most of the library is: JPEG and HEIC, not pictures or screenshots.
static BOOL POIsOrdinaryPhoto(POPhotoItem *item) {
    if (item.isVideo || item.isTiny || item.pixelWidth <= 0 || item.pixelHeight <= 0 || item.fileSize == 0) return NO;
    NSString *extension = item.url.pathExtension.lowercaseString;
    if (![@[@"jpg", @"jpeg", @"heic", @"heif"] containsObject:extension]) return NO;
    return !POIsPicture(item) && !POIsGooglePhotosCreation(item) && !POIsScreenshot(item);
}

void POTypicalPhoto(NSArray<POPhotoItem *> *items, NSInteger *megapixels, double *bytesPerMegapixel, NSInteger *count) {
    NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *bySize = [NSMutableDictionary dictionary];
    for (POPhotoItem *item in items) {
        if (!POIsOrdinaryPhoto(item)) continue;
        double size = item.pixelWidth * (double)item.pixelHeight / 1e6;
        NSNumber *key = @((NSInteger)llround(size));
        if (key.integerValue < 2) continue;
        NSMutableArray<NSNumber *> *list = bySize[key];
        if (!list) bySize[key] = list = [NSMutableArray array];
        [list addObject:@(item.fileSize / size)];
    }
    NSNumber *best = nil;
    for (NSNumber *key in bySize) {
        NSUInteger n = bySize[key].count, bestCount = best ? bySize[best].count : 0;
        if (!best || n > bestCount || (n == bestCount && key.integerValue > best.integerValue)) best = key;
    }
    if (!best) {
        *megapixels = 12;
        *bytesPerMegapixel = 300000;
        *count = 0;
        return;
    }
    NSArray<NSNumber *> *sorted = [bySize[best] sortedArrayUsingSelector:@selector(compare:)];
    *megapixels = best.integerValue;
    *bytesPerMegapixel = sorted[sorted.count / 2].doubleValue;
    *count = (NSInteger)sorted.count;
}

static NSInteger POEven(double value) {
    return MAX(2, (NSInteger)llround(value / 2) * 2);
}

CGSize POCompressedPhotoSize(NSInteger width, NSInteger height, NSInteger megapixels) {
    double pixels = (double)width * height, wanted = megapixels * 1e6;
    if (width <= 0 || height <= 0 || wanted >= pixels * 0.97) return CGSizeMake(width, height);
    double scale = sqrt(wanted / pixels);
    // Half or a quarter when about that (48 MP to 12): the exact size phones make, and the sharpest scaling.
    for (NSNumber *exact in @[@0.5, @0.25]) {
        double e = exact.doubleValue;
        NSInteger step = (NSInteger)llround(1 / e);
        if (fabs(scale - e) / e < 0.05 && width % step == 0 && height % step == 0) scale = e;
    }
    return CGSizeMake(POEven(width * scale), POEven(height * scale));
}

/// The upright size of a video brought down so that its shorter side is at most `maxHeight`; even numbers.
static CGSize POVideoSize(NSInteger width, NSInteger height, NSInteger maxHeight) {
    NSInteger shorter = MIN(width, height);
    if (shorter <= maxHeight) return CGSizeMake(width / 2 * 2, height / 2 * 2);
    double scale = (double)maxHeight / shorter;
    return CGSizeMake(POEven(width * scale), POEven(height * scale));
}

long long POVideoBitrate(NSInteger width, NSInteger height, double fps, NSInteger quality) {
    static const double factors[] = {1.6, 1.0, 0.6};
    double pixels = MAX(1, (double)width * height) / (1920.0 * 1080.0);
    double frames = MIN(MAX(fps > 0 ? fps : 30, 15), 240) / 30.0;
    double factor = factors[MIN(MAX(quality, 0), 2)];
    return (long long)(6000000 * pow(pixels, 0.75) * pow(frames, 0.6) * factor);
}

@implementation POVideoInfo
@end

@implementation POVideoJob
@end

@implementation POCompressionOutcome
@end

POVideoJob *POPlanVideo(POVideoInfo *info, NSInteger maxHeight, NSInteger quality) {
    if (info.width <= 0 || info.height <= 0 || info.duration <= 0) return nil;
    CGSize size = POVideoSize(info.width, info.height, maxHeight);
    long long target = POVideoBitrate((NSInteger)size.width, (NSInteger)size.height, info.fps, quality);
    BOOL smaller = size.width < info.width - 1 || size.height < info.height - 1;
    long long source = info.videoBitrate;
    // Never more bits than the video has; and not worth it for a few percent.
    long long bitrate = MIN(target, (long long)(source * 0.9));
    if (!smaller && source < target * 1.3) return nil;
    if (bitrate <= 0) return nil;
    POVideoJob *job = [POVideoJob new];
    job.width = (NSInteger)size.width;
    job.height = (NSInteger)size.height;
    job.bitrate = bitrate;
    job.estimatedSize = (long long)((bitrate + MAX(info.audioBitrate, 0)) * info.duration / 8 * 1.01);
    return job;
}

#pragma mark - Gain maps

/// How a gain map is applied (ISO 21496-1, in stops): HDR = (SDR + offsetSdr) × 2^(min + g^(1/gamma) × (max − min)) −
/// offsetHdr, shown in full on a screen with capacityMax stops of headroom, not at all with capacityMin.
typedef struct {
    double min, max, gamma, offsetSdr, offsetHdr, capacityMin, capacityMax;
    BOOL useBaseColorSpace;
} POGainMapInfo;

/// The light of an sRGB value (0…255) on a linear scale (0…1).
static double POSrgbToLinear(int value) {
    double v = value / 255.0;
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

/// The HDR gain map from the light of each point in the SDR picture and in the HDR one (linear, white = 1), as on
/// Windows: the HDR one is brought to the SDR one's exposure in the mid-tones, then how many stops brighter it is. Nil
/// when there is nothing brighter worth keeping.
static NSData *POWorkOutGainMap(const float *sdr, const float *hdr, NSUInteger count, POGainMapInfo *info) {
    NSMutableData *ratioData = [NSMutableData dataWithLength:count * sizeof(float)];
    float *ratios = ratioData.mutableBytes;
    NSUInteger ratioCount = 0;
    for (NSUInteger i = 0; i < count; i++) {
        if (sdr[i] >= 0.05f && sdr[i] <= 0.5f && hdr[i] > 0) ratios[ratioCount++] = hdr[i] / sdr[i];
    }
    float exposure = 1;
    if (ratioCount >= 100) {
        qsort_b(ratios, ratioCount, sizeof(float), ^int(const void *a, const void *b) {
            float x = *(const float *)a, y = *(const float *)b;
            return x < y ? -1 : x > y ? 1 : 0;
        });
        exposure = ratios[ratioCount / 2];
    }
    if (!(exposure > 0) || isinf(exposure)) exposure = 1;
    const float offset = 1.0f / 64;
    NSMutableData *stopData = [NSMutableData dataWithLength:count * sizeof(float)];
    float *stops = stopData.mutableBytes;
    for (NSUInteger i = 0; i < count; i++) {
        float gain = log2f((MAX(hdr[i], 0) / exposure + offset) / (MAX(sdr[i], 0) + offset));
        stops[i] = isfinite(gain) ? MIN(MAX(gain, 0), (float)POMaxHdrStops) : 0;
    }
    // The brightest 0.1 % sets the top, so that one hot pixel does not flatten the rest.
    NSMutableData *sortedData = [stopData mutableCopy];
    float *sorted = sortedData.mutableBytes;
    qsort_b(sorted, count, sizeof(float), ^int(const void *a, const void *b) {
        float x = *(const float *)a, y = *(const float *)b;
        return x < y ? -1 : x > y ? 1 : 0;
    });
    double maxStops = count ? sorted[MIN(count - 1, (NSUInteger)(count * 0.999))] : 0;
    if (maxStops < 0.1) return nil;
    NSMutableData *map = [NSMutableData dataWithLength:count];
    uint8_t *bytes = map.mutableBytes;
    for (NSUInteger i = 0; i < count; i++) bytes[i] = (uint8_t)lround(MIN(MAX(stops[i] / maxStops, 0), 1) * 255);
    *info = (POGainMapInfo){0, maxStops, 1, offset, offset, 0, maxStops, YES};
    return map;
}

/// The headroom of Apple's gain map from the maker note of the photo (tags 33 and 48), by Apple's formula.
static double POAppleHeadroom(double tag33, double tag48) {
    double stops = tag33 < 1
        ? (tag48 <= 0.01 ? -20 * tag48 + 1.8 : -0.101 * tag48 + 1.601)
        : (tag48 <= 0.01 ? -70 * tag48 + 3.0 : -0.303 * tag48 + 2.303);
    return pow(2, MAX(stops, 0));
}

#pragma mark - JPEG segments

static NSData *POSegment(uint8_t marker, NSData *contents) {
    NSMutableData *segment = [NSMutableData dataWithCapacity:contents.length + 4];
    NSUInteger length = contents.length + 2;
    uint8_t head[4] = {0xFF, marker, (uint8_t)(length >> 8), (uint8_t)length};
    [segment appendBytes:head length:4];
    [segment appendData:contents];
    return segment;
}

static NSData *POASCII(NSString *text) {
    return [text dataUsingEncoding:NSASCIIStringEncoding];
}

static NSData *POXmp(NSString *xml) {
    NSMutableData *data = [POASCII(@"http://ns.adobe.com/xap/1.0/") mutableCopy];
    [data appendBytes:"\0" length:1];
    [data appendData:[xml dataUsingEncoding:NSUTF8StringEncoding]];
    return data;
}

static const char POIsoName[] = "urn:iso:std:iso:ts:21496:-1";   // and its terminating zero

static NSData *POIso(NSData *payload) {
    NSMutableData *data = [NSMutableData dataWithBytes:POIsoName length:sizeof(POIsoName)];
    [data appendData:payload];
    return data;
}

/// The APPn segments of a JPEG up to its picture data: each one's marker and where its contents are.
static void POEachSegment(NSData *jpeg, void (^visit)(uint8_t marker, NSRange segment, NSRange contents, BOOL *stop)) {
    const uint8_t *bytes = jpeg.bytes;
    NSUInteger at = 2, length = jpeg.length;
    BOOL stop = NO;
    while (!stop && at + 4 <= length && bytes[at] == 0xFF && bytes[at + 1] != 0xDA) {
        NSUInteger size = ((NSUInteger)bytes[at + 2] << 8) | bytes[at + 3];
        if (size < 2 || at + 2 + size > length) return;
        visit(bytes[at + 1], NSMakeRange(at, size + 2), NSMakeRange(at + 4, size - 2), &stop);
        at += 2 + size;
    }
}

static BOOL POStartsWith(NSData *data, NSRange range, const void *prefix, NSUInteger prefixLength) {
    return range.length >= prefixLength && memcmp((const uint8_t *)data.bytes + range.location, prefix, prefixLength) == 0;
}

/// `segments` put in a JPEG after the segments it starts with (JFIF, Exif, the colour profile), any XMP of its own
/// dropped: the one put in is the one to read.
static NSData *POInsertSegments(NSData *jpeg, NSArray<NSData *> *segments) {
    __block NSUInteger end = 2;
    NSMutableArray<NSValue *> *dropped = [NSMutableArray array];
    POEachSegment(jpeg, ^(uint8_t marker, NSRange segment, NSRange contents, BOOL *stop) {
        if (marker < 0xE0 || marker > 0xEF) {
            *stop = YES;
            return;
        }
        if (marker == 0xE1 && POStartsWith(jpeg, contents, "http://ns.adobe.com/xap/1.0/", 28)) [dropped addObject:[NSValue valueWithRange:segment]];
        end = NSMaxRange(segment);
    });
    NSMutableData *result = [NSMutableData dataWithCapacity:jpeg.length + 4096];
    NSUInteger at = 0;
    for (NSValue *value in dropped) {
        NSRange range = value.rangeValue;
        [result appendData:[jpeg subdataWithRange:NSMakeRange(at, range.location - at)]];
        at = NSMaxRange(range);
    }
    [result appendData:[jpeg subdataWithRange:NSMakeRange(at, end - at)]];
    for (NSData *segment in segments) [result appendData:segment];
    [result appendData:[jpeg subdataWithRange:NSMakeRange(end, jpeg.length - end)]];
    return result;
}

static void POAppendU16(NSMutableData *data, uint16_t v) {
    uint8_t b[2] = {(uint8_t)(v >> 8), (uint8_t)v};
    [data appendBytes:b length:2];
}

static void POAppendU32(NSMutableData *data, uint32_t v) {
    uint8_t b[4] = {(uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v};
    [data appendBytes:b length:4];
}

/// ISO 21496-1 gain map metadata: one channel, every value a fraction over a million, big-endian.
static NSData *POIsoGainMapMetadata(POGainMapInfo info) {
    const uint32_t denominator = 1000000;
    NSMutableData *data = [NSMutableData data];
    void (^fraction)(double) = ^(double v) {
        POAppendU32(data, (uint32_t)(int32_t)lround(v * denominator));
        POAppendU32(data, denominator);
    };
    POAppendU16(data, 0);   // minimum version
    POAppendU16(data, 0);   // writer version
    uint8_t flags = info.useBaseColorSpace ? 0x40 : 0;   // single channel; the colour space it applies in
    [data appendBytes:&flags length:1];
    fraction(info.capacityMin);   // base HDR headroom (the base picture is SDR)
    fraction(info.capacityMax);   // alternate HDR headroom
    fraction(info.min);
    fraction(info.max);
    fraction(info.gamma);
    fraction(info.offsetSdr);
    fraction(info.offsetHdr);
    return POIso(data);
}

/// The ISO 21496-1 metadata of a gain map JPEG, the first channel's; NO when there is none or it is of a kind not
/// handled (an HDR base picture).
static BOOL POReadIsoGainMapMetadata(NSData *gainMap, POGainMapInfo *info) {
    __block BOOL found = NO;
    POEachSegment(gainMap, ^(uint8_t marker, NSRange segment, NSRange contents, BOOL *stop) {
        if (marker != 0xE2 || !POStartsWith(gainMap, contents, POIsoName, sizeof(POIsoName)) || contents.length < sizeof(POIsoName) + 5) return;
        *stop = YES;
        const uint8_t *bytes = (const uint8_t *)gainMap.bytes + contents.location;
        NSUInteger length = contents.length;
        __block NSUInteger at = sizeof(POIsoName) + 4;   // after the versions
        uint8_t flags = bytes[at++];
        if (flags & 0x04) return;   // the base picture is the HDR one
        __block BOOL overrun = NO;
        uint32_t (^u32)(void) = ^uint32_t {
            if (at + 4 > length) { overrun = YES; return 0; }
            uint32_t v = ((uint32_t)bytes[at] << 24) | ((uint32_t)bytes[at + 1] << 16) | ((uint32_t)bytes[at + 2] << 8) | bytes[at + 3];
            at += 4;
            return v;
        };
        double (^ratio)(double, uint32_t) = ^double(double n, uint32_t d) { return d == 0 ? 0 : n / d; };
        double values[7];
        if (flags & 0x08) {
            // One denominator for everything.
            uint32_t d = u32();
            values[0] = ratio(u32(), d);
            values[1] = ratio(u32(), d);
            values[2] = ratio((int32_t)u32(), d);
            values[3] = ratio((int32_t)u32(), d);
            values[4] = ratio(u32(), d);
            values[5] = ratio((int32_t)u32(), d);
            values[6] = ratio((int32_t)u32(), d);
        } else {
            for (int i = 0; i < 7; i++) {
                // Headrooms and the gamma are unsigned, the rest signed.
                uint32_t n = u32();
                uint32_t d = u32();
                values[i] = ratio(i == 0 || i == 1 || i == 4 ? (double)n : (double)(int32_t)n, d);
            }
        }
        if (overrun || values[3] <= values[2] || values[4] <= 0) return;
        *info = (POGainMapInfo){values[2], values[3], values[4], values[5], values[6], values[0], values[1], (flags & 0x40) != 0};
        found = YES;
    });
    return found;
}

/// The MP index of two pictures, little-endian: the primary at 0, the gain map at `offset` (from the TIFF header).
static NSData *POMultiPictureIndex(uint32_t primarySize, uint32_t gainMapSize, uint32_t offset) {
    uint8_t data[4 + 8 + 2 + 3 * 12 + 4 + 32] = {0};
    memcpy(data, "MPF\0", 4);
    uint8_t *tiff = data + 4;
    memcpy(tiff, "II*\0", 4);
    void (^u16)(uint8_t *, uint16_t) = ^(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); };
    void (^u32)(uint8_t *, uint32_t) = ^(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24); };
    u32(tiff + 4, 8);
    u16(tiff + 8, 3);
    void (^entry)(int, uint16_t, uint16_t, uint32_t, uint32_t) = ^(int index, uint16_t tag, uint16_t type, uint32_t count, uint32_t value) {
        uint8_t *p = tiff + 10 + index * 12;
        u16(p, tag);
        u16(p + 2, type);
        u32(p + 4, count);
        u32(p + 8, value);
    };
    entry(0, 0xB000, 7, 4, (uint32_t)'0' | ((uint32_t)'1' << 8) | ((uint32_t)'0' << 16) | ((uint32_t)'0' << 24));   // version "0100"
    entry(1, 0xB001, 4, 1, 2);                                                                                          // two pictures
    uint32_t entries = 10 + 3 * 12 + 4;
    entry(2, 0xB002, 7, 32, entries);
    uint8_t *list = tiff + entries;
    u32(list, 0x030000);   // the primary, a baseline JPEG
    u32(list + 4, primarySize);
    u32(list + 20, gainMapSize);
    u32(list + 24, offset);
    return [NSData dataWithBytes:data length:sizeof(data)];
}

/// The second picture of a JPEG with a Multi-Picture index (a gain map, a depth map…); NSNotFound when there is none.
static NSRange POSecondPicture(NSData *jpeg) {
    __block NSRange found = NSMakeRange(NSNotFound, 0);
    POEachSegment(jpeg, ^(uint8_t marker, NSRange segment, NSRange contents, BOOL *stop) {
        if (marker != 0xE2 || !POStartsWith(jpeg, contents, "MPF\0", 4) || contents.length < 16) return;
        *stop = YES;
        const uint8_t *tiff = (const uint8_t *)jpeg.bytes + contents.location + 4;
        NSUInteger length = contents.length - 4, start = contents.location + 4;
        BOOL little = tiff[0] == 'I';
        uint32_t (^u32)(NSUInteger) = ^uint32_t(NSUInteger at) {
            if (at + 4 > length) return 0;
            return little ? (uint32_t)tiff[at] | ((uint32_t)tiff[at + 1] << 8) | ((uint32_t)tiff[at + 2] << 16) | ((uint32_t)tiff[at + 3] << 24)
                          : ((uint32_t)tiff[at] << 24) | ((uint32_t)tiff[at + 1] << 16) | ((uint32_t)tiff[at + 2] << 8) | tiff[at + 3];
        };
        uint16_t (^u16)(NSUInteger) = ^uint16_t(NSUInteger at) {
            if (at + 2 > length) return 0;
            return little ? (uint16_t)(tiff[at] | (tiff[at + 1] << 8)) : (uint16_t)((tiff[at] << 8) | tiff[at + 1]);
        };
        NSUInteger ifd = u32(4);
        for (NSUInteger i = 0, count = u16(ifd); i < count; i++) {
            NSUInteger entry = ifd + 2 + i * 12;
            if (u16(entry) != 0xB002 || u32(entry + 4) < 32) continue;
            NSUInteger list = u32(entry + 8);
            NSUInteger size = u32(list + 16 + 4), offset = u32(list + 16 + 8);
            if (offset > 0 && size > 0 && start + offset + size <= jpeg.length) found = NSMakeRange(start + offset, size);
            return;
        }
    });
    return found;
}

/// One JPEG of the SDR picture and its gain map, as on Windows (Ultra HDR, with ISO 21496-1 metadata): the gain map
/// goes after the picture, the Multi-Picture index says where. `gainMapSegments` go into the gain map.
static NSData *POUltraHdr(NSData *primary, NSData *gainMap, POGainMapInfo info, NSArray<NSData *> *gainMapSegments) {
    NSString *(^n)(double) = ^NSString *(double v) {
        NSString *text = [NSString stringWithFormat:@"%.6f", v];
        while ([text containsString:@"."] && ([text hasSuffix:@"0"] || [text hasSuffix:@"."])) text = [text substringToIndex:text.length - 1];
        return text;
    };
    NSString *gainMapXmp = [NSString stringWithFormat:
        @"<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"Photo Organizer\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
        @"<rdf:Description rdf:about=\"\" xmlns:hdrgm=\"http://ns.adobe.com/hdr-gain-map/1.0/\" hdrgm:Version=\"1.0\""
        @" hdrgm:GainMapMin=\"%@\" hdrgm:GainMapMax=\"%@\" hdrgm:Gamma=\"%@\" hdrgm:OffsetSDR=\"%@\" hdrgm:OffsetHDR=\"%@\""
        @" hdrgm:HDRCapacityMin=\"%@\" hdrgm:HDRCapacityMax=\"%@\" hdrgm:BaseRenditionIsHDR=\"False\"/></rdf:RDF></x:xmpmeta>",
        n(info.min), n(info.max), n(info.gamma), n(info.offsetSdr), n(info.offsetHdr), n(info.capacityMin), n(info.capacityMax)];
    NSArray<NSData *> *mapSegments = [@[POSegment(0xE1, POXmp(gainMapXmp)), POSegment(0xE2, POIsoGainMapMetadata(info))]
                                      arrayByAddingObjectsFromArray:gainMapSegments];
    NSData *secondary = POInsertSegments(gainMap, mapSegments);

    NSString *primaryXmp = [NSString stringWithFormat:
        @"<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"Photo Organizer\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
        @"<rdf:Description rdf:about=\"\" xmlns:Container=\"http://ns.google.com/photos/1.0/container/\""
        @" xmlns:Item=\"http://ns.google.com/photos/1.0/container/item/\" xmlns:hdrgm=\"http://ns.adobe.com/hdr-gain-map/1.0/\" hdrgm:Version=\"1.0\">"
        @"<Container:Directory><rdf:Seq>"
        @"<rdf:li rdf:parseType=\"Resource\"><Container:Item Item:Semantic=\"Primary\" Item:Mime=\"image/jpeg\"/></rdf:li>"
        @"<rdf:li rdf:parseType=\"Resource\"><Container:Item Item:Semantic=\"GainMap\" Item:Mime=\"image/jpeg\" Item:Length=\"%lu\"/></rdf:li>"
        @"</rdf:Seq></Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>", (unsigned long)secondary.length];
    // The Multi-Picture index is written last, once the offset of the gain map is known.
    NSData *placeholder = POSegment(0xE2, POMultiPictureIndex(0, 0, 0));
    NSData *version = POSegment(0xE2, POIso([NSData dataWithBytes:"\0\0\0\0" length:4]));
    NSMutableData *first = [POInsertSegments(primary, @[POSegment(0xE1, POXmp(primaryXmp)), version, placeholder]) mutableCopy];
    NSRange at = [first rangeOfData:placeholder options:0 range:NSMakeRange(0, first.length)];
    NSUInteger tiff = at.location + 8;   // the marker and length, then "MPF\0": offsets count from there
    NSData *index = POSegment(0xE2, POMultiPictureIndex((uint32_t)first.length, (uint32_t)secondary.length, (uint32_t)(first.length - tiff)));
    [first replaceBytesInRange:at withBytes:index.bytes];
    [first appendData:secondary];
    return first;
}

#pragma mark - DNG

/// Where the largest JPEG picture in a TIFF-based RAW file is (the camera's preview), and the size of the RAW data.
typedef struct {
    NSRange preview;
    NSInteger rawWidth, rawHeight;
} PORawLayout;

typedef struct {
    const uint8_t *bytes;
    NSUInteger length;
    BOOL little;
} POTiff;

static uint32_t POTiffU16(const POTiff *t, NSUInteger at) {
    if (at + 2 > t->length) return 0;
    const uint8_t *p = t->bytes + at;
    return t->little ? (uint32_t)(p[0] | (p[1] << 8)) : (uint32_t)((p[0] << 8) | p[1]);
}

static uint32_t POTiffU32(const POTiff *t, NSUInteger at) {
    if (at + 4 > t->length) return 0;
    const uint8_t *p = t->bytes + at;
    return t->little ? (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24)
                     : ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static NSUInteger POTiffTypeSize(uint32_t type) {
    switch (type) {
        case 3: case 8: return 2;
        case 4: case 9: case 11: case 13: return 4;
        case 5: case 10: case 12: return 8;
        default: return 1;
    }
}

/// The `index`th value of a directory entry (BYTE, SHORT or LONG).
static uint32_t POTiffValue(const POTiff *t, NSUInteger entry, uint32_t index) {
    uint32_t type = POTiffU16(t, entry + 2), count = POTiffU32(t, entry + 4);
    if (index >= count) return 0;
    NSUInteger size = POTiffTypeSize(type);
    NSUInteger at = size * count <= 4 ? entry + 8 : POTiffU32(t, entry + 8);
    at += index * size;
    if (size == 2) return POTiffU16(t, at);
    if (size == 4) return POTiffU32(t, at);
    return at < t->length ? t->bytes[at] : 0;
}

static void POTiffWalk(const POTiff *t, NSUInteger at, int depth, PORawLayout *layout, NSInteger *bestArea) {
    NSUInteger count = POTiffU16(t, at);
    if (count == 0 || count > 1000 || at + 2 + count * 12 > t->length) return;
    uint32_t width = 0, height = 0, compression = 1, photometric = 0, subfile = 0, strip = 0, stripLength = 0, stripCount = 0, jpeg = 0, jpegLength = 0;
    NSMutableArray<NSNumber *> *children = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        NSUInteger entry = at + 2 + i * 12;
        switch (POTiffU16(t, entry)) {
            case 254: subfile = POTiffValue(t, entry, 0); break;
            case 256: width = POTiffValue(t, entry, 0); break;
            case 257: height = POTiffValue(t, entry, 0); break;
            case 259: compression = POTiffValue(t, entry, 0); break;
            case 262: photometric = POTiffValue(t, entry, 0); break;
            case 273: strip = POTiffValue(t, entry, 0); stripCount = POTiffU32(t, entry + 4); break;
            case 279: stripLength = POTiffValue(t, entry, 0); break;
            case 513: jpeg = POTiffValue(t, entry, 0); break;
            case 514: jpegLength = POTiffValue(t, entry, 0); break;
            case 330:
                for (uint32_t k = 0, n = MIN(POTiffU32(t, entry + 4), 16u); k < n; k++) [children addObject:@(POTiffValue(t, entry, k))];
                break;
        }
    }
    if (subfile == 0 && (photometric == 32803 || photometric == 34892) && (NSInteger)width * height > layout->rawWidth * layout->rawHeight) {
        layout->rawWidth = width;
        layout->rawHeight = height;
    }
    NSRange candidate = NSMakeRange(NSNotFound, 0);
    if (compression == 7 && photometric == 6 && stripCount == 1) candidate = NSMakeRange(strip, stripLength);
    else if (jpeg && jpegLength) candidate = NSMakeRange(jpeg, jpegLength);
    if (candidate.location != NSNotFound && NSMaxRange(candidate) <= t->length && candidate.length > 4
        && t->bytes[candidate.location] == 0xFF && t->bytes[candidate.location + 1] == 0xD8) {
        NSInteger area = (NSInteger)width * height;
        if (area <= 0) area = (NSInteger)candidate.length;   // no size given: the larger file is the larger picture
        if (area > *bestArea) {
            *bestArea = area;
            layout->preview = candidate;
        }
    }
    if (depth < 3) {
        for (NSNumber *child in children) {
            if (child.unsignedIntegerValue > 0) POTiffWalk(t, child.unsignedIntegerValue, depth + 1, layout, bestArea);
        }
    }
}

static PORawLayout PORawLayoutOf(NSData *data) {
    PORawLayout layout = {NSMakeRange(NSNotFound, 0), 0, 0};
    const uint8_t *bytes = data.bytes;
    if (data.length < 8 || !((bytes[0] == 'I' && bytes[1] == 'I') || (bytes[0] == 'M' && bytes[1] == 'M'))) return layout;
    POTiff tiff = {bytes, data.length, bytes[0] == 'I'};
    if (POTiffU16(&tiff, 2) != 42) return layout;
    NSInteger bestArea = 0;
    NSUInteger at = POTiffU32(&tiff, 4);
    for (int i = 0; i < 8 && at > 0 && at < data.length; i++) {
        POTiffWalk(&tiff, at, 0, &layout, &bestArea);
        NSUInteger count = POTiffU16(&tiff, at);
        at = POTiffU32(&tiff, at + 2 + count * 12);
    }
    return layout;
}

#pragma mark - Pictures

static CGSize POImageSize(NSData *data) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return CGSizeZero;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    CFRelease(source);
    return CGSizeMake([properties[(id)kCGImagePropertyPixelWidth] doubleValue], [properties[(id)kCGImagePropertyPixelHeight] doubleValue]);
}

/// A JPEG decoded at most `maxSide` across, as stored (not turned: the orientation goes along in the metadata).
static CGImageRef POCreateScaledImage(NSData *data, NSInteger maxSide) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return NULL;
    NSDictionary *options = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                              (id)kCGImageSourceThumbnailMaxPixelSize: @(maxSide),
                              (id)kCGImageSourceCreateThumbnailWithTransform: @NO,
                              (id)kCGImageSourceShouldCacheImmediately: @YES};
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    return image;
}

/// The values of a one-channel picture (a gain map) as they are, without colour conversion.
static NSMutableData *POGrayValues(CGImageRef image, size_t *width, size_t *height) {
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    *width = w;
    *height = h;
    CGColorSpaceRef space = CGImageGetColorSpace(image);
    BOOL mono = space && CGColorSpaceGetModel(space) == kCGColorSpaceModelMonochrome;
    if (mono) {
        NSMutableData *values = [NSMutableData dataWithLength:w * h];
        CGContextRef context = CGBitmapContextCreate(values.mutableBytes, w, h, 8, w, space, (CGBitmapInfo)kCGImageAlphaNone);
        if (!context) return nil;
        CGContextDrawImage(context, CGRectMake(0, 0, w, h), image);
        CGContextRelease(context);
        return values;
    }
    // Decoded as colour: in its own colour space, so that nothing is converted; the first channel is the value.
    NSMutableData *rgba = [NSMutableData dataWithLength:w * h * 4];
    CGColorSpaceRef rgb = space && CGColorSpaceGetModel(space) == kCGColorSpaceModelRGB ? CGColorSpaceRetain(space) : CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(rgba.mutableBytes, w, h, 8, w * 4, rgb, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(rgb);
    if (!context) return nil;
    CGContextDrawImage(context, CGRectMake(0, 0, w, h), image);
    CGContextRelease(context);
    NSMutableData *values = [NSMutableData dataWithLength:w * h];
    const uint8_t *source = rgba.bytes;
    uint8_t *target = values.mutableBytes;
    for (size_t i = 0; i < w * h; i++) target[i] = source[i * 4];
    return values;
}

/// A one-channel JPEG of the values.
static NSData *POGrayJpeg(NSData *values, size_t width, size_t height) {
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)values);
    CGImageRef image = CGImageCreate(width, height, 8, 8, width, gray, (CGBitmapInfo)kCGImageAlphaNone, provider, NULL, NO, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(gray);
    if (!image) return nil;
    NSMutableData *jpeg = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, NULL);
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality: @(POJpegQuality)});
    BOOL done = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    return done ? jpeg : nil;
}

static double POXmpNumber(NSString *xmp, NSString *name) {
    NSRange range = [xmp rangeOfString:name];
    if (range.location == NSNotFound) return 0;
    NSScanner *scanner = [NSScanner scannerWithString:[xmp substringFromIndex:NSMaxRange(range)]];
    scanner.charactersToBeSkipped = [NSCharacterSet characterSetWithCharactersInString:@">=\" \n\t"];
    double value = 0;
    return [scanner scanDouble:&value] ? value : 0;
}

/// The gain map the camera put in its preview, brought to `width` across: as it is when it already says how to apply
/// it (ISO 21496-1), turned into one that does when it is Apple's own. Nil when the preview has none.
static NSData *POCameraGainMap(NSData *preview, NSDictionary *properties, NSInteger width, NSInteger previewWidth,
                               POGainMapInfo *info, NSArray<NSData *> **segments) {
    NSRange second = POSecondPicture(preview);
    if (second.location == NSNotFound) return nil;
    NSData *map = [preview subdataWithRange:second];
    NSString *head = [[NSString alloc] initWithData:[map subdataWithRange:NSMakeRange(0, MIN(map.length, 4096))] encoding:NSISOLatin1StringEncoding] ?: @"";
    BOOL apple = [head containsString:@"urn:com:apple:photo:2020:aux:hdrgainmap"];
    POGainMapInfo iso;
    BOOL hasIso = POReadIsoGainMapMetadata(map, &iso);
    if (!apple && !hasIso) return nil;   // a depth map or some other picture

    // The map keeps its proportion to the picture (Apple's is half of it, or all of it).
    CGSize mapSize = POImageSize(map);
    NSInteger mapWidth = MAX(1, (NSInteger)llround(mapSize.width * width / MAX(1, previewWidth)));
    NSInteger mapSide = (NSInteger)llround(MAX(mapSize.width, mapSize.height) * mapWidth / MAX(1.0, mapSize.width));
    CGImageRef scaled = POCreateScaledImage(map, mapSide);
    if (!scaled) return nil;
    size_t w = 0, h = 0;
    NSMutableData *values = POGrayValues(scaled, &w, &h);
    CGImageRelease(scaled);
    if (!values) return nil;

    *segments = @[];
    if (hasIso) {
        *info = iso;
        // Applied in the HDR picture's colours: the map's own profile says which.
        if (!iso.useBaseColorSpace) {
            NSMutableArray<NSData *> *profiles = [NSMutableArray array];
            POEachSegment(map, ^(uint8_t marker, NSRange segment, NSRange contents, BOOL *stop) {
                if (marker == 0xE2 && POStartsWith(map, contents, "ICC_PROFILE\0", 12)) [profiles addObject:[map subdataWithRange:segment]];
            });
            *segments = profiles;
        }
    } else {
        double headroom = POXmpNumber(head, @"HDRGainMap:HDRGainMapHeadroom");
        NSDictionary *maker = properties[(id)kCGImagePropertyMakerAppleDictionary];
        if (headroom <= 0 && maker[@"33"] && maker[@"48"]) headroom = POAppleHeadroom([maker[@"33"] doubleValue], [maker[@"48"] doubleValue]);
        if (headroom <= 1.01) return nil;
        // Apple's: HDR = SDR × (1 + (headroom − 1) × g), g on a linear scale; as ISO 21496-1, log2 of that over log2 of the headroom.
        double stops = log2(headroom);
        uint8_t table[256];
        for (int v = 0; v < 256; v++) {
            double gain = 1 + (headroom - 1) * POSrgbToLinear(v);
            table[v] = (uint8_t)lround(MIN(MAX(log2(gain) / stops, 0), 1) * 255);
        }
        uint8_t *bytes = values.mutableBytes;
        for (NSUInteger i = 0; i < values.length; i++) bytes[i] = table[bytes[i]];
        *info = (POGainMapInfo){0, stops, 1, 0, 0, 0, stops, YES};
    }
    return POGrayJpeg(values, w, h);
}

/// The light of each pixel of a float RGBA picture (linear Display P3).
static NSMutableData *POLight(CIContext *context, CIImage *image, CGRect rect, CGColorSpaceRef linear) {
    CGImageRef rendered = [context createCGImage:image fromRect:rect format:kCIFormatRGBAf colorSpace:linear];
    if (!rendered) return nil;
    NSData *pixels = CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(rendered)));
    size_t w = CGImageGetWidth(rendered), h = CGImageGetHeight(rendered), row = CGImageGetBytesPerRow(rendered);
    CGImageRelease(rendered);
    NSMutableData *light = [NSMutableData dataWithLength:w * h * sizeof(float)];
    float *out = light.mutableBytes;
    for (size_t y = 0; y < h; y++) {
        const float *p = (const float *)((const uint8_t *)pixels.bytes + y * row);
        for (size_t x = 0; x < w; x++) out[y * w + x] = 0.2290f * p[x * 4] + 0.6917f * p[x * 4 + 1] + 0.0793f * p[x * 4 + 2];
    }
    return light;
}

/// The metadata of the RAW for the JPEG: the camera, the time, the place, Apple's maker note; the new size and orientation.
static NSDictionary *POPhotoMetadata(NSDictionary *properties, NSInteger width, NSInteger height, NSInteger orientation) {
    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    for (NSString *key in @[(id)kCGImagePropertyGPSDictionary, (id)kCGImagePropertyMakerAppleDictionary]) {
        if (properties[key]) metadata[key] = properties[key];
    }
    NSMutableDictionary *exif = [properties[(id)kCGImagePropertyExifDictionary] mutableCopy] ?: [NSMutableDictionary dictionary];
    exif[(id)kCGImagePropertyExifPixelXDimension] = @(width);
    exif[(id)kCGImagePropertyExifPixelYDimension] = @(height);
    metadata[(id)kCGImagePropertyExifDictionary] = exif;
    NSMutableDictionary *tiff = [NSMutableDictionary dictionary];
    NSDictionary *rawTiff = properties[(id)kCGImagePropertyTIFFDictionary];
    for (NSString *key in @[(id)kCGImagePropertyTIFFMake, (id)kCGImagePropertyTIFFModel, (id)kCGImagePropertyTIFFSoftware,
                            (id)kCGImagePropertyTIFFDateTime, (id)kCGImagePropertyTIFFArtist, (id)kCGImagePropertyTIFFCopyright]) {
        if (rawTiff[key]) tiff[key] = rawTiff[key];
    }
    tiff[(id)kCGImagePropertyTIFFOrientation] = @(orientation);
    metadata[(id)kCGImagePropertyTIFFDictionary] = tiff;
    metadata[(id)kCGImagePropertyOrientation] = @(orientation);
    metadata[(id)kCGImageDestinationLossyCompressionQuality] = @(POJpegQuality);
    return metadata;
}

NSData *POCompressRawPhoto(NSURL *url, NSInteger megapixels, BOOL *hdr, NSString **error) {
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&readError];
    if (!data) {
        if (error) *error = readError.localizedDescription;
        return nil;
    }
    CGImageSourceRef rawSource = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    NSDictionary *properties = rawSource ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(rawSource, 0, NULL)) : @{};
    if (rawSource) CFRelease(rawSource);

    // The camera's own picture whenever it is large enough for the size asked (a full-size one in older ProRAW, a
    // 12 MP one since iOS 18); Core Image's rendering of the RAW otherwise.
    PORawLayout layout = PORawLayoutOf(data);
    NSData *preview = layout.preview.location != NSNotFound ? [data subdataWithRange:layout.preview] : nil;
    CGSize previewSize = preview ? POImageSize(preview) : CGSizeZero;
    double previewArea = previewSize.width * previewSize.height;
    BOOL usePreview = preview && previewArea > 0
        && (layout.rawWidth == 0 || previewArea >= MIN((double)layout.rawWidth * layout.rawHeight * 0.8, megapixels * 1e6 * 0.97));

    CGImageRef picture = NULL;
    NSInteger orientation = 1;
    NSData *gainMap = nil;
    POGainMapInfo info = {0};
    NSArray<NSData *> *gainMapSegments = @[];
    if (usePreview) {
        CGSize size = POCompressedPhotoSize((NSInteger)previewSize.width, (NSInteger)previewSize.height, megapixels);
        picture = POCreateScaledImage(preview, (NSInteger)MAX(size.width, size.height));
        orientation = [properties[(id)kCGImagePropertyOrientation] integerValue] ?: 1;
        if (picture) {
            gainMap = POCameraGainMap(preview, properties, (NSInteger)CGImageGetWidth(picture), (NSInteger)previewSize.width, &info, &gainMapSegments);
        }
    } else {
        CIRAWFilter *filter = [CIRAWFilter filterWithImageURL:url];
        CGSize native = filter.nativeSize;
        if (filter && native.width > 0) {
            CGSize size = POCompressedPhotoSize((NSInteger)native.width, (NSInteger)native.height, megapixels);
            float scale = (float)(size.width / native.width);
            filter.scaleFactor = scale;
            CIImage *image = filter.outputImage;
            CIContext *context = [CIContext contextWithOptions:@{kCIContextCacheIntermediates: @NO}];
            CGColorSpaceRef p3 = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
            if (image) picture = [context createCGImage:image fromRect:image.extent format:kCIFormatRGBA8 colorSpace:p3];
            CGColorSpaceRelease(p3);
            // Core Image turns the picture upright.
            orientation = 1;
            // The HDR rendition Core Image makes of the RAW, when the camera recorded more than SDR shows.
            if (picture && filter.maximumExtendedDynamicRangeAmount > 0) {
                CIRAWFilter *bright = [CIRAWFilter filterWithImageURL:url], *plain = [CIRAWFilter filterWithImageURL:url];
                bright.scaleFactor = plain.scaleFactor = scale / POGainMapScale;
                bright.extendedDynamicRangeAmount = 1;
                CIImage *hdrImage = bright.outputImage, *sdrImage = plain.outputImage;
                CGColorSpaceRef linear = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
                CGRect rect = CGRectIntersection(CGRectIntegral(hdrImage.extent), CGRectIntegral(sdrImage.extent));
                NSMutableData *hdrLight = hdrImage && sdrImage ? POLight(context, hdrImage, rect, linear) : nil;
                NSMutableData *sdrLight = hdrLight ? POLight(context, sdrImage, rect, linear) : nil;
                CGColorSpaceRelease(linear);
                if (hdrLight && sdrLight && hdrLight.length == sdrLight.length) {
                    NSData *map = POWorkOutGainMap(sdrLight.bytes, hdrLight.bytes, sdrLight.length / sizeof(float), &info);
                    if (map) gainMap = POGrayJpeg(map, (size_t)rect.size.width, (size_t)rect.size.height);
                }
            }
        }
    }
    if (!picture) {
        if (error) *error = POL(@"Не удалось прочитать RAW");
        return nil;
    }
    NSMutableData *primary = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)primary, CFSTR("public.jpeg"), 1, NULL);
    CGImageDestinationAddImage(destination, picture,
        (__bridge CFDictionaryRef)POPhotoMetadata(properties, (NSInteger)CGImageGetWidth(picture), (NSInteger)CGImageGetHeight(picture), orientation));
    BOOL written = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(picture);
    if (!written) {
        if (error) *error = POL(@"Не удалось записать JPEG");
        return nil;
    }
    if (hdr) *hdr = gainMap != nil;
    return gainMap ? POUltraHdr(primary, gainMap, info, gainMapSegments) : primary;
}

#pragma mark - Videos

POVideoInfo *POProbeVideo(NSURL *url) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) return nil;
    CGSize size = CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform);
    POVideoInfo *info = [POVideoInfo new];
    info.width = (NSInteger)llround(fabs(size.width));
    info.height = (NSInteger)llround(fabs(size.height));
    info.fps = track.nominalFrameRate;
    info.duration = CMTimeGetSeconds(asset.duration);
    info.videoBitrate = (long long)track.estimatedDataRate;
    AVAssetTrack *audio = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    info.audioBitrate = audio ? (long long)audio.estimatedDataRate : 0;
    CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
    if (format) {
        CFPropertyListRef transfer = CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_TransferFunction);
        info.hdr = transfer && (CFEqual(transfer, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG)
                                || CFEqual(transfer, kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ));
        CFPropertyListRef bits = CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_BitsPerComponent);
        info.tenBit = info.hdr || (bits && [(__bridge NSNumber *)bits integerValue] > 8);
    }
    if (info.width <= 0 || info.height <= 0 || !(info.duration > 0)) return nil;
    return info;
}

/// Feeds a writer input from a reader output until the output runs dry, writing fails or `stop` says so.
static void POPump(AVAssetWriterInput *input, AVAssetReaderTrackOutput *output, dispatch_group_t group, BOOL (^stop)(void),
                   void (^_Nullable seen)(CMSampleBufferRef sample)) {
    dispatch_queue_t queue = dispatch_queue_create("photo-organizer.compress", DISPATCH_QUEUE_SERIAL);
    dispatch_group_enter(group);
    __block BOOL finished = NO;
    [input requestMediaDataWhenReadyOnQueue:queue usingBlock:^{
        if (finished) return;
        while (input.isReadyForMoreMediaData) {
            CMSampleBufferRef sample = stop() ? NULL : [output copyNextSampleBuffer];
            BOOL appended = NO;
            if (sample) {
                if (seen) seen(sample);
                appended = [input appendSampleBuffer:sample];
                CFRelease(sample);
            }
            if (!appended) {
                finished = YES;
                [input markAsFinished];
                dispatch_group_leave(group);
                return;
            }
        }
    }];
}

/// Writes the compressed video to `destination`; nil when it worked, what went wrong otherwise.
static NSString *POEncodeVideo(NSURL *source, NSURL *destination, POVideoInfo *info, POVideoJob *job,
                               void (^progress)(double), BOOL (^cancelled)(void)) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:source options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    AVAssetTrack *videoTrack = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetTrack *audioTrack = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!videoTrack) return POL(@"В файле нет видео");
    NSError *error = nil;
    NSString *extension = source.pathExtension.lowercaseString;
    AVFileType type = [extension isEqualToString:@"mp4"] || [extension isEqualToString:@"m4v"] ? AVFileTypeMPEG4 : AVFileTypeQuickTimeMovie;
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:destination fileType:type error:&error];
    if (!writer) return error.localizedDescription;
    BOOL tenBit = info.tenBit || info.hdr;
    // The frames are written as they are stored, turned by the track's transform: the size asked is upright.
    CGAffineTransform transform = videoTrack.preferredTransform;
    BOOL turned = fabs(transform.b) > 0.5 && fabs(transform.c) > 0.5;
    NSDictionary *compression = @{AVVideoAverageBitRateKey: @(job.bitrate),
                                  AVVideoExpectedSourceFrameRateKey: @(MAX(1, (NSInteger)llround(info.fps))),
                                  AVVideoProfileLevelKey: tenBit ? (__bridge NSString *)kVTProfileLevel_HEVC_Main10_AutoLevel
                                                                 : (__bridge NSString *)kVTProfileLevel_HEVC_Main_AutoLevel};
    NSMutableDictionary *settings = [@{AVVideoCodecKey: AVVideoCodecTypeHEVC,
                                       AVVideoWidthKey: @(turned ? job.height : job.width),
                                       AVVideoHeightKey: @(turned ? job.width : job.height),
                                       AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
                                       AVVideoCompressionPropertiesKey: compression} mutableCopy];
    // The colour description, so that HDR stays HDR.
    CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)videoTrack.formatDescriptions.firstObject;
    if (format) {
        id primaries = (__bridge id)CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_ColorPrimaries);
        id transfer = (__bridge id)CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_TransferFunction);
        id matrix = (__bridge id)CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_YCbCrMatrix);
        if (primaries && transfer && matrix) {
            settings[AVVideoColorPropertiesKey] = @{AVVideoColorPrimariesKey: primaries, AVVideoTransferFunctionKey: transfer, AVVideoYCbCrMatrixKey: matrix};
        }
    }
    AVAssetWriterInput *videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    videoInput.transform = transform;
    videoInput.expectsMediaDataInRealTime = NO;
    if (![writer canAddInput:videoInput]) return POL(@"Этот Mac не умеет кодировать HEVC");
    [writer addInput:videoInput];
    AVAssetWriterInput *audioInput = nil;
    if (audioTrack) {
        CMFormatDescriptionRef audioFormat = (__bridge CMFormatDescriptionRef)audioTrack.formatDescriptions.firstObject;
        audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:nil sourceFormatHint:audioFormat];
        audioInput.expectsMediaDataInRealTime = NO;
        if ([writer canAddInput:audioInput]) [writer addInput:audioInput];
        else audioInput = nil;
    }
    // The capture date, the place and the camera.
    writer.metadata = type == AVFileTypeQuickTimeMovie ? asset.metadata : asset.commonMetadata;
    writer.shouldOptimizeForNetworkUse = YES;

    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (!reader) return error.localizedDescription;
    NSDictionary *pixels = @{(id)kCVPixelBufferPixelFormatTypeKey: @(tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                                                            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
    AVAssetReaderTrackOutput *videoOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:pixels];
    videoOutput.alwaysCopiesSampleData = NO;
    [reader addOutput:videoOutput];
    AVAssetReaderTrackOutput *audioOutput = nil;
    if (audioInput) {
        audioOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:nil];
        audioOutput.alwaysCopiesSampleData = NO;
        [reader addOutput:audioOutput];
    }
    if (![reader startReading]) return reader.error.localizedDescription ?: POL(@"Не удалось прочитать видео");
    if (![writer startWriting]) {
        [reader cancelReading];
        return writer.error.localizedDescription ?: POL(@"Не удалось записать видео");
    }
    [writer startSessionAtSourceTime:kCMTimeZero];
    dispatch_group_t group = dispatch_group_create();
    double duration = MAX(info.duration, 0.001);
    POPump(videoInput, videoOutput, group, cancelled, ^(CMSampleBufferRef sample) {
        if (progress) progress(MIN(MAX(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) / duration, 0), 1));
    });
    if (audioInput) POPump(audioInput, audioOutput, group, cancelled, nil);
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    if (cancelled() || reader.status == AVAssetReaderStatusFailed || writer.status == AVAssetWriterStatusFailed) {
        NSString *why = cancelled() ? POL(@"Остановлено")
                      : (writer.error ?: reader.error).localizedDescription ?: POL(@"Не удалось записать видео");
        [reader cancelReading];
        [writer cancelWriting];
        [NSFileManager.defaultManager removeItemAtURL:destination error:NULL];
        return why;
    }
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(finished); }];
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) {
        [NSFileManager.defaultManager removeItemAtURL:destination error:NULL];
        return writer.error.localizedDescription ?: POL(@"Не удалось записать видео");
    }
    // What came out must be the whole video.
    POVideoInfo *result = POProbeVideo(destination);
    if (!result || fabs(result.duration - info.duration) > MAX(1, info.duration * 0.02)) {
        [NSFileManager.defaultManager removeItemAtURL:destination error:NULL];
        return POL(@"Сжатое видео получилось неполным");
    }
    return nil;
}

#pragma mark - Replacing the originals

/// Hidden next to the file (the scan skips hidden files), with the extension AVFoundation and ImageIO expect.
static NSURL *POTemporaryURL(NSURL *source, NSString *extension) {
    NSString *name = [NSString stringWithFormat:@".%@.po-compressing.%@", source.lastPathComponent, extension];
    return [source.URLByDeletingLastPathComponent URLByAppendingPathComponent:name];
}

static NSURL *POFreeURL(NSURL *url) {
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files fileExistsAtPath:url.path]) return url;
    NSURL *folder = url.URLByDeletingLastPathComponent;
    NSString *name = url.lastPathComponent.stringByDeletingPathExtension, *extension = url.pathExtension;
    for (NSInteger n = 2;; n++) {
        NSURL *candidate = [folder URLByAppendingPathComponent:[[NSString stringWithFormat:@"%@ (%ld)", name, (long)n] stringByAppendingPathExtension:extension]];
        if (![files fileExistsAtPath:candidate.path]) return candidate;
    }
}

static POCompressionOutcome *POOutcome(POPhotoItem *item, NSURL *compressed, long long before, long long after, BOOL hdr, NSString *error) {
    POCompressionOutcome *outcome = [POCompressionOutcome new];
    outcome.item = item;
    outcome.compressedURL = compressed;
    outcome.before = before;
    outcome.after = after;
    outcome.hdr = hdr;
    outcome.error = error;
    return outcome;
}

/// The original to the Trash, the compressed file in its place with its dates. One at a time: photos are compressed
/// several at once, and the free names are shared.
static POCompressionOutcome *POReplace(POPhotoItem *item, NSURL *temporary, NSURL *target, BOOL hdr) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *source = item.url;
    NSDictionary *attributes = [files attributesOfItemAtPath:source.path error:NULL];
    long long before = (long long)attributes.fileSize;
    NSDate *created = attributes[NSFileCreationDate], *modified = attributes[NSFileModificationDate];
    @synchronized ([POCompressionOutcome class]) {
        if (![target.path isEqualToString:source.path]) target = POFreeURL(target);
        NSError *error = nil;
        if (![files trashItemAtURL:source resultingItemURL:NULL error:&error]) {
            [files removeItemAtURL:temporary error:NULL];
            return POOutcome(item, nil, before, 0, hdr, error.localizedDescription);
        }
        if (![files moveItemAtURL:temporary toURL:target error:&error]) {
            // The original is in the Trash and the new file is still under its hidden name: said, with where.
            return POOutcome(item, nil, before, 0, hdr, [NSString stringWithFormat:@"%@ (%@)", error.localizedDescription, temporary.path]);
        }
        NSMutableDictionary *dates = [NSMutableDictionary dictionary];
        if (created) dates[NSFileCreationDate] = created;
        if (modified) dates[NSFileModificationDate] = modified;
        [files setAttributes:dates ofItemAtPath:target.path error:NULL];
    }
    long long after = (long long)[files attributesOfItemAtPath:target.path error:NULL].fileSize;
    return POOutcome(item, target, before, after, hdr, nil);
}

POCompressionOutcome *POCompressPhotoItem(POPhotoItem *item, NSInteger megapixels) {
    NSURL *source = item.url;
    BOOL upper = ![source.pathExtension isEqualToString:source.pathExtension.lowercaseString];
    NSURL *target = [source.URLByDeletingPathExtension URLByAppendingPathExtension:upper ? @"JPG" : @"jpg"];
    NSURL *temporary = POTemporaryURL(source, @"jpg");
    @autoreleasepool {
        BOOL hdr = NO;
        NSString *error = nil;
        NSData *jpeg = POCompressRawPhoto(source, megapixels, &hdr, &error);
        NSError *writeError = nil;
        if (!jpeg || ![jpeg writeToURL:temporary options:NSDataWritingAtomic error:&writeError]) {
            [NSFileManager.defaultManager removeItemAtURL:temporary error:NULL];
            return POOutcome(item, nil, (long long)item.fileSize, 0, NO, error ?: writeError.localizedDescription);
        }
        return POReplace(item, temporary, target, hdr);
    }
}

POCompressionOutcome *POCompressVideoItem(POPhotoItem *item, POVideoInfo *info, POVideoJob *job,
                                          void (^progress)(double), BOOL (^cancelled)(void)) {
    NSURL *source = item.url;
    NSURL *temporary = POTemporaryURL(source, source.pathExtension.length ? source.pathExtension : @"mov");
    [NSFileManager.defaultManager removeItemAtURL:temporary error:NULL];
    NSString *error = POEncodeVideo(source, temporary, info, job, progress, cancelled);
    if (error) return POOutcome(item, nil, (long long)item.fileSize, 0, info.hdr, error);
    // Not smaller after all (an already well-compressed video): the original stays.
    long long after = (long long)[NSFileManager.defaultManager attributesOfItemAtPath:temporary.path error:NULL].fileSize;
    if (after >= (long long)item.fileSize) {
        [NSFileManager.defaultManager removeItemAtURL:temporary error:NULL];
        return POOutcome(item, nil, (long long)item.fileSize, (long long)item.fileSize, info.hdr, nil);
    }
    return POReplace(item, temporary, source, info.hdr);
}
