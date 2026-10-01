#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// The "search by photo" panel: drop a picture, see how it is described in words, untick the words that don't
/// matter, and search the open folder for files that match the words and look alike.
@interface POPhotoSearchWindowController : NSWindowController

@property (class, nonatomic, readonly) POPhotoSearchWindowController *sharedController;

/// Called with the example and the chosen label identifiers when the user presses the search button.
@property (nonatomic, copy, nullable) void (^onSearch)(CGImageRef image, NSArray<NSString *> *labels);

/// Shown under the button ("Сравниваем: 120 из 800", "Найдено 37").
- (void)setStatus:(NSString *)status busy:(BOOL)busy;

/// Uses a file as the example, as if it had been dropped.
- (void)loadImageAtURL:(NSURL *)url;

/// Same, and searches by every word found as soon as the picture has been described.
- (void)loadImageAtURL:(NSURL *)url searchWhenReady:(BOOL)search;

@end

NS_ASSUME_NONNULL_END
