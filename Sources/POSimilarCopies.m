#import "POSimilarCopies.h"
#import "POMediaTypes.h"
#import "POScanner.h"
#import "POStrings.h"
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#import <sys/stat.h>

static const int POMaximumHashDistance = 2, POMaximumMomentHashDistance = 12;
/// Pictures that differ in a share of pixels above this are different pictures, however alike their fingerprints:
/// screenshots of one app with other numbers differ in 1–2 %, recompressed and resized copies in under 0.1 %.
static const double POMaximumChangedShare = 0.003;

/// The picture as w×h grey values (upright, smoothly scaled); NULL when it can't be read. The caller frees it.
static uint8_t *POGrayPixels(NSURL *url, size_t w, size_t h) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) return NULL;
    NSDictionary *options = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                              (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                              (id)kCGImageSourceShouldCacheImmediately: @NO,
                              (id)kCGImageSourceThumbnailMaxPixelSize: @(MAX(w, h) * 3)};
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!image) return NULL;
    uint8_t *pixels = calloc(w * h, 1);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(pixels, w, h, 8, w, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (context) {
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        CGContextDrawImage(context, CGRectMake(0, 0, w, h), image);
        CGContextRelease(context);
    }
    CGImageRelease(image);
    if (!context) {
        free(pixels);
        return NULL;
    }
    return pixels;
}

/// Both pictures compared on one grid of up to 160 pixels across (at least two pixels of the smaller one per cell):
/// the share of pixels that differ clearly (more than 40 of 255, after evening out an overall change of brightness).
/// Negative when either can't be read.
static double POChangedShareOfURLs(NSURL *a, NSURL *b, NSInteger width, NSInteger height, NSInteger smallerWidth) {
    size_t w = (size_t)MIN(MAX(smallerWidth / 2, 8), 160);
    size_t h = (size_t)MAX(8, lround(w * (double)height / width));
    uint8_t *pa = POGrayPixels(a, w, h), *pb = POGrayPixels(b, w, h);
    double share = -1;
    if (pa && pb) {
        size_t n = w * h;
        double offset = 0;
        for (size_t i = 0; i < n; i++) offset += (double)pa[i] - pb[i];
        offset /= n;
        size_t changed = 0;
        for (size_t i = 0; i < n; i++) if (fabs((double)pa[i] - pb[i] - offset) > 40) changed++;
        share = (double)changed / n;
    }
    free(pa);
    free(pb);
    return share;
}

static double POChangedShare(POPhotoItem *a, POPhotoItem *b) {
    POPhotoItem *smaller = (long long)a.pixelWidth * a.pixelHeight <= (long long)b.pixelWidth * b.pixelHeight ? a : b;
    return POChangedShareOfURLs(a.url, b.url, a.pixelWidth, a.pixelHeight, smaller.pixelWidth);
}

/// Identifies a file as it is now: when it is changed or replaced, an earlier comparison no longer applies.
static NSString *POFileKey(POPhotoItem *item) {
    struct stat info;
    if (stat(item.url.fileSystemRepresentation, &info) != 0) return nil;
    return [NSString stringWithFormat:@"%d-%llu-%lld-%ld", info.st_dev, (unsigned long long)info.st_ino, (long long)info.st_size,
            (long)info.st_mtimespec.tv_sec];
}

/// What the pixel comparison found for each pair of files, kept in Application Support so that it is done once.
static NSURL *POVerdictsURL(void) {
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                                                 appropriateForURL:nil create:YES error:NULL];
    NSURL *folder = [support URLByAppendingPathComponent:@"Photo Organizer" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    return [folder URLByAppendingPathComponent:@"copies.plist"];
}

@implementation POSimilarCopies

+ (NSNumber *)visualHashOfImage:(CGImageRef)image {
    // 9×8 grey pixels; each bit says whether a pixel is brighter than its right-hand neighbour.
    uint8_t pixels[9 * 8] = {0};
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(pixels, 9, 8, 8, 9, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!context) return nil;
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0, 0, 9, 8), image);
    CGContextRelease(context);

    uint64_t hash = 0;
    for (int row = 0; row < 8; row++) {
        for (int column = 0; column < 8; column++) {
            hash = (hash << 1) | (pixels[row * 9 + column] > pixels[row * 9 + column + 1] ? 1 : 0);
        }
    }
    int bits = __builtin_popcountll(hash);
    if (bits < 10 || bits > 54) return nil;   // nearly uniform: any two such pictures would "match"
    return @(hash);
}

/// The number a camera gave the shot ("IMG_1218(3).JPG" → "IMG1218"); nil for names it did not give.
static NSString *POCameraNumber(POPhotoItem *item) {
    static NSRegularExpression *expression;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:@"^(IMG|DSC|DSCF|DSCN|DJI|GOPR|_DSC|_MG|P)_?(\\d{4,5})(?!\\d)"
                                                               options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    NSString *name = item.url.lastPathComponent.stringByDeletingPathExtension;
    NSTextCheckingResult *match = [expression firstMatchInString:name options:0 range:NSMakeRange(0, name.length)];
    if (!match) return nil;
    NSString *prefix = [[name substringWithRange:[match rangeAtIndex:1]].uppercaseString stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"_"]];
    return [prefix stringByAppendingString:[name substringWithRange:[match rangeAtIndex:2]]];
}

/// Whether the name ends in what a copy gets: "_1", "(1)", " copy", " - Copy 2".
static BOOL POHasCopySuffix(POPhotoItem *item) {
    static NSRegularExpression *expression;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:@"(_\\d{1,2}|\\s?\\(\\d+\\)|\\s(-\\s)?copy(\\s\\d+)?)$"
                                                               options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    NSString *name = item.url.lastPathComponent.stringByDeletingPathExtension;
    return [expression firstMatchInString:name options:0 range:NSMakeRange(0, name.length)] != nil;
}

