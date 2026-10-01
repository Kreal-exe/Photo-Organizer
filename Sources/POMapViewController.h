#import <Cocoa/Cocoa.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN

/// The files that know where they were taken, as markers on a map; nearby ones merge into one marker with a
/// count. Clicking a marker hands its files over, to be shown in the grid.
@interface POMapViewController : NSViewController

- (void)setItems:(NSArray<POPhotoItem *> *)items;

@property (nonatomic, copy, nullable) void (^onSelectItems)(NSArray<POPhotoItem *> *items);

@end

NS_ASSUME_NONNULL_END
