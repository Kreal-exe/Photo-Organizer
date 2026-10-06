#import "POThumbnailCache.h"
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <ImageIO/ImageIO.h>

/// The picture decoded by the app itself, for when QuickLook gives nothing: an image it has no thumbnail for, or a
/// QuickLook too busy to answer.
static CGImageRef POCreateDecodedThumbnail(NSURL *url, CGFloat pixels) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, (__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCache: @NO});
    if (!source) return NULL;
    NSDictionary *options = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                              (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                              (id)kCGImageSourceThumbnailMaxPixelSize: @(MAX(pixels, 64))};
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    return image;
}

/// What -thumbnailForURL: hands out for -cancel:: a cell scrolled away needs no picture decoded for it.
@interface POThumbnailToken : NSObject
@property (nonatomic, strong) QLThumbnailGenerationRequest *request;
@property (atomic) BOOL cancelled;
@end

@implementation POThumbnailToken
@end

@implementation POThumbnailCache {
    NSCache<NSString *, id> *_cache;
}

+ (POThumbnailCache *)sharedCache {
    static POThumbnailCache *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [POThumbnailCache new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cache = [NSCache new];
        _cache.countLimit = 3000;
    }
    return self;
}

- (id)thumbnailForURL:(NSURL *)url size:(CGFloat)size scale:(CGFloat)scale completion:(void (^)(CGImageRef))completion {
    NSString *key = url.path;
    id cached = [_cache objectForKey:key];
    if (cached) {
        completion((__bridge CGImageRef)cached);
        return nil;
    }
    QLThumbnailGenerationRequest *request =
        [[QLThumbnailGenerationRequest alloc] initWithFileAtURL:url
                                                           size:CGSizeMake(size, size)
                                                          scale:scale
                                            representationTypes:QLThumbnailGenerationRequestRepresentationTypeThumbnail];
    NSCache *cache = _cache;
    POThumbnailToken *token = [POThumbnailToken new];
    token.request = request;
    __block BOOL delivered = NO;
    void (^deliver)(id) = ^(id image) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (delivered) return;
            delivered = YES;
            if (image) [cache setObject:image forKey:key];
            completion((__bridge CGImageRef)image);
        });
    };
    void (^decode)(void) = ^{
        if (token.cancelled) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            CGImageRef image = POCreateDecodedThumbnail(url, size * scale);
            deliver(image ? CFBridgingRelease(image) : nil);
        });
    };
    [QLThumbnailGenerator.sharedGenerator generateBestRepresentationForRequest:request
                                                             completionHandler:^(QLThumbnailRepresentation *thumbnail, NSError *error) {
        CGImageRef image = thumbnail.CGImage;
        if (image) deliver((__bridge id)image);
        else decode();   // no thumbnail from QuickLook: the app decodes the picture itself
    }];
    // QuickLook works in another process, and while the analysis keeps the Mac busy it may take its time: after a
    // few seconds the app decodes the picture itself, whichever comes first is shown.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!delivered) decode();
    });
    return token;
}

- (void)cancel:(id)token {
    if (![token isKindOfClass:POThumbnailToken.class]) return;
    POThumbnailToken *thumbnail = token;
    thumbnail.cancelled = YES;
    [QLThumbnailGenerator.sharedGenerator cancelRequest:thumbnail.request];
}

@end
