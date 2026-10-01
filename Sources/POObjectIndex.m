#import "POObjectIndex.h"
#import <Vision/Vision.h>
#import <Accelerate/Accelerate.h>

/// Length of one print (Vision's feature print, revision 2). Prints of another length are ignored.
static const NSUInteger PODim = 768;
static const NSUInteger POMaximumObjects = 3;

@implementation POObjectIndex {
    NSMutableDictionary<NSString *, NSData *> *_vectors;   // key → n × PODim half-precision floats
    NSMutableArray<NSString *> *_unsaved;
}

+ (POObjectIndex *)sharedIndex {
    static POObjectIndex *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [POObjectIndex new]; });
    return shared;
}

+ (NSURL *)fileURL {
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                                                 appropriateForURL:nil create:YES error:NULL];
    return [support URLByAppendingPathComponent:@"Photo Organizer/objects.bin"];
}

/// File format: records of [uint16 key length][key UTF-8][uint16 print count][count × PODim float16], appended
/// as files are analysed; a later record for a key replaces an earlier one.
- (instancetype)init {
    if ((self = [super init])) {
        _vectors = [NSMutableDictionary dictionary];
        _unsaved = [NSMutableArray array];
        NSData *data = [NSData dataWithContentsOfURL:POObjectIndex.fileURL options:NSDataReadingMappedIfSafe error:NULL];
        const uint8_t *bytes = data.bytes;
        NSUInteger offset = 0, length = data.length;
        while (offset + 4 <= length) {
            uint16_t keyLength;
            memcpy(&keyLength, bytes + offset, 2);
            if (offset + 2 + keyLength + 2 > length) break;
            NSString *key = [[NSString alloc] initWithBytes:bytes + offset + 2 length:keyLength encoding:NSUTF8StringEncoding];
            uint16_t count;
            memcpy(&count, bytes + offset + 2 + keyLength, 2);
            NSUInteger size = (NSUInteger)count * PODim * 2, start = offset + 4 + keyLength;
            if (start + size > length) break;   // a record cut short by a crash
            if (key) _vectors[key] = [NSData dataWithBytes:bytes + start length:size];
            offset = start + size;
        }
    }
    return self;
}

- (BOOL)hasVectorsForKey:(NSString *)key {
    @synchronized (self) {
        return _vectors[key] != nil;
    }
}

- (void)setVectors:(NSData *)vectors forKey:(NSString *)key {
    BOOL shouldSave;
    @synchronized (self) {
        _vectors[key] = vectors;
        [_unsaved addObject:key];
        shouldSave = _unsaved.count >= 300;
    }
    if (shouldSave) [self save];
}

- (void)save {
    NSMutableData *data = [NSMutableData data];
    @synchronized (self) {
        for (NSString *key in _unsaved) {
            NSData *keyData = [key dataUsingEncoding:NSUTF8StringEncoding];
            NSData *vectors = _vectors[key];
            uint16_t keyLength = (uint16_t)keyData.length, count = (uint16_t)(vectors.length / (PODim * 2));
            [data appendBytes:&keyLength length:2];
            [data appendData:keyData];
            [data appendBytes:&count length:2];
            [data appendData:vectors];
        }
        [_unsaved removeAllObjects];
    }
    if (!data.length) return;
    NSURL *url = POObjectIndex.fileURL;
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) [NSData.data writeToURL:url atomically:YES];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:url error:NULL];
    [handle seekToEndOfFile];
    [handle writeData:data];
    [handle closeFile];
}

#pragma mark - Prints

/// One unit-length print of `image`, as float32; nil on failure.
static NSData *POPrint(CGImageRef image) {
    VNGenerateImageFeaturePrintRequest *request = [VNGenerateImageFeaturePrintRequest new];
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    if (![handler performRequests:@[request] error:NULL]) return nil;
    VNFeaturePrintObservation *print = request.results.firstObject;
    if (print.elementType != VNElementTypeFloat || print.elementCount != PODim) return nil;
    NSMutableData *vector = [print.data mutableCopy];
    float norm = 0;
    vDSP_svesq(vector.bytes, 1, &norm, PODim);
    norm = sqrtf(norm);
    if (norm > 0) vDSP_vsdiv(vector.bytes, 1, &norm, vector.mutableBytes, 1, PODim);
    return vector;
}

/// `rect` (pixels, origin top-left) grown by `margin` of its size on every side, kept inside the image.
static CGImageRef POCopyCrop(CGImageRef image, CGRect rect, CGFloat margin) CF_RETURNS_RETAINED {
    CGRect bounds = CGRectMake(0, 0, CGImageGetWidth(image), CGImageGetHeight(image));
    CGRect grown = CGRectIntegral(CGRectIntersection(CGRectInset(rect, -rect.size.width * margin, -rect.size.height * margin), bounds));
    if (grown.size.width < 16 || grown.size.height < 16) return NULL;
    return CGImageCreateWithImageInRect(image, grown);
}

