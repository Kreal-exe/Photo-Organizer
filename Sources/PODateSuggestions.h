#import <Foundation/Foundation.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PODateSuggestionKind) {
    PODateSuggestionNeighbors,   // the files next to it in its folder (by name) are from the same day / month / year
    PODateSuggestionFileName,    // a year (or year and month) written in the file name
    PODateSuggestionFolderName,  // a year (or year and month) in the name of a folder it sits in
    PODateSuggestionFileDate,    // the file system's date — often the day the file was copied, so never applied on its own
};

/// A guess at the date of an undated file, for the user to accept or not.
@interface PODateSuggestion : NSObject
@property (nonatomic, readonly) PODateSuggestionKind kind;
@property (nonatomic, readonly) NSDate *date;
@property (nonatomic, readonly) PODatePrecision precision;
/// "из названия папки «Photos from 2019»".
@property (nonatomic, readonly, copy) NSString *reason;
/// "2019" / "май 2019 г." / "12 мая 2019 г.".
@property (nonatomic, readonly, copy) NSString *dateText;
/// Same date at the same precision.
- (BOOL)isSameAs:(PODateSuggestion *)other;
@end

/// Works out suggestions for the undated files of a library. Build once per library; thread-safe to read.
@interface PODateSuggester : NSObject

- (instancetype)initWithItems:(NSArray<POPhotoItem *> *)items NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Best first: neighbours, then the file name, then the folder name, then the file date. Empty for a dated file.
- (NSArray<PODateSuggestion *> *)suggestionsForItem:(POPhotoItem *)item;

/// The suggestion "Accept suggestions" would apply: the first one that is not the file date, or nil.
- (nullable PODateSuggestion *)bestSuggestionForItem:(POPhotoItem *)item;

@end

NS_ASSUME_NONNULL_END
