#import "PONudityClassifier.h"
#import "POStrings.h"
#import "POMLXImageModel.h"
#import <CoreML/CoreML.h>
#import <Vision/Vision.h>

@interface PONudityClassifier () {
@protected
    POModel *_model;
}
@end

static NSError *POClassifierError(NSString *message) {
    return [NSError errorWithDomain:@"PONudityClassifier" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// Scales `image` into a size×size RGB buffer: squashed to fit, or filling it with the centre kept.
static NSData *PORGBData(CGImageRef image, NSInteger size, BOOL centerCrop) {
    CGFloat width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    if (width <= 0 || height <= 0) return nil;
    CGFloat scaleX = size / width, scaleY = size / height;
    if (centerCrop) scaleX = scaleY = MAX(scaleX, scaleY);
    CGAffineTransform transform = CGAffineTransformMake(scaleX, 0, 0, scaleY, (size - width * scaleX) / 2, (size - height * scaleY) / 2);
    return PORGBDataWithTransform(image, size, transform);
}

#pragma mark - MLX

@interface POMLXNudityClassifier : PONudityClassifier
- (nullable instancetype)initWithModel:(POModel *)model snapshot:(NSURL *)snapshot error:(NSError **)error;
@end

@implementation POMLXNudityClassifier {
    POMLXImageModel *_helper;
}

- (instancetype)initWithModel:(POModel *)model snapshot:(NSURL *)snapshot error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _model = model;
    _helper = [[POMLXImageModel alloc] initWithSnapshotURL:snapshot embedding:NO error:error];
    return _helper ? self : nil;
}

- (NSNumber *)scoreForImage:(CGImageRef)image {
    NSData *pixels = PORGBData(image, _helper.inputSize, _model.centerCrop);
    NSString *reply = pixels ? [_helper replyForRGBData:pixels] : nil;
    return reply ? @(MIN(MAX(reply.doubleValue, 0), 1)) : nil;
}

- (void)invalidate {
    [_helper invalidate];
}

@end

#pragma mark - Core ML

@interface POCoreMLNudityClassifier : PONudityClassifier
- (nullable instancetype)initWithModel:(POModel *)model snapshot:(NSURL *)snapshot error:(NSError **)error;
@end

@implementation POCoreMLNudityClassifier {
    VNCoreMLModel *_visionModel;
}

- (instancetype)initWithModel:(POModel *)model snapshot:(NSURL *)snapshot error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _model = model;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *packageName = model.files.firstObject.pathComponents.firstObject;

    // Core ML runs a compiled copy. It is compiled once per downloaded revision and kept next to the app's data.
    NSURL *support = [fm URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:NULL];
    NSURL *models = [support URLByAppendingPathComponent:@"Photo Organizer/Models" isDirectory:YES];
    NSString *compiledName = [NSString stringWithFormat:@"%@-%@.mlmodelc", packageName.stringByDeletingPathExtension, snapshot.lastPathComponent];
    NSURL *compiled = [models URLByAppendingPathComponent:compiledName isDirectory:YES];
    if (![fm fileExistsAtPath:compiled.path]) {
        // The cache holds symlinks into blobs/; the compiler wants a plain package, so it gets a real copy.
        NSURL *scratch = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        for (NSString *file in model.files) {
            NSURL *destination = [scratch URLByAppendingPathComponent:file];
            [fm createDirectoryAtURL:destination.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
            NSURL *source = [snapshot URLByAppendingPathComponent:file].URLByResolvingSymlinksInPath;
            if (![fm copyItemAtURL:source toURL:destination error:error]) return nil;
        }
        NSURL *built = [MLModel compileModelAtURL:[scratch URLByAppendingPathComponent:packageName isDirectory:YES] error:error];
        if (!built) return nil;
        [fm createDirectoryAtURL:models withIntermediateDirectories:YES attributes:nil error:NULL];
        BOOL moved = [fm moveItemAtURL:built toURL:compiled error:error];
        [fm removeItemAtURL:scratch error:NULL];
        if (!moved) return nil;
    }

    MLModelConfiguration *configuration = [MLModelConfiguration new];
    configuration.computeUnits = MLComputeUnitsAll;
    MLModel *mlModel = [MLModel modelWithContentsOfURL:compiled configuration:configuration error:error];
    _visionModel = mlModel ? [VNCoreMLModel modelForMLModel:mlModel error:error] : nil;
    return _visionModel ? self : nil;
}

- (NSNumber *)scoreForImage:(CGImageRef)image {
    VNCoreMLRequest *request = [[VNCoreMLRequest alloc] initWithModel:_visionModel];
    request.imageCropAndScaleOption = _model.centerCrop ? VNImageCropAndScaleOptionCenterCrop : VNImageCropAndScaleOptionScaleFill;
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    if (![handler performRequests:@[request] error:NULL]) return nil;
    for (VNClassificationObservation *observation in request.results) {
        if (![observation isKindOfClass:VNClassificationObservation.class]) continue;
        if ([observation.identifier caseInsensitiveCompare:@"NSFW"] == NSOrderedSame) return @(observation.confidence);
    }
    return nil;
}

- (void)invalidate {
    _visionModel = nil;
}

@end

#pragma mark - Factory

@implementation PONudityClassifier

+ (instancetype)classifierWithModel:(POModel *)model error:(NSError **)error {
    NSURL *snapshot = model.snapshotURL;
    if (!model.isSupported || !snapshot) {
        if (error) *error = POClassifierError(POL(@"Модель не загружена — откройте «Настройки» и нажмите «Загрузить»."));
        return nil;
    }
    if (model.backend == POModelBackendMLX) return [[POMLXNudityClassifier alloc] initWithModel:model snapshot:snapshot error:error];
    return [[POCoreMLNudityClassifier alloc] initWithModel:model snapshot:snapshot error:error];
}

- (POModel *)model { return _model; }
- (NSNumber *)scoreForImage:(CGImageRef)image { return nil; }
- (void)invalidate {}

@end
