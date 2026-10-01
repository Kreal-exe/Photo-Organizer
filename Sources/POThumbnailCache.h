#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Asynchronous, cached thumbnails backed by QuickLook (handles HEIC, RAW, PSD… the same way Finder does).
@interface POThumbnailCache : NSObject

@property (class, nonatomic, readonly) POThumbnailCache *sharedCache;

/// Calls `completion` on the main queue — synchronously when the thumbnail is already cached.
/// Returns a token for -cancel:, or nil when nothing was started.
- (nullable id)thumbnailForURL:(NSURL *)url
                          size:(CGFloat)size
                         scale:(CGFloat)scale
                    completion:(void (^)(CGImageRef _Nullable image))completion;

- (void)cancel:(nullable id)token;

@end

NS_ASSUME_NONNULL_END
