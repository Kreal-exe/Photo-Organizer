#import <Cocoa/Cocoa.h>
#import "POCompression.h"

NS_ASSUME_NONNULL_BEGIN

/// "Сжать…": what compressing the chosen files would give before anything is touched, as on Windows. RAW photos become
/// JPEGs of the size most photos of the library have (offered first), HDR kept; videos come down to a chosen height
/// (1080p unless asked otherwise) at a bitrate that loses nothing visible, HDR kept, and only those that weigh too much
/// for what they show are taken. Sizes after are estimated: photos from a trial compression of two of them, videos
/// from their bitrate.
@interface POCompressController : NSViewController

/// `library` is every file of the library: the size most of its photos have is what RAW photos are offered.
- (instancetype)initWithItems:(NSArray<POPhotoItem *> *)items library:(NSArray<POPhotoItem *> *)library;

/// Called after the sheet closes with "Сжать", not when it is cancelled.
@property (nonatomic, copy, nullable) void (^completion)(POCompressController *controller);

/// The RAW photos to compress, when chosen, and to what size.
@property (nonatomic, readonly) NSArray<POPhotoItem *> *photos;
@property (nonatomic, readonly) NSInteger megapixels;
/// The videos worth compressing with what is chosen: each an item, its POVideoInfo and its POVideoJob.
@property (nonatomic, readonly) NSArray<NSArray *> *videos;

@end

NS_ASSUME_NONNULL_END
