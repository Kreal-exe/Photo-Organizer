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

/// Same; `decodes` NO never reads the file itself when QuickLook has no thumbnail — for a file whose contents are in
/// iCloud only, which reading would download.
- (nullable id)thumbnailForURL:(NSURL *)url
                          size:(CGFloat)size
                         scale:(CGFloat)scale
                       decodes:(BOOL)decodes
                    completion:(void (^)(CGImageRef _Nullable image))completion;

/// Forgets the thumbnails of files that were moved or went to the Trash: another file may come to stand at the path.
- (void)forgetURLs:(NSArray<NSURL *> *)urls;

@end

NS_ASSUME_NONNULL_END
