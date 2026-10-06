#import "POPeople.h"
#import "POStrings.h"
#import "POFaces.h"
#import <Accelerate/Accelerate.h>
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>

/// The same thresholds as on Windows.
/// A face joins a group when its similarity (cosine) to the group's average face is at least this.
static const float POJoinSimilarity = 0.45f;
/// A group joins a person whose average face (of all joined so far) is at least this similar.
static const float POMergeSimilarity = 0.55f;
/// Faces of one person are on average at least this similar to each other; a group below it is a mix of faces that
/// cannot be told apart (turned away, blurred, babies, animals) and is not listed as a person.
static const double POMinimumCoherence = 0.38;
/// A stored name applies to a group whose average face is at least this similar to the named one.
static const float PONameSimilarity = 0.45f;
/// Search by face: a photo matches when one of its faces is at least this similar.
static const float POSearchSimilarity = 0.42f;
static const NSUInteger POMinimumFilesPerPerson = 4;

enum { PODim = 512 };

@interface POPerson ()
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic) BOOL named;
@property (nonatomic, copy) NSArray<POPhotoItem *> *items;
@property (nonatomic, copy) NSArray<POPhotoItem *> *soloItems;
@property (nonatomic, strong) NSCountedSet<POPhotoItem *> *facesPerFile;   // how many of a file's faces are this person's
@property (nonatomic) NSUInteger faceCount;
@property (nonatomic, copy) NSData *centroid;   // PODim floats, unit length
@property (nonatomic, strong) POPhotoItem *representativeItem;
@property (nonatomic) NSUInteger representativeFace;
@end

@implementation POPerson
@end

static NSURL *PONamesURL(void) {
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                                                 appropriateForURL:nil create:YES error:NULL];
    return [support URLByAppendingPathComponent:@"Photo Organizer/people.plist"];
}

/// [{"name": …, "face": PODim floats}] — one entry per time the user named a group.
static NSArray<NSDictionary *> *POLoadNames(void) {
    NSArray *names = [NSArray arrayWithContentsOfURL:PONamesURL()];
    return [names isKindOfClass:NSArray.class] ? names : @[];
}

static void PONormalize(float *vector) {
    float norm = 0;
    vDSP_svesq(vector, 1, &norm, PODim);
    norm = sqrtf(norm);
    if (norm > 0) vDSP_vsdiv(vector, 1, &norm, vector, 1, PODim);
}

@implementation POPeople

/// The int8 embedding as a unit-length float vector.
static void POVector(NSData *embedding, float *row) {
    vDSP_vflt8(embedding.bytes, 1, row, 1, PODim);
    PONormalize(row);
}

