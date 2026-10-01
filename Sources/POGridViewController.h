#import <Cocoa/Cocoa.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN

@interface POGridSection : NSObject
+ (instancetype)sectionWithTitle:(NSString *)title
                          detail:(NSString *)detail
                      symbolName:(NSString *)symbolName
                           items:(NSArray<POPhotoItem *> *)items;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSString *detail;
@property (nonatomic, readonly, copy) NSString *symbolName;
@property (nonatomic, readonly, copy) NSArray<POPhotoItem *> *items;
/// A button in the section's header ("Подтвердить"); nil for none.
@property (nonatomic, copy, nullable) NSString *actionTitle;
@property (nonatomic, copy, nullable) void (^action)(void);
@end

/// Thumbnail grid grouped into sections with pinned headers. Space opens Quick Look, double-click opens the viewer.
@interface POGridViewController : NSViewController

/// `showsOriginalBadge` marks the kept file of every duplicate set (used when reviewing duplicates).
- (void)setSections:(NSArray<POGridSection *> *)sections showsOriginalBadge:(BOOL)showsOriginalBadge;
/// Same; `keepScroll` leaves the grid where it was scrolled (for a refresh of the same list).
- (void)setSections:(NSArray<POGridSection *> *)sections showsOriginalBadge:(BOOL)showsOriginalBadge keepScroll:(BOOL)keepScroll;

/// Shows the nudity model's score as a badge on every file that has one (used when reviewing flagged files).
@property (nonatomic) BOOL showsNudityScores;

/// Smallest width of a cell, in points; the grid fits as many columns of at least this width as it can.
/// Remembered between launches.
@property (nonatomic) CGFloat cellWidth;

/// Called after files dragged out of the grid (to a Finder folder, say) are no longer where they were.
@property (nonatomic, copy, nullable) void (^onFilesMovedAway)(void);

/// Text shown in the middle of the grid while it has nothing to show ("Перетащите фото сюда"); nil for none.
@property (nonatomic, copy, nullable) NSString *placeholder;
/// When set, the grid accepts an image file dropped onto it (from Finder or another app) and calls this.
@property (nonatomic, copy, nullable) void (^onImageDropped)(NSURL *url);

/// Called when an item is opened; `items` is everything currently in the grid, in display order.
@property (nonatomic, copy, nullable) void (^onOpen)(NSArray<POPhotoItem *> *items, NSUInteger index);

/// YES while the grid itself (not a text field) has the keyboard focus.
@property (nonatomic, readonly) BOOL hasKeyboardFocus;

/// Files selected in the grid, in display order.
@property (nonatomic, readonly) NSArray<POPhotoItem *> *selectedItems;
/// Everything the grid currently shows.
@property (nonatomic, readonly) NSArray<POPhotoItem *> *allItems;

/// Opens the selected item in the viewer, or the first item when nothing is selected.
- (void)openSelectedOrFirstItem;

/// Selects `item` and scrolls it into view.
- (void)revealItem:(POPhotoItem *)item;

@end

NS_ASSUME_NONNULL_END
