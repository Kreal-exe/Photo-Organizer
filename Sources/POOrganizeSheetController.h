#import <Cocoa/Cocoa.h>
#import "POPlan.h"

NS_ASSUME_NONNULL_BEGIN

/// The sheet shown before anything is moved: how to group, how to name the folders, and the resulting
/// folder list, where every folder can be renamed. Edits the plan in place and rebuilds it.
@interface POOrganizeSheetController : NSViewController

- (instancetype)initWithPlan:(POPlan *)plan;

/// Called after every change, once the plan has been rebuilt and its options saved.
@property (nonatomic, copy, nullable) void (^onChange)(void);
/// Called after the sheet has been dismissed.
@property (nonatomic, copy, nullable) void (^completion)(BOOL confirmed);

@end

NS_ASSUME_NONNULL_END