/// The fractions of the second of the capture time (Exif SubSecTimeOriginal); nil when not written. Read once a file.
static NSString *POSubSeconds(NSURL *url) {
    static NSMutableDictionary<NSString *, id> *read;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ read = [NSMutableDictionary dictionary]; });
    @synchronized (read) {
        id known = read[url.path];
        if (known) return known == NSNull.null ? nil : known;
    }
    NSString *sub = nil;
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (source) {
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        CFRelease(source);
        id value = properties[(id)kCGImagePropertyExifDictionary][(id)kCGImagePropertyExifSubsecTimeOriginal];
        if ([value isKindOfClass:NSString.class] && [value length]) sub = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        else if ([value isKindOfClass:NSNumber.class]) sub = [value stringValue];
    }
    @synchronized (read) {
        read[url.path] = sub ?: NSNull.null;
    }
    return sub;
}

static BOOL POAreCopies(POPhotoItem *a, POPhotoItem *b) {
    if (a.pixelWidth <= 0 || a.pixelHeight <= 0 || b.pixelWidth <= 0 || b.pixelHeight <= 0) return NO;
    double aspectA = (double)a.pixelWidth / a.pixelHeight, aspectB = (double)b.pixelWidth / b.pixelHeight;
    if (fabs(aspectA - aspectB) > 0.02 * MAX(aspectA, aspectB)) return NO;
    // Two files that both know when they were shot, at different moments, are different shots however alike:
    // frames of a burst (IMG_20171022_181417 and …181418) must not be offered for deletion.
    BOOL timedA = a.dateSource == PODateSourceEXIF || a.dateSource == PODateSourceName;
    BOOL timedB = b.dateSource == PODateSourceEXIF || b.dateSource == PODateSourceName;
    if (timedA && timedB && fabs([a.date timeIntervalSinceDate:b.date]) >= 1) return NO;
    // A burst takes several frames in one second, alike but for closed eyes or a turned head — fewer pixels than any
    // comparison can tell from compression: the camera's numbers (IMG_1218, IMG_1219) or the fractions of the second
    // it wrote (.365, .609) tell them apart. Copies of one shot keep both. The same as on Windows.
    NSString *numberA = POCameraNumber(a), *numberB = POCameraNumber(b);
    if (numberA && numberB && ![numberA isEqualToString:numberB]) return NO;
    if (a.dateSource == PODateSourceEXIF && b.dateSource == PODateSourceEXIF) {
        NSString *subA = POSubSeconds(a.url), *subB = POSubSeconds(b.url);
        if (subA && subB && ![subA isEqualToString:subB]) return NO;
    }
    return YES;
}

static NSString *const PORawPreferenceKey = @"rawJpegPreference";

/// A camera RAW file (the same list as POMediaTypes and Windows).
static BOOL POIsRaw(POPhotoItem *item) {
    return !item.isVideo && [PORawExtensions() containsObject:item.url.pathExtension.lowercaseString];
}

/// The kept one first: of a RAW and a JPEG of the same shot, the one rawPreference asks for; otherwise the better
/// quality — most pixels, then the larger file, then the one that kept its metadata.
static BOOL POIsHevc(NSURL *url);
static BOOL POIsReencoded(NSURL *url);

static NSComparisonResult POCompareQuality(POPhotoItem *a, POPhotoItem *b) {
    BOOL rawA = POIsRaw(a), rawB = POIsRaw(b);
    NSInteger preference = POSimilarCopies.rawPreference;
    if (rawA != rawB && POSimilarCopies.compressedPreference == 1) return rawA ? NSOrderedDescending : NSOrderedAscending;
    if (rawA != rawB && preference != 0) return rawA == (preference == 1) ? NSOrderedAscending : NSOrderedDescending;
    if (a.isVideo && b.isVideo) {
        if (POSimilarCopies.compressedPreference == 1) {
            // The lightest; of two as light, HEVC.
            if (a.fileSize != b.fileSize) return a.fileSize < b.fileSize ? NSOrderedAscending : NSOrderedDescending;
            BOOL hevcA = POIsHevc(a.url), hevcB = POIsHevc(b.url);
            if (hevcA != hevcB) return hevcA ? NSOrderedAscending : NSOrderedDescending;
        } else if ((long long)a.pixelWidth * a.pixelHeight == (long long)b.pixelWidth * b.pixelHeight) {
            // Of one frame size, the camera's own file over one encoded again (by this app or another): every encoding
            // loses — a copy that came back from iCloud encoded by Apple and then compressed here was larger than the
            // camera's H.264 and scored lower against it (VMAF), with a higher bitrate. More pixels still win: a 720p
            // original over a 640p copy of it.
            BOOL againA = POIsReencoded(a.url), againB = POIsReencoded(b.url);
            if (againA != againB) return againA ? NSOrderedDescending : NSOrderedAscending;
        }
    }
    long long pixelsA = (long long)a.pixelWidth * a.pixelHeight, pixelsB = (long long)b.pixelWidth * b.pixelHeight;
    if (pixelsA != pixelsB) return pixelsA > pixelsB ? NSOrderedAscending : NSOrderedDescending;
    // As good as each other: the one under the camera's own name, not the one a copy got ("IMG_0389_1", "IMG_0409(1)").
    if (llabs((long long)a.fileSize - (long long)b.fileSize) <= (long long)MAX(a.fileSize, b.fileSize) / 100) {
        BOOL copyA = POHasCopySuffix(a), copyB = POHasCopySuffix(b);
        if (copyA != copyB) return copyA ? NSOrderedDescending : NSOrderedAscending;
    }
    if (a.fileSize != b.fileSize) return a.fileSize > b.fileSize ? NSOrderedAscending : NSOrderedDescending;
    BOOL exifA = a.dateSource == PODateSourceEXIF, exifB = b.dateSource == PODateSourceEXIF;
    if (exifA != exifB) return exifA ? NSOrderedAscending : NSOrderedDescending;   // the one that kept its metadata
    return [a.relativePath localizedStandardCompare:b.relativePath];
}

