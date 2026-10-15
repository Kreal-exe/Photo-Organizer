#import "POKinds.h"
#import "POModel.h"
#import "POStrings.h"
#import <Vision/Vision.h>
#import <CoreML/CoreML.h>
#import <Accelerate/Accelerate.h>

static const NSUInteger PODimension = 512;
/// CLIP's logit scale: similarities × 100 go into the softmax over every description.
static const float POLogitScale = 100;

/// A request's output as a unit-length float16 vector; nil when it has none.
static NSData *POHalfVector(VNCoreMLRequest *request) {
    MLMultiArray *output = ((VNCoreMLFeatureValueObservation *)request.results.firstObject).featureValue.multiArrayValue;
    if (output.count != (NSInteger)PODimension) return nil;
    float vector[PODimension];
    for (NSUInteger i = 0; i < PODimension; i++) vector[i] = output[i].floatValue;
    float norm = 0;
    vDSP_svesq(vector, 1, &norm, PODimension);
    if (norm <= 0) return nil;
    norm = sqrtf(norm);
    vDSP_vsdiv(vector, 1, &norm, vector, 1, PODimension);
    NSMutableData *half = [NSMutableData dataWithLength:PODimension * 2];
    vImage_Buffer source = {vector, 1, PODimension, PODimension * 4}, destination = {half.mutableBytes, 1, PODimension, PODimension * 2};
    vImageConvert_PlanarFtoPlanar16F(&source, &destination, 0);
    return half;
}

@implementation POKindEncoder {
    VNCoreMLModel *_model;
}

+ (instancetype)encoderWithError:(NSError **)error {
    POModel *model = POModel.pictureModel;
    NSURL *compiled = model.isReady ? [model compiledModelURLWithError:error] : nil;
    if (!compiled) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"PhotoOrganizer" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: POL(@"Модель картинок не загружена — «Настройки»")}];
        }
        return nil;
    }
    MLModelConfiguration *configuration = [MLModelConfiguration new];
    configuration.computeUnits = MLComputeUnitsAll;
    MLModel *mlModel = [MLModel modelWithContentsOfURL:compiled configuration:configuration error:error];
    VNCoreMLModel *visionModel = mlModel ? [VNCoreMLModel modelForMLModel:mlModel error:error] : nil;
    if (!visionModel) return nil;
    POKindEncoder *encoder = [POKindEncoder new];
    encoder->_model = visionModel;
    return encoder;
}

- (NSArray<NSData *> *)vectorsForImage:(CGImageRef)image {
    if (!image) return nil;
    // As MobileCLIP was trained (the shorter side scaled to 256, the centre cut out), and the whole image.
    VNCoreMLRequest *centre = [[VNCoreMLRequest alloc] initWithModel:_model];
    centre.imageCropAndScaleOption = VNImageCropAndScaleOptionCenterCrop;
    VNCoreMLRequest *whole = [[VNCoreMLRequest alloc] initWithModel:_model];
    whole.imageCropAndScaleOption = VNImageCropAndScaleOptionScaleFit;
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    if (![handler performRequests:@[centre, whole] error:NULL]) return nil;
    NSData *first = POHalfVector(centre), *second = POHalfVector(whole);
    return first && second ? @[first, second] : nil;
}

@end

/// The descriptions of each kind (photo, picture, collage) from Resources/clip-kinds.bin: "POCK", int32 dimension,
/// int32 group count, then per group an int32 count and count × dimension float32.
static NSArray<NSData *> *PODescriptions(void) {
    static NSArray<NSData *> *groups;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *data = [NSData dataWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"clip-kinds" withExtension:@"bin"]];
        const uint8_t *bytes = data.bytes;
        if (data.length < 12 || memcmp(bytes, "POCK", 4) != 0) return;
        int32_t dimension, count;
        memcpy(&dimension, bytes + 4, 4);
        memcpy(&count, bytes + 8, 4);
        if (dimension != (int32_t)PODimension || count != 3) return;
        NSMutableArray<NSData *> *read = [NSMutableArray array];
        NSUInteger offset = 12;
        for (int32_t group = 0; group < count; group++) {
            int32_t vectors;
            if (offset + 4 > data.length) return;
            memcpy(&vectors, bytes + offset, 4);
            offset += 4;
            NSUInteger size = (NSUInteger)vectors * PODimension * 4;
            if (vectors <= 0 || offset + size > data.length) return;
            [read addObject:[data subdataWithRange:NSMakeRange(offset, size)]];
            offset += size;
        }
        groups = read;
    });
    return groups;
}

/// The share of each kind (photo, picture, collage) for one view: a softmax over every description.
static BOOL POViewScores(NSData *vector, NSArray<NSData *> *groups, float shares[3]) {
    if (vector.length != PODimension * 2) return NO;
    float image[PODimension];
    vImage_Buffer source = {(void *)vector.bytes, 1, PODimension, PODimension * 2}, destination = {image, 1, PODimension, PODimension * 4};
    vImageConvert_Planar16FtoPlanarF(&source, &destination, 0);
    float logits[3][64];
    NSUInteger counts[3];
    float maximum = -FLT_MAX;
    for (NSUInteger group = 0; group < 3; group++) {
        counts[group] = MIN(groups[group].length / (PODimension * 4), 64);
        const float *texts = groups[group].bytes;
        for (NSUInteger i = 0; i < counts[group]; i++) {
            float dot = 0;
            vDSP_dotpr(texts + i * PODimension, 1, image, 1, &dot, PODimension);
            logits[group][i] = POLogitScale * dot;
            maximum = MAX(maximum, logits[group][i]);
        }
    }
    float total = 0;
    for (NSUInteger group = 0; group < 3; group++) {
        shares[group] = 0;
        for (NSUInteger i = 0; i < counts[group]; i++) shares[group] += expf(logits[group][i] - maximum);
        total += shares[group];
    }
    if (total <= 0) return NO;
    for (NSUInteger group = 0; group < 3; group++) shares[group] /= total;
    return YES;
}

BOOL POKindScores(NSArray<NSData *> *vectors, float *picture, float *collage) {
    NSArray<NSData *> *groups = PODescriptions();
    if (groups.count != 3 || !vectors.count) return NO;
    float sumPicture = 0, sumCollage = 0;
    for (NSData *vector in vectors) {
        float shares[3];
        if (!POViewScores(vector, groups, shares)) return NO;
        sumPicture += shares[1];
        sumCollage += shares[2];
    }
    *picture = sumPicture / vectors.count;
    *collage = sumCollage / vectors.count;
    return YES;
}

void POSetKindVectors(POPhotoItem *item, NSArray<NSData *> *vectors) {
    float picture = 0, collage = 0;
    if (POKindScores(vectors, &picture, &collage)) {
        item.pictureScore = @(picture);
        item.collageScore = @(collage);
    } else {
        item.pictureScore = nil;
        item.collageScore = nil;
    }
}