+ (NSArray<POPerson *> *)peopleInItems:(NSArray<POPhotoItem *> *)items previous:(NSArray<POPerson *> *)previous {
    // Every face of every file as a row of unit-length floats.
    NSMutableArray<POPhotoItem *> *owners = [NSMutableArray array];
    NSMutableData *faceIndexData = [NSMutableData data];
    NSMutableData *faceData = [NSMutableData data];
    for (POPhotoItem *item in items) {
        NSArray<NSData *> *itemFaces = item.faces;
        for (NSUInteger index = 0; index < itemFaces.count; index++) {
            NSData *embedding = itemFaces[index];
            if ((NSInteger)embedding.length != POFaceEmbeddingLength) continue;
            float row[PODim];
            POVector(embedding, row);
            [faceData appendBytes:row length:sizeof row];
            [faceIndexData appendBytes:&index length:sizeof index];
            [owners addObject:item];
        }
    }
    NSUInteger faceCount = owners.count;
    if (!faceCount) return @[];
    const float *faces = faceData.bytes;
    const NSUInteger *faceIndexes = faceIndexData.bytes;

    // Pass 1: each face joins the most similar existing group or starts a new one. Groups are represented by
    // the sum of their faces; `centroids` holds the same sums scaled to unit length for comparing.
    NSMutableData *sumData = [NSMutableData data], *centroidData = [NSMutableData data];
    NSMutableData *assignmentData = [NSMutableData dataWithLength:faceCount * sizeof(int)];
    int *assignment = assignmentData.mutableBytes;
    NSMutableData *scoreData = [NSMutableData data];
    int groupCount = 0;
    for (NSUInteger face = 0; face < faceCount; face++) {
        const float *row = faces + face * PODim;
        int best = -1;
        if (groupCount) {
            scoreData.length = groupCount * sizeof(float);
            float *scores = scoreData.mutableBytes;
            vDSP_mmul(centroidData.bytes, 1, row, 1, scores, 1, groupCount, 1, PODim);
            float bestScore = 0;
            vDSP_Length bestIndex = 0;
            vDSP_maxvi(scores, 1, &bestScore, &bestIndex, groupCount);
            if (bestScore >= POJoinSimilarity) best = (int)bestIndex;
        }
        if (best < 0) {
            best = groupCount++;
            [sumData appendBytes:row length:PODim * sizeof(float)];
            [centroidData appendBytes:row length:PODim * sizeof(float)];
        } else {
            float *sum = (float *)sumData.mutableBytes + best * PODim, *centroid = (float *)centroidData.mutableBytes + best * PODim;
            vDSP_vadd(sum, 1, row, 1, sum, 1, PODim);
            memcpy(centroid, sum, PODim * sizeof(float));
            PONormalize(centroid);
        }
        assignment[face] = best;
    }

    // Pass 2: groups with nearly the same average face are one person seen in different conditions. Largest first,
    // each group joins the person whose average face — of everything joined so far — is similar enough. Not a chain of
    // pairs (A like B, B like C…): that joined nearly everybody into one person once most faces were found.
    NSMutableData *sizeData = [NSMutableData dataWithLength:groupCount * sizeof(int)];
    int *groupSizes = sizeData.mutableBytes;
    for (NSUInteger face = 0; face < faceCount; face++) groupSizes[assignment[face]]++;
    NSMutableArray<NSNumber *> *bySize = [NSMutableArray arrayWithCapacity:groupCount];
    for (int g = 0; g < groupCount; g++) [bySize addObject:@(g)];
    [bySize sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        int sizeA = groupSizes[a.intValue], sizeB = groupSizes[b.intValue];
        return sizeA > sizeB ? NSOrderedAscending : sizeA < sizeB ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableData *personSumData = [NSMutableData data], *personCentroidData = [NSMutableData data];
    NSMutableData *personOfData = [NSMutableData dataWithLength:groupCount * sizeof(int)];
    int *personOf = personOfData.mutableBytes;
    int personCount = 0;
    const float *centroids = centroidData.bytes, *sums = sumData.bytes;
    for (NSNumber *number in bySize) {
        int g = number.intValue;
        int best = -1;
        if (personCount) {
            scoreData.length = personCount * sizeof(float);
            float *scores = scoreData.mutableBytes;
            vDSP_mmul(personCentroidData.bytes, 1, centroids + (size_t)g * PODim, 1, scores, 1, personCount, 1, PODim);
            float bestScore = 0;
            vDSP_Length bestIndex = 0;
            vDSP_maxvi(scores, 1, &bestScore, &bestIndex, personCount);
            if (bestScore >= POMergeSimilarity) best = (int)bestIndex;
        }
        if (best < 0) {
            best = personCount++;
            [personSumData appendBytes:sums + (size_t)g * PODim length:PODim * sizeof(float)];
            [personCentroidData appendBytes:centroids + (size_t)g * PODim length:PODim * sizeof(float)];
        } else {
            float *sum = (float *)personSumData.mutableBytes + best * PODim, *centroid = (float *)personCentroidData.mutableBytes + best * PODim;
            vDSP_vadd(sum, 1, sums + (size_t)g * PODim, 1, sum, 1, PODim);
            memcpy(centroid, sum, PODim * sizeof(float));
            PONormalize(centroid);
        }
        personOf[g] = best;
    }

    // Collect the people's faces, in the order of the faces.
    NSMutableArray<NSMutableArray<NSNumber *> *> *members = [NSMutableArray arrayWithCapacity:personCount];
    for (int p = 0; p < personCount; p++) [members addObject:[NSMutableArray array]];
    for (NSUInteger face = 0; face < faceCount; face++) [members[personOf[assignment[face]]] addObject:@(face)];

    NSArray<NSDictionary *> *names = POLoadNames();
    NSMutableDictionary<NSString *, POPerson *> *namedPeople = [NSMutableDictionary dictionary];
    NSMutableArray<POPerson *> *people = [NSMutableArray array];
    for (NSArray<NSNumber *> *list in members) {
        if (!list.count) continue;
        float centroid[PODim] = {0};
        NSMutableOrderedSet<POPhotoItem *> *files = [NSMutableOrderedSet orderedSet];
        NSCountedSet<POPhotoItem *> *facesPerFile = [NSCountedSet set];
        for (NSNumber *face in list) {
            vDSP_vadd(centroid, 1, faces + face.unsignedIntegerValue * PODim, 1, centroid, 1, PODim);
            [files addObject:owners[face.unsignedIntegerValue]];
            [facesPerFile addObject:owners[face.unsignedIntegerValue]];
        }
        // The mean similarity of every two faces of the group, from the length of their sum (the faces are unit length).
        float squared = 0;
        vDSP_svesq(centroid, 1, &squared, PODim);
        double n = list.count, coherence = n > 1 ? (squared - n) / (n * (n - 1)) : 1;
        PONormalize(centroid);

        NSString *name = nil;
        float bestScore = PONameSimilarity;
        for (NSDictionary *entry in names) {
            NSData *face = entry[@"face"];
            if (face.length != sizeof centroid) continue;
            float score = 0;
            vDSP_dotpr(centroid, 1, face.bytes, 1, &score, PODim);
            if (score >= bestScore) { bestScore = score; name = entry[@"name"]; }
        }
        if (!name && (files.count < POMinimumFilesPerPerson || coherence < POMinimumCoherence)) continue;

        // The face nearest to the average one; photos with a single face win.
        NSUInteger bestFace = list.firstObject.unsignedIntegerValue;
        float representativeScore = -FLT_MAX;
        for (NSNumber *face in list) {
            POPhotoItem *owner = owners[face.unsignedIntegerValue];
            float score = 0;
            vDSP_dotpr(centroid, 1, faces + face.unsignedIntegerValue * PODim, 1, &score, PODim);
            if (owner.faces.count == 1) score += 2;
            if (score > representativeScore) { representativeScore = score; bestFace = face.unsignedIntegerValue; }
        }

        POPerson *person = name ? namedPeople[name] : nil;
        if (person) {
            // Two groups carrying the same name: one person.
            NSMutableOrderedSet<POPhotoItem *> *merged = [NSMutableOrderedSet orderedSetWithArray:person.items];
            [merged unionOrderedSet:files];
            person.items = merged.array;
            person.faceCount += list.count;
            for (POPhotoItem *file in facesPerFile) {
                for (NSUInteger i = 0; i < [facesPerFile countForObject:file]; i++) [person.facesPerFile addObject:file];
            }
            continue;
        }
        person = [POPerson new];
        person.named = name != nil;
        person.displayName = name ?: @"";
        person.items = files.array;
        person.faceCount = list.count;
        person.facesPerFile = facesPerFile;
        person.centroid = [NSData dataWithBytes:centroid length:sizeof centroid];
        person.representativeItem = owners[bestFace];
        person.representativeFace = faceIndexes[bestFace];
        if (name) namedPeople[name] = person;
        [people addObject:person];
    }

    [people sortUsingComparator:^NSComparisonResult(POPerson *a, POPerson *b) {
        if (a.isNamed != b.isNamed) return a.isNamed ? NSOrderedAscending : NSOrderedDescending;
        if (a.items.count != b.items.count) return a.items.count > b.items.count ? NSOrderedAscending : NSOrderedDescending;
        return [a.displayName localizedStandardCompare:b.displayName];
    }];
    // While the analysis runs the groups are made again every few seconds and grow: a group that is still the same
    // person keeps the number it had, so the person shown does not turn into someone else.
    NSMapTable<POPerson *, NSNumber *> *kept = [NSMapTable strongToStrongObjectsMapTable];
    NSMutableArray<NSArray *> *pairs = [NSMutableArray array];   // @[score, new person, old person]
    for (POPerson *person in people) {
        if (person.isNamed) continue;
        for (POPerson *old in previous ?: @[]) {
            if (old.isNamed || old.centroid.length != sizeof(float) * PODim || ![old.key hasPrefix:@"#"]) continue;
            float score = 0;
            vDSP_dotpr(person.centroid.bytes, 1, old.centroid.bytes, 1, &score, PODim);
            if (score >= POMergeSimilarity) [pairs addObject:@[@(score), person, old]];
        }
    }
    [pairs sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
    NSHashTable<POPerson *> *taken = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for (NSArray *pair in pairs) {
        POPerson *person = pair[1], *old = pair[2];
        if ([kept objectForKey:person] || [taken containsObject:old]) continue;
        [taken addObject:old];
        [kept setObject:@([old.key substringFromIndex:1].integerValue) forKey:person];
    }
    // Everyone else gets the smallest number not taken, so the numbers stay 1, 2, 3… (handing out ever new ones ran
    // them up to hundreds while the groups were made again and again).
    NSMutableSet<NSNumber *> *used = [NSMutableSet set];
    for (POPerson *person in kept) [used addObject:[kept objectForKey:person]];
    NSUInteger number = 0;
    for (POPerson *person in people) {
        if (person.isNamed) {
            person.key = person.displayName;
        } else {
            NSNumber *own = [kept objectForKey:person];
            if (!own) {
                do number++; while ([used containsObject:@(number)]);
                own = @(number);
            }
            person.key = [NSString stringWithFormat:@"#%@", own];
            person.displayName = [NSString stringWithFormat:POL(@"Человек %lu"), own.unsignedLongValue];
        }
        NSMutableArray<POPhotoItem *> *solo = [NSMutableArray array];
        for (POPhotoItem *file in person.items) {
            // Alone: this person's is the only face, and nobody else shows up — not even without a usable face.
            // Two faces of one group in a photo mean the group mixed up two people, so that photo is not alone either.
            BOOL alone = file.faces.count == 1 && [person.facesPerFile countForObject:file] == 1 &&
                         (!file.peopleCount || file.peopleCount.integerValue <= 1);
            if (alone) [solo addObject:file];
        }
        person.soloItems = [solo sortedArrayUsingComparator:^NSComparisonResult(POPhotoItem *a, POPhotoItem *b) {
            return [a.date compare:b.date];
        }];
        person.facesPerFile = nil;
        person.items = [person.items sortedArrayUsingComparator:^NSComparisonResult(POPhotoItem *a, POPhotoItem *b) {
            return [a.date compare:b.date];
        }];
    }
    return people;
}

+ (NSArray<POPhotoItem *> *)itemsWithFace:(NSData *)embedding inItems:(NSArray<POPhotoItem *> *)items {
    if ((NSInteger)embedding.length != POFaceEmbeddingLength) return @[];
    float query[PODim], row[PODim];
    POVector(embedding, query);
    NSMutableArray<NSArray *> *found = [NSMutableArray array];   // @[score, item]
    for (POPhotoItem *item in items) {
        float best = -FLT_MAX;
        for (NSData *face in item.faces) {
            if ((NSInteger)face.length != POFaceEmbeddingLength) continue;
            POVector(face, row);
            float score = 0;
            vDSP_dotpr(query, 1, row, 1, &score, PODim);
            best = MAX(best, score);
        }
        if (best >= POSearchSimilarity) [found addObject:@[@(best), item]];
    }
    [found sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
    NSMutableArray<POPhotoItem *> *result = [NSMutableArray arrayWithCapacity:found.count];
    for (NSArray *entry in found) [result addObject:entry[1]];
    return result;
}

+ (void)faceThumbnailForPerson:(POPerson *)person completion:(void (^)(NSImage *))completion {
    static NSCache<NSString *, id> *cache;   // path → NSImage, or NSNull when there is no usable face
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        queue = dispatch_queue_create("photo-organizer.face-thumbnails", DISPATCH_QUEUE_SERIAL);
    });
    NSURL *url = person.representativeItem.url;
    if (!url) {
        completion(nil);
        return;
    }
    // The face the person was recognised by, where the analysis found it; files analysed before the places were kept
    // have their largest face found again.
    NSArray<NSArray<NSNumber *> *> *boxes = person.representativeItem.faceBoxes;
    NSArray<NSNumber *> *stored = person.representativeFace < boxes.count ? boxes[person.representativeFace] : nil;
    NSString *cacheKey = stored ? [url.path stringByAppendingFormat:@"#%lu", (unsigned long)person.representativeFace] : url.path;
    id cached = [cache objectForKey:cacheKey];
    if (cached) {
        completion([cached isKindOfClass:NSImage.class] ? cached : nil);
        return;
    }
    dispatch_async(queue, ^{
        NSImage *thumbnail = nil;
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        NSDictionary *options = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                                  (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                                  (id)kCGImageSourceThumbnailMaxPixelSize: @1280};
        CGImageRef image = source ? CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options) : NULL;
        if (source) CFRelease(source);
        if (image) {
            CGRect box = CGRectZero;
            if (stored.count == 4) {
                // Kept from the top left; Vision's boxes (and the code below) count from the bottom left.
                box = CGRectMake(stored[0].doubleValue, 1 - stored[1].doubleValue - stored[3].doubleValue, stored[2].doubleValue, stored[3].doubleValue);
            }
            VNDetectFaceRectanglesRequest *request = [VNDetectFaceRectanglesRequest new];
            VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
            if (CGRectIsEmpty(box) && [handler performRequests:@[request] error:NULL]) {
                for (VNFaceObservation *face in request.results) {   // the largest face, as when the photo was analysed
                    if (face.boundingBox.size.width * face.boundingBox.size.height > box.size.width * box.size.height) box = face.boundingBox;
                }
            }
            if (!CGRectIsEmpty(box)) {
                CGFloat width = CGImageGetWidth(image), height = CGImageGetHeight(image);
                // Vision's box hugs the face from brow to chin; a square 1.6 times larger takes in the whole head.
                CGFloat side = MAX(box.size.width * width, box.size.height * height) * 1.6;
                CGFloat centerX = CGRectGetMidX(box) * width, centerY = (1 - CGRectGetMidY(box)) * height;   // CGImage rows run top-down
                CGRect crop = CGRectIntersection(CGRectMake(centerX - side / 2, centerY - side / 2, side, side), CGRectMake(0, 0, width, height));
                CGImageRef face = CGImageCreateWithImageInRect(image, CGRectIntegral(crop));
                if (face) {
                    thumbnail = [[NSImage alloc] initWithCGImage:face size:NSMakeSize(96, 96)];
                    CGImageRelease(face);
                }
            }
            CGImageRelease(image);
        }
        [cache setObject:thumbnail ?: (id)NSNull.null forKey:cacheKey];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(thumbnail); });
    });
}

+ (void)setName:(NSString *)name forPerson:(POPerson *)person {
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSDictionary *> *names = [NSMutableArray array];
    for (NSDictionary *entry in POLoadNames()) {
        if (person.isNamed && [entry[@"name"] isEqual:person.displayName]) {
            // Renaming keeps every remembered look of the person; an empty name forgets them.
            if (name.length) [names addObject:@{@"name": name, @"face": entry[@"face"]}];
        } else {
            [names addObject:entry];
        }
    }
    if (name.length && !person.isNamed && person.centroid) [names addObject:@{@"name": name, @"face": person.centroid}];
    NSURL *file = PONamesURL();
    [NSFileManager.defaultManager createDirectoryAtURL:file.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    [names writeToURL:file atomically:YES];
}

@end