/// Salient objects in pixels (origin top-left), most confident first.
static NSArray<NSValue *> *POSalientRects(CGImageRef image) {
    VNGenerateObjectnessBasedSaliencyImageRequest *request = [VNGenerateObjectnessBasedSaliencyImageRequest new];
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    if (![handler performRequests:@[request] error:NULL]) return @[];
    CGFloat width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    NSArray<VNRectangleObservation *> *objects = [((VNSaliencyImageObservation *)request.results.firstObject).salientObjects
        sortedArrayUsingComparator:^NSComparisonResult(VNRectangleObservation *a, VNRectangleObservation *b) {
            return a.confidence > b.confidence ? NSOrderedAscending : (a.confidence < b.confidence ? NSOrderedDescending : NSOrderedSame);
        }];
    NSMutableArray<NSValue *> *rects = [NSMutableArray array];
    for (VNRectangleObservation *object in objects) {
        CGRect box = object.boundingBox;   // normalised, origin bottom-left
        CGFloat area = box.size.width * box.size.height;
        if (area < 0.02 || area > 0.9) continue;   // specks, and "the whole picture" (already covered)
        [rects addObject:[NSValue valueWithRect:NSMakeRect(box.origin.x * width, (1 - CGRectGetMaxY(box)) * height,
                                                          box.size.width * width, box.size.height * height)]];
    }
    return rects;
}

+ (CGRect)mostSalientRectInImage:(CGImageRef)image {
    NSArray<NSValue *> *rects = POSalientRects(image);
    return rects.count ? NSRectToCGRect(rects.firstObject.rectValue) : CGRectNull;
}

static void POAppendHalf(NSMutableData *out, NSData *vector) {
    NSMutableData *half = [NSMutableData dataWithLength:PODim * 2];
    vImage_Buffer source = {(void *)vector.bytes, 1, PODim, PODim * 4};
    vImage_Buffer destination = {half.mutableBytes, 1, PODim, PODim * 2};
    vImageConvert_PlanarFtoPlanar16F(&source, &destination, 0);
    [out appendData:half];
}

+ (NSData *)vectorsForImage:(CGImageRef)image {
    NSMutableData *out = [NSMutableData data];
    NSData *whole = POPrint(image);
    if (whole) POAppendHalf(out, whole);
    NSUInteger objects = 0;
    for (NSValue *value in POSalientRects(image)) {
        if (objects >= POMaximumObjects) break;
        CGImageRef crop = POCopyCrop(image, NSRectToCGRect(value.rectValue), 0.08);
        if (!crop) continue;
        NSData *print = POPrint(crop);
        CGImageRelease(crop);
        if (!print) continue;
        POAppendHalf(out, print);
        objects++;
    }
    return out;   // empty when nothing could be computed: remembered, so the file is not retried every time
}

+ (NSData *)queryVectorForImage:(CGImageRef)image rect:(CGRect)rect {
    CGImageRef crop = POCopyCrop(image, rect, 0.04);
    if (!crop) return nil;
    NSData *print = POPrint(crop);
    CGImageRelease(crop);
    return print;
}

#pragma mark - Search

- (NSUInteger)countOfIndexedKeys:(NSArray<NSString *> *)keys {
    NSUInteger count = 0;
    @synchronized (self) {
        for (NSString *key in keys) if ((id)key != NSNull.null && _vectors[key]) count++;
    }
    return count;
}

- (NSArray<POPhotoItem *> *)itemsNearest:(NSData *)query inItems:(NSArray<POPhotoItem *> *)items keys:(NSArray<NSString *> *)keys
                                   limit:(NSUInteger)limit distances:(NSArray<NSNumber *> **)distancesOut {
    NSDictionary<NSString *, NSData *> *vectors;
    @synchronized (self) {
        vectors = [_vectors copy];
    }
    NSUInteger count = items.count;
    float *best = malloc(MAX(count, 1) * sizeof(float));
    dispatch_apply(count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
        best[index] = FLT_MAX;
        NSString *key = keys[index];
        NSData *stored = (id)key == NSNull.null ? nil : vectors[key];
        NSUInteger prints = stored.length / (PODim * 2);
        if (!prints) return;
        float buffer[PODim];
        for (NSUInteger p = 0; p < prints; p++) {
            vImage_Buffer source = {(void *)((const uint8_t *)stored.bytes + p * PODim * 2), 1, PODim, PODim * 2};
            vImage_Buffer destination = {buffer, 1, PODim, PODim * 4};
            vImageConvert_Planar16FtoPlanarF(&source, &destination, 0);
            float dot = 0;
            vDSP_dotpr(buffer, 1, query.bytes, 1, &dot, PODim);
            float distance = 2 - 2 * dot;   // squared distance between unit vectors
            if (distance < best[index]) best[index] = distance;
        }
    });
    NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    for (NSUInteger index = 0; index < count; index++) if (best[index] < FLT_MAX) [order addObject:@(index)];
    [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        float da = best[a.unsignedIntegerValue], db = best[b.unsignedIntegerValue];
        return da < db ? NSOrderedAscending : (da > db ? NSOrderedDescending : NSOrderedSame);
    }];
    NSMutableArray<POPhotoItem *> *results = [NSMutableArray array];
    NSMutableArray<NSNumber *> *distances = [NSMutableArray array];
    for (NSNumber *index in order) {
        if (results.count >= limit) break;
        [results addObject:items[index.unsignedIntegerValue]];
        [distances addObject:@(best[index.unsignedIntegerValue])];
    }
    free(best);
    if (distancesOut) *distancesOut = distances;
    return results;
}

@end
