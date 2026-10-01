#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Downloads a VK photo album in original size through the VK API (photos.get) with the user's own access token
/// (see POVKLoginWindowController). Files are named by their position in the album:
/// 0001.jpg, 0002.jpg, … Existing files are never overwritten, so an interrupted download can be resumed.
@interface POVKAlbum : NSObject

/// Understands vk.ru / vk.com / m.vk.com links like ".../album123456_000". `album` is what the API wants:
/// "saved", "wall", "profile" for the service albums (ids 000, 00, 0) or the album's number.
+ (BOOL)parseAlbumURL:(NSString *)link owner:(NSString *_Nullable *_Nonnull)owner album:(NSString *_Nullable *_Nonnull)album;

/// The largest version of a photo as returned by photos.get with photo_sizes=1.
+ (nullable NSURL *)originalURLOfPhoto:(NSDictionary *)photo;

/// "0007.png": `index` starts at 1; at least three digits, more when the album needs them.
+ (NSString *)fileNameForIndex:(NSUInteger)index ofCount:(NSUInteger)count url:(NSURL *)url;

- (instancetype)initWithLink:(NSString *)link token:(NSString *)token folder:(NSURL *)folder newestFirst:(BOOL)newestFirst NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Both blocks are called on the main queue. `message` describes the outcome (or the error) for the user.
- (void)startWithProgress:(void (^)(NSUInteger done, NSUInteger total))progress
               completion:(void (^)(BOOL success, NSString *message))completion;
- (void)cancel;

@end

/// The VK access token, kept in the login keychain.
FOUNDATION_EXPORT NSString *_Nullable POVKSavedToken(void);
FOUNDATION_EXPORT void POVKSaveToken(NSString *_Nullable token);

NS_ASSUME_NONNULL_END
