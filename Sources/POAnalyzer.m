#import "POAnalyzer.h"
#import "POStrings.h"
#import "POSettings.h"
#import "POModel.h"
#import "PONudityClassifier.h"
#import "POFaces.h"
#import "POSimilarCopies.h"
#import "POObjectIndex.h"
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>
#import <AVFoundation/AVFoundation.h>
#import <stdatomic.h>
#import <sys/stat.h>

/// Longest side of the picture handed to the models; they work on far smaller inputs than a full photo.
static const NSInteger POAnalysisPixelSize = 512;
/// Faces in a group shot are small, so face grouping looks at a larger version.
static const NSInteger POFacePixelSize = 1280;
/// Labels below this confidence are noise.
static const float POLabelMinimumConfidence = 0.3f;
static const NSInteger POMaximumVideoFrames = 5;

#pragma mark - Remembered results

/// identity of a file → {"l": {label: confidence}, "n": {model id: score}, "f": [face embedding], "p": people in the photo, "h": visual hash (0 when the picture is too plain to have one)}. The identity survives moving and
/// renaming the file on its volume, and changes when the file's contents do.
@interface POAnalysisCache : NSObject
@property (class, nonatomic, readonly) POAnalysisCache *sharedCache;
+ (nullable NSString *)keyForURL:(NSURL *)url;
- (nullable NSDictionary *)recordForKey:(NSString *)key;
- (void)setLabels:(nullable NSDictionary *)labels nudityScore:(nullable NSNumber *)score model:(nullable NSString *)model
            faces:(nullable NSArray<NSData *> *)faces visualHash:(nullable NSNumber *)visualHash forKey:(NSString *)key;
- (void)setPeopleCount:(NSInteger)count forKey:(NSString *)key;
- (void)save;
- (void)removeAll;
@end

@implementation POAnalysisCache {
    NSMutableDictionary<NSString *, NSDictionary *> *_records;
    NSUInteger _unsaved;
}

+ (POAnalysisCache *)sharedCache {
    static POAnalysisCache *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [POAnalysisCache new]; });
    return shared;
}

+ (NSURL *)fileURL {
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                                                 appropriateForURL:nil create:YES error:NULL];
    return [support URLByAppendingPathComponent:@"Photo Organizer/analysis.plist"];
}

+ (NSString *)keyForURL:(NSURL *)url {
    struct stat info;
    if (stat(url.fileSystemRepresentation, &info) != 0) return nil;
    return [NSString stringWithFormat:@"%d-%llu-%lld-%ld", info.st_dev, (unsigned long long)info.st_ino, (long long)info.st_size, (long)info.st_mtimespec.tv_sec];
}

- (instancetype)init {
    if ((self = [super init])) {
        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfURL:POAnalysisCache.fileURL];
        _records = [saved isKindOfClass:NSDictionary.class] ? [saved mutableCopy] : [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSDictionary *)recordForKey:(NSString *)key {
    @synchronized (self) {
        return _records[key];
    }
}

- (void)setLabels:(NSDictionary *)labels nudityScore:(NSNumber *)score model:(NSString *)model faces:(NSArray<NSData *> *)faces
       visualHash:(NSNumber *)visualHash forKey:(NSString *)key {
    BOOL shouldSave;
    @synchronized (self) {
        NSMutableDictionary *record = [_records[key] mutableCopy] ?: [NSMutableDictionary dictionary];
        if (labels) record[@"l"] = labels;
        if (faces) record[@"f"] = faces;
        if (visualHash) record[@"h"] = visualHash;
        if (score && model) {
            NSMutableDictionary *scores = [record[@"n"] mutableCopy] ?: [NSMutableDictionary dictionary];
            scores[model] = score;
            record[@"n"] = scores;
        }
        _records[key] = record;
        shouldSave = ++_unsaved >= 500;   // a crash or a quit loses at most this many results
    }
    if (shouldSave) [self save];
}

- (void)setPeopleCount:(NSInteger)count forKey:(NSString *)key {
    BOOL shouldSave;
    @synchronized (self) {
        NSMutableDictionary *record = [_records[key] mutableCopy] ?: [NSMutableDictionary dictionary];
        record[@"p"] = @(count);
        _records[key] = record;
        shouldSave = ++_unsaved >= 500;
    }
    if (shouldSave) [self save];
}

- (void)save {
    NSData *data;
    @synchronized (self) {
        if (!_unsaved) return;
        _unsaved = 0;
        data = [NSPropertyListSerialization dataWithPropertyList:_records format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    }
    NSURL *file = POAnalysisCache.fileURL;
    [NSFileManager.defaultManager createDirectoryAtURL:file.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    [data writeToURL:file atomically:YES];
}

- (void)removeAll {
    @synchronized (self) {
        [_records removeAllObjects];
        _unsaved = 1;
    }
    [self save];
}

@end

#pragma mark - Pictures to analyse

/// Small decoded versions of what the file shows: the photo itself, or frames spread over a video.
static NSArray *POImagesForItem(POPhotoItem *item, NSInteger pixelSize) {
    NSMutableArray *images = [NSMutableArray array];
    if (item.isVideo) {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:item.url options:nil];
        AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
        generator.appliesPreferredTrackTransform = YES;
        generator.maximumSize = CGSizeMake(POAnalysisPixelSize, POAnalysisPixelSize);
        double duration = CMTIME_IS_NUMERIC(asset.duration) ? CMTimeGetSeconds(asset.duration) : 0;
        NSInteger count = MIN(MAX((NSInteger)ceil(duration / 3), 1), POMaximumVideoFrames);
        for (NSInteger frame = 0; frame < count; frame++) {
            CMTime time = CMTimeMakeWithSeconds(duration * (frame + 0.5) / count, 600);
            CGImageRef image = [generator copyCGImageAtTime:time actualTime:NULL error:NULL];
            if (image) [images addObject:CFBridgingRelease(image)];
        }
    } else {
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)item.url, (__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCache: @NO});
        if (source) {
            NSDictionary *options = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                                      (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                                      (id)kCGImageSourceThumbnailMaxPixelSize: @(pixelSize)};
            CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
            if (image) [images addObject:CFBridgingRelease(image)];
            CFRelease(source);
        }
    }
    return images;
}