/// A date of the file's own, which a copy never overwrites — the one the user gave by hand included.
static BOOL POHasOwnDate(POPhotoItem *item) {
    return item.dateSource == PODateSourceEXIF || item.dateSource == PODateSourceName || item.dateSource == PODateSourceTakeout ||
           item.dateSource == PODateSourceManual;
}

/// The same frame and the size within 1 %: nothing to choose between them but the name.
static BOOL POSameQuality(POPhotoItem *a, POPhotoItem *b) {
    return MAX(a.pixelWidth, a.pixelHeight) == MAX(b.pixelWidth, b.pixelHeight) &&
           MIN(a.pixelWidth, a.pixelHeight) == MIN(b.pixelWidth, b.pixelHeight) && POIsRaw(a) == POIsRaw(b) &&
           llabs((long long)a.fileSize - (long long)b.fileSize) <= (long long)MAX(a.fileSize, b.fileSize) / 100;
}

/// A set put in order (the kept one first) and marked: `betterCopy` on every other one, `tiny` on the thumbnails.
/// Why a copy stands below the best one, in a word on its badge: fewer pixels; encoded again where the best is the
/// camera's own file; or merely lighter (or, when the compressed one is preferred, heavier). Nil when nothing to say.
static NSString *POCopyNote(POPhotoItem *best, POPhotoItem *copy) {
    if ((long long)copy.pixelWidth * copy.pixelHeight < (long long)best.pixelWidth * best.pixelHeight) return POL(@"Меньше пикселей");
    if (best.isVideo && copy.isVideo && POIsReencoded(copy.url) && !POIsReencoded(best.url)) return POL(@"Перекодирован");
    if (best.fileSize <= 0) return nil;
    double ratio = (double)copy.fileSize / best.fileSize;
    if (ratio < 0.99) return [NSString stringWithFormat:POL(@"Легче на %@ %%"), PONumber((NSInteger)lround((1 - ratio) * 100))];
    if (ratio > 1.01) return [NSString stringWithFormat:POL(@"Тяжелее на %@ %%"), PONumber((NSInteger)lround((ratio - 1) * 100))];
    return nil;
}

static void POOrderAndMark(NSMutableArray<POPhotoItem *> *group) {
    [group sortUsingComparator:^NSComparisonResult(POPhotoItem *a, POPhotoItem *b) { return POCompareQuality(a, b); }];
    POPhotoItem *best = group.firstObject;
    best.bestOfCopies = YES;
    best.betterCopy = nil;
    best.tiny = NO;
    best.rankNote = nil;
    NSInteger bestSide = MAX(best.pixelWidth, best.pixelHeight);
    BOOL allSame = YES, reencodedCopy = NO;
    for (NSUInteger i = 1; i < group.count; i++) {
        POPhotoItem *copy = group[i];
        copy.bestOfCopies = NO;
        copy.betterCopy = best;
        copy.sameAsBest = POSameQuality(best, copy);
        copy.rankNote = POCopyNote(best, copy);
        reencodedCopy = reencodedCopy || [copy.rankNote isEqualToString:POL(@"Перекодирован")];
        allSame = allSame && copy.sameAsBest;
        NSInteger side = MAX(copy.pixelWidth, copy.pixelHeight);
        copy.tiny = side * 2 <= bestSide;
        // An exact copy of a thumbnail is a thumbnail too.
        for (POPhotoItem *twin in copy.duplicates) twin.tiny = copy.tiny;
    }
    best.sameAsBest = allSame;
    if (best.isVideo && reencodedCopy) best.rankNote = POL(@"Файл камеры");
}

+ (NSInteger)rawPreference {
    return MIN(MAX([NSUserDefaults.standardUserDefaults integerForKey:PORawPreferenceKey], 0), 2);
}

+ (void)setRawPreference:(NSInteger)rawPreference {
    [NSUserDefaults.standardUserDefaults setInteger:rawPreference forKey:PORawPreferenceKey];
}

+ (NSInteger)compressedPreference {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id saved = [defaults objectForKey:@"compressedCopyPreference"] ?: [defaults objectForKey:@"videoCopyPreference"];
    return MIN(MAX([saved integerValue], 0), 1);
}

+ (void)setCompressedPreference:(NSInteger)compressedPreference {
    [NSUserDefaults.standardUserDefaults setInteger:compressedPreference forKey:@"compressedCopyPreference"];
}

+ (NSArray<NSArray<POPhotoItem *> *> *)reorderedSets:(NSArray<NSArray<POPhotoItem *> *> *)sets {
    NSMutableArray<NSArray<POPhotoItem *> *> *ordered = [NSMutableArray arrayWithCapacity:sets.count];
    for (NSArray<POPhotoItem *> *set in sets) {
        NSMutableArray<POPhotoItem *> *group = [set mutableCopy];
        POOrderAndMark(group);
        [ordered addObject:group];
    }
    return ordered;
}

+ (BOOL)isSamePictureAtURL:(NSURL *)url asItem:(POPhotoItem *)item {
    if (item.isVideo || item.pixelWidth <= 0 || item.pixelHeight <= 0) return NO;
    double share = POChangedShareOfURLs(item.url, url, item.pixelWidth, item.pixelHeight, item.pixelWidth);
    return share >= 0 && share <= POMaximumChangedShare;
}

