#import <Cocoa/Cocoa.h>
#import "POPlan.h"
#import "POPeople.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, POFilterKind) {
    POFilterKindAll,
    POFilterKindYear,         // one year; `folder` holds it ("2019")
    POFilterKindUndated,      // files without a date and without a suggestion
    POFilterKindSuggested,    // files without a date, grouped by the rule that suggests one
    POFilterKindDuplicates,   // duplicate sets, originals included
    POFilterKindTiny,
    POFilterKindNudity,       // files the optional nudity model flagged
    POFilterKindPerson,       // files with one person; `folder` holds the person's key
    POFilterKindSimilar,      // results of the last search by photo
    POFilterKindObject,       // a saved object filter; `folder` holds its search words
    POFilterKindObjectSearch, // what the search field finds, on its own page
    POFilterKindMap,          // the files that know where they were taken, on a map
    POFilterKindScreenshots,  // screenshots, told by name, folder and screen size (see POScreenshots)
    POFilterKindVideos,
    POFilterKindType,         // one of the other types (see POTypeFolder); `folder` holds its name
};

/// What the grid should show; identifies a sidebar row across plan rebuilds.
@interface POFilter : NSObject
+ (instancetype)filterWithKind:(POFilterKind)kind folder:(nullable NSString *)folder;
@property (nonatomic, readonly) POFilterKind kind;
@property (nonatomic, readonly, copy, nullable) NSString *folder;
@end

@class POSidebarViewController;

@protocol POSidebarDelegate <NSObject>
- (void)sidebar:(POSidebarViewController *)sidebar didSelectFilter:(POFilter *)filter;
/// The user asked to name the person (double-click or the row's menu).
- (void)sidebar:(POSidebarViewController *)sidebar renamePerson:(POPerson *)person;
/// "Only photos with them alone" was chosen in a person's menu.
- (void)sidebar:(POSidebarViewController *)sidebar showOnlyPersonAlone:(POPerson *)person;
/// The "+" of the Objects section was pressed; `view` is the button, for anchoring a menu.
- (void)sidebar:(POSidebarViewController *)sidebar addObjectFilterFromView:(NSView *)view;
- (void)sidebar:(POSidebarViewController *)sidebar removeObjectFilter:(NSString *)query;
@end

/// Source list: the library by year, people, saved object filters, the search by photo and the "to check" lists.
@interface POSidebarViewController : NSViewController

@property (nonatomic, weak) id<POSidebarDelegate> delegate;
@property (nonatomic, readonly) POFilter *selectedFilter;

/// Rebuilds the rows. Keeps `filter` selected when it still exists, otherwise falls back to "all photos".
/// Does not call the delegate.
- (void)setPlan:(nullable POPlan *)plan selecting:(nullable POFilter *)filter;

/// Number of files without a date and without any suggestion.
@property (nonatomic) NSInteger undatedCount;
/// Number of files without a date for which a date is suggested; 0 hides the row.
@property (nonatomic) NSInteger suggestedCount;
/// Number of files that know where they were taken.
@property (nonatomic) NSInteger locatedCount;
/// Numbers counted among the ticked kinds of file (see the strip above the grid): the library, its duplicates and
/// thumbnails, and each person's photos (nil: all of them).
@property (nonatomic) NSInteger libraryCount;
@property (nonatomic) NSInteger duplicateCount;
@property (nonatomic) NSInteger tinyCount;
@property (nonatomic, copy, nullable) NSInteger (^personCount)(POPerson *person);
/// Numbers of screenshots and of videos, for the Types section.
@property (nonatomic) NSInteger screenshotCount;
@property (nonatomic) NSInteger videoCount;
/// The other types found — screen recordings, messengers, animations, panoramas, RAW, pictures, collages… — as
/// @{@"name": NSString, @"count": NSNumber}, in display order; types with nothing in them are left out.
@property (nonatomic, copy) NSArray<NSDictionary *> *typeCounts;

/// Number of files flagged by the nudity model; a negative value hides the row (the feature is off).
/// Takes effect with the next -setPlan:selecting:.
@property (nonatomic) NSInteger nudityCount;

/// People found by face grouping; empty hides the section. Takes effect with the next -setPlan:selecting:.
@property (nonatomic, copy) NSArray<POPerson *> *people;
/// Saved object filters as @{@"query": NSString, @"count": NSNumber}. Takes effect with the next -setPlan:selecting:.
@property (nonatomic, copy) NSArray<NSDictionary *> *objectFilters;
/// Number of results of the search by photo; negative when there has been no search yet (the row stays). Takes effect with the next -setPlan:selecting:.
@property (nonatomic) NSInteger similarCount;

/// Size of the rows, icons and faces: 1 is the standard sidebar, up to 3. Remembered between launches.
@property (nonatomic) CGFloat scale;

/// Resized / recompressed copies, counted together with the exact duplicates. Takes effect with the next -setPlan:selecting:.
@property (nonatomic) NSInteger similarCopyCount;

/// Selects the row for `filter` without calling the delegate.
- (void)selectFilter:(POFilter *)filter;

@end

NS_ASSUME_NONNULL_END
