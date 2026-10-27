#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Actions sent down the responder chain (target nil) by menus, the toolbar and the content views.
/// MainWindowController implements all of them.
@protocol POActions <NSObject>
- (IBAction)openDocument:(nullable id)sender;
- (IBAction)addFolder:(nullable id)sender;
- (IBAction)removeFolder:(nullable id)sender;
- (IBAction)rescan:(nullable id)sender;
- (IBAction)organize:(nullable id)sender;
- (IBAction)cancelScan:(nullable id)sender;
- (IBAction)revealRootInFinder:(nullable id)sender;
/// Sent by the buttons of the strip above the grid; the sender's tag is the POQuickFilter to show.
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
/// "Сжать…": the selected RAW photos and videos (or everything shown when nothing is selected).
- (IBAction)compressSelection:(nullable id)sender;
/// Stops compressing after the file under way.
- (IBAction)stopCompressing:(nullable id)sender;
/// Opens (or closes) the details of the compressing above the bar at the bottom; the sender is the bar.
- (IBAction)toggleCompressionDetails:(nullable id)sender;
/// Where only videos are shown: all of them, or one resolution (the sender's selected tag: 0 all, then 4K, 1440p…).
- (IBAction)chooseVideoResolution:(nullable id)sender;
/// Of a RAW and a JPEG of one shot, which is kept (the sender's selected tag: 0 quality, 1 RAW, 2 JPEG).
- (IBAction)chooseRawPreference:(nullable id)sender;
/// Which copy is kept: the better quality (0) or the compressed one (1); the index is the sender's tag.
- (IBAction)chooseCompressedPreference:(nullable id)sender;
/// Moves everything the grid shows (a search result, a person, the flagged files…) into one folder.
- (IBAction)moveShownToFolder:(nullable id)sender;
- (IBAction)showPhotoSearch:(nullable id)sender;
/// Moves every duplicate to the Trash, keeping the original or best-quality file of each set.
- (IBAction)removeDuplicates:(nullable id)sender;
/// Exact copies cleaned up folder by folder: the folder that stays is chosen for each group of folders.
- (IBAction)removeDuplicatesByFolder:(nullable id)sender;
/// Finds the photos of the person whose face is in the selected photo.
- (IBAction)findPersonInSelection:(nullable id)sender;
/// Sent by the View menu's ⌘1 ⌘2 ⌘3; the sender's tag is the grouping (years, months, days).
- (IBAction)chooseGrouping:(nullable id)sender;
/// Puts the shown files into one folder ("Разложить…"), moved or copied.
- (IBAction)arrangeShown:(nullable id)sender;
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
/// Shows the original of a selected copy or thumbnail — the file it is a copy of, or its larger version — in the library.
- (IBAction)showOriginal:(nullable id)sender;
/// Sent by the checkboxes of the strip; the sender's tag is the POMediaKind to tick or untick.
- (IBAction)toggleKindIncluded:(nullable id)sender;
/// Marks an object on the selected photo and finds the photos where it appears.
- (IBAction)findObjectInSelection:(nullable id)sender;
/// Marks another object on the last example photo.
- (IBAction)pickAnotherObject:(nullable id)sender;
/// Tells that the selected files are pictures (or photos): they move to that kind, and the model learns from them.
- (IBAction)markSelectionAsPicture:(nullable id)sender;
- (IBAction)markSelectionAsPhoto:(nullable id)sender;
/// Puts the cursor into the search field.
- (IBAction)focusSearch:(nullable id)sender;
@end

NS_ASSUME_NONNULL_END
