#import <Cocoa/Cocoa.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN

/// "Дубликаты по папкам…": exact copies grouped by the folders they lie in, so that a photo set copied into several
/// folders is cleaned up as a whole — the folder chosen for each group keeps its files, the copies in the others go to
/// the Trash. (The automatic original of each copy is chosen file by file, by date and path, and so ends up now in one
/// folder, now in another.)
@interface POFolderDuplicatesController : NSViewController

/// `sets`: each the original the app chose first, then its exact copies.
- (instancetype)initWithSets:(NSArray<NSArray<POPhotoItem *> *> *)sets;

/// Called after the sheet closes with "Переместить в Корзину", not when it is cancelled.
@property (nonatomic, copy, nullable) void (^completion)(NSArray<POPhotoItem *> *victims, NSArray<NSURL *> *folders);

/// The files to send to the Trash: in each set one file stays, in the folder chosen for its group — and only while
/// that file is still there with the size the scan saw.
- (NSArray<POPhotoItem *> *)victims;
/// Folders with nothing left in them but the copies going away (and the system's own little files): they go to the
/// Trash whole when the checkbox says so. Never a library folder itself; of folders inside one another only the outer one.
- (NSArray<NSURL *> *)foldersToRemove;

@end

NS_ASSUME_NONNULL_END
