#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// A small browser window in which the user signs in to vk.ru themselves. Once signed in, the app asks VK's
/// web site — inside that same signed-in page — for the access token the site itself uses to read the user's
/// data, and keeps it in the keychain. The app never sees the password; the sign-in is remembered by the
/// browser storage of this window, like in Safari.
@interface POVKLoginWindowController : NSWindowController

@property (class, nonatomic, readonly) POVKLoginWindowController *sharedController;

/// Called on the main queue once a token has been obtained and saved (`userID` may be empty).
@property (nonatomic, copy, nullable) void (^onLogin)(NSString *userID);

/// Forgets the sign-in: the saved token and the window's cookies.
+ (void)signOut;

@end

NS_ASSUME_NONNULL_END