/// The same moment: within a second, or apart by whole time zones (up to 14 hours, in quarters of an hour) — one file
/// says it in local time, the other in UTC, read as this computer's local time.
static BOOL POSameClock(double seconds) {
    if (seconds > 14 * 3600 + 1) return NO;
    double rest = fmod(seconds, 900);
    return rest < 1 || rest > 899;
}

/// The copy whose date is the right one: the date given by hand; else the one that agrees with the moment its name
/// says (VID_20180516_135705); else the earliest — a recording is made before any copy or export of it. As on Windows.
static POPhotoItem *POTrustedDate(NSArray<POPhotoItem *> *members) {
    NSMutableArray<POPhotoItem *> *own = [NSMutableArray array];
    for (POPhotoItem *item in members) if (POHasOwnDate(item)) [own addObject:item];
    if (!own.count) return nil;
    for (POPhotoItem *item in own) if (item.dateSource == PODateSourceManual) return item;
    for (POPhotoItem *item in own) {
        NSDate *named = PODateFromFileName(item.url.lastPathComponent);
        if (!named) continue;
        NSDateComponents *time = [NSCalendar.currentCalendar components:NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:named];
        if (time.hour == 12 && time.minute == 0 && time.second == 0) continue;   // no time of day in it
        if (POSameClock(fabs([item.date timeIntervalSinceDate:named]))) return item;
    }
    [own sortUsingComparator:^NSComparisonResult(POPhotoItem *a, POPhotoItem *b) {
        NSComparisonResult byDate = [a.date compare:b.date];
        if (byDate != NSOrderedSame) return byDate;
        return (a.dateSource == PODateSourceEXIF) == (b.dateSource == PODateSourceEXIF) ? NSOrderedSame
             : a.dateSource == PODateSourceEXIF ? NSOrderedAscending : NSOrderedDescending;
    }];
    return own.firstObject;
}

/// Gives every copy of a set the right date: one without a date of its own gets it, and so does one whose own date is
/// another moment — an export that wrote its own time into the file (Google's). See POTrustedDate. As on Windows.
+ (NSUInteger)shareDatesInSets:(NSArray<NSArray<POPhotoItem *> *> *)sets {
    NSUInteger shared = 0;
    for (NSArray<POPhotoItem *> *set in sets) {
        NSMutableArray<POPhotoItem *> *members = [NSMutableArray array];
        for (POPhotoItem *item in set) {
            [members addObject:item];
            [members addObjectsFromArray:item.duplicates ?: @[]];   // exact twins too
        }
        POPhotoItem *source = POTrustedDate(members);
        if (!source) continue;
        for (POPhotoItem *copy in members) {
            if (copy == source || copy.dateSource == PODateSourceManual) continue;
            // The same moment, maybe written in another time zone: its own date stays. A date given by hand goes only to
            // the copies without one — a camera's date is not overwritten by what was set on another copy.
            if (POHasOwnDate(copy) && (source.dateSource == PODateSourceManual ||
                                       POSameClock(fabs([copy.date timeIntervalSinceDate:source.date])))) continue;
            copy.date = source.date;
            copy.dateSource = PODateSourceCopy;
            shared++;
        }
    }
    return shared;
}

static const NSTimeInterval POMaximumDurationDifference = 0.05, POMaximumMomentDurationDifference = 0.25;

/// The name without its extension and without what a copy gets ("_1", "(2)", " copy").
static NSString *POBaseName(POPhotoItem *item) {
    NSString *name = item.url.lastPathComponent.stringByDeletingPathExtension;
    NSRegularExpression *suffix = [NSRegularExpression regularExpressionWithPattern:@"(_\\d{1,2}|\\s?\\(\\d+\\)|\\s(-\\s)?copy(\\s\\d+)?)$"
                                                                            options:NSRegularExpressionCaseInsensitive error:NULL];
    return [suffix stringByReplacingMatchesInString:name options:0 range:NSMakeRange(0, name.length) withTemplate:@""].lowercaseString;
}

/// One recording kept twice in different encodings (Google Photos' H.264, the HEVC of compressing): the moment it was
/// shot, to the second, as both files say; the same shape of frame (the size may differ); the same length within a
/// quarter of a second; and the same camera's number, or the same name but for a copy's suffix. A camera can't start
/// two videos in one second, and an export's date shared by several videos is not enough: their numbers differ. As on
/// Windows.
static BOOL POSameMoment(POPhotoItem *a, POPhotoItem *b) {
    BOOL timedA = a.dateSource == PODateSourceEXIF || a.dateSource == PODateSourceName;
    BOOL timedB = b.dateSource == PODateSourceEXIF || b.dateSource == PODateSourceName;
    // Within a second, or apart by whole time zones: one file says it in local time, the other in UTC.
    if (!timedA || !timedB || !POSameClock(fabs([a.date timeIntervalSinceDate:b.date]))) return NO;
    double aspectA = (double)MAX(a.pixelWidth, a.pixelHeight) / MIN(a.pixelWidth, a.pixelHeight);
    double aspectB = (double)MAX(b.pixelWidth, b.pixelHeight) / MIN(b.pixelWidth, b.pixelHeight);
    if (fabs(aspectA - aspectB) > 0.01 * aspectA) return NO;
    NSString *numberA = POCameraNumber(a), *numberB = POCameraNumber(b);
    if (numberA && numberB) return [numberA isEqualToString:numberB];
    return [POBaseName(a) isEqualToString:POBaseName(b)];
}

