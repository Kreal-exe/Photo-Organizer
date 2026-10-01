#import "POSimilaritySearch.h"
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>
#import <stdatomic.h>

/// How many of the best word matches are compared visually; the comparison costs a decode per file.
static const NSUInteger POMaximumCandidates = 1500;
static const NSUInteger POMaximumResults = 300;
static const NSInteger POComparePixelSize = 384;

@implementation POSimilaritySearch

+ (CGImageRef)newImageWithContentsOfURL:(NSURL *)url {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, (__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCache: @NO});
    if (!source) return NULL;
    NSDictionary *options = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                              (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                              (id)kCGImageSourceThumbnailMaxPixelSize: @(POComparePixelSize)};
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    return image;
}

static VNFeaturePrintObservation *POFeaturePrint(CGImageRef image) {
    VNGenerateImageFeaturePrintRequest *request = [VNGenerateImageFeaturePrintRequest new];
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    if (![handler performRequests:@[request] error:NULL]) return nil;
    return request.results.firstObject;
}

/// Feature prints of library files, kept while the app runs so that a second search is instant.
static NSCache<NSString *, VNFeaturePrintObservation *> *POPrintCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 30000;
    });
    return cache;
}

+ (void)findItemsSimilarToImage:(CGImageRef)image labels:(NSArray<NSString *> *)labels inItems:(NSArray<POPhotoItem *> *)items
                       progress:(void (^)(NSUInteger, NSUInteger))progress completion:(void (^)(NSArray<POPhotoItem *> *))completion {
    CGImageRetain(image);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Step 1 — words: a file is a candidate when it shares labels with the example; the more it shares
        // (and the surer the classifier was), the earlier it comes.
        NSMutableArray<NSArray *> *scored = [NSMutableArray array];
        for (POPhotoItem *item in items) {
            if (item.isVideo || item.isCloudOnly) continue;   // the visual comparison below needs a still picture
            double score = 0;
            NSDictionary<NSString *, NSNumber *> *own = item.labels;
            for (NSString *label in labels) score += own[label].doubleValue;
            if (labels.count && score <= 0) continue;
            [scored addObject:@[@(score), item]];
        }
        [scored sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
        if (scored.count > POMaximumCandidates) [scored removeObjectsInRange:NSMakeRange(POMaximumCandidates, scored.count - POMaximumCandidates)];

        // Step 2 — looks: distance between the example's feature print and each candidate's.
        VNFeaturePrintObservation *example = POFeaturePrint(image);
        CGImageRelease(image);
        NSUInteger total = scored.count;
        NSMutableData *distanceData = [NSMutableData dataWithLength:total * sizeof(float)];
        float *distances = distanceData.mutableBytes;
        __block atomic_uint_fast64_t done = 0;
        NSCache<NSString *, VNFeaturePrintObservation *> *cache = POPrintCache();
        dispatch_apply(total, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
            @autoreleasepool {
                POPhotoItem *item = scored[index][1];
                VNFeaturePrintObservation *print = [cache objectForKey:item.url.path];
                if (!print) {
                    CGImageRef candidate = [self newImageWithContentsOfURL:item.url];
                    if (candidate) {
                        print = POFeaturePrint(candidate);
                        CGImageRelease(candidate);
                        if (print) [cache setObject:print forKey:item.url.path];
                    }
                }
                float distance = FLT_MAX;
                if (!example || !print || ![example computeDistance:&distance toFeaturePrintObservation:print error:NULL]) distance = FLT_MAX;
                distances[index] = distance;
            }
            NSUInteger count = (NSUInteger)atomic_fetch_add(&done, 1) + 1;
            if (progress && (count % 25 == 0 || count == total)) dispatch_async(dispatch_get_main_queue(), ^{ progress(count, total); });
        });

        NSMutableArray<NSNumber *> *order = [NSMutableArray arrayWithCapacity:total];
        for (NSUInteger index = 0; index < total; index++) {
            if (distances[index] < FLT_MAX) [order addObject:@(index)];
        }
        [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            float distanceA = distances[a.unsignedIntegerValue], distanceB = distances[b.unsignedIntegerValue];
            return distanceA < distanceB ? NSOrderedAscending : (distanceA > distanceB ? NSOrderedDescending : NSOrderedSame);
        }];
        NSMutableArray<POPhotoItem *> *results = [NSMutableArray array];
        for (NSNumber *index in order) {
            if (results.count >= POMaximumResults) break;
            [results addObject:scored[index.unsignedIntegerValue][1]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(results); });
    });
}

@end
