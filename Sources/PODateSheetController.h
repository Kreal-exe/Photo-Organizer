#import <Cocoa/Cocoa.h>
#import "PODateSuggestions.h"

NS_ASSUME_NONNULL_BEGIN

/// Sheet for giving files a date by hand: one of the suggestions, or a year / month / day picked by the user.
@interface PODateSheetController : NSViewController

- (instancetype)initWithItemCount:(NSUInteger)count
                      suggestions:(NSArray<PODateSuggestion *> *)suggestions
                      initialDate:(nullable NSDate *)date
                        canRemove:(BOOL)canRemove;

/// Called after the sheet closes, unless it was cancelled. `remove` asks to forget hand-given dates.
@property (nonatomic, copy, nullable) void (^completion)(NSDate *date, PODatePrecision precision, BOOL remove);

@end

NS_ASSUME_NONNULL_END