/// The same recording under a name that says when it was made ("VID_20180516_135705.mp4"), of the same length and
/// shape: kept twice by an export that wrote another date inside (Google's). A camera's counter (IMG_7797) starts again
/// and does not count here. As on Windows.
static BOOL POSameNamedMoment(POPhotoItem *a, POPhotoItem *b) {
    if (![POBaseName(a) isEqualToString:POBaseName(b)]) return NO;
    NSDate *date = PODateFromFileName(a.url.lastPathComponent);
    if (!date) return NO;
    NSDateComponents *time = [NSCalendar.currentCalendar components:NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:date];
    if (time.hour == 12 && time.minute == 0 && time.second == 0) return NO;   // no time of day in it
    double aspectA = (double)MAX(a.pixelWidth, a.pixelHeight) / MIN(a.pixelWidth, a.pixelHeight);
    double aspectB = (double)MAX(b.pixelWidth, b.pixelHeight) / MIN(b.pixelWidth, b.pixelHeight);
    return fabs(aspectA - aspectB) <= 0.01 * aspectA;
}

static uint32_t POBig32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint64_t POBig64(const uint8_t *p) { return (uint64_t)POBig32(p) << 32 | POBig32(p + 4); }

/// The box of `type` directly inside [start, end) of an MP4 structure: its body as a range; NO when there is none.
static BOOL POChildBox(const uint8_t *data, NSUInteger start, NSUInteger end, const char *type, NSUInteger *bodyStart, NSUInteger *bodyEnd) {
    NSUInteger position = start;
    while (position + 8 <= end) {
        uint64_t size = POBig32(data + position);
        NSUInteger header = 8;
        if (size == 1 && position + 16 <= end) { size = POBig64(data + position + 8); header = 16; }
        else if (size == 0) size = end - position;
        if (size < header || position + size > end) return NO;
        if (memcmp(data + position + 4, type, 4) == 0) {
            *bodyStart = position + header;
            *bodyEnd = (NSUInteger)(position + size);
            return YES;
        }
        position += (NSUInteger)size;
    }
    return NO;
}

/// The video stream of a MOV or MP4, independent of everything written around it: a hash of the size of every frame
/// of its video track and of the first frame's bytes. Two files with the same print hold the same pictures, bit for
/// bit — whatever their dates, names or other tracks. nil when the file is not a MOV/MP4 or unreadable. As on Windows.
/// Whether a video's pictures are HEVC (hvc1, hev1): what compressing makes, and what keeps more in fewer bytes. Read
/// once a file. As on Windows.
static BOOL POIsHevc(NSURL *url) {
    static NSMutableDictionary<NSString *, NSNumber *> *read;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ read = [NSMutableDictionary dictionary]; });
    @synchronized (read) {
        if (read[url.path]) return read[url.path].boolValue;
    }
    BOOL hevc = NO;
    NSFileHandle *file = [NSFileHandle fileHandleForReadingFromURL:url error:NULL];
    @try {
        unsigned long long length = [file seekToEndOfFile], position = 0;
        NSData *moov = nil;
        while (file && position + 8 <= length) {
            [file seekToFileOffset:position];
            NSData *headerData = [file readDataOfLength:16];
            if (headerData.length < 8) break;
            const uint8_t *header = headerData.bytes;
            uint64_t size = POBig32(header);
            unsigned headerSize = 8;
            if (size == 1 && headerData.length >= 16) { size = POBig64(header + 8); headerSize = 16; }
            else if (size == 0) size = length - position;
            if (size < headerSize) break;
            if (memcmp(header + 4, "moov", 4) == 0) {
                if (size <= 64 << 20) {
                    [file seekToFileOffset:position + headerSize];
                    moov = [file readDataOfLength:(NSUInteger)(size - headerSize)];
                }
                break;
            }
            position += size;
        }
        const uint8_t *data = moov.bytes;
        NSUInteger end = moov.length, cursor = 0, trakStart, trakEnd;
        while (data && cursor + 8 <= end && POChildBox(data, cursor, end, "trak", &trakStart, &trakEnd)) {
            cursor = trakEnd;
            NSUInteger mdiaStart, mdiaEnd, hdlrStart, hdlrEnd, minfStart, minfEnd, stblStart, stblEnd, stsdStart, stsdEnd;
            if (!POChildBox(data, trakStart, trakEnd, "mdia", &mdiaStart, &mdiaEnd)) continue;
            if (!POChildBox(data, mdiaStart, mdiaEnd, "hdlr", &hdlrStart, &hdlrEnd) || hdlrEnd - hdlrStart < 12 ||
                memcmp(data + hdlrStart + 8, "vide", 4) != 0) continue;
            if (POChildBox(data, mdiaStart, mdiaEnd, "minf", &minfStart, &minfEnd) &&
                POChildBox(data, minfStart, minfEnd, "stbl", &stblStart, &stblEnd) &&
                POChildBox(data, stblStart, stblEnd, "stsd", &stsdStart, &stsdEnd) && stsdEnd - stsdStart >= 16) {
                // The first sample description: version and count, its size, its type.
                hevc = memcmp(data + stsdStart + 12, "hvc1", 4) == 0 || memcmp(data + stsdStart + 12, "hev1", 4) == 0;
            }
            break;
        }
    } @catch (NSException *exception) {
    } @finally {
        [file closeFile];
    }
    @synchronized (read) { read[url.path] = @(hevc); }
    return hevc;
}

