#import <Cocoa/Cocoa.h>
#import "POPlan.h"

NS_ASSUME_NONNULL_BEGIN

/// "Разложить…" of a section (screenshots, a person, an object…): the name of the folder and whether its files lie in
/// it together or in folders by year, month or day; moved into the library, or copied anywhere — another drive with an
/// archive by years of its own, which is filled up. The choices are remembered.
@interface POArrangeController : NSViewController

/// `name` is offered for the folder; `rootURL` is the library's folder (where moves go).
- (instancetype)initWithItemCount:(NSUInteger)count name:(NSString *)name rootURL:(NSURL *)rootURL;

/// Called after the sheet closes with "Разложить", not when it is cancelled.
@property (nonatomic, copy, nullable) void (^completion)(POArrangeController *controller);

/// What was chosen. `folderName` may be empty only when copying into another folder than the library's.
@property (nonatomic, readonly) NSString *folderName;
@property (nonatomic, readonly) POFolderLayout layout;
@property (nonatomic, readonly) BOOL copies;
@property (nonatomic, readonly) BOOL skipsSameContent;
/// The folder the section's folder goes into: the library's when moving.
@property (nonatomic, readonly) NSURL *destinationURL;

@end

NS_ASSUME_NONNULL_END
