#import <Foundation/Foundation.h>
#import "POPlan.h"

NS_ASSUME_NONNULL_BEGIN

@interface POMoveRecord : NSObject
@property (nonatomic, readonly) NSURL *from;
@property (nonatomic, readonly) NSURL *to;
@property (nonatomic, readonly) unsigned long long fileSize;
@end

/// Everything needed to report on and undo one run of the organizer.
@interface POOrganizeResult : NSObject
@property (nonatomic, readonly, copy) NSArray<POMoveRecord *> *records;
@property (nonatomic, readonly, copy) NSArray<NSURL *> *createdDirectories;
/// Human-readable failures ("IMG_1.jpg: …").
@property (nonatomic, readonly, copy) NSArray<NSString *> *errors;
/// The files were copied: `records` lead from each original to its copy, and the originals did not move.
@property (nonatomic, readonly) BOOL copied;
/// Files whose copy was already in its folder (same name and size), so they were not copied again.
@property (nonatomic, readonly) NSUInteger alreadyCopied;
@end

/// Moves the original files into the folders chosen by a plan — nothing is copied, deleted or overwritten.
///
/// Safety rules:
/// - a file is only touched if it is still the regular file of the size seen by the scan;
/// - the move is an exclusive rename (renamex_np + RENAME_EXCL), so the file's bytes are never rewritten and
///   an existing file can't be replaced even if it appears between the check and the move;
/// - every move is verified afterwards and recorded, so the whole run can be reverted.
///
/// Both methods block and may be called from any queue.
@interface POOrganizer : NSObject

/// Moves the files, or copies them when the plan says so (plan.copiesFiles). A copy is made with the same safety
/// rules: it never replaces a file, keeps the original's dates, is checked by size, and a copy already in place (same
/// name, size and modification date) is not made twice. Folders that already exist at the destination — a drive that
/// already has its 2016, 2017… — are filled up, not duplicated.
+ (POOrganizeResult *)applyPlan:(POPlan *)plan progress:(nullable void (^)(NSUInteger done, NSUInteger total))progress;

/// Moves `items` into `folder` (a path relative to `rootURL`), with the same safety rules. Files already there
/// are left alone.
+ (POOrganizeResult *)moveItems:(NSArray<POPhotoItem *> *)items
                       toFolder:(NSString *)folder
                        rootURL:(NSURL *)rootURL
                       progress:(nullable void (^)(NSUInteger done, NSUInteger total))progress;

/// Moves each item into folderForItem(item), a path relative to `rootURL`, with the same safety rules.
+ (POOrganizeResult *)moveItems:(NSArray<POPhotoItem *> *)items
                        rootURL:(NSURL *)rootURL
                       progress:(nullable void (^)(NSUInteger done, NSUInteger total))progress
                         folder:(NSString *(^)(POPhotoItem *item))folderForItem;

/// Moves every file back to where it was; after a copy, moves the copies to the Trash. Returns failures, empty on success.
+ (NSArray<NSString *> *)revert:(POOrganizeResult *)result;

/// Same; `moves` receives a record for every file put back (from = where it was, to = where it is now).
+ (NSArray<NSString *> *)revert:(POOrganizeResult *)result moves:(NSArray<POMoveRecord *> *_Nullable *_Nullable)moves;

/// Saves the list of moves ("to ← from", one per line) to Application Support, so that a run can still be
/// traced back by hand after the app has quit. Returns the file, or nil when there was nothing to write.
+ (nullable NSURL *)writeJournalForResult:(POOrganizeResult *)result rootURL:(NSURL *)rootURL;

@end

NS_ASSUME_NONNULL_END