/// Whether FFmpeg wrote the video (its name is in the file's metadata): encoded again after the camera.
static BOOL POIsReencoded(NSURL *url) {
    static NSMutableDictionary<NSString *, NSNumber *> *read;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ read = [NSMutableDictionary dictionary]; });
    @synchronized (read) {
        if (read[url.path]) return read[url.path].boolValue;
    }
    BOOL again = NO;
    NSFileHandle *file = [NSFileHandle fileHandleForReadingFromURL:url error:NULL];
    @try {
        unsigned long long length = [file seekToEndOfFile], position = 0;
        while (file && position + 8 <= length) {
            [file seekToFileOffset:position];
            NSData *headerData = [file readDataOfLength:16];
            if (headerData.length < 8) break;
            const uint8_t *header = headerData.bytes;
            uint64_t size = POBig32(header);
            unsigned headerSize = 8;
            if (size == 1 && headerData.length >= 16) { size = POBig64(header + 8); headerSize = 16; }
            else if (size == 0) size = length - position;
            if (size < headerSize) break;
            if (memcmp(header + 4, "moov", 4) == 0) {
                if (size <= 64 << 20) {
                    [file seekToFileOffset:position + headerSize];
                    NSData *moov = [file readDataOfLength:(NSUInteger)(size - headerSize)];
                    again = [moov rangeOfData:[NSData dataWithBytes:"Lavf" length:4] options:0 range:NSMakeRange(0, moov.length)].location != NSNotFound;
                }
                break;
            }
            position += size;
        }
    } @catch (NSException *exception) {
    } @finally {
        [file closeFile];
    }
    @synchronized (read) { read[url.path] = @(again); }
    return again;
}

static NSString *POVideoStreamPrint(NSURL *url) {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingFromURL:url error:NULL];
    if (!file) return nil;
    @try {
        unsigned long long length = [file seekToEndOfFile], position = 0;
        NSData *moov = nil;
        while (position + 8 <= length) {
            [file seekToFileOffset:position];
            NSData *headerData = [file readDataOfLength:16];
            if (headerData.length < 8) return nil;
            const uint8_t *header = headerData.bytes;
            uint64_t size = POBig32(header);
            unsigned header_size = 8;
            if (size == 1 && headerData.length >= 16) { size = POBig64(header + 8); header_size = 16; }
            else if (size == 0) size = length - position;
            if (size < header_size) return nil;
            if (memcmp(header + 4, "moov", 4) == 0) {
                if (size > 64 << 20) return nil;
                [file seekToFileOffset:position + header_size];
                moov = [file readDataOfLength:(NSUInteger)(size - header_size)];
                break;
            }
            position += size;
        }
        if (moov.length < 8) return nil;
        const uint8_t *data = moov.bytes;
        NSUInteger end = moov.length, cursor = 0;
        // Each track in turn, until the video one.
        while (cursor + 8 <= end) {
            NSUInteger trakStart, trakEnd;
            if (!POChildBox(data, cursor, end, "trak", &trakStart, &trakEnd)) return nil;
            cursor = trakEnd;
            NSUInteger mdiaStart, mdiaEnd, hdlrStart, hdlrEnd, minfStart, minfEnd, stblStart, stblEnd, stszStart, stszEnd;
            if (!POChildBox(data, trakStart, trakEnd, "mdia", &mdiaStart, &mdiaEnd)) continue;
            if (!POChildBox(data, mdiaStart, mdiaEnd, "hdlr", &hdlrStart, &hdlrEnd) || hdlrEnd - hdlrStart < 12 ||
                memcmp(data + hdlrStart + 8, "vide", 4) != 0) continue;
            if (!POChildBox(data, mdiaStart, mdiaEnd, "minf", &minfStart, &minfEnd) ||
                !POChildBox(data, minfStart, minfEnd, "stbl", &stblStart, &stblEnd)) continue;
            if (!POChildBox(data, stblStart, stblEnd, "stsz", &stszStart, &stszEnd) || stszEnd - stszStart < 12) return nil;
            // The first frame itself: at the start of the first chunk, as long as the table says.
            NSUInteger coStart, coEnd;
            long long offset = -1;
            if (POChildBox(data, stblStart, stblEnd, "stco", &coStart, &coEnd) && coEnd - coStart >= 12) offset = POBig32(data + coStart + 8);
            else if (POChildBox(data, stblStart, stblEnd, "co64", &coStart, &coEnd) && coEnd - coStart >= 16) offset = (long long)POBig64(data + coStart + 8);
            uint32_t fixedSize = POBig32(data + stszStart + 4);
            long long firstSize = fixedSize ? fixedSize : (stszEnd - stszStart >= 16 ? POBig32(data + stszStart + 12) : 0);
            if (offset < 0 || firstSize <= 0 || (unsigned long long)(offset + firstSize) > length) return nil;
            [file seekToFileOffset:(unsigned long long)offset];
            NSData *first = [file readDataOfLength:(NSUInteger)MIN(firstSize, 4 << 20)];
            CC_SHA256_CTX context;
            CC_SHA256_Init(&context);
            CC_SHA256_Update(&context, data + stszStart, (CC_LONG)(stszEnd - stszStart));
            CC_SHA256_Update(&context, first.bytes, (CC_LONG)first.length);
            unsigned char digest[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256_Final(digest, &context);
            NSMutableString *hex = [NSMutableString string];
            for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02X", digest[i]];
            return hex;
        }
        return nil;
    } @catch (NSException *exception) {
        return nil;
    } @finally {
        [file closeFile];
    }
}

/// What is cheap to check, before the files are read.
static BOOL POMayBeVideoCopies(POPhotoItem *a, POPhotoItem *b) {
    if (MAX(a.pixelWidth, a.pixelHeight) != MAX(b.pixelWidth, b.pixelHeight) ||
        MIN(a.pixelWidth, a.pixelHeight) != MIN(b.pixelWidth, b.pixelHeight)) return NO;
    NSString *numberA = POCameraNumber(a), *numberB = POCameraNumber(b);
    return !(numberA && numberB && ![numberA isEqualToString:numberB]);
}

