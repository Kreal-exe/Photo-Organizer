#import "POFaces.h"
#import "POStrings.h"
#import "POModel.h"
#import "POMLXImageModel.h"
#import <Vision/Vision.h>

const NSInteger POFaceEmbeddingLength = 512;

/// Faces smaller than this (pixels, shorter side of the box) carry too little detail to tell people apart.
static const CGFloat POMinimumFaceSize = 48;
static const NSUInteger POMaximumFacesPerImage = 12;

static CGPoint POCentroid(VNFaceLandmarkRegion2D *region, CGSize imageSize) {
    const CGPoint *points = [region pointsInImageOfSize:imageSize];
    CGPoint sum = CGPointZero;
    for (NSUInteger i = 0; i < region.pointCount; i++) {
        sum.x += points[i].x;
        sum.y += points[i].y;
    }
    return CGPointMake(sum.x / region.pointCount, sum.y / region.pointCount);
}

/// The transform that puts the face where the ArcFace models expect it in a 112×112 crop: a rotation, uniform
/// scale and shift (least squares over the eyes and the mouth corners). NO when landmarks are missing.
static BOOL POAlignmentForFace(VNFaceObservation *face, CGSize imageSize, CGAffineTransform *transform) {
    VNFaceLandmarks2D *landmarks = face.landmarks;
    if (!landmarks.leftEye.pointCount || !landmarks.rightEye.pointCount || landmarks.outerLips.pointCount < 4) return NO;
    CGPoint eyeA = POCentroid(landmarks.leftEye, imageSize), eyeB = POCentroid(landmarks.rightEye, imageSize);
    const CGPoint *lips = [landmarks.outerLips pointsInImageOfSize:imageSize];
    CGPoint mouthA = lips[0], mouthB = lips[0];
    for (NSUInteger i = 1; i < landmarks.outerLips.pointCount; i++) {
        if (lips[i].x < mouthA.x) mouthA = lips[i];
        if (lips[i].x > mouthB.x) mouthB = lips[i];
    }
    // "Left" below means left in the picture, whichever eye Vision calls left.
    if (eyeA.x > eyeB.x) { CGPoint swap = eyeA; eyeA = eyeB; eyeB = swap; }

    // The standard ArcFace template, with y flipped because image coordinates here grow upwards.
    const CGPoint source[4] = {eyeA, eyeB, mouthA, mouthB};
    const CGPoint target[4] = {{38.2946, 112 - 51.6963}, {73.5318, 112 - 51.5014}, {41.5493, 112 - 92.3655}, {70.7299, 112 - 92.2041}};
    CGPoint sourceMean = CGPointZero, targetMean = CGPointZero;
    for (int i = 0; i < 4; i++) {
        sourceMean.x += source[i].x / 4; sourceMean.y += source[i].y / 4;
        targetMean.x += target[i].x / 4; targetMean.y += target[i].y / 4;
    }
    double dot = 0, cross = 0, norm = 0;
    for (int i = 0; i < 4; i++) {
        double px = source[i].x - sourceMean.x, py = source[i].y - sourceMean.y;
        double qx = target[i].x - targetMean.x, qy = target[i].y - targetMean.y;
        dot += px * qx + py * qy;
        cross += px * qy - py * qx;
        norm += px * px + py * py;
    }
    if (norm < 1) return NO;
    double a = dot / norm, b = cross / norm;
    *transform = CGAffineTransformMake(a, b, -b, a,
                                       targetMean.x - (a * sourceMean.x - b * sourceMean.y),
                                       targetMean.y - (b * sourceMean.x + a * sourceMean.y));
    return YES;
}

@implementation POFaceEmbedder {
    POMLXImageModel *_helper;
}

+ (instancetype)embedderWithError:(NSError **)error {
    NSURL *snapshot = POModel.faceModel.snapshotURL;
    if (!snapshot) {
        if (error) *error = [NSError errorWithDomain:@"POFaces" code:1 userInfo:@{NSLocalizedDescriptionKey: POL(@"Модель лиц не загружена — откройте «Настройки».")}];
        return nil;
    }
    POFaceEmbedder *embedder = [POFaceEmbedder new];
    embedder->_helper = [[POMLXImageModel alloc] initWithSnapshotURL:snapshot embedding:YES error:error];
    return embedder->_helper ? embedder : nil;
}

/// Human figures sure enough to count as someone else in the photo.
static NSInteger POHumanCount(VNDetectHumanRectanglesRequest *request) {
    NSInteger count = 0;
    for (VNHumanObservation *human in request.results) {
        if (human.confidence >= 0.5) count++;
    }
    return count;
}

+ (NSInteger)peopleCountInImage:(CGImageRef)image {
    VNDetectFaceRectanglesRequest *faces = [VNDetectFaceRectanglesRequest new];
    VNDetectHumanRectanglesRequest *humans = [VNDetectHumanRectanglesRequest new];
    humans.upperBodyOnly = NO;
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    if (![handler performRequests:@[faces, humans] error:NULL]) return 0;
    return MAX((NSInteger)faces.results.count, POHumanCount(humans));
}

- (NSArray<NSData *> *)embeddingsForFacesInImage:(CGImageRef)image peopleCount:(NSInteger *)peopleCount {
    CGSize size = CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image));
    VNDetectFaceLandmarksRequest *request = [VNDetectFaceLandmarksRequest new];
    VNDetectHumanRectanglesRequest *humans = [VNDetectHumanRectanglesRequest new];
    humans.upperBodyOnly = NO;
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    if (![handler performRequests:@[request, humans] error:NULL]) return @[];
    if (peopleCount) *peopleCount = MAX((NSInteger)request.results.count, POHumanCount(humans));

    NSArray<VNFaceObservation *> *faces = [request.results sortedArrayUsingComparator:^NSComparisonResult(VNFaceObservation *a, VNFaceObservation *b) {
        CGFloat areaA = a.boundingBox.size.width * a.boundingBox.size.height, areaB = b.boundingBox.size.width * b.boundingBox.size.height;
        return areaA > areaB ? NSOrderedAscending : (areaA < areaB ? NSOrderedDescending : NSOrderedSame);
    }];
    NSMutableArray<NSData *> *embeddings = [NSMutableArray array];
    for (VNFaceObservation *face in faces) {
        if (embeddings.count >= POMaximumFacesPerImage) break;
        if (MIN(face.boundingBox.size.width * size.width, face.boundingBox.size.height * size.height) < POMinimumFaceSize) continue;
        CGAffineTransform transform;
        if (!POAlignmentForFace(face, size, &transform)) continue;
        NSData *pixels = PORGBDataWithTransform(image, _helper.inputSize, transform);
        NSString *reply = pixels ? [_helper replyForRGBData:pixels] : nil;
        NSArray<NSString *> *values = [reply componentsSeparatedByString:@","];
        if ((NSInteger)values.count != POFaceEmbeddingLength) continue;
        NSMutableData *embedding = [NSMutableData dataWithLength:POFaceEmbeddingLength];
        int8_t *bytes = embedding.mutableBytes;
        for (NSInteger i = 0; i < POFaceEmbeddingLength; i++) bytes[i] = (int8_t)MIN(MAX(values[i].intValue, -127), 127);
        [embeddings addObject:embedding];
    }
    return embeddings;
}

- (void)invalidate {
    [_helper invalidate];
}

@end
