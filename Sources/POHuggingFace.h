#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Reads and fills the standard Hugging Face hub cache (~/.cache/huggingface/hub, or wherever HF_HUB_CACHE /
/// HF_HOME point), using the same layout as the `huggingface_hub` Python library, so models downloaded here are
/// visible to other tools and vice versa.
@interface POHuggingFace : NSObject

@property (class, nonatomic, readonly) NSURL *cacheURL;

/// Folder of the cached repo ("models--org--name"), whether or not it exists.
+ (NSURL *)repoURLForRepo:(NSString *)repo;

/// The cached snapshot that contains every one of `files`, or nil.
+ (nullable NSURL *)snapshotURLForRepo:(NSString *)repo files:(NSArray<NSString *> *)files;

@end

/// Downloads the given files of a model repo into the cache. One-shot; blocks are called on the main queue.
@interface POHuggingFaceDownload : NSObject

- (instancetype)initWithRepo:(NSString *)repo files:(NSArray<NSString *> *)files NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)startWithProgress:(nullable void (^)(int64_t receivedBytes, int64_t totalBytes))progress
               completion:(void (^)(NSURL *_Nullable snapshotURL, NSError *_Nullable error))completion;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