static NSDictionary<NSString *, NSNumber *> *POLabelsForImages(NSArray *images) {
    NSMutableDictionary<NSString *, NSNumber *> *labels = [NSMutableDictionary dictionary];
    for (id image in images) {
        VNClassifyImageRequest *request = [VNClassifyImageRequest new];
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:(__bridge CGImageRef)image options:@{}];
        if (![handler performRequests:@[request] error:NULL]) continue;
        for (VNClassificationObservation *observation in request.results) {
            if (observation.confidence < POLabelMinimumConfidence) continue;
            if (observation.confidence > labels[observation.identifier].floatValue) {
                // Rounded so the property list stays small.
                labels[observation.identifier] = @(round(observation.confidence * 100) / 100);
            }
        }
    }
    return labels;
}

#pragma mark - Analyzer

@implementation POAnalyzer {
    NSArray<POPhotoItem *> *_items;
    atomic_bool _cancelled;
    atomic_uint_fast64_t _done;
}

- (instancetype)initWithItems:(NSArray<POPhotoItem *> *)items {
    if ((self = [super init])) {
        _items = [items copy];
    }
    return self;
}

- (void)cancel {
    atomic_store(&_cancelled, true);
}

+ (NSDictionary<NSString *, NSNumber *> *)labelsForImage:(CGImageRef)image {
    return POLabelsForImages(@[(__bridge id)image]);
}

+ (NSString *)cacheKeyForURL:(NSURL *)url {
    return [POAnalysisCache keyForURL:url];
}

+ (void)removeAllCachedResults {
    [POAnalysisCache.sharedCache removeAll];
}