/// Copies of one video saved again (IMG_0389.MOV and IMG_0389_1.MOV, an export that wrote other metadata around the
/// same pictures): the same length and frame size, and then the proof — the same video stream, frame for frame (see
/// POVideoStreamPrint). The camera's number alone proves nothing: an iPhone counts to IMG_9999 and starts again, so
/// IMG_7797 of 2021 and IMG_7797 of 2024 are different videos of one length. Each set ordered and marked. As on Windows.
static NSArray<NSArray<POPhotoItem *> *> *POVideoSets(NSArray<POPhotoItem *> *items) {
    NSMutableArray<POPhotoItem *> *videos = [NSMutableArray array];
    for (POPhotoItem *item in items) {
        if (item.isVideo && !item.isDuplicate && item.duration >= 0.5 && item.pixelWidth > 0 && item.pixelHeight > 0 && item.fileSize > 0) [videos addObject:item];
    }
    [videos sortUsingComparator:^NSComparisonResult(POPhotoItem *a, POPhotoItem *b) {
        return a.duration < b.duration ? NSOrderedAscending : a.duration > b.duration ? NSOrderedDescending : NSOrderedSame;
    }];
    NSUInteger count = videos.count;
    NSMutableArray<NSNumber *> *parent = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) [parent addObject:@(i)];
    NSUInteger (^find)(NSUInteger) = ^NSUInteger(NSUInteger i) {
        while (parent[i].unsignedIntegerValue != i) i = parent[i].unsignedIntegerValue;
        return i;
    };
    NSMutableIndexSet *candidates = [NSMutableIndexSet indexSet];
    for (NSUInteger a = 0; a < count; a++) {
        for (NSUInteger b = a + 1; b < count && videos[b].duration - videos[a].duration <= POMaximumMomentDurationDifference; b++) {
            if (POSameMoment(videos[a], videos[b]) || POSameNamedMoment(videos[a], videos[b])) parent[find(b)] = @(find(a));
            if (videos[b].duration - videos[a].duration > POMaximumDurationDifference || !POMayBeVideoCopies(videos[a], videos[b])) continue;
            [candidates addIndex:a];
            [candidates addIndex:b];
        }
    }
    // Only the index of each file is read (its table of frames) and its first frame: a few hundredths of a second.
    NSArray<NSNumber *> *indexes = ({
        NSMutableArray *list = [NSMutableArray array];
        [candidates enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) { [list addObject:@(index)]; }];
        list;
    });
    NSMutableDictionary<NSString *, NSNumber *> *firstOfPrint = [NSMutableDictionary dictionary];
    NSMutableArray<NSArray *> *same = [NSMutableArray array];   // [index, index of the first with that print]
    dispatch_apply(indexes.count, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(size_t i) {
        NSNumber *index = indexes[i];
        NSString *print = POVideoStreamPrint(videos[index.unsignedIntegerValue].url);
        if (!print) return;
        @synchronized (firstOfPrint) {
            if (firstOfPrint[print]) [same addObject:@[index, firstOfPrint[print]]];
            else firstOfPrint[print] = index;
        }
    });
    for (NSArray<NSNumber *> *pair in same) parent[find(pair[0].unsignedIntegerValue)] = @(find(pair[1].unsignedIntegerValue));
    NSMutableDictionary<NSNumber *, NSMutableArray<POPhotoItem *> *> *groups = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < count; i++) {
        NSNumber *root = @(find(i));
        if (!groups[root]) groups[root] = [NSMutableArray array];
        [groups[root] addObject:videos[i]];
    }
    NSMutableArray<NSArray<POPhotoItem *> *> *sets = [NSMutableArray array];
    for (NSMutableArray<POPhotoItem *> *group in groups.allValues) {
        if (group.count < 2) continue;
        POOrderAndMark(group);
        [sets addObject:group];
    }
    return sets;
}

