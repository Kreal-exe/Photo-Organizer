#import "POThumbnailCache.h"
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

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
    [QLThumbnailGenerator.sharedGenerator generateBestRepresentationForRequest:request
                                                             completionHandler:^(QLThumbnailRepresentation *thumbnail, NSError *error) {
        CGImageRef image = thumbnail.CGImage;
        if (image) [cache setObject:(__bridge id)image forKey:key];
        id retained = (__bridge id)image;
        dispatch_async(dispatch_get_main_queue(), ^{ completion((__bridge CGImageRef)retained); });
    }];
    return request;
}

- (void)cancel:(id)token {
    if ([token isKindOfClass:QLThumbnailGenerationRequest.class]) {
        [QLThumbnailGenerator.sharedGenerator cancelRequest:token];
    }
}

@end
