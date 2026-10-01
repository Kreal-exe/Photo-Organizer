#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Actions sent down the responder chain (target nil) by menus, the toolbar and the content views.
/// MainWindowController implements all of them.
@protocol POActions <NSObject>
- (IBAction)openDocument:(nullable id)sender;
- (IBAction)rescan:(nullable id)sender;
- (IBAction)organize:(nullable id)sender;
- (IBAction)cancelScan:(nullable id)sender;
- (IBAction)revealRootInFinder:(nullable id)sender;
/// Sent by the quick-filter strip above the grid; the sender's selectedSegment is a POQuickFilter.
- (IBAction)selectQuickFilter:(nullable id)sender;
/// Opens the selected file (or the first one) in the built-in viewer.
- (IBAction)openSelectedItem:(nullable id)sender;
- (IBAction)closeViewer:(nullable id)sender;
- (IBAction)zoomImageIn:(nullable id)sender;
- (IBAction)zoomImageOut:(nullable id)sender;
- (IBAction)zoomImageToActualSize:(nullable id)sender;
- (IBAction)zoomImageToFit:(nullable id)sender;
/// Act on the files selected in the grid.
- (IBAction)findSimilarToSelection:(nullable id)sender;
- (IBAction)moveSelectionToFolder:(nullable id)sender;
- (IBAction)trashSelection:(nullable id)sender;
/// Moves everything the grid shows (a search result, a person, the flagged files…) into one folder.
- (IBAction)moveShownToFolder:(nullable id)sender;
- (IBAction)showPhotoSearch:(nullable id)sender;
/// Moves every duplicate to the Trash, keeping the original or best-quality file of each set.
- (IBAction)removeDuplicates:(nullable id)sender;
/// Switches people's views between every photo of the person and only those where they are alone.
- (IBAction)toggleSoloPerson:(nullable id)sender;
/// Gives the selected files (or every file shown) a date by hand.
- (IBAction)setDateForSelection:(nullable id)sender;
/// Gives every undated file shown the date of its best suggestion.
- (IBAction)acceptDateSuggestions:(nullable id)sender;
/// Returns from the photos of one place to the map.
- (IBAction)backToMap:(nullable id)sender;
/// Shows the selected file in the library, among the photos of its date.
- (IBAction)showInLibrary:(nullable id)sender;
/// Marks an object on the selected photo and finds the photos where it appears.
- (IBAction)findObjectInSelection:(nullable id)sender;
/// Marks another object on the last example photo.
- (IBAction)pickAnotherObject:(nullable id)sender;
/// Puts the cursor into the search field.
- (IBAction)focusSearch:(nullable id)sender;
@end

NS_ASSUME_NONNULL_END
