#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A browser profile on this Mac that holds a VK sign-in.
@interface POVKBrowserSession : NSObject
@property (nonatomic, readonly) NSString *browserName;          // "Google Chrome"
@property (nonatomic, readonly) NSURL *cookiesFile;
@property (nonatomic, readonly) NSString *keychainService;      // "Chrome Safe Storage"
@end

/// Finds the VK sign-in the user already has in a Chromium-based browser (Chrome, Yandex, Arc, Brave, Edge, Vivaldi,
/// Opera). Only cookies of vk.ru and vk.com are ever read, and they go nowhere but this app's own sign-in window.
@interface POVKBrowserCookies : NSObject

/// The profile used most recently among those signed in to VK. Looks only at cookie names, so the Keychain is not
/// touched and nothing is decrypted; nil when no browser is signed in.
+ (nullable POVKBrowserSession *)mostRecentSession;

/// Asks the Keychain for the browser's key (macOS shows the user its own prompt, so call this off the main queue
/// and only after the user asked for it) and returns the session's VK cookies. Nil with `error` when it fails.
+ (nullable NSArray<NSHTTPCookie *> *)cookiesOfSession:(POVKBrowserSession *)session error:(NSString *_Nullable *_Nullable)error;

/// The VK cookies of a Chromium "Cookies" database, decrypted with the browser's Safe Storage password.
+ (nullable NSArray<NSHTTPCookie *> *)cookiesInFile:(NSURL *)file password:(NSData *)password;

@end

NS_ASSUME_NONNULL_END
