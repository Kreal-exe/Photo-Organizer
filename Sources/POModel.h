#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, POModelBackend) {
    POModelBackendMLX,      // weights run by Apple's MLX in a private Python environment; Apple Silicon only
    POModelBackendCoreML,   // run by Core ML inside the app; works on Intel too
};

/// One entry of the built-in catalogue of downloadable models hosted on Hugging Face: the nudity classifiers
/// (`allModels`) and the face-embedding model.
@interface POModel : NSObject

@property (class, nonatomic, readonly) NSArray<POModel *> *allModels;
/// The best fit for this Mac: an MLX model on Apple Silicon, the Core ML one on Intel.
@property (class, nonatomic, readonly) POModel *recommendedModel;
/// The model chosen in the settings, or the recommended one.
@property (class, nonatomic, readonly) POModel *selectedModel;
/// The face-embedding model used to group photos by person (not part of `allModels`).
@property (class, nonatomic, readonly) POModel *faceModel;
+ (nullable POModel *)modelWithIdentifier:(nullable NSString *)identifier;

/// Hugging Face repo id, e.g. "Marqo/nsfw-image-detection-384".
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSString *summary;
@property (nonatomic, readonly, copy) NSString *license;
@property (nonatomic, readonly) POModelBackend backend;
/// Files of the repo that are needed (the rest — optimizer states, ONNX exports — is not downloaded).
@property (nonatomic, readonly, copy) NSArray<NSString *> *files;
@property (nonatomic, readonly) long long byteSize;
/// Side of the square input, in pixels.
@property (nonatomic, readonly) NSInteger inputSize;
/// YES: scale to fill and crop the centre; NO: squash the whole picture into the square.
@property (nonatomic, readonly) BOOL centerCrop;

/// NO for MLX models on Intel Macs.
@property (nonatomic, readonly, getter=isSupported) BOOL supported;
/// Folder of the downloaded files in the Hugging Face cache, or nil.
@property (nonatomic, readonly, nullable) NSURL *snapshotURL;
/// Downloaded, and (for MLX) the runtime is installed.
@property (nonatomic, readonly, getter=isReady) BOOL ready;

@end

NS_ASSUME_NONNULL_END
