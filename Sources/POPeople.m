#import "POPeople.h"
#import "POStrings.h"
#import "POFaces.h"
#import <Accelerate/Accelerate.h>
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>

/// A face joins a group when its similarity (cosine) to the group's average face is at least this.
static const float POJoinSimilarity = 0.42f;
/// Two groups are the same person when their average faces are at least this similar.
static const float POMergeSimilarity = 0.50f;
/// A stored name applies to a group whose average face is at least this similar to the named one.
static const float PONameSimilarity = 0.45f;
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

+ (NSArray<POPerson *> *)peopleInItems:(NSArray<POPhotoItem *> *)items {
    // Every face of every file as a row of unit-length floats.
    NSMutableArray<POPhotoItem *> *owners = [NSMutableArray array];
    NSMutableData *faceData = [NSMutableData data];
    for (POPhotoItem *item in items) {
        for (NSData *embedding in item.faces) {
            if ((NSInteger)embedding.length != POFaceEmbeddingLength) continue;
            float row[PODim];
            vDSP_vflt8(embedding.bytes, 1, row, 1, PODim);
            PONormalize(row);
            [faceData appendBytes:row length:sizeof row];
            [owners addObject:item];
        }
    }
    NSUInteger faceCount = owners.count;
    if (!faceCount) return @[];
    const float *faces = faceData.bytes;

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

    // Pass 2: groups that ended up with nearly the same average face are one person seen in different
    // conditions. Union-find over all pairs above the merge threshold.
    NSMutableData *parentData = [NSMutableData dataWithLength:groupCount * sizeof(int)];
    int *parent = parentData.mutableBytes;
    for (int i = 0; i < groupCount; i++) parent[i] = i;
    int (^find)(int) = ^int(int i) {
        while (parent[i] != i) { parent[i] = parent[parent[i]]; i = parent[i]; }
        return i;
    };
    const float *centroids = centroidData.bytes;
    scoreData.length = groupCount * sizeof(float);
    for (int i = 0; i < groupCount; i++) {
        float *scores = scoreData.mutableBytes;
        vDSP_mmul(centroids, 1, centroids + (size_t)i * PODim, 1, scores, 1, groupCount, 1, PODim);
        for (int j = i + 1; j < groupCount; j++) {
            if (scores[j] >= POMergeSimilarity) parent[find(j)] = find(i);
        }
    }

    // Collect the merged groups.
    NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *members = [NSMutableDictionary dictionary];
    for (NSUInteger face = 0; face < faceCount; face++) {
        NSNumber *root = @(find(assignment[face]));
        NSMutableArray *list = members[root];
        if (!list) members[root] = list = [NSMutableArray array];
        [list addObject:@(face)];
    }

    NSArray<NSDictionary *> *names = POLoadNames();
    NSMutableDictionary<NSString *, POPerson *> *namedPeople = [NSMutableDictionary dictionary];
    NSMutableArray<POPerson *> *people = [NSMutableArray array];
    for (NSArray<NSNumber *> *list in members.allValues) {
        float centroid[PODim] = {0};
        NSMutableOrderedSet<POPhotoItem *> *files = [NSMutableOrderedSet orderedSet];
        NSCountedSet<POPhotoItem *> *facesPerFile = [NSCountedSet set];
        for (NSNumber *face in list) {
            vDSP_vadd(centroid, 1, faces + face.unsignedIntegerValue * PODim, 1, centroid, 1, PODim);
            [files addObject:owners[face.unsignedIntegerValue]];
            [facesPerFile addObject:owners[face.unsignedIntegerValue]];
        }
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
        if (!name && files.count < POMinimumFilesPerPerson) continue;

        // The face nearest to the average one. Photos with a single face win, because the thumbnail is cut
        // from the photo later without knowing which of several faces was this person's.
        POPhotoItem *representative = nil;
        float representativeScore = -FLT_MAX;
        for (NSNumber *face in list) {
            POPhotoItem *owner = owners[face.unsignedIntegerValue];
            float score = 0;
            vDSP_dotpr(centroid, 1, faces + face.unsignedIntegerValue * PODim, 1, &score, PODim);
            if (owner.faces.count == 1) score += 2;
            if (score > representativeScore) { representativeScore = score; representative = owner; }
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
            if (!person.representativeItem) person.representativeItem = representative;
            continue;
        }
        person = [POPerson new];
        person.named = name != nil;
        person.displayName = name ?: @"";
        person.items = files.array;
        person.faceCount = list.count;
        person.facesPerFile = facesPerFile;
        person.centroid = [NSData dataWithBytes:centroid length:sizeof centroid];
        person.representativeItem = representative;
        if (name) namedPeople[name] = person;
        [people addObject:person];
    }

    [people sortUsingComparator:^NSComparisonResult(POPerson *a, POPerson *b) {
        if (a.isNamed != b.isNamed) return a.isNamed ? NSOrderedAscending : NSOrderedDescending;
        if (a.items.count != b.items.count) return a.items.count > b.items.count ? NSOrderedAscending : NSOrderedDescending;
        return [a.displayName localizedStandardCompare:b.displayName];
    }];
    NSUInteger number = 0;
    for (POPerson *person in people) {
        if (person.isNamed) {
            person.key = person.displayName;
        } else {
            number++;
            person.key = [NSString stringWithFormat:@"#%lu", (unsigned long)number];
            person.displayName = [NSString stringWithFormat:POL(@"Человек %lu"), (unsigned long)number];
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
    id cached = [cache objectForKey:url.path];
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
            VNDetectFaceRectanglesRequest *request = [VNDetectFaceRectanglesRequest new];
            VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
            CGRect box = CGRectZero;
            if ([handler performRequests:@[request] error:NULL]) {
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
        [cache setObject:thumbnail ?: (id)NSNull.null forKey:url.path];
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
