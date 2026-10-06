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

/// What the library is organized by: the date (2024/…), or a first level of folders by type, person or format.
typedef NS_ENUM(NSInteger, POArrangement) {
    POArrangementDate,
    POArrangementType,     // Скриншоты/, Видео/, WhatsApp/, Фото/… (see POMediaTypes)
    POArrangementPerson,   // a folder per named person; the rest by date
    POArrangementFormat,   // JPEG/, HEIC/, MOV/…
};

/// How "Разложить…" of a section (screenshots, a person…) arranges its files inside the section's folder.
typedef NS_ENUM(NSInteger, POFolderLayout) {
    POFolderLayoutFlat,          // all files together
    POFolderLayoutYear,          // Скриншоты/2024/
    POFolderLayoutYearMonth,     // Скриншоты/2024/2024-03/
    POFolderLayoutYearMonthDay,  // Скриншоты/2024/2024-03/2024-03-15/
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
@property (class, nonatomic, readonly) NSString *defaultScreenshotsFolderName;
@property (class, nonatomic, readonly) NSString *undatedFolderName;
/// The duplicates folder name currently stored in the user defaults (needed before a plan exists).
@property (class, nonatomic, readonly) NSString *savedDuplicatesFolderName;

/// Cleans up a user-typed folder path: trims, drops empty / "." / ".." components and characters Finder can't show.
/// Returns nil when nothing usable is left.
+ (nullable NSString *)sanitizedFolderPath:(NSString *)path;

/// The folder everything is organized into: the library's first folder, or another one (-setDestinationURL:).
@property (nonatomic, readonly) NSURL *rootURL;
/// The library's folders (several when more than one was opened); by default just rootURL.
@property (nonatomic, copy) NSArray<NSURL *> *sourceURLs;
/// Organizes into another folder than the first one of the library: files from all the library's folders are moved
/// there. Call -rebuild afterwards.
- (void)setDestinationURL:(NSURL *)url;
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
/// Duplicates — exact copies and lesser versions of a picture, not thumbnails — go to the Trash when the files are
/// moved (when copied, they are not copied): only one file of each picture, the original or the best version, is
/// organized. Only a copy whose original stays is removed.
@property (nonatomic) BOOL removesDuplicates;
/// What -rebuild found to go to the Trash with removesDuplicates (empty when the files are copied).
@property (nonatomic, readonly) NSArray<POPhotoItem *> *duplicatesToRemove;
@property (nonatomic) BOOL separateTiny;
/// Copies the files into the folders instead of moving them; the originals stay where they are.
@property (nonatomic) BOOL copiesFiles;
/// Setting an unusable name restores the default one.
@property (nonatomic, copy) NSString *duplicatesFolderName;
@property (nonatomic, copy) NSString *tinyFolderName;
@property (nonatomic) POArrangement arrangement;
/// By type, person or format: date folders inside each of those folders (by the options above), or not.
@property (nonatomic) BOOL datesInside;
/// Which files are organized: photos, videos, pictures (postcards, memes, drawings… see POIsPicture) and collages
/// (what Google Photos made, see POIsGooglePhotosCreation). The kinds turned off stay where they are — e.g. only the
/// real photos go into the year folders, with or without the videos, or only the videos.
@property (nonatomic) BOOL organizesPhotos;
/// The same, as remembered, by POMediaKind (photos, videos, pictures, collages): the strip above the library ticks
/// and unticks these, so organizing takes what the library shows.
+ (BOOL)organizesKind:(NSInteger)kind;
+ (void)setOrganizes:(BOOL)organizes kind:(NSInteger)kind;
@property (nonatomic) BOOL organizesVideos;
@property (nonatomic) BOOL organizesPictures;
@property (nonatomic) BOOL organizesCollages;
/// Screenshots to a folder of their own, whatever the rest is organized by: one folder at the top with the date
/// folders inside (Скриншоты/2024/…), or, with screenshotsInEachDate, one inside every date folder (2024/Скриншоты/…).
@property (nonatomic) BOOL separateScreenshots;
@property (nonatomic) BOOL screenshotsInEachDate;
@property (nonatomic, copy) NSString *screenshotsFolderName;
/// For organizing by person: the files in which exactly one named person was recognised, and that person's name.
/// Set by the window from the people found; files not in it are organized by date.
@property (nonatomic, strong, nullable) NSMapTable<POPhotoItem *, NSString *> *personNames;

/// Top-level folders the user filled by hand ("Скриншоты", a person's name…, see "Разложить…" and "Переместить в
/// папку…"): their files stay where they are when the library is organized by date. Remembered per library.
@property (nonatomic, readonly) NSSet<NSString *> *keptFolders;
- (void)keepFolder:(NSString *)folder;
/// The folder a file goes to inside a section's folder: the folder itself, or its date folders below it (named as
/// the options above say; undated files go to the "Без даты" folder inside).
- (NSString *)folderForItem:(POPhotoItem *)item inFolder:(NSString *)folder layout:(POFolderLayout)layout;

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
