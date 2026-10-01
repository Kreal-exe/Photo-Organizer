#import "POSimilarCopies.h"

static const int POMaximumHashDistance = 2;

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
                    uint32_t a = order[i], b = order[j];
                    if (__builtin_popcountll(hashes[a] ^ hashes[b]) > POMaximumHashDistance) continue;
                    if (find(a) != find(b) && POAreCopies(hashed[a], hashed[b])) parent[find(b)] = find(a);
                }
            }
            start = end;
        }
    }

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
