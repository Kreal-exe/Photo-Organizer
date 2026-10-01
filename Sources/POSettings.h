#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main queue after any of the settings below changes.
FOUNDATION_EXPORT NSNotificationName const POSettingsDidChangeNotification;

/// Content-recognition settings, stored in the user defaults.
@interface POSettings : NSObject

/// Recognise objects and scenes with the classifier built into macOS (on by default).
@property (class, nonatomic) BOOL analyzesObjects;
/// Optional: score photos and videos with a downloaded nudity model (off by default).
@property (class, nonatomic) BOOL detectsNudity;
/// Optional: find faces and group photos by person (needs the downloaded face model; off by default).
@property (class, nonatomic) BOOL groupsFaces;
/// Hugging Face repo id of the chosen nudity model; nil picks the recommended one.
@property (class, nonatomic, copy, nullable) NSString *nudityModelIdentifier;
/// Files scoring at or above this (0…1) are listed as explicit.
@property (class, nonatomic) double nudityThreshold;

/// "ru", "en", or nil to follow the system language. Takes effect when the app is reopened.
@property (class, nonatomic, copy, nullable) NSString *language;

/// Posts POSettingsDidChangeNotification; for changes that are not a setting, such as a finished model download.
+ (void)didChange;

@end

NS_ASSUME_NONNULL_END
