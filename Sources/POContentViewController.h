#import <Cocoa/Cocoa.h>
#import "POGridViewController.h"
#import "POViewerViewController.h"
#import "POMapViewController.h"

/// Segments of the quick-filter strip above the grid, in display order.
/// The media-type strip above the grid narrows whatever the sidebar shows.
typedef NS_ENUM(NSInteger, POQuickFilter) {
    POQuickFilterAll,
    POQuickFilterPhotos,
    POQuickFilterVideos,
};

NS_ASSUME_NONNULL_BEGIN

/// The area right of the sidebar. Shows one of four states: empty (drop zone), progress, results
/// (grid + bottom bar), or the full-size viewer opened from the grid. Its controls send POActions down the responder chain.
@interface POContentViewController : NSViewController

@property (nonatomic, readonly) POGridViewController *grid;
@property (nonatomic, readonly) POViewerViewController *viewer;
@property (nonatomic, readonly) POMapViewController *map;
/// Shows the map in place of the grid.
@property (nonatomic) BOOL showsMap;
/// The "back to the map" button next to the strip (while photos of one place are shown).
- (void)setShowsBackToMap:(BOOL)shows;
@property (nonatomic, readonly) BOOL showsResults;
@property (nonatomic, readonly) BOOL showsViewer;

- (void)showEmpty;
/// `fraction` < 0 shows an indeterminate bar.
- (void)showProgressWithText:(NSString *)text fraction:(double)fraction cancellable:(BOOL)cancellable;
- (void)showResults;

- (void)setStatusText:(NSString *)text canOrganize:(BOOL)canOrganize;
/// All / photos / videos in what the sidebar shows; segments with nothing in them are disabled.
- (void)setQuickFilterCounts:(NSArray<NSNumber *> *)counts selected:(POQuickFilter)selected;
/// Shows "Задать дату…" and "Принять подсказки…" next to the strip (in the undated list).
- (void)setShowsDateButtons:(BOOL)shows canAcceptSuggestions:(BOOL)canAccept;
/// A general button next to the strip that sends `action` down the responder chain; nil title hides it.
- (void)setExtraButtonTitle:(nullable NSString *)title action:(nullable SEL)action;
/// The clean-up button next to the filter strip ("Удалить дубликаты…"); nil hides it.
- (void)setCleanupButtonTitle:(nullable NSString *)title;
/// The "only this person" checkbox shown while a person is selected; it sends toggleSoloPerson:.
- (void)setSoloCheckboxVisible:(BOOL)visible on:(BOOL)on;
/// Short note right of the filter strip ("Распознавание: 120 из 5 000"); empty hides it.
- (void)setAnalysisStatus:(NSString *)text;

/// Highlights the window as a drop target while a folder is dragged over it.
- (void)setDropHighlighted:(BOOL)highlighted;

@end

NS_ASSUME_NONNULL_END