- (void)startWithProgress:(void (^)(NSUInteger, NSUInteger))progress completion:(void (^)(NSString *))completion {
    BOOL wantsLabels = POSettings.analyzesObjects;
    POModel *model = POSettings.detectsNudity ? POModel.selectedModel : nil;
    if (!model.isReady) model = nil;
    BOOL wantsFaces = POSettings.groupsFaces && POModel.faceModel.isReady;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        POAnalysisCache *cache = POAnalysisCache.sharedCache;
        POObjectIndex *objectIndex = POObjectIndex.sharedIndex;
        NSString *modelKey = model.identifier;

        // First what is already known, so that searching works straight away on a folder seen before.
        NSMutableArray<POPhotoItem *> *pending = [NSMutableArray array];
        NSMutableArray<NSString *> *pendingKeys = [NSMutableArray array];
        for (POPhotoItem *item in self->_items) {
            if (item.isCloudOnly) continue;   // reading it would download it
            NSString *key = [POAnalysisCache keyForURL:item.url];
            if (!key) continue;
            NSDictionary *record = [cache recordForKey:key];
            NSDictionary *labels = wantsLabels ? record[@"l"] : nil;
            NSNumber *score = modelKey ? record[@"n"][modelKey] : nil;
            NSArray<NSData *> *faces = wantsFaces ? record[@"f"] : nil;
            item.labels = labels;
            item.nudityScore = score;
            item.faces = faces;
            item.peopleCount = wantsFaces ? record[@"p"] : nil;
            // Only photos with someone in a group need the count; it came after faces, so older results lack it.
            BOOL needsCount = wantsFaces && faces.count && !item.peopleCount;
            NSNumber *hash = record[@"h"];
            item.visualHash = hash.unsignedLongLongValue ? hash : nil;
            BOOL needsHash = !hash && !item.isVideo;
            BOOL needsObjects = wantsLabels && !item.isVideo && ![objectIndex hasVectorsForKey:key];
            if ((wantsLabels && !labels) || (modelKey && !score) || (wantsFaces && !faces) || needsCount || needsHash || needsObjects) {
                [pending addObject:item];
                [pendingKeys addObject:key];
            }
        }

        NSString *errorMessage = nil;
        PONudityClassifier *classifier = nil;
        if (model && pending.count && !atomic_load(&self->_cancelled)) {
            NSError *error = nil;
            classifier = [PONudityClassifier classifierWithModel:model error:&error];
            if (!classifier) errorMessage = error.localizedDescription ?: POL(@"Модель распознавания наготы не запустилась");
        }

        POFaceEmbedder *embedder = nil;
        if (wantsFaces && pending.count && !atomic_load(&self->_cancelled)) {
            NSError *error = nil;
            embedder = [POFaceEmbedder embedderWithError:&error];
            if (!embedder && !errorMessage) errorMessage = error.localizedDescription ?: POL(@"Модель лиц не запустилась");
        }

        NSUInteger total = pending.count;
        if (total && progress) dispatch_async(dispatch_get_main_queue(), ^{ progress(0, total); });
        dispatch_apply(total, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(size_t index) {
            if (atomic_load(&self->_cancelled)) return;
            @autoreleasepool {
                POPhotoItem *item = pending[index];
                BOOL needsFaces = embedder && !item.faces;
                BOOL needsCount = wantsFaces && !item.isVideo && !item.peopleCount && (needsFaces || item.faces.count);
                NSArray *images = POImagesForItem(item, (needsFaces || needsCount) && !item.isVideo ? POFacePixelSize : POAnalysisPixelSize);
                NSDictionary *labels = nil;
                NSNumber *score = nil;
                NSArray<NSData *> *faces = nil;
                if (needsFaces) {
                    // Photos only for now: a video would need its faces tracked across frames.
                    NSInteger people = 0;
                    faces = item.isVideo || !images.count ? @[] : [embedder embeddingsForFacesInImage:(__bridge CGImageRef)images.firstObject peopleCount:&people];
                    item.faces = faces;
                    if (needsCount && images.count) {
                        people = MAX(people, (NSInteger)faces.count);
                        item.peopleCount = @(people);
                        [cache setPeopleCount:people forKey:pendingKeys[index]];
                    }
                } else if (needsCount && images.count) {
                    NSInteger people = MAX([POFaceEmbedder peopleCountInImage:(__bridge CGImageRef)images.firstObject], (NSInteger)item.faces.count);
                    item.peopleCount = @(people);
                    [cache setPeopleCount:people forKey:pendingKeys[index]];
                }
                NSNumber *hash = nil;
                if (!item.isVideo && !item.visualHash && ![cache recordForKey:pendingKeys[index]][@"h"]) {
                    NSNumber *computed = images.count ? [POSimilarCopies visualHashOfImage:(__bridge CGImageRef)images.firstObject] : nil;
                    item.visualHash = computed;
                    hash = computed ?: @0;   // remembered either way, so plain pictures are not re-read on every launch
                }
                if (wantsLabels && !item.isVideo && images.count && ![objectIndex hasVectorsForKey:pendingKeys[index]]) {
                    // Prints for "search by object"; from the analysis-sized picture, whatever size faces needed.
                    CGImageRef picture = (__bridge CGImageRef)images.firstObject;
                    CGImageRef small = NULL;
                    if (MAX(CGImageGetWidth(picture), CGImageGetHeight(picture)) > POAnalysisPixelSize) {
                        CGFloat scale = (CGFloat)POAnalysisPixelSize / MAX(CGImageGetWidth(picture), CGImageGetHeight(picture));
                        size_t width = MAX(1, (size_t)(CGImageGetWidth(picture) * scale)), height = MAX(1, (size_t)(CGImageGetHeight(picture) * scale));
                        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                        CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
                        CGColorSpaceRelease(space);
                        CGContextDrawImage(context, CGRectMake(0, 0, width, height), picture);
                        small = CGBitmapContextCreateImage(context);
                        CGContextRelease(context);
                    }
                    [objectIndex setVectors:[POObjectIndex vectorsForImage:small ?: picture] forKey:pendingKeys[index]];
                    if (small) CGImageRelease(small);
                }
                if (wantsLabels && !item.labels) {
                    // Unreadable files get an empty result, so they are not retried on every launch.
                    item.labels = labels = POLabelsForImages(images);
                }
                if (classifier && !item.nudityScore) {
                    for (id image in images) {
                        NSNumber *frame = [classifier scoreForImage:(__bridge CGImageRef)image];
                        if (frame && frame.doubleValue >= score.doubleValue) score = frame;
                    }
                    if (!images.count) score = @0;
                    item.nudityScore = score;
                }
                if (labels || score || faces || hash) {
                    [cache setLabels:labels nudityScore:score model:modelKey faces:faces visualHash:hash forKey:pendingKeys[index]];
                }
            }
            NSUInteger done = (NSUInteger)atomic_fetch_add(&self->_done, 1) + 1;
            if (progress && (done % 10 == 0 || done == total)) dispatch_async(dispatch_get_main_queue(), ^{ progress(done, total); });
        });
        [classifier invalidate];
        [embedder invalidate];
        [cache save];
        [objectIndex save];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!atomic_load(&self->_cancelled)) completion(errorMessage);
        });
    });
}

@end
