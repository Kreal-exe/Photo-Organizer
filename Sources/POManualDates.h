#import <Foundation/Foundation.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN

/// Dates the user gave files by hand. They are kept by the app (Application Support/Photo Organizer/dates.plist),
/// not written into the files, and follow a file when it is moved or renamed on the same disk.
@interface POManualDates : NSObject

/// Gives every file that has a remembered date that date (source PODateSourceManual).
+ (void)applyToItems:(NSArray<POPhotoItem *> *)items;

/// Remembers `date` for the files and applies it to them; nil forgets the dates (the files are then undated
/// until the next scan finds something better).
+ (void)setDate:(nullable NSDate *)date precision:(PODatePrecision)precision forItems:(NSArray<POPhotoItem *> *)items;

/// Where the dates are stored; tests point it elsewhere.
@property (class, nonatomic, copy) NSURL *storeURL;

@end

NS_ASSUME_NONNULL_END
