#import <Cocoa/Cocoa.h>
#import "POGridViewController.h"
#import "POViewerViewController.h"
#import "POMapViewController.h"

/// The kinds of file, in the order of the strip above the grid (see POMediaKindOfItem): each with a checkbox — ticked,
/// it is in the library and gets organized — and a button that shows that kind alone.
typedef NS_ENUM(NSInteger, POMediaKind) {
    POMediaKindPhotos,
    POMediaKindVideos,
    POMediaKindPictures,   // postcards, memes, drawings, documents (see POIsPicture)
    POMediaKindCollages,   // what Google Photos made: collages, frames, animations, movies, effects
};

/// What the strip shows: "Медиа" — every ticked kind — or one kind alone (POQuickFilterAll + 1 + a POMediaKind).
typedef NS_ENUM(NSInteger, POQuickFilter) {
    POQuickFilterAll,
    POQuickFilterPhotos,
    POQuickFilterVideos,
    POQuickFilterPictures,
    POQuickFilterCollages,
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
/// Same, with a button of this title (Esc) that sends cancelScan: ("Остановить" while copying); nil for none.
- (void)showProgressWithText:(NSString *)text fraction:(double)fraction cancelTitle:(nullable NSString *)cancelTitle;
- (void)showResults;

- (void)setStatusText:(NSString *)text canOrganize:(BOOL)canOrganize;
/// The count of each POMediaKind in what the sidebar shows, which kinds are ticked, and what is shown. A kind with
/// nothing in it is hidden, unless it is shown or unticked.
- (void)setKindCounts:(NSArray<NSNumber *> *)counts included:(NSArray<NSNumber *> *)included selected:(POQuickFilter)selected;
/// Same; "Медиа" adds up the kinds `counted` says (all of them on a type row, which shows every kind) while the
/// checkboxes show `included`.
- (void)setKindCounts:(NSArray<NSNumber *> *)counts included:(NSArray<NSNumber *> *)included counted:(NSArray<NSNumber *> *)counted
             selected:(POQuickFilter)selected;
/// Shows "Задать дату…" and "Принять подсказки…" next to the strip (in the undated list).
- (void)setShowsDateButtons:(BOOL)shows canAcceptSuggestions:(BOOL)canAccept;
/// A general button next to the strip that sends `action` down the responder chain; nil title hides it.
- (void)setExtraButtonTitle:(nullable NSString *)title action:(nullable SEL)action toolTip:(nullable NSString *)toolTip;
/// The clean-up button next to the filter strip ("Удалить дубликаты…"); nil hides it.
- (void)setCleanupButtonTitle:(nullable NSString *)title toolTip:(nullable NSString *)toolTip;
/// "Дубликаты по папкам…" after the clean-up button (in the duplicates view, when there are exact copies).
- (void)setShowsDuplicatesByFolder:(BOOL)shows;
/// The "only this person" checkbox shown while a person is selected; it sends toggleSoloPerson:.
- (void)setSoloCheckboxVisible:(BOOL)visible on:(BOOL)on;
/// Short note right of the filter strip ("Распознавание: 120 из 5 000"); empty hides it.
- (void)setAnalysisStatus:(NSString *)text;
@property (nonatomic, readonly) NSString *analysisStatus;

/// Highlights the window as a drop target while a folder is dragged over it.
- (void)setDropHighlighted:(BOOL)highlighted;

@end

NS_ASSUME_NONNULL_END
