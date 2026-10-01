#import <Foundation/Foundation.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, POScheme) {
    POSchemeYear,           // 2024/
    POSchemeYearMonth,      // 2024/2024-03/
    POSchemeYearMonthDay,   // 2024/2024-03/2024-03-15/
};

typedef NS_ENUM(NSInteger, POYearStyle) {
    POYearStyleNumber,      // 2024
    POYearStyleWord,        // 2024 год
};

typedef NS_ENUM(NSInteger, POMonthStyle) {
    POMonthStyleISO,        // 2024-03
    POMonthStyleISOName,    // 2024-03 Март
    POMonthStyleNumberName, // 03 Март
    POMonthStyleNameYear,   // Март 2024
};

typedef NS_ENUM(NSInteger, PODayStyle) {
    PODayStyleISO,          // 2024-03-15
    PODayStyleNumber,       // 15
    PODayStyleDayMonth,     // 15 марта
};

typedef NS_ENUM(NSInteger, POGroupKind) {
    POGroupKindDate,
    POGroupKindTiny,
    POGroupKindDuplicates,
    POGroupKindUndated,      // files without a date: never guessed into a year
};

/// One destination folder and the files that will end up in it.
@interface POGroup : NSObject
@property (nonatomic, readonly) POGroupKind kind;
/// Folder path relative to the root, after any custom name was applied.
@property (nonatomic, readonly, copy) NSString *folder;
/// The automatically generated names this folder stands for (several when folders were renamed to the same name).
@property (nonatomic, readonly, copy) NSArray<NSString *> *generatedFolders;
@property (nonatomic, readonly, copy) NSArray<POPhotoItem *> *items;
@end

/// Decides which folder every file goes to. Call -rebuild after changing any option.
@interface POPlan : NSObject

- (instancetype)initWithRootURL:(NSURL *)rootURL items:(NSArray<POPhotoItem *> *)items NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (class, nonatomic, readonly) NSString *defaultDuplicatesFolderName;
@property (class, nonatomic, readonly) NSString *defaultTinyFolderName;
@property (class, nonatomic, readonly) NSString *undatedFolderName;
/// The duplicates folder name currently stored in the user defaults (needed before a plan exists).
@property (class, nonatomic, readonly) NSString *savedDuplicatesFolderName;

/// Cleans up a user-typed folder path: trims, drops empty / "." / ".." components and characters Finder can't show.
/// Returns nil when nothing usable is left.
+ (nullable NSString *)sanitizedFolderPath:(NSString *)path;

@property (nonatomic, readonly) NSURL *rootURL;
@property (nonatomic, readonly, copy) NSArray<POPhotoItem *> *items;
@property (nonatomic, readonly, copy) NSArray<POPhotoItem *> *duplicateItems;
/// Thumbnails: small copies of other photos (see POPhotoItem.tiny).
@property (nonatomic, readonly) NSArray<POPhotoItem *> *tinyItems;

#pragma mark Options

@property (nonatomic) POScheme scheme;
@property (nonatomic) POYearStyle yearStyle;
@property (nonatomic) POMonthStyle monthStyle;
@property (nonatomic) PODayStyle dayStyle;
/// YES: 2024/2024-03/…; NO: only the deepest level, directly in the root.
@property (nonatomic) BOOL nested;
/// When off, duplicates / thumbnails are sorted by date like any other file.
@property (nonatomic) BOOL separateDuplicates;
@property (nonatomic) BOOL separateTiny;
/// Setting an unusable name restores the default one.
@property (nonatomic, copy) NSString *duplicatesFolderName;
@property (nonatomic, copy) NSString *tinyFolderName;

/// Renames one destination folder; nil or an empty name restores the generated one.
- (void)setCustomName:(nullable NSString *)name forGroup:(POGroup *)group;
@property (nonatomic, readonly) BOOL hasCustomNames;
- (void)removeCustomNames;

/// Everything above except custom names is remembered between launches.
- (void)loadOptionsFromDefaults;
- (void)saveOptionsToDefaults;

#pragma mark Result

/// Files that are gone (to the Trash, dragged elsewhere): they leave the plan, and exact-duplicate sets are
/// re-formed from what is left (a remaining copy becomes the original). Call -rebuild afterwards.
- (void)removeItems:(NSArray<POPhotoItem *> *)items;
/// Files the app moved: each item at `from` now lives at `to` (absolute URLs, inside the root). Call -rebuild afterwards.
- (void)itemsMovedFrom:(NSArray<NSURL *> *)from to:(NSArray<NSURL *> *)to;

/// Puts `items` back in date order, after dates have been refined (by copies sharing their date).
- (void)sortItemsByDate;
- (void)rebuild;
/// In chronological order, followed by the thumbnails and duplicates folders.
@property (nonatomic, readonly, copy) NSArray<POGroup *> *groups;
/// Files that are not yet in their destination folder.
@property (nonatomic, readonly, copy) NSArray<POPhotoItem *> *pendingItems;

@end

NS_ASSUME_NONNULL_END
