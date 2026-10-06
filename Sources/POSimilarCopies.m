#import "POSimilarCopies.h"
#import <ImageIO/ImageIO.h>
#import <sys/stat.h>

static const int POMaximumHashDistance = 2;
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
static double POChangedShare(POPhotoItem *a, POPhotoItem *b) {
    POPhotoItem *smaller = (long long)a.pixelWidth * a.pixelHeight <= (long long)b.pixelWidth * b.pixelHeight ? a : b;
    size_t w = (size_t)MIN(MAX(smaller.pixelWidth / 2, 8), 160);
    size_t h = (size_t)MAX(8, lround(w * (double)a.pixelHeight / a.pixelWidth));
    uint8_t *pa = POGrayPixels(a.url, w, h), *pb = POGrayPixels(b.url, w, h);
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

static BOOL POAreCopies(POPhotoItem *a, POPhotoItem *b) {
    if (a.pixelWidth <= 0 || a.pixelHeight <= 0 || b.pixelWidth <= 0 || b.pixelHeight <= 0) return NO;
    double aspectA = (double)a.pixelWidth / a.pixelHeight, aspectB = (double)b.pixelWidth / b.pixelHeight;
    if (fabs(aspectA - aspectB) > 0.02 * MAX(aspectA, aspectB)) return NO;
    // Two files that both know when they were shot, at different moments, are different shots however alike:
    // frames of a burst (IMG_20171022_181417 and …181418) must not be offered for deletion.
    BOOL timedA = a.dateSource == PODateSourceEXIF || a.dateSource == PODateSourceName;
    BOOL timedB = b.dateSource == PODateSourceEXIF || b.dateSource == PODateSourceName;
    if (timedA && timedB && fabs([a.date timeIntervalSinceDate:b.date]) >= 1) return NO;
    return YES;
}

/// Better quality first.
static NSComparisonResult POCompareQuality(POPhotoItem *a, POPhotoItem *b) {
    long long pixelsA = (long long)a.pixelWidth * a.pixelHeight, pixelsB = (long long)b.pixelWidth * b.pixelHeight;
    if (pixelsA != pixelsB) return pixelsA > pixelsB ? NSOrderedAscending : NSOrderedDescending;
    if (a.fileSize != b.fileSize) return a.fileSize > b.fileSize ? NSOrderedAscending : NSOrderedDescending;
    BOOL exifA = a.dateSource == PODateSourceEXIF, exifB = b.dateSource == PODateSourceEXIF;
    if (exifA != exifB) return exifA ? NSOrderedAscending : NSOrderedDescending;   // the one that kept its metadata
    return [a.relativePath localizedStandardCompare:b.relativePath];
}

static BOOL POHasOwnDate(POPhotoItem *item) {
    return item.dateSource == PODateSourceEXIF || item.dateSource == PODateSourceName || item.dateSource == PODateSourceTakeout;
}

+ (NSUInteger)shareDatesInSets:(NSArray<NSArray<POPhotoItem *> *> *)sets {
    NSUInteger shared = 0;
    for (NSArray<POPhotoItem *> *set in sets) {
        POPhotoItem *source = nil;
        for (POPhotoItem *item in set) {
            if (POHasOwnDate(item) && (!source || (item.dateSource == PODateSourceEXIF && source.dateSource != PODateSourceEXIF))) source = item;
        }
        if (!source) continue;
        for (POPhotoItem *item in set) {
            NSArray<POPhotoItem *> *group = [@[item] arrayByAddingObjectsFromArray:item.duplicates ?: @[]];   // exact twins too
            for (POPhotoItem *copy in group) {
                if (POHasOwnDate(copy)) continue;
                copy.date = source.date;
                copy.dateSource = PODateSourceCopy;
                shared++;
            }
        }
    }
    return shared;
}

+ (NSArray<NSArray<POPhotoItem *> *> *)setsInItems:(NSArray<POPhotoItem *> *)items {
    NSMutableArray<POPhotoItem *> *hashed = [NSMutableArray array];
    for (POPhotoItem *item in items) {
        item.betterCopy = nil;
        item.tiny = NO;
        item.bestOfCopies = NO;
        if (item.visualHash && !item.isDuplicate && !item.isVideo) [hashed addObject:item];
    }
    NSUInteger count = hashed.count;
    if (count < 2) return @[];
    uint64_t *hashes = malloc(count * sizeof(uint64_t));
    uint32_t *order = malloc(count * sizeof(uint32_t)), *parent = malloc(count * sizeof(uint32_t));
    for (NSUInteger i = 0; i < count; i++) {
        hashes[i] = hashed[i].visualHash.unsignedLongLongValue;
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
                    if (__builtin_popcountll(hashes[a] ^ hashes[b]) > POMaximumHashDistance) continue;
                    if (POAreCopies(hashed[a], hashed[b])) [candidates addObject:@(((uint64_t)a << 32) | b)];
                }
            }
            start = end;
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
    free(order);
    free(parent);

    NSMutableArray<NSArray<POPhotoItem *> *> *sets = [NSMutableArray array];
    for (NSMutableArray<POPhotoItem *> *group in groups.allValues) {
        if (group.count < 2) continue;
        [group sortUsingComparator:^NSComparisonResult(POPhotoItem *a, POPhotoItem *b) { return POCompareQuality(a, b); }];
        group.firstObject.bestOfCopies = YES;
        POPhotoItem *best = group.firstObject;
        NSInteger bestSide = MAX(best.pixelWidth, best.pixelHeight);
        for (NSUInteger i = 1; i < group.count; i++) {
            POPhotoItem *copy = group[i];
            copy.betterCopy = best;
            NSInteger side = MAX(copy.pixelWidth, copy.pixelHeight);
            copy.tiny = side * 2 <= bestSide;
            // An exact copy of a thumbnail is a thumbnail too.
            for (POPhotoItem *twin in copy.duplicates) twin.tiny = copy.tiny;
        }
        [sets addObject:group];
    }
    [sets sortUsingComparator:^NSComparisonResult(NSArray<POPhotoItem *> *a, NSArray<POPhotoItem *> *b) {
        return [a.firstObject.date compare:b.firstObject.date] ?: [a.firstObject.relativePath localizedStandardCompare:b.firstObject.relativePath];
    }];
    return sets;
}

@end