+ (NSArray<NSArray<POPhotoItem *> *> *)setsInItems:(NSArray<POPhotoItem *> *)items {
    NSMutableArray<POPhotoItem *> *hashed = [NSMutableArray array];
    for (POPhotoItem *item in items) {
        item.betterCopy = nil;
        item.tiny = NO;
        item.bestOfCopies = NO;
        item.sameAsBest = NO;
        item.rankNote = nil;
        // With a fingerprint, or — a dark or plain picture has none worth having — a moment from the camera to go by.
        if (!item.isDuplicate && !item.isVideo && (item.visualHash || item.dateSource == PODateSourceEXIF)) [hashed addObject:item];
    }
    NSUInteger count = hashed.count;
    if (count < 2) return POVideoSets(items);
    uint64_t *hashes = malloc(count * sizeof(uint64_t));
    BOOL *fingerprinted = malloc(count * sizeof(BOOL));
    uint32_t *order = malloc(count * sizeof(uint32_t)), *parent = malloc(count * sizeof(uint32_t));
    for (NSUInteger i = 0; i < count; i++) {
        hashes[i] = hashed[i].visualHash.unsignedLongLongValue;
        fingerprinted[i] = hashed[i].visualHash != nil;
        parent[i] = (uint32_t)i;
    }
    uint32_t (^find)(uint32_t) = ^uint32_t(uint32_t i) {
        while (parent[i] != i) { parent[i] = parent[parent[i]]; i = parent[i]; }
        return i;
    };

    // Two 64-bit values at most 2 bits apart agree on at least two of their four 16-bit quarters, so looking
    // only at files that share a quarter finds every pair without comparing everything with everything.
    NSMutableSet<NSNumber *> *candidates = [NSMutableSet set];   // (a << 32) | b, a < b
    for (int quarter = 0; quarter < 4; quarter++) {
        int shift = quarter * 16;
        for (NSUInteger i = 0; i < count; i++) order[i] = (uint32_t)i;
        qsort_b(order, count, sizeof(uint32_t), ^int(const void *a, const void *b) {
            uint16_t keyA = (uint16_t)(hashes[*(const uint32_t *)a] >> shift), keyB = (uint16_t)(hashes[*(const uint32_t *)b] >> shift);
            return keyA < keyB ? -1 : (keyA > keyB ? 1 : 0);
        });
        NSUInteger start = 0;
        while (start < count) {
            NSUInteger end = start + 1;
            uint16_t key = (uint16_t)(hashes[order[start]] >> shift);
            while (end < count && (uint16_t)(hashes[order[end]] >> shift) == key) end++;
            for (NSUInteger i = start; i < end; i++) {
                for (NSUInteger j = i + 1; j < end; j++) {
                    uint32_t a = MIN(order[i], order[j]), b = MAX(order[i], order[j]);
                    if (!fingerprinted[a] || !fingerprinted[b]) continue;
                    if (__builtin_popcountll(hashes[a] ^ hashes[b]) > POMaximumHashDistance) continue;
                    if (POAreCopies(hashed[a], hashed[b])) [candidates addObject:@(((uint64_t)a << 32) | b)];
                }
            }
            start = end;
        }
    }

    // A thumbnail squeezed hard moves the fingerprint a few bits more (a 600×800 copy of a 12-megapixel photo: 3 to 6),
    // and a dark one more still, or has none. Shot at the same second, with the same proportions — and, when the
    // fingerprints are far apart or missing, at the same fraction of that second — the two are compared all the same:
    // the pixels decide, as for every candidate. As on Windows.
    NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *moments = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < count; i++) {
        if (hashed[i].dateSource != PODateSourceEXIF) continue;
        NSNumber *second = @((long long)floor(hashed[i].date.timeIntervalSinceReferenceDate));
        if (!moments[second]) moments[second] = [NSMutableArray array];
        [moments[second] addObject:@(i)];
    }
    for (NSArray<NSNumber *> *members in moments.allValues) {
        if (members.count < 2 || members.count > 20) continue;
        for (NSUInteger x = 0; x < members.count; x++) {
            for (NSUInteger y = x + 1; y < members.count; y++) {
                uint32_t a = (uint32_t)MIN(members[x].unsignedIntegerValue, members[y].unsignedIntegerValue);
                uint32_t b = (uint32_t)MAX(members[x].unsignedIntegerValue, members[y].unsignedIntegerValue);
                BOOL near = fingerprinted[a] && fingerprinted[b] && __builtin_popcountll(hashes[a] ^ hashes[b]) <= POMaximumMomentHashDistance;
                NSString *subA = POSubSeconds(hashed[a].url);
                BOOL sameFraction = subA.length && [subA isEqualToString:POSubSeconds(hashed[b].url)];
                if ((near || sameFraction) && POAreCopies(hashed[a], hashed[b])) [candidates addObject:@(((uint64_t)a << 32) | b)];
            }
        }
    }

    // The fingerprint is coarse (9×8 pixels): every candidate is checked on the pictures themselves, on several
    // cores, and what was found is remembered for the next time.
    NSArray<NSNumber *> *pairs = candidates.allObjects;
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfURL:POVerdictsURL()];
    NSMutableDictionary<NSString *, NSNumber *> *verdicts = [saved isKindOfClass:NSDictionary.class] ? [saved mutableCopy] : [NSMutableDictionary dictionary];
    NSUInteger before = verdicts.count;
    BOOL *same = calloc(MAX(pairs.count, 1), sizeof(BOOL));
    NSObject *lock = [NSObject new];
    dispatch_apply(pairs.count, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(size_t index) {
        @autoreleasepool {
            uint64_t pair = pairs[index].unsignedLongLongValue;
            POPhotoItem *a = hashed[(NSUInteger)(pair >> 32)], *b = hashed[(NSUInteger)(pair & 0xFFFFFFFF)];
            NSString *keyA = POFileKey(a), *keyB = POFileKey(b);
            NSString *key = keyA && keyB ? ([keyA compare:keyB] == NSOrderedAscending ? [NSString stringWithFormat:@"%@ %@", keyA, keyB]
                                                                                   : [NSString stringWithFormat:@"%@ %@", keyB, keyA]) : nil;
            NSNumber *known;
            @synchronized (lock) { known = key ? verdicts[key] : nil; }
            if (known) {
                same[index] = known.boolValue;
                return;
            }
            double share = POChangedShare(a, b);
            if (share < 0) return;   // unreadable now: not remembered, asked again next time
            same[index] = share <= POMaximumChangedShare;
            if (key) @synchronized (lock) { verdicts[key] = @(same[index]); }
        }
    });
    if (verdicts.count != before) [verdicts writeToURL:POVerdictsURL() atomically:YES];
    for (NSUInteger index = 0; index < pairs.count; index++) {
        if (!same[index]) continue;
        uint64_t pair = pairs[index].unsignedLongLongValue;
        uint32_t a = (uint32_t)(pair >> 32), b = (uint32_t)(pair & 0xFFFFFFFF);
        if (find(a) != find(b)) parent[find(b)] = find(a);
    }
    free(same);

    NSMutableDictionary<NSNumber *, NSMutableArray<POPhotoItem *> *> *groups = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < count; i++) {
        NSNumber *root = @(find((uint32_t)i));
        NSMutableArray *group = groups[root];
        if (!group) groups[root] = group = [NSMutableArray array];
        [group addObject:hashed[i]];
    }
    free(hashes);
    free(fingerprinted);
    free(order);
    free(parent);

    NSMutableArray<NSArray<POPhotoItem *> *> *sets = [NSMutableArray array];
    for (NSMutableArray<POPhotoItem *> *group in groups.allValues) {
        if (group.count < 2) continue;
        POOrderAndMark(group);
        [sets addObject:group];
    }
    [sets addObjectsFromArray:POVideoSets(items)];
    [sets sortUsingComparator:^NSComparisonResult(NSArray<POPhotoItem *> *a, NSArray<POPhotoItem *> *b) {
        return [a.firstObject.date compare:b.firstObject.date] ?: [a.firstObject.relativePath localizedStandardCompare:b.firstObject.relativePath];
    }];
    return sets;
}

@end
