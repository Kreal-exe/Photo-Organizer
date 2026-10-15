#import "MainWindowController.h"
#import "POSidebarViewController.h"
#import "POContentViewController.h"
#import "POScanner.h"
#import "POPlan.h"
#import "POOrganizer.h"
#import "POStrings.h"
#import "POOrganizeSheetController.h"
#import "POAnalyzer.h"
#import "POLabels.h"
#import "POSettings.h"
#import "POModel.h"
#import "POPeople.h"
#import "POSimilarCopies.h"
#import "POSimilaritySearch.h"
#import "POMediaTypes.h"
#import "POPictures.h"
#import "POScreenshots.h"
#import "POPhotoSearchWindowController.h"
#import "POManualDates.h"
#import "PODateSuggestions.h"
#import "PODateSheetController.h"
#import "POObjectIndex.h"
#import "POObjectPickerController.h"
#import "POFolderDuplicatesController.h"
#import "POArrangeController.h"
#import "POThumbnailCache.h"

static NSToolbarItemIdentifier const POToolbarOpen = @"open";
static NSToolbarItemIdentifier const POToolbarAddFolder = @"addFolder";
static NSToolbarItemIdentifier const POToolbarRescan = @"rescan";
static NSToolbarItemIdentifier const POToolbarReveal = @"reveal";
static NSToolbarItemIdentifier const POToolbarScheme = @"scheme";
static NSToolbarItemIdentifier const POToolbarSearch = @"search";
static NSString *const POSoloPersonKey = @"personAloneOnly";
static NSString *const POGroupingKey = @"gridGrouping";   // 0 years, 1 months, 2 days
static NSString *const POMediaKindKey = @"mediaKind";     // a POQuickFilter

/// Raised by "Остановить" on the progress page; the copying looks at it before each file.
@interface POStopFlag : NSObject
@property (atomic) BOOL stopped;
@end

@implementation POStopFlag
@end

@interface MainWindowController () <NSToolbarDelegate, NSWindowDelegate, NSDraggingDestination, POSidebarDelegate, NSSearchFieldDelegate>
@end

NSString *const POUnfinishedFolderKey = @"POUnfinishedFolder";

static POMediaKind POMediaKindOfItem(POPhotoItem *item);

@implementation MainWindowController {
    NSSplitViewItem *_sidebarItem;
    POSidebarViewController *_sidebar;
    POContentViewController *_content;
    NSToolbarItemGroup *_schemeItem;

    NSURL *_rootURL;                      // the library's first folder
    NSArray<NSURL *> *_rootURLs;          // all of them: several folders can be organized together
    NSURL *_destinationURL;               // where organizing puts everything, when not the first folder
    POScanner *_scanner;      // non-nil while a scan is running
    POPlan *_plan;
    BOOL _organizing;         // files are being moved (or moved back)
    NSUndoManager *_undo;     // the window's; an inert one stands in while files are being moved
    NSString *_lastMessage;   // outcome of the last move, shown while nothing is pending

    NSSearchToolbarItem *_searchItem;
    NSArray<NSString *> *_searchTokens;   // words typed into the search field; empty when not searching
    POAnalyzer *_analyzer;                // non-nil while files are being recognised in the background
    NSArray<POPerson *> *_people;         // groups of faces found in the folder
    NSArray<NSArray<POPhotoItem *> *> *_copySets;   // resized / recompressed copies of one picture, best first
    NSArray<POPhotoItem *> *_similarItems; // results of the last search by photo, most similar first; nil when none
    NSUInteger _similarGeneration;
    PODateSuggester *_suggester;          // date suggestions for the undated files; rebuilt with the dates
    NSArray<POPhotoItem *> *_objectResults;  // photos with the marked object, closest first; nil before a search
    NSURL *_objectExampleURL;               // the photo the object was marked on
    NSString *_objectStatus;                // "Ищем…", or why the results may be incomplete
    NSUInteger _objectGeneration;
    NSString *_lastGridKey;                 // what the grid showed last, to keep its scroll position on a refresh
    NSArray<POPhotoItem *> *_placeItems;  // the files of the map marker that was clicked; nil while the map shows
    NSString *_similarTitle;              // the title of the search results: by photo, or "Этот человек…" by face
    POStopFlag *_copyStop;                // set by "Остановить" while files are being copied; nil otherwise
    NSTimer *_searchTimer;                // the grid follows the search field once typing pauses
    NSTimer *_regroupTimer;               // people are grouped again every few seconds while faces are being found
    BOOL _regrouping, _regroupAgain;
    NSString *_analysisSettings;          // what the running analysis depends on (see -analysisSettings)
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1180, 760)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                                                             NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    if ((self = [super initWithWindow:window])) {
        _sidebar = [POSidebarViewController new];
        _sidebar.delegate = self;
        _content = [POContentViewController new];

        NSSplitViewController *split = [NSSplitViewController new];
        // The sidebar keeps the width it was dragged to, as on Windows.
        split.splitView.autosaveName = @"MainSplit";
        _sidebarItem = [NSSplitViewItem sidebarWithViewController:_sidebar];
        _sidebarItem.minimumThickness = 230;
        _sidebarItem.maximumThickness = 520;
        NSSplitViewItem *contentItem = [NSSplitViewItem splitViewItemWithViewController:_content];
        contentItem.minimumThickness = 620;
        [split addSplitViewItem:_sidebarItem];
        [split addSplitViewItem:contentItem];
        _sidebarItem.collapsed = YES;

        window.title = @"Photo Organizer";
        window.toolbarStyle = NSWindowToolbarStyleUnified;
        window.tabbingMode = NSWindowTabbingModeDisallowed;
        window.contentViewController = split;
        window.minSize = NSMakeSize(860, 520);
        [window setContentSize:NSMakeSize(1180, 760)];
        [window center];
        window.frameAutosaveName = @"MainWindow";
        window.delegate = self;
        // The window forwards NSDraggingDestination messages to its delegate, so a folder can be dropped anywhere.
        [window registerForDraggedTypes:@[NSPasteboardTypeFileURL]];

        NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"MainToolbar"];
        toolbar.delegate = self;
        toolbar.displayMode = NSToolbarDisplayModeIconOnly;
        window.toolbar = toolbar;

        _searchTokens = @[];
        __weak typeof(self) weakSelf = self;
        (void)_content.view;   // the grid exists once the content view is loaded
        _content.map.onSelectItems = ^(NSArray<POPhotoItem *> *items) { [weakSelf showPlaceItems:items]; };
        _content.grid.onFilesMovedAway = ^{
            typeof(self) me = weakSelf;
            if (!me || !me->_plan || me->_scanner || me->_organizing) return;
            NSMutableArray<POPhotoItem *> *gone = [NSMutableArray array];
            for (POPhotoItem *item in me->_plan.items) {
                if (![NSFileManager.defaultManager fileExistsAtPath:item.url.path]) [gone addObject:item];
            }
            if (!gone.count) return;
            // Explorer's and Finder's moves finish after the drop: the files no longer there leave the library.
            me->_lastMessage = [NSString stringWithFormat:POL(@"Перенесено из папки: %@."), POCount(gone.count, POL(@"файл"), POL(@"файла"), POL(@"файлов"))];
            [me applyRemovedItems:gone moves:@[]];
        };
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsDidChange:)
                                                   name:POSettingsDidChangeNotification object:nil];
        [self updateUI];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - Toolbar

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[NSToolbarToggleSidebarItemIdentifier, NSToolbarSidebarTrackingSeparatorItemIdentifier,
             POToolbarOpen, POToolbarAddFolder, POToolbarRescan, POToolbarReveal, NSToolbarFlexibleSpaceItemIdentifier, POToolbarScheme, POToolbarSearch];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return [self toolbarDefaultItemIdentifiers:toolbar];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)identifier willBeInsertedIntoToolbar:(BOOL)flag {
    if ([identifier isEqualToString:POToolbarScheme]) {
        _schemeItem = [NSToolbarItemGroup groupWithItemIdentifier:identifier
                                                           titles:@[POL(@"По годам"), POL(@"По месяцам"), POL(@"По дням")]
                                                    selectionMode:NSToolbarItemGroupSelectionModeSelectOne
                                                           labels:@[POL(@"По годам"), POL(@"По месяцам"), POL(@"По дням")]
                                                           target:self
                                                           action:@selector(groupingChanged:)];
        _schemeItem.label = POL(@"Группировка");
        _schemeItem.toolTip = POL(@"Как делить фото на разделы в окне: по годам, месяцам или дням. На раскладку файлов по папкам не влияет.");
        _schemeItem.selectedIndex = [self grouping];
        _schemeItem.enabled = _plan != nil;
        return _schemeItem;
    }

    if ([identifier isEqualToString:POToolbarSearch]) {
        _searchItem = [[NSSearchToolbarItem alloc] initWithItemIdentifier:identifier];
        _searchItem.label = POL(@"Поиск");
        _searchItem.toolTip = POL(@"Поиск по тому, что на снимке, и по имени файла: «море», «собака», «документ»");
        _searchItem.searchField.placeholderString = POL(@"Что на снимке или имя файла");
        _searchItem.searchField.delegate = self;
        _searchItem.searchField.sendsSearchStringImmediately = YES;
        _searchItem.searchField.target = self;
        _searchItem.searchField.action = @selector(searchChanged:);
        return _searchItem;
    }

    NSDictionary<NSToolbarItemIdentifier, NSArray *> *specs = @{
        POToolbarOpen: @[POL(@"Открыть папку"), @"folder", NSStringFromSelector(@selector(openDocument:))],
        POToolbarAddFolder: @[POL(@"Добавить папку"), @"folder.badge.plus", NSStringFromSelector(@selector(addFolder:))],
        POToolbarRescan: @[POL(@"Пересканировать"), @"arrow.clockwise", NSStringFromSelector(@selector(rescan:))],
        POToolbarReveal: @[POL(@"Показать в Finder"), @"arrow.up.forward.app", NSStringFromSelector(@selector(revealRootInFinder:))],
    };
    NSArray *spec = specs[identifier];
    if (!spec) return nil;
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
    item.label = spec[0];
    item.toolTip = spec[0];
    item.image = [NSImage imageWithSystemSymbolName:spec[1] accessibilityDescription:spec[0]];
    item.bordered = YES;
    item.target = self;
    item.action = NSSelectorFromString(spec[2]);
    return item;
}

- (BOOL)validateToolbarItem:(NSToolbarItem *)item {
    return [self validateAction:item.action];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    // Only for a copy or a thumbnail: other files have no original to show.
    if (menuItem.action == @selector(showOriginal:)) menuItem.hidden = ![self originalOfSelection];
    // Only for a photo with a face found in it.
    if (menuItem.action == @selector(findPersonInSelection:)) menuItem.hidden = ![self faceOfSelection];
    // One of the two: "Это фото" when everything selected is already a picture, "Это картинка" otherwise.
    if (menuItem.action == @selector(markSelectionAsPicture:) || menuItem.action == @selector(markSelectionAsPhoto:)) {
        NSArray<POPhotoItem *> *items = [self markableSelection];
        BOOL allPictures = items.count > 0;
        for (POPhotoItem *item in items) allPictures = allPictures && POIsPicture(item);
        menuItem.hidden = !items.count || allPictures != (menuItem.action == @selector(markSelectionAsPhoto:));
    }
    // The grouping of the toolbar, ⌘1 ⌘2 ⌘3.
    if (menuItem.action == @selector(chooseGrouping:)) menuItem.state = menuItem.tag == [self grouping] ? NSControlStateValueOn : NSControlStateValueOff;
    return [self validateAction:menuItem.action];
}

- (BOOL)validateAction:(SEL)action {
    if (action == @selector(openDocument:)) return !_organizing;
    if (action == @selector(rescan:)) return _rootURL && !_scanner && !_organizing;
    if (action == @selector(revealRootInFinder:)) return _rootURL != nil;
    if (action == @selector(addFolder:)) return !_organizing && !_scanner;
    if (action == @selector(removeFolder:)) return _rootURLs.count > 1 && !_organizing && !_scanner;
    if (action == @selector(organize:)) return [self canOrganize];
    if (action == @selector(focusSearch:)) return _plan != nil;
    if (action == @selector(removeDuplicates:)) return _plan && !_scanner && !_organizing && (_plan.duplicateItems.count || _copySets.count || _plan.tinyItems.count);
    // The files shown: in the grid, or — for the viewer's menu — the one on screen, which is then the grid's selection.
    BOOL idle = _plan && !_scanner && !_organizing && (_content.showsResults || _content.showsViewer);
    if (action == @selector(moveShownToFolder:)) return idle && _content.grid.allItems.count > 0;
    if (action == @selector(moveSelectionToFolder:)) return idle && _content.grid.selectedItems.count > 0;
    // ⌘⌫ also clears a line in a text field: it only means "to the Trash" while the grid has the focus, or from
    // the grid's own menu.
    if (action == @selector(trashSelection:)) {
        // In the viewer: the file on screen.
        BOOL viewing = _plan && !_scanner && !_organizing && _content.showsViewer && _content.viewer.currentItem;
        BOOL fromKeyboard = NSApp.currentEvent.type == NSEventTypeKeyDown;
        return viewing || (idle && _content.grid.selectedItems.count > 0 && (!fromKeyboard || _content.grid.hasKeyboardFocus));
    }
    if (action == @selector(removeDuplicatesByFolder:)) return _plan && !_scanner && !_organizing && _plan.duplicateItems.count > 0;
    if (action == @selector(showOriginal:)) return idle && [self originalOfSelection] != nil;
    if (action == @selector(showInLibrary:)) {
        POFilterKind kind = _sidebar.selectedFilter.kind;
        return idle && _content.grid.selectedItems.count == 1 && (kind != POFilterKindAll || _content.showsViewer);
    }
    if (action == @selector(findPersonInSelection:)) return idle && [self faceOfSelection] != nil;
    if (action == @selector(markSelectionAsPicture:) || action == @selector(markSelectionAsPhoto:)) return idle && [self markableSelection].count > 0;
    if (action == @selector(chooseGrouping:)) return _plan && !_scanner && !_organizing;
    if (action == @selector(setDateForSelection:) || action == @selector(acceptDateSuggestions:)) {
        return idle && (_content.grid.selectedItems.count || _content.grid.allItems.count);
    }
    if (action == @selector(findObjectInSelection:)) return idle && _content.grid.selectedItems.count == 1 && !_content.grid.selectedItems.firstObject.isVideo;
    if (action == @selector(pickAnotherObject:)) return _objectExampleURL != nil && !self.window.attachedSheet;
    if (action == @selector(arrangeShown:)) return idle && _content.grid.allItems.count > 0 && !self.window.attachedSheet;
    if (action == @selector(findSimilarToSelection:)) return idle && _content.grid.selectedItems.count == 1 && !_content.grid.selectedItems.firstObject.isVideo;
    if (action == @selector(openSelectedItem:)) return _content.showsResults && _plan.items.count > 0;
    if (action == @selector(closeViewer:)) return _content.showsViewer;
    if (action == @selector(zoomImageIn:) || action == @selector(zoomImageOut:) || action == @selector(zoomImageToActualSize:)) {
        return _content.showsViewer ? _content.viewer.canZoom : _plan != nil && _content.showsResults;
    }
    if (action == @selector(zoomImageToFit:)) return _content.showsViewer && _content.viewer.canZoom;
    return YES;
}

#pragma mark - Opening a folder

- (IBAction)openDocument:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.allowsMultipleSelection = YES;
    panel.message = POL(@"Выберите папку с фото и видео (можно несколько)");
    panel.prompt = POL(@"Сканировать");
    if (_rootURL) panel.directoryURL = _rootURL;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSModalResponseOK && panel.URLs.count) [self loadFolders:panel.URLs];
    }];
}

/// Another folder into the library: several folders are scanned and organized together.
- (IBAction)addFolder:(id)sender {
    if (_organizing || self.window.attachedSheet) return;
    if (!_rootURLs.count) {
        [self openDocument:sender];
        return;
    }
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.allowsMultipleSelection = YES;
    panel.message = POL(@"Добавить папку к разбору");
    panel.prompt = POL(@"Добавить");
    panel.directoryURL = _rootURLs.lastObject.URLByDeletingLastPathComponent;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSModalResponseOK && panel.URLs.count) [self loadFolders:[self->_rootURLs arrayByAddingObjectsFromArray:panel.URLs] keepDestination:YES];
    }];
}

/// Takes one of the library's folders out of it (Файл → Убрать папку из разбора…).
- (IBAction)removeFolder:(id)sender {
    if (_rootURLs.count < 2 || _organizing || self.window.attachedSheet) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = POL(@"Убрать папку из разбора");
    alert.informativeText = POL(@"Папка и файлы в ней остаются на месте — их просто перестанут показывать и раскладывать.");
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 320, 26) pullsDown:NO];
    for (NSURL *url in _rootURLs) [popup addItemWithTitle:url.path.stringByAbbreviatingWithTildeInPath];
    alert.accessoryView = popup;
    [alert addButtonWithTitle:POL(@"Убрать")];
    [alert addButtonWithTitle:POL(@"Отмена")];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSMutableArray<NSURL *> *left = [self->_rootURLs mutableCopy];
        [left removeObjectAtIndex:(NSUInteger)popup.indexOfSelectedItem];
        [self loadFolders:left keepDestination:YES];
    }];
}

- (void)loadFolder:(NSURL *)url {
    [self loadFolders:@[url] keepDestination:NO];
}

- (void)loadFolders:(NSArray<NSURL *> *)urls {
    [self loadFolders:urls keepDestination:NO];
}

- (void)loadFolders:(NSArray<NSURL *> *)urls keepDestination:(BOOL)keepDestination {
    if (_organizing) return;
    NSMutableArray<NSURL *> *folders = [NSMutableArray array];
    for (NSURL *url in urls) {
        NSNumber *isDirectory = nil;
        [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
        [folders addObject:isDirectory.boolValue ? url : url.URLByDeletingLastPathComponent];
    }
    NSArray<NSURL *> *roots = [POScanner normalizedRootURLs:folders];
    if (!roots.count) return;
    NSURL *url = roots.firstObject;
    if (!keepDestination) _destinationURL = nil;

    if (![[roots valueForKey:@"path"] isEqualToArray:[_rootURLs valueForKey:@"path"] ?: @[]]) {
        // Undoing a move in a folder that is no longer on screen would be surprising.
        [_undo removeAllActions];
        _plan = nil;
        _searchItem.searchField.stringValue = @"";
        _searchTokens = @[];
        _people = @[];
        _copySets = @[];
        _similarItems = nil;
        _objectResults = nil;
        _objectExampleURL = nil;
        _objectStatus = nil;
        _lastMessage = nil;
    }
    _rootURL = url;
    _rootURLs = roots;
    for (NSURL *root in roots) [NSDocumentController.sharedDocumentController noteNewRecentDocumentURL:root];
    [self startScan];
}

- (IBAction)rescan:(id)sender {
    if (_rootURL && !_organizing) [self startScan];
}

- (IBAction)revealRootInFinder:(id)sender {
    NSURL *folder = _plan.rootURL ?: _rootURL;
    if (folder) [NSWorkspace.sharedWorkspace openURL:folder];
}

#pragma mark - Scanning

- (void)startScan {
    [self stopAnalysis];
    _similarItems = nil;   // its files may be about to move
    _objectResults = nil;
    [_scanner cancel];
    // Until the scan and the recognition after it are through, the folder is opened again at the next launch, and
    // both go on from where they stopped (the scan cache and the analysis cache).
    [NSUserDefaults.standardUserDefaults setObject:[_rootURLs valueForKey:@"path"] forKey:POUnfinishedFolderKey];
    POScanner *scanner = [[POScanner alloc] initWithRootURLs:_rootURLs ?: @[_rootURL]];
    // Files in the duplicates and thumbnails folders are never chosen as originals.
    scanner.deprioritizedFolders = @[POPlan.savedDuplicatesFolderName, POPlan.defaultTinyFolderName];
    _scanner = scanner;
    [_content showProgressWithText:POL(@"Поиск фото и видео…") fraction:-1 cancellable:YES];
    [self updateUI];

    __weak typeof(self) weakSelf = self;
    [scanner startWithProgress:^(POScanPhase phase, NSUInteger done, NSUInteger total) {
        [weakSelf scanner:scanner didProgressInPhase:phase done:done total:total];
    } completion:^(NSArray<POPhotoItem *> *items) {
        [weakSelf scanner:scanner didFinishWithItems:items];
    }];
}

- (void)scanner:(POScanner *)scanner didProgressInPhase:(POScanPhase)phase done:(NSUInteger)done total:(NSUInteger)total {
    if (scanner != _scanner) return;
    switch (phase) {
        case POScanPhaseEnumerating:
            [_content showProgressWithText:[NSString stringWithFormat:POL(@"Поиск фото и видео… найдено %@"), PONumber(done)] fraction:-1 cancellable:YES];
            break;
        case POScanPhaseMetadata:
            [_content showProgressWithText:[NSString stringWithFormat:POL(@"Чтение дат и размеров: %@ из %@"), PONumber(done), PONumber(total)]
                                  fraction:(double)done / total
                               cancellable:YES];
            break;
        case POScanPhaseDuplicates:
            [_content showProgressWithText:[NSString stringWithFormat:POL(@"Поиск дубликатов: %@ из %@"), PONumber(done), PONumber(total)]
                                  fraction:(double)done / total
                               cancellable:YES];
            break;
    }
}

- (void)scanner:(POScanner *)scanner didFinishWithItems:(NSArray<POPhotoItem *> *)items {
    if (scanner != _scanner) return;   // superseded by a newer scan, or cancelled
    _scanner = nil;
    if (items) {
        _plan = [[POPlan alloc] initWithRootURL:scanner.rootURL items:items];
        _plan.sourceURLs = scanner.rootURLs;
        if (_destinationURL) [_plan setDestinationURL:_destinationURL];
        [_plan loadOptionsFromDefaults];
        [self planDidChange];
        [self updateSearchSuggestions];   // what this folder holds, not the last one
        [self startAnalysis];
    }
    [self updateUI];
}

- (IBAction)cancelScan:(id)sender {
    // While files are being copied the button stops the copying: what was copied stays, and can be undone.
    if (_copyStop) {
        _copyStop.stopped = YES;
        return;
    }
    if (!_scanner) return;
    [_scanner cancel];
    _scanner = nil;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:POUnfinishedFolderKey];
    if (!_plan) {
        _rootURL = nil;
        _rootURLs = nil;
    }
    [self updateUI];
}

#pragma mark - Plan

/// Call after changing any option of the plan.
- (void)planDidChange {
    [_plan rebuild];
    [_plan saveOptionsToDefaults];
    [self reloadSidebar];
    [self updateGrid];
}

/// `items` of the ticked kinds — what the library shows and counts under "Все" (see the strip above the grid).
- (NSArray<POPhotoItem *> *)shownIn:(NSArray<POPhotoItem *> *)items {
    NSArray<NSNumber *> *included = [self includedKinds];
    if (![included containsObject:@NO]) return items;
    return [items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(POPhotoItem *item, NSDictionary *bindings) {
        return included[POMediaKindOfItem(item)].boolValue;
    }]];
}

- (void)reloadSidebar {
    // Counted as shown: only the ticked kinds (the library and the type rows count everything).
    NSArray<POPhotoItem *> *shown = [self shownIn:_plan.items];
    NSSet<POPhotoItem *> *shownSet = [NSSet setWithArray:shown];
    // The library itself counts everything found, ticked or not.
    _sidebar.libraryCount = (NSInteger)_plan.items.count;
    _sidebar.duplicateCount = (NSInteger)[self shownIn:_plan.duplicateItems].count;
    _sidebar.tinyCount = (NSInteger)[self shownIn:_plan.tinyItems].count;
    _sidebar.personCount = ^NSInteger(POPerson *person) {
        NSInteger count = 0;
        for (POPhotoItem *item in person.items) if ([shownSet containsObject:item]) count++;
        return count;
    };
    _sidebar.nudityCount = POSettings.detectsNudity ? (NSInteger)[self explicitItemsIn:shown].count : -1;
    _sidebar.people = POSettings.groupsFaces ? (_people ?: @[]) : @[];
    _sidebar.similarCount = _similarItems ? (NSInteger)[self shownIn:_similarItems].count : -1;
    _sidebar.similarCopyCount = [self shownIn:[self lesserCopies]].count;
    NSUInteger suggested = 0, undated = 0;
    PODateSuggester *suggester = [self suggester];
    for (POPhotoItem *item in shown) {
        if (!item.isUndated) continue;
        if ([suggester bestSuggestionForItem:item]) suggested++; else undated++;
    }
    _sidebar.suggestedCount = (NSInteger)suggested;
    _sidebar.undatedCount = (NSInteger)undated;
    _sidebar.locatedCount = (NSInteger)[[shown valueForKeyPath:@"@sum.hasLocation"] unsignedIntegerValue];
    _sidebar.screenshotCount = (NSInteger)[self screenshotsIn:shown].count;
    _sidebar.videoCount = (NSInteger)[[shown valueForKeyPath:@"@sum.video"] unsignedIntegerValue];
    // Every other type found gets a row of its own.
    NSCountedSet<NSString *> *types = [NSCountedSet set];
    for (POPhotoItem *item in _plan.items) [types addObject:POTypeFolder(item)];
    NSMutableArray<NSDictionary *> *typeCounts = [NSMutableArray array];
    for (NSString *key in @[@"Записи экрана", @"WhatsApp", @"Telegram", @"Viber", @"Instagram", @"Анимации", @"Панорамы", @"RAW", @"Картинки", @"Коллажи"]) {
        NSString *name = POL(key);
        NSUInteger count = [types countForObject:name];
        if (count) [typeCounts addObject:@{@"key": key, @"name": name, @"count": @(count)}];
    }
    _sidebar.typeCounts = typeCounts;
    NSMutableArray<NSDictionary *> *objectFilters = [NSMutableArray array];
    for (NSString *query in [self savedObjectFilters]) {
        [objectFilters addObject:@{@"query": query, @"count": @([self itemsIn:shown matchingQuery:query].count)}];
    }
    _sidebar.objectFilters = objectFilters;
    [_sidebar setPlan:_plan selecting:_sidebar.selectedFilter];
}

- (NSInteger)grouping {
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:POGroupingKey];
    return saved ? MIN(MAX([saved integerValue], 0), 2) : 1;   // by month unless chosen otherwise
}

- (void)groupingChanged:(NSToolbarItemGroup *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:sender.selectedIndex forKey:POGroupingKey];
    [self updateGrid];
}

- (void)optionsDidChange {
    _lastMessage = nil;
    if (_plan) [self planDidChange];
    [self updateUI];
}

- (void)sidebar:(POSidebarViewController *)sidebar didSelectFilter:(POFilter *)filter {
    if (!_scanner && !_organizing) [_content showResults];   // leaves the viewer, if it is open
    _placeItems = nil;
    [self updateGrid];
}

static NSString *POFilesDetail(NSUInteger count) {
    return POCount(count, POL(@"файл"), POL(@"файла"), POL(@"файлов"));
}

/// Splits date-ordered files into sections by year, month or day ("май 2019 г."). A file whose date is known
/// less precisely than that goes into a section of its own ("2019") instead of a made-up month or day, and
/// undated files close the list.
static NSArray<POGridSection *> *POSectionsByDate(NSArray<POPhotoItem *> *items, NSInteger grouping) {
    static NSDateFormatter *yearFormat, *monthFormat, *dayFormat;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        yearFormat = [NSDateFormatter new];
        monthFormat = [NSDateFormatter new];
        dayFormat = [NSDateFormatter new];
        for (NSDateFormatter *formatter in @[yearFormat, monthFormat, dayFormat]) formatter.locale = POLocale();
        [yearFormat setLocalizedDateFormatFromTemplate:@"yyyy"];
        [monthFormat setLocalizedDateFormatFromTemplate:@"LLLLyyyy"];
        [dayFormat setLocalizedDateFormatFromTemplate:@"dMMMMyyyyEEEE"];
    });
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    NSMutableArray<POGridSection *> *sections = [NSMutableArray array];
    NSMutableArray<POPhotoItem *> *current = [NSMutableArray array], *undated = [NSMutableArray array];
    __block NSString *currentKey = nil, *currentTitle = nil;
    void (^flush)(void) = ^{
        if (!current.count) return;
        [sections addObject:[POGridSection sectionWithTitle:currentTitle detail:POFilesDetail(current.count) symbolName:@"calendar" items:current.copy]];
        [current removeAllObjects];
    };
    for (POPhotoItem *item in items) {
        if (item.isUndated) {
            [undated addObject:item];
            continue;
        }
        // Precision: 0 day, 1 month, 2 year — a section can't be finer than the date it holds.
        NSInteger level = MAX(2 - grouping, (NSInteger)POItemDatePrecision(item));
        NSDateComponents *c = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:item.date];
        NSString *key = level == 2 ? [NSString stringWithFormat:@"%ld", (long)c.year]
                      : level == 1 ? [NSString stringWithFormat:@"%ld-%ld", (long)c.year, (long)c.month]
                                   : [NSString stringWithFormat:@"%ld-%ld-%ld", (long)c.year, (long)c.month, (long)c.day];
        if (![key isEqualToString:currentKey]) {
            flush();
            currentKey = key;
            NSString *title = [(level == 2 ? yearFormat : level == 1 ? monthFormat : dayFormat) stringFromDate:item.date];
            title = [[title substringToIndex:1].localizedUppercaseString stringByAppendingString:[title substringFromIndex:1]];
            if (level > 2 - grouping) title = [title stringByAppendingString:level == 2 ? POL(@" — месяц неизвестен") : POL(@" — день неизвестен")];
            currentTitle = title;
        }
        [current addObject:item];
    }
    flush();
    if (undated.count) {
        [sections addObject:[POGridSection sectionWithTitle:POL(@"Без даты") detail:POFilesDetail(undated.count)
                                                 symbolName:@"calendar.badge.exclamationmark" items:undated]];
    }
    return sections;
}

/// Undated files grouped by the folder they are in, so that a whole folder can be dated at once.
static NSArray<POGridSection *> *POSectionsByFolder(NSArray<POPhotoItem *> *items) {
    NSMutableDictionary<NSString *, NSMutableArray<POPhotoItem *> *> *folders = [NSMutableDictionary dictionary];
    for (POPhotoItem *item in items) {
        NSMutableArray *list = folders[item.currentFolder];
        if (!list) folders[item.currentFolder] = list = [NSMutableArray array];
        [list addObject:item];
    }
    NSMutableArray<POGridSection *> *sections = [NSMutableArray array];
    for (NSString *folder in [folders.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        NSArray<POPhotoItem *> *list = [folders[folder] sortedArrayUsingComparator:^NSComparisonResult(POPhotoItem *a, POPhotoItem *b) {
            return [a.url.lastPathComponent localizedStandardCompare:b.url.lastPathComponent];
        }];
        [sections addObject:[POGridSection sectionWithTitle:folder.length ? folder : POL(@"Корневая папка")
                                                     detail:POFilesDetail(list.count) symbolName:@"folder" items:list]];
    }
    return sections;
}

- (POQuickFilter)mediaKind {
    return MIN(MAX([NSUserDefaults.standardUserDefaults integerForKey:POMediaKindKey], POQuickFilterAll), POQuickFilterScreenshots);
}

- (IBAction)selectQuickFilter:(NSButton *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:sender.tag forKey:POMediaKindKey];
    [self updateGrid];
}

/// Which kinds are ticked, by POMediaKind: in the library under "Все", and organized.
- (NSArray<NSNumber *> *)includedKinds {
    return @[@([POPlan organizesKind:POMediaKindPhotos]), @([POPlan organizesKind:POMediaKindVideos]),
             @([POPlan organizesKind:POMediaKindPictures]), @([POPlan organizesKind:POMediaKindCollages]),
             @([POPlan organizesKind:POMediaKindScreenshots])];
}

- (IBAction)toggleKindIncluded:(NSButton *)sender {
    if (sender.tag < POMediaKindPhotos || sender.tag > POMediaKindScreenshots) return;
    BOOL on = sender.state == NSControlStateValueOn;
    [POPlan setOrganizes:on kind:sender.tag];
    if (_plan) {
        switch ((POMediaKind)sender.tag) {
            case POMediaKindPhotos: _plan.organizesPhotos = on; break;
            case POMediaKindVideos: _plan.organizesVideos = on; break;
            case POMediaKindPictures: _plan.organizesPictures = on; break;
            case POMediaKindCollages: _plan.organizesCollages = on; break;
            case POMediaKindScreenshots: _plan.organizesScreenshots = on; break;
        }
        [_plan rebuild];
        [self reloadSidebar];
        [self updateUI];
    }
    [self updateGrid];
}

/// The kind of a file in the strip — the same one organizing goes by (see POPlan).
static POMediaKind POMediaKindOfItem(POPhotoItem *item) {
    if (POIsCollage(item)) return POMediaKindCollages;
    // What the user called a picture or a photo is that, even when it looks like a screen.
    if (POIsScreenshot(item) && !item.pictureMark) return POMediaKindScreenshots;
    if (POIsPicture(item)) return POMediaKindPictures;
    return item.isVideo ? POMediaKindVideos : POMediaKindPhotos;
}

- (NSArray<POPhotoItem *> *)itemsIn:(NSArray<POPhotoItem *> *)items matchingQuery:(NSString *)query {
    NSArray<NSString *> *tokens = POSearchTokens(query);
    if (!tokens.count) return @[];
    return [items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(POPhotoItem *item, NSDictionary *bindings) {
        return POItemMatchesTokens(item, tokens);
    }]];
}

/// The files of `items` that the search field lets through (all of them when it is empty).
- (NSArray<POPhotoItem *> *)searchResultsIn:(NSArray<POPhotoItem *> *)items {
    NSArray<NSString *> *tokens = _searchTokens;
    if (!tokens.count) return items;
    return [items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(POPhotoItem *item, NSDictionary *bindings) {
        return POItemMatchesTokens(item, tokens);
    }]];
}

/// Files the nudity model scored at or above the threshold, most confident first.
- (NSArray<POPhotoItem *> *)explicitItemsIn:(NSArray<POPhotoItem *> *)items {
    double threshold = POSettings.nudityThreshold;
    NSArray<POPhotoItem *> *flagged = [items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(POPhotoItem *item, NSDictionary *bindings) {
        NSNumber *score = item.nudityScore;
        return score && score.doubleValue >= threshold;
    }]];
    return [flagged sortedArrayUsingComparator:^NSComparisonResult(POPhotoItem *a, POPhotoItem *b) {
        return [b.nudityScore compare:a.nudityScore];
    }];
}

/// The files the sidebar selection stands for, before the media-type strip; nil for the views that are lists
/// of sets (duplicates) rather than of files.
- (NSArray<POPhotoItem *> *)itemsForFilter:(POFilter *)filter {
    switch (filter.kind) {
        case POFilterKindAll: return _plan.items;
        case POFilterKindYear: {
            NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
            NSInteger year = filter.folder.integerValue;
            return [_plan.items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(POPhotoItem *item, NSDictionary *bindings) {
                return !item.isUndated && [calendar component:NSCalendarUnitYear fromDate:item.date] == year;
            }]];
        }
        case POFilterKindUndated:
        case POFilterKindSuggested: {
            PODateSuggester *suggester = [self suggester];
            BOOL wantSuggested = filter.kind == POFilterKindSuggested;
            return [_plan.items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(POPhotoItem *item, NSDictionary *bindings) {
                return item.isUndated && ([suggester bestSuggestionForItem:item] != nil) == wantSuggested;
            }]];
        }
        case POFilterKindObject: return [self itemsIn:_plan.items matchingQuery:filter.folder];
        case POFilterKindPerson: {
            POPerson *person = [self personWithKey:filter.folder];
            BOOL alone = [NSUserDefaults.standardUserDefaults boolForKey:POSoloPersonKey];
            return (alone ? person.soloItems : person.items) ?: @[];
        }
        case POFilterKindSimilar: return _similarItems ?: @[];
        case POFilterKindObjectSearch: return _objectResults ?: @[];
        case POFilterKindMap: return _placeItems ?: [_plan.items filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"hasLocation == YES"]];
        case POFilterKindNudity: return [self explicitItemsIn:_plan.items];
        case POFilterKindTiny: return _plan.tinyItems;
        case POFilterKindDuplicates: return nil;
        case POFilterKindScreenshots: return [self screenshotsIn:_plan.items];
        case POFilterKindVideos: return [_plan.items filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"video == YES"]];
        case POFilterKindType: {
            NSString *type = filter.folder ?: @"";
            return [_plan.items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(POPhotoItem *item, NSDictionary *bindings) {
                return [POTypeFolder(item) isEqualToString:type];
            }]];
        }
    }
    return @[];
}

- (NSArray<POPhotoItem *> *)screenshotsIn:(NSArray<POPhotoItem *> *)items {
    return [items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(POPhotoItem *item, NSDictionary *bindings) {
        return POIsScreenshot(item);
    }]];
}

- (void)updateGrid {
    POFilter *filter = _sidebar.selectedFilter;
    // "Все": the ticked kinds; one kind: that kind alone, ticked or not. A type row of the sidebar shows all of its type.
    POQuickFilter media = [self mediaKind];
    NSArray<NSNumber *> *included = filter.kind == POFilterKindType ? @[@YES, @YES, @YES, @YES, @YES] : [self includedKinds];
    BOOL everything = media == POQuickFilterAll && ![included containsObject:@NO];
    NSPredicate *kindPredicate = everything ? nil : [NSPredicate predicateWithBlock:^BOOL(POPhotoItem *item, NSDictionary *bindings) {
        POMediaKind kind = POMediaKindOfItem(item);
        return media == POQuickFilterAll ? included[kind].boolValue : (NSInteger)kind == media - 1;
    }];
    NSArray<POPhotoItem *> *(^narrow)(NSArray<POPhotoItem *> *) = ^NSArray<POPhotoItem *> *(NSArray<POPhotoItem *> *list) {
        NSArray<POPhotoItem *> *found = [self searchResultsIn:list];
        return kindPredicate ? [found filteredArrayUsingPredicate:kindPredicate] : found;
    };

    NSArray<POPhotoItem *> *base = [self itemsForFilter:filter];
    NSArray<POPhotoItem *> *items = base ? narrow(base) : @[];
    NSMutableArray<POGridSection *> *sections = [NSMutableArray array];
    NSString *placeholder = nil;
    switch (filter.kind) {
        case POFilterKindAll:
        case POFilterKindYear:
        case POFilterKindObject:
        case POFilterKindPerson:
        case POFilterKindMap:
        case POFilterKindScreenshots:
        case POFilterKindVideos:
        case POFilterKindType:
            [sections addObjectsFromArray:POSectionsByDate(items, [self grouping])];
            if (filter.kind == POFilterKindAll && !_plan.items.count) placeholder = POL(@"В этой папке нет фото и видео");
            break;
        case POFilterKindObjectSearch:
            if (items.count) {
                NSString *title = _objectStatus.length ? [NSString stringWithFormat:POL(@"Этот предмет — самые похожие в начале (%@)"), _objectStatus]
                                                       : POL(@"Этот предмет — самые похожие в начале");
                [sections addObject:[POGridSection sectionWithTitle:title detail:POFilesDetail(items.count) symbolName:@"viewfinder" items:items]];
            }
            placeholder = _objectStatus.length && !_objectResults.count ? _objectStatus
                : POL(@"Перетащите сюда фото с предметом, выделите его рамкой — и приложение найдёт фото, где он есть. "
                      @"Или щёлкните фото правой кнопкой → «Найти этот предмет на других фото…».");
            break;
        case POFilterKindUndated:
            [sections addObjectsFromArray:POSectionsByFolder(items)];
            placeholder = POL(@"У всех файлов есть дата или подсказка — см. «Предполагаемые даты».");
            break;
        case POFilterKindSuggested:
            [sections addObjectsFromArray:[self sectionsBySuggestion:items]];
            placeholder = POL(@"Предположений не осталось.");
            break;
        case POFilterKindSimilar:
            if (items.count) {
                [sections addObject:[POGridSection sectionWithTitle:_similarTitle ?: POL(@"Похожие на фото — самые похожие в начале")
                                                             detail:POFilesDetail(items.count) symbolName:@"photo.badge.magnifyingglass" items:items]];
            }
            placeholder = _similarItems ? POL(@"Ничего похожего не нашлось. Перетащите сюда другое фото.")
                                        : POL(@"Перетащите сюда фото предмета, места или человека — приложение найдёт похожие в этой папке.");
            break;
        case POFilterKindNudity:
            if (items.count) {
                NSString *title = [NSString stringWithFormat:POL(@"Оценка модели %.0f %% и выше — проверьте глазами"), POSettings.nudityThreshold * 100];
                [sections addObject:[POGridSection sectionWithTitle:title detail:POFilesDetail(items.count) symbolName:@"eye.slash" items:items]];
            }
            break;
        case POFilterKindTiny:
            if (items.count) {
                [sections addObject:[POGridSection sectionWithTitle:POL(@"Уменьшенные копии других фото")
                                                             detail:POFilesDetail(items.count) symbolName:@"arrow.down.right.and.arrow.up.left" items:items]];
            }
            break;
        case POFilterKindDuplicates: {
            // Resized or recompressed versions of one picture: the best one, then the lesser ones.
            NSMutableArray<POPhotoItem *> *all = [NSMutableArray array];
            for (NSArray<POPhotoItem *> *set in _copySets) {
                if (!narrow(set).count) continue;
                [all addObjectsFromArray:set];
                [sections addObject:[POGridSection sectionWithTitle:set.firstObject.url.lastPathComponent
                                                             detail:POCount(set.count - 1, POL(@"копия хуже качеством"), POL(@"копии хуже качеством"), POL(@"копий хуже качеством"))
                                                         symbolName:@"square.on.square.dashed" items:set]];
            }
            // One section per set: the kept original followed by its exact copies.
            for (POPhotoItem *item in _plan.items) {
                if (!item.duplicates.count) continue;
                NSArray<POPhotoItem *> *set = [@[item] arrayByAddingObjectsFromArray:item.duplicates];
                if (!narrow(set).count) continue;
                [all addObjectsFromArray:set];
                [sections addObject:[POGridSection sectionWithTitle:item.url.lastPathComponent
                                                             detail:POCount(item.duplicates.count, POL(@"копия"), POL(@"копии"), POL(@"копий"))
                                                         symbolName:@"square.on.square" items:set]];
            }
            base = all;
            items = narrow(all);
            placeholder = POL(@"Дубликатов нет");
            break;
        }
    }
    // Nothing found because of the search, not because the view is empty: say so, and where else to look.
    if (_searchTokens.count && !items.count && base.count) {
        NSString *query = [_searchItem.searchField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        placeholder = [NSString stringWithFormat:POL(@"Ничего не найдено по запросу «%@»."), query];
        if (filter.kind != POFilterKindAll) {
            placeholder = [placeholder stringByAppendingFormat:@" %@", POL(@"Поиск идёт только в выбранном разделе — выберите «Медиатека», чтобы искать везде.")];
        }
        if (_analyzer) placeholder = [placeholder stringByAppendingFormat:@" %@", POL(@"Распознавание ещё идёт — найдётся больше, когда оно закончится.")];
    }

    BOOL undatedView = filter.kind == POFilterKindUndated || filter.kind == POFilterKindSuggested;
    BOOL mapView = filter.kind == POFilterKindMap && !_placeItems;
    _content.showsMap = mapView;
    if (mapView) [_content.map setItems:items];
    [_content setShowsBackToMap:filter.kind == POFilterKindMap && _placeItems != nil];
    _content.grid.showsNudityScores = filter.kind == POFilterKindNudity;
    _content.grid.placeholder = placeholder;
    __weak typeof(self) weakSelf = self;
    if (filter.kind == POFilterKindSimilar) {
        _content.grid.onImageDropped = ^(NSURL *url) { [weakSelf searchByPhotoAtURL:url]; };
    } else if (filter.kind == POFilterKindObjectSearch) {
        _content.grid.onImageDropped = ^(NSURL *url) { [weakSelf findObjectInImageAtURL:url]; };
    } else {
        _content.grid.onImageDropped = nil;
    }
    // Screenshots, pictures, videos, a person, an object filter: "Разложить…" puts what is shown into a folder of its own.
    BOOL arrangeable = (filter.kind == POFilterKindScreenshots || filter.kind == POFilterKindType || filter.kind == POFilterKindVideos || filter.kind == POFilterKindPerson
                        || filter.kind == POFilterKindObject) && items.count > 0;
    if (filter.kind == POFilterKindObjectSearch && _objectExampleURL) {
        [_content setExtraButtonTitle:POL(@"Выделить другой предмет…") action:@selector(pickAnotherObject:) toolTip:nil];
    } else {
        [_content setExtraButtonTitle:arrangeable ? POL(@"Разложить…") : nil action:@selector(arrangeShown:)
                              toolTip:POL(@"Сложить показанные файлы в одну папку — всё вместе или по годам, месяцам, дням")];
    }
    [_content setSoloCheckboxVisible:filter.kind == POFilterKindPerson on:[NSUserDefaults.standardUserDefaults boolForKey:POSoloPersonKey]];
    BOOL canAccept = NO;
    if (undatedView) {
        PODateSuggester *suggester = [self suggester];
        for (POPhotoItem *item in items) if ((canAccept = [suggester bestSuggestionForItem:item] != nil)) break;
    }
    [_content setShowsDateButtons:undatedView && items.count > 0 canAcceptSuggestions:canAccept];
    NSString *gridKey = [NSString stringWithFormat:@"%ld|%@|%ld|%ld|%@", (long)filter.kind, filter.folder, (long)(media * 32 + included[0].intValue + included[1].intValue * 2 + included[2].intValue * 4 + included[3].intValue * 8 + included[4].intValue * 16), (long)[self grouping],
                         [_searchTokens componentsJoinedByString:@" "]];
    [_content.grid setSections:sections showsOriginalBadge:filter.kind == POFilterKindDuplicates keepScroll:[gridKey isEqualToString:_lastGridKey]];
    _lastGridKey = gridKey;

    if (filter.kind == POFilterKindDuplicates && items.count) {
        [_content setCleanupButtonTitle:POL(@"Удалить дубликаты…")
                                toolTip:POL(@"Переместить в Корзину все копии, оставив в каждом наборе оригинал или файл лучшего качества")];
    } else if (filter.kind == POFilterKindTiny && items.count) {
        [_content setCleanupButtonTitle:POL(@"Удалить миниатюры…")
                                toolTip:POL(@"Переместить в Корзину все миниатюры, у которых есть оригинал большего размера")];
    } else {
        [_content setCleanupButtonTitle:nil toolTip:nil];
    }
    [_content setShowsDuplicatesByFolder:filter.kind == POFilterKindDuplicates && _plan.duplicateItems.count > 0];
    // The strip counts within the selection (and the search), so "Видео 3" means three videos of this year. Its
    // checkboxes show what is ticked, also on a type row, which shows every kind whatever is ticked.
    NSArray<POPhotoItem *> *searched = [self searchResultsIn:base ?: @[]];
    NSUInteger counts[5] = {0, 0, 0, 0, 0};
    for (POPhotoItem *item in searched) counts[POMediaKindOfItem(item)]++;
    [_content setKindCounts:@[@(counts[0]), @(counts[1]), @(counts[2]), @(counts[3]), @(counts[4])] included:[self includedKinds] counted:included selected:media];
}

#pragma mark - Map and library

- (void)showPlaceItems:(NSArray<POPhotoItem *> *)items {
    _placeItems = items;
    [self updateGrid];
}

- (IBAction)backToMap:(id)sender {
    _placeItems = nil;
    [self updateGrid];
}

/// The file the only selected one is a copy of: the original of an exact copy, the best version of a look-alike
/// (for a thumbnail, its larger version); nil for anything else.
- (nullable POPhotoItem *)originalOfSelection {
    NSArray<POPhotoItem *> *selected = _content.grid.selectedItems;
    if (selected.count != 1) return nil;
    POPhotoItem *item = selected.firstObject;
    POPhotoItem *original = item.duplicateOf ?: item.betterCopy;
    // An exact copy of a lesser copy: the best version, not the lesser one.
    return original.betterCopy ?: original;
}

- (IBAction)showOriginal:(id)sender {
    POPhotoItem *original = [self originalOfSelection];
    if (original) [self revealInLibrary:original];
}

/// Leaves a search, a person, an object… for the library, scrolled to the file among the others of its date.
- (IBAction)showInLibrary:(id)sender {
    POPhotoItem *item = _content.grid.selectedItems.firstObject;
    if (item) [self revealInLibrary:item];
}

- (void)revealInLibrary:(POPhotoItem *)item {
    if (!_plan) return;
    if (!_scanner && !_organizing) [_content showResults];   // leaves the viewer, if it is open
    if (_searchTokens.count) {
        _searchItem.searchField.stringValue = @"";
        _searchTokens = @[];
    }
    // Under "Все" if its kind is ticked, else among its own kind.
    POMediaKind kind = POMediaKindOfItem(item);
    [NSUserDefaults.standardUserDefaults setInteger:[POPlan organizesKind:kind] ? POQuickFilterAll : POQuickFilterAll + 1 + kind forKey:POMediaKindKey];
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    (void)calendar;
    POFilter *target = [POFilter filterWithKind:POFilterKindAll folder:nil];
    _placeItems = nil;
    [_sidebar selectFilter:target];
    [self updateGrid];
    // After the grid has been laid out with the new sections.
    dispatch_async(dispatch_get_main_queue(), ^{ [self->_content.grid revealItem:item]; });
}

#pragma mark - Dates

/// The undated files grouped by the rule that suggests their date ("2016 — в папке «Photos from 2016»"), each
/// group with a button that confirms it: the files get that date and move into place in the library at once.
- (NSArray<POGridSection *> *)sectionsBySuggestion:(NSArray<POPhotoItem *> *)items {
    PODateSuggester *suggester = [self suggester];
    NSMutableDictionary<NSString *, NSMutableArray<POPhotoItem *> *> *groups = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, PODateSuggestion *> *rules = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (POPhotoItem *item in items) {
        PODateSuggestion *best = [suggester bestSuggestionForItem:item];
        if (!best) continue;
        // One rule per date and kind of evidence; folder rules also per folder.
        NSString *where = best.kind == PODateSuggestionFolderName ? item.currentFolder : @"";
        NSString *key = [NSString stringWithFormat:@"%ld|%@|%ld|%@", (long)best.kind, best.dateText, (long)best.precision, where];
        if (!groups[key]) {
            groups[key] = [NSMutableArray array];
            rules[key] = best;
            [order addObject:key];
        }
        [groups[key] addObject:item];
    }
    [order sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [rules[a].date compare:rules[b].date] ?: [a compare:b];
    }];
    NSMutableArray<POGridSection *> *sections = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    for (NSString *key in order) {
        PODateSuggestion *rule = rules[key];
        NSArray<POPhotoItem *> *files = groups[key];
        NSString *why;
        switch (rule.kind) {
            case PODateSuggestionFolderName: why = [NSString stringWithFormat:POL(@"лежат в папке «%@»"), files.firstObject.currentFolder.lastPathComponent]; break;
            case PODateSuggestionNeighbors: why = POL(@"соседние кадры той же серии"); break;
            case PODateSuggestionFileName: why = POL(@"год в имени файла"); break;
            default: why = rule.reason; break;
        }
        POGridSection *section = [POGridSection sectionWithTitle:[NSString stringWithFormat:@"%@ — %@", rule.dateText, why]
                                                          detail:POFilesDetail(files.count) symbolName:@"calendar.badge.clock" items:files];
        section.actionTitle = POL(@"Подтвердить");
        section.action = ^{ [weakSelf confirmSuggestionsForItems:files]; };
        [sections addObject:section];
    }
    return sections;
}

/// Each file gets the date of its best suggestion (the same within one rule's group).
- (void)confirmSuggestionsForItems:(NSArray<POPhotoItem *> *)items {
    PODateSuggester *suggester = [self suggester];
    for (POPhotoItem *item in items) {
        PODateSuggestion *best = [suggester bestSuggestionForItem:item];
        if (best) [POManualDates setDate:best.date precision:best.precision forItems:@[item]];
    }
    _lastMessage = [NSString stringWithFormat:POL(@"Дата подтверждена: %@."), POFilesDetail(items.count)];
    [self datesDidChange];
}

- (PODateSuggester *)suggester {
    if (!_suggester && _plan) _suggester = [[PODateSuggester alloc] initWithItems:_plan.items];
    return _suggester;
}

/// After dates were given: everything that depends on them follows.
- (void)datesDidChange {
    _suggester = nil;
    [_plan sortItemsByDate];
    [_plan rebuild];
    [self reloadSidebar];
    [self updateGrid];
    [self updateUI];
}

- (IBAction)setDateForSelection:(id)sender {
    NSArray<POPhotoItem *> *items = _content.grid.selectedItems;
    if (!items.count) items = _content.grid.allItems;
    if (!items.count || !_plan || self.window.attachedSheet) return;
    NSMutableArray<PODateSuggestion *> *suggestions = [NSMutableArray array];
    PODateSuggester *suggester = [self suggester];
    // Suggestions every chosen file shares, so that one click can date a whole folder.
    NSArray<PODateSuggestion *> *first = [suggester suggestionsForItem:items.firstObject];
    for (PODateSuggestion *candidate in first) {
        BOOL shared = YES;
        for (POPhotoItem *item in items) {
            if (item == items.firstObject) continue;
            BOOL found = NO;
            for (PODateSuggestion *other in [suggester suggestionsForItem:item]) if ((found = [other isSameAs:candidate])) break;
            if (!(shared = found)) break;
        }
        if (shared && (items.count == 1 || candidate.kind != PODateSuggestionFileDate)) [suggestions addObject:candidate];
    }
    BOOL anyManual = NO;
    for (POPhotoItem *item in items) if ((anyManual = item.dateSource == PODateSourceManual)) break;
    PODateSheetController *sheet = [[PODateSheetController alloc] initWithItemCount:items.count suggestions:suggestions
                                                                       initialDate:items.firstObject.isUndated ? nil : items.firstObject.date
                                                                         canRemove:anyManual];
    __weak typeof(self) weakSelf = self;
    sheet.completion = ^(NSDate *date, PODatePrecision precision, BOOL remove) {
        typeof(self) me = weakSelf;
        if (!me) return;
        [POManualDates setDate:remove ? nil : date precision:precision forItems:items];
        me->_lastMessage = nil;
        [me datesDidChange];
    };
    [self.window.contentViewController presentViewControllerAsSheet:sheet];
}

- (IBAction)acceptDateSuggestions:(id)sender {
    if (!_plan || self.window.attachedSheet) return;
    NSArray<POPhotoItem *> *items = _content.grid.selectedItems;
    if (!items.count) items = _content.grid.allItems;
    PODateSuggester *suggester = [self suggester];
    NSMutableArray<POPhotoItem *> *dated = [NSMutableArray array];
    NSMutableArray<PODateSuggestion *> *chosen = [NSMutableArray array];
    NSCountedSet<NSNumber *> *kinds = [NSCountedSet set];
    for (POPhotoItem *item in items) {
        PODateSuggestion *best = [suggester bestSuggestionForItem:item];
        if (!best) continue;
        [dated addObject:item];
        [chosen addObject:best];
        [kinds addObject:@(best.kind)];
    }
    if (!dated.count) return;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSDictionary<NSNumber *, NSString *> *names = @{@(PODateSuggestionNeighbors): POL(@"по соседним файлам"),
                                                    @(PODateSuggestionFileName): POL(@"по имени файла"),
                                                    @(PODateSuggestionFolderName): POL(@"по названию папки")};
    for (NSNumber *kind in @[@(PODateSuggestionNeighbors), @(PODateSuggestionFileName), @(PODateSuggestionFolderName)]) {
        NSUInteger count = [kinds countForObject:kind];
        if (count) [lines addObject:[NSString stringWithFormat:@"• %@: %@", names[kind], POFilesDetail(count)]];
    }
    if (items.count > dated.count) [lines addObject:[NSString stringWithFormat:POL(@"• без подсказки, останутся без даты: %@"), POFilesDetail(items.count - dated.count)]];
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:POL(@"Дать дату %@ по подсказкам?"), POCount(dated.count, POL(@"файлу"), POL(@"файлам"), POL(@"файлам"))];
    alert.informativeText = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:
                             POL(@"\n\nДата из папки или от соседей — догадка: год (или месяц) будет указан без дня. Её можно поменять в любой момент, сами файлы не изменяются.")];
    [alert addButtonWithTitle:POL(@"Принять")];
    [alert addButtonWithTitle:POL(@"Отмена")];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        for (NSUInteger i = 0; i < dated.count; i++) {
            [POManualDates setDate:chosen[i].date precision:chosen[i].precision forItems:@[dated[i]]];
        }
        self->_lastMessage = [NSString stringWithFormat:POL(@"Дата подтверждена: %@."), POFilesDetail(dated.count)];
        [self datesDidChange];
    }];
}

#pragma mark - Search

/// The grid follows the search field once typing pauses (250 ms, as on Windows), not on every key: a library can hold
/// a hundred thousand files.
- (void)searchChanged:(NSSearchField *)sender {
    [_searchTimer invalidate];
    _searchTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(searchTimerFired:) userInfo:nil repeats:NO];
}

- (void)searchTimerFired:(NSTimer *)timer {
    _searchTimer = nil;
    [self applySearch:_searchItem.searchField];
}

- (void)applySearch:(NSSearchField *)sender {
    [_searchTimer invalidate];
    _searchTimer = nil;
    NSArray<NSString *> *tokens = POSearchTokens(sender.stringValue);
    if ([tokens isEqualToArray:_searchTokens]) return;
    _searchTokens = tokens;
    if (!_plan) return;
    if (!_scanner && !_organizing) [_content showResults];   // leaves the viewer, if it is open
    [self updateGrid];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == _searchItem.searchField) [self searchChanged:_searchItem.searchField];
}

- (IBAction)focusSearch:(id)sender {
    [_searchItem beginSearchInteraction];
}

- (void)searchSuggestionChosen:(NSMenuItem *)sender {
    _searchItem.searchField.stringValue = sender.representedObject;
    [self applySearch:_searchItem.searchField];
}

/// Lists what was recognised most often in this folder under the search field's magnifying glass, because
/// the classifier only knows a fixed set of words and the user can't guess which ones.
/// What was recognised most often in this folder: @[name, count] pairs, most frequent first.
- (NSArray<NSArray *> *)commonLabelNamesWithLimit:(NSUInteger)limit {
    NSCountedSet<NSString *> *names = [NSCountedSet set];
    for (POPhotoItem *item in _plan.items) {
        NSMutableSet<NSString *> *own = [NSMutableSet set];   // synonymous labels count once per file
        for (NSString *label in item.labels) [own addObject:POLabelDisplayName(label)];
        for (NSString *name in own) [names addObject:name];
    }
    NSArray<NSString *> *sorted = [names.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSUInteger countA = [names countForObject:a], countB = [names countForObject:b];
        if (countA != countB) return countA > countB ? NSOrderedAscending : NSOrderedDescending;
        return [a localizedStandardCompare:b];
    }];
    NSMutableArray<NSArray *> *result = [NSMutableArray array];
    for (NSString *name in [sorted subarrayWithRange:NSMakeRange(0, MIN(sorted.count, limit))]) {
        [result addObject:@[name, @([names countForObject:name])]];
    }
    return result;
}

/// Lists what was recognised most often in this folder under the search field's magnifying glass, because
/// the classifier only knows a fixed set of words and the user can't guess which ones.
- (void)updateSearchSuggestions {
    NSArray<NSArray *> *common = [self commonLabelNamesWithLimit:30];
    NSMenu *menu = nil;
    if (common.count) {
        menu = [NSMenu new];
        menu.autoenablesItems = NO;
        [menu addItemWithTitle:POL(@"Чаще всего на снимках") action:NULL keyEquivalent:@""].enabled = NO;
        for (NSArray *entry in common) {
            NSString *title = [NSString stringWithFormat:@"%@ — %@", entry[0], PONumber([entry[1] integerValue])];
            NSMenuItem *menuItem = [menu addItemWithTitle:title action:@selector(searchSuggestionChosen:) keyEquivalent:@""];
            menuItem.target = self;
            menuItem.representedObject = entry[0];
        }
    }
    _searchItem.searchField.searchMenuTemplate = menu;
}

#pragma mark - Object filters

static NSString *const POObjectFiltersKey = @"objectFilters";

- (NSArray<NSString *> *)savedObjectFilters {
    return [NSUserDefaults.standardUserDefaults stringArrayForKey:POObjectFiltersKey] ?: @[];
}

- (void)addObjectFilterWithQuery:(NSString *)query {
    query = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length) return;
    NSMutableArray<NSString *> *filters = [[self savedObjectFilters] mutableCopy];
    if (![filters containsObject:query]) [filters addObject:query];
    [NSUserDefaults.standardUserDefaults setObject:filters forKey:POObjectFiltersKey];
    if (!_scanner && !_organizing) [_content showResults];
    [self reloadSidebar];
    [_sidebar selectFilter:[POFilter filterWithKind:POFilterKindObject folder:query]];
    [self updateGrid];
}

- (void)objectFilterChosen:(NSMenuItem *)sender {
    [self addObjectFilterWithQuery:sender.representedObject];
}

- (void)askForObjectFilter:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = POL(@"Новый фильтр по объектам");
    alert.informativeText = POL(@"Слова, как в поиске: «собака», «море закат». Фильтр покажет файлы, где распознано всё перечисленное.");
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
    alert.accessoryView = field;
    [alert addButtonWithTitle:POL(@"Добавить")];
    [alert addButtonWithTitle:POL(@"Отмена")];
    alert.window.initialFirstResponder = field;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) [self addObjectFilterWithQuery:field.stringValue];
    }];
}

/// The "+" offers what was actually recognised in this folder, most frequent first, plus free text.
- (void)sidebar:(POSidebarViewController *)sidebar addObjectFilterFromView:(NSView *)view {
    NSMenu *menu = [NSMenu new];
    NSArray<NSString *> *saved = [self savedObjectFilters];
    for (NSArray *entry in [self commonLabelNamesWithLimit:40]) {
        if ([saved containsObject:entry[0]]) continue;
        NSString *title = [NSString stringWithFormat:@"%@ — %@", entry[0], PONumber([entry[1] integerValue])];
        NSMenuItem *menuItem = [menu addItemWithTitle:title action:@selector(objectFilterChosen:) keyEquivalent:@""];
        menuItem.target = self;
        menuItem.representedObject = entry[0];
    }
    if (menu.numberOfItems) [menu addItem:NSMenuItem.separatorItem];
    [[menu addItemWithTitle:POL(@"Другое…") action:@selector(askForObjectFilter:) keyEquivalent:@""] setTarget:self];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSMaxY(view.bounds) + 4) inView:view];
}

- (void)sidebar:(POSidebarViewController *)sidebar removeObjectFilter:(NSString *)query {
    NSMutableArray<NSString *> *filters = [[self savedObjectFilters] mutableCopy];
    [filters removeObject:query];
    [NSUserDefaults.standardUserDefaults setObject:filters forKey:POObjectFiltersKey];
    BOOL wasSelected = _sidebar.selectedFilter.kind == POFilterKindObject && [_sidebar.selectedFilter.folder isEqualToString:query];
    [self reloadSidebar];
    if (wasSelected) [self updateGrid];
}

#pragma mark - Duplicates

/// Every file that has a better version of itself among the similar copies.
/// Every file that has a better version of itself among the similar copies, thumbnails excluded (they are
/// counted and listed apart).
- (NSArray<POPhotoItem *> *)lesserCopies {
    NSMutableArray<POPhotoItem *> *copies = [NSMutableArray array];
    for (NSArray<POPhotoItem *> *set in _copySets) {
        for (POPhotoItem *copy in [set subarrayWithRange:NSMakeRange(1, set.count - 1)]) {
            if (!copy.isTiny) [copies addObject:copy];
        }
    }
    return copies;
}

- (void)regroupCopies {
    POPlan *plan = _plan;
    if (!plan) return;
    // The candidates are compared pixel by pixel, which takes a while on a large folder: the status line says so.
    NSString *searching = POL(@"Поиск похожих копий…"), *status = _content.analysisStatus;
    if (!_analyzer) [_content setAnalysisStatus:searching];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSArray<POPhotoItem *> *> *sets = [POSimilarCopies setsInItems:plan.items];
        NSUInteger dated = [POSimilarCopies shareDatesInSets:sets];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_plan != plan) return;
            if ([self->_content.analysisStatus isEqualToString:searching]) [self->_content setAnalysisStatus:status];
            self->_copySets = sets;
            if (dated) [plan sortItemsByDate];   // on the main queue: the grid reads plan.items
            // Thumbnails and look-alike copies have their own folders in the plan.
            [plan rebuild];
            [self reloadSidebar];
            [self updateGrid];
            [self updateUI];
        });
    });
}

/// What the user said files are ("Это картинка" / "Это фото", see POPictures.h), read in the background.
- (void)loadPictureMarks {
    POPlan *plan = _plan;
    if (!plan) return;
    NSArray<POPhotoItem *> *items = plan.items;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *marks = POPictureMarks(items);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_plan != plan || self->_organizing) return;
            for (NSUInteger i = 0; i < items.count; i++) items[i].pictureMark = marks[i] == NSNull.null ? nil : marks[i];
            [plan rebuild];
            [self reloadSidebar];
            [self updateGrid];
            [self updateUI];
        });
    });
}

/// "Это картинка" / "Это фото": the selected files move to their kind at once, and it is remembered.
- (IBAction)markSelectionAsPicture:(id)sender {
    [self markSelectionAsPictures:YES];
}

- (IBAction)markSelectionAsPhoto:(id)sender {
    [self markSelectionAsPictures:NO];
}

- (void)markSelectionAsPictures:(BOOL)pictures {
    NSArray<POPhotoItem *> *items = [self markableSelection];
    if (!items.count || !_plan) return;
    for (POPhotoItem *item in items) item.pictureMark = @(pictures);
    [_plan rebuild];
    [self reloadSidebar];
    [self updateGrid];
    [self updateUI];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ POMarkPictures(items, pictures); });
}

/// The selected files that can be told a picture or a photo: not videos.
- (NSArray<POPhotoItem *> *)markableSelection {
    NSArray<POPhotoItem *> *selection = _content.showsViewer && _content.viewer.currentItem ? @[_content.viewer.currentItem] : _content.grid.selectedItems;
    return [selection filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"video == NO"]];
}

/// YES while the file is on the disk with the size the scan saw: the copy that stays when others go to the Trash.
static BOOL POIsStillThere(POPhotoItem *item) {
    NSDictionary<NSFileAttributeKey, id> *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:item.url.path error:NULL];
    return attributes && [attributes[NSFileSize] unsignedLongLongValue] == item.fileSize;
}

/// Exact copies cleaned up folder by folder: for each group of folders the user picks the one that stays.
- (IBAction)removeDuplicatesByFolder:(id)sender {
    if (!_plan || _scanner || _organizing || self.window.attachedSheet) return;
    NSMutableArray<NSArray<POPhotoItem *> *> *sets = [NSMutableArray array];
    for (POPhotoItem *item in _plan.items) {
        if (item.duplicates.count) [sets addObject:[@[item] arrayByAddingObjectsFromArray:item.duplicates]];
    }
    if (!sets.count) return;
    POFolderDuplicatesController *sheet = [[POFolderDuplicatesController alloc] initWithSets:sets];
    __weak typeof(self) weakSelf = self;
    sheet.completion = ^(NSArray<POPhotoItem *> *victims, NSArray<NSURL *> *folders) {
        [weakSelf trashItems:victims folders:folders];
    };
    [self.window.contentViewController presentViewControllerAsSheet:sheet];
}

/// In the thumbnails view: moves every thumbnail to the Trash. Elsewhere: every exact copy and every lesser
/// version of a picture (thumbnails included), keeping the original or the best-quality file of each set.
- (IBAction)removeDuplicates:(id)sender {
    if (!_plan || _scanner || _organizing || self.window.attachedSheet) return;
    BOOL thumbnailsOnly = _sidebar.selectedFilter.kind == POFilterKindTiny;
    // Only copies whose better version stays: in the thumbnails view the thumbnails that have one; elsewhere the exact
    // copies and the lesser versions of a picture — the thumbnails have their own view and button.
    NSMutableOrderedSet<POPhotoItem *> *doomed = [NSMutableOrderedSet orderedSet];
    for (POPhotoItem *item in thumbnailsOnly ? _plan.tinyItems : _plan.items) {
        if (thumbnailsOnly ? (item.betterCopy || item.duplicateOf) : (item.duplicateOf || (item.betterCopy && !item.isTiny))) [doomed addObject:item];
    }
    // Never the last copy of anything: a file whose better version is itself going away stays.
    NSMutableOrderedSet<POPhotoItem *> *safe = [NSMutableOrderedSet orderedSet];
    for (POPhotoItem *item in doomed) {
        // …and only while the file that stays is still there on the disk, as the scan saw it.
        POPhotoItem *keeper = item.duplicateOf ?: item.betterCopy;
        if (keeper && [doomed containsObject:keeper]) keeper = keeper.betterCopy && ![doomed containsObject:keeper.betterCopy] ? keeper.betterCopy : nil;
        if (keeper && POIsStillThere(keeper)) [safe addObject:item];
    }
    if (!safe.count) return;
    unsigned long long bytes = 0;
    for (POPhotoItem *item in safe) bytes += item.fileSize;

    NSAlert *alert = [NSAlert new];
    NSString *size = [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
    if (thumbnailsOnly) {
        alert.messageText = [NSString stringWithFormat:POL(@"Переместить %@ в Корзину?"), POCount(safe.count, POL(@"миниатюра"), POL(@"миниатюры"), POL(@"миниатюр"))];
        alert.informativeText = [NSString stringWithFormat:POL(@"У каждой миниатюры в папке есть оригинал большего размера — он останется. Освободится %@. "
                                                               @"Файлы попадут в Корзину, откуда их можно вернуть."), size];
    } else {
        alert.messageText = [NSString stringWithFormat:POL(@"Переместить %@ в Корзину?"), POCount(safe.count, POL(@"дубликат"), POL(@"дубликата"), POL(@"дубликатов"))];
        alert.informativeText = [NSString stringWithFormat:POL(@"В каждом наборе останется один файл: оригинал у точных копий и версия с наибольшим разрешением "
                                                               @"(при равном — с большим размером файла) у похожих. Освободится %@. Файлы попадут в Корзину, откуда их можно вернуть."), size];
    }
    [alert addButtonWithTitle:POL(@"Переместить в Корзину")];
    [alert addButtonWithTitle:POL(@"Отмена")];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) [self trashItems:safe.array];
    }];
}

#pragma mark - People


- (IBAction)toggleSoloPerson:(id)sender {
    BOOL alone = ![NSUserDefaults.standardUserDefaults boolForKey:POSoloPersonKey];
    [NSUserDefaults.standardUserDefaults setBool:alone forKey:POSoloPersonKey];
    [self updateGrid];
}

- (void)sidebar:(POSidebarViewController *)sidebar showOnlyPersonAlone:(POPerson *)person {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:POSoloPersonKey];
    if (!_scanner && !_organizing) [_content showResults];
    [_sidebar selectFilter:[POFilter filterWithKind:POFilterKindPerson folder:person.key]];
    [self updateGrid];
}

- (POPerson *)personWithKey:(NSString *)key {
    for (POPerson *person in _people) {
        if ([person.key isEqualToString:key]) return person;
    }
    return nil;
}

/// Groups the faces found so far into people (in the background; it compares every face with every group). The
/// people found before keep their numbers. One grouping at a time: asked again meanwhile, it runs once more after.
- (void)regroupPeople {
    if (!POSettings.groupsFaces || !_plan) {
        _people = @[];
        return;
    }
    if (_regrouping) {
        _regroupAgain = YES;
        return;
    }
    _regrouping = YES;
    POPlan *plan = _plan;
    NSArray<POPhotoItem *> *items = plan.items;
    NSArray<POPerson *> *previous = _people;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<POPerson *> *people = [POPeople peopleInItems:items previous:previous];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_regrouping = NO;
            if (self->_plan != plan) return;
            self->_people = people;
            [self reloadSidebar];
            if (self->_sidebar.selectedFilter.kind == POFilterKindPerson) [self updateGrid];
            if (self->_regroupAgain) {
                self->_regroupAgain = NO;
                [self regroupPeople];
            }
        });
    });
}

/// While faces are being found, people appear and grow every few seconds rather than at the end only.
- (void)regroupTimerFired:(NSTimer *)timer {
    if (_analyzer && POSettings.groupsFaces) [self regroupPeople];
}

- (void)sidebar:(POSidebarViewController *)sidebar renamePerson:(POPerson *)person {
    NSAlert *alert = [NSAlert new];
    alert.messageText = POL(@"Как зовут этого человека?");
    alert.informativeText = POL(@"Имя запомнится вместе с лицом: человек будет узнан и в других папках. Пустое имя — забыть.");
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
    field.stringValue = person.isNamed ? person.displayName : @"";
    field.placeholderString = person.displayName;
    alert.accessoryView = field;
    [alert addButtonWithTitle:POL(@"Сохранить")];
    [alert addButtonWithTitle:POL(@"Отмена")];
    alert.window.initialFirstResponder = field;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSString *name = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [POPeople setName:name forPerson:person];
        // The key of a named person is the name, so the selection can follow the rename.
        if (name.length && [self->_sidebar.selectedFilter.folder isEqualToString:person.key]) {
            [self->_sidebar selectFilter:[POFilter filterWithKind:POFilterKindPerson folder:name]];
        }
        [self regroupPeople];
    }];
}

#pragma mark - Search by face

/// The face to look for in the only selected file: its first (largest) one.
- (nullable NSData *)faceOfSelection {
    NSArray<POPhotoItem *> *selected = _content.grid.selectedItems;
    return selected.count == 1 ? selected.firstObject.faces.firstObject : nil;
}

- (IBAction)findPersonInSelection:(id)sender {
    NSData *face = [self faceOfSelection];
    if (face) [self searchByFace:face];
}

/// The photos someone with this face is in, most alike first — shown with the results of the search by photo.
- (void)searchByFace:(NSData *)face {
    if (!_plan) return;
    POPlan *plan = _plan;
    NSUInteger generation = ++_similarGeneration;
    NSArray<POPhotoItem *> *items = plan.items;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<POPhotoItem *> *found = [POPeople itemsWithFace:face inItems:items];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_similarGeneration || self->_plan != plan) return;
            [POPhotoSearchWindowController.sharedController setStatus:found.count
                ? [NSString stringWithFormat:POL(@"Найдено: %@. Результаты — в разделе «Похожие на фото»."), PONumber(found.count)]
                : POL(@"Ничего похожего не нашлось. Попробуйте снять часть галочек.") busy:NO];
            [self showSimilarItems:found title:POL(@"Этот человек — самые похожие в начале")];
        });
    });
}

/// The results of a search by photo or by face, in their own view.
- (void)showSimilarItems:(NSArray<POPhotoItem *> *)items title:(nullable NSString *)title {
    _similarItems = items;
    _similarTitle = title;
    if (!_scanner && !_organizing) [_content showResults];
    [_sidebar selectFilter:[POFilter filterWithKind:POFilterKindSimilar folder:nil]];
    [self reloadSidebar];
    [self updateGrid];
}

#pragma mark - Search by photo

- (IBAction)showPhotoSearch:(id)sender {
    POPhotoSearchWindowController *panel = POPhotoSearchWindowController.sharedController;
    __weak typeof(self) weakSelf = self;
    panel.onSearch = ^(CGImageRef image, NSArray<NSString *> *labels, NSData *face) {
        if (face) [weakSelf searchByFace:face]; else [weakSelf findItemsSimilarToImage:image labels:labels];
    };
    [panel showWindow:nil];
}

/// An image dropped onto the "search by photo" view: described and searched for at once; the panel shows the
/// words, so the search can be narrowed and run again.
#pragma mark - Search by object

- (IBAction)findObjectInSelection:(id)sender {
    POPhotoItem *item = _content.grid.selectedItems.firstObject;
    if (!item || item.isVideo) return;
    [self findObjectInImageAtURL:item.url];
}

- (IBAction)pickAnotherObject:(id)sender {
    if (_objectExampleURL) [self findObjectInImageAtURL:_objectExampleURL];
}

/// Opens the example photo for the user to frame the object, then searches.
- (void)findObjectInImageAtURL:(NSURL *)url {
    if (!_plan || self.window.attachedSheet) return;
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    NSDictionary *options = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES, (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                              (id)kCGImageSourceThumbnailMaxPixelSize: @1600};
    CGImageRef image = source ? CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options) : NULL;
    if (source) CFRelease(source);
    if (!image) {
        NSBeep();
        return;
    }
    CGRect initial = [POObjectIndex mostSalientRectInImage:image];
    POObjectPickerController *picker = [[POObjectPickerController alloc] initWithImage:image initialRect:initial];
    __weak typeof(self) weakSelf = self;
    picker.completion = ^(CGRect rect) {
        NSData *query = [POObjectIndex queryVectorForImage:image rect:rect];
        CGImageRelease(image);
        typeof(self) me = weakSelf;
        if (!me || !query) return;
        me->_objectExampleURL = url;
        [me searchForObject:query];
    };
    [self.window.contentViewController presentViewControllerAsSheet:picker];
}

- (void)searchForObject:(NSData *)query {
    POPlan *plan = _plan;
    NSUInteger generation = ++_objectGeneration;
    _objectResults = nil;
    _objectStatus = POL(@"Ищем…");
    [_sidebar selectFilter:[POFilter filterWithKind:POFilterKindObjectSearch folder:nil]];
    if (!_scanner && !_organizing) [_content showResults];
    [self updateGrid];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<POPhotoItem *> *photos = [NSMutableArray array];
        NSMutableArray *keys = [NSMutableArray array];
        for (POPhotoItem *item in plan.items) {
            if (item.isVideo) continue;
            [photos addObject:item];
            [keys addObject:[POAnalyzer cacheKeyForURL:item.url] ?: (id)NSNull.null];
        }
        POObjectIndex *index = POObjectIndex.sharedIndex;
        NSUInteger indexed = [index countOfIndexedKeys:keys];
        NSArray<POPhotoItem *> *found = [index itemsNearest:query inItems:photos keys:keys limit:201 distances:NULL];
        // The example photo itself would always come first.
        NSURL *example = self->_objectExampleURL.URLByStandardizingPath;
        NSArray<POPhotoItem *> *results = [found filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(POPhotoItem *item, NSDictionary *bindings) {
            return ![item.url.URLByStandardizingPath.path isEqualToString:example.path];
        }]];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_objectGeneration || self->_plan != plan) return;
            self->_objectResults = results;
            self->_objectStatus = indexed < photos.count
                ? [NSString stringWithFormat:POL(@"подготовлено %@ из %@ фото — остальные ещё анализируются, повторите поиск позже"),
                   PONumber(indexed), PONumber(photos.count)]
                : nil;
            if (!indexed) self->_objectStatus = POL(@"Фото ещё анализируются — поиск по предметам заработает, когда анализ пройдёт хотя бы часть папки.");
            [self updateGrid];
        });
    });
}

- (void)searchByPhotoAtURL:(NSURL *)url {
    [self showPhotoSearch:nil];
    [POPhotoSearchWindowController.sharedController loadImageAtURL:url searchWhenReady:YES];
}

- (IBAction)findSimilarToSelection:(id)sender {
    POPhotoItem *item = _content.grid.selectedItems.firstObject;
    if (!item) return;
    [self searchByPhotoAtURL:item.url];
}

- (void)findItemsSimilarToImage:(CGImageRef)image labels:(NSArray<NSString *> *)labels {
    POPhotoSearchWindowController *panel = POPhotoSearchWindowController.sharedController;
    if (!_plan || _scanner || _organizing) {
        [panel setStatus:POL(@"Сначала откройте папку с фото.") busy:NO];
        return;
    }
    NSUInteger generation = ++_similarGeneration;
    POPlan *plan = _plan;
    [panel setStatus:POL(@"Подбираем кандидатов по словам…") busy:YES];
    __weak typeof(self) weakSelf = self;
    [POSimilaritySearch findItemsSimilarToImage:image labels:labels inItems:plan.items progress:^(NSUInteger done, NSUInteger total) {
        typeof(self) me = weakSelf;
        if (!me || me->_similarGeneration != generation) return;
        [panel setStatus:[NSString stringWithFormat:POL(@"Сравниваем по виду: %@ из %@"), PONumber(done), PONumber(total)] busy:YES];
    } completion:^(NSArray<POPhotoItem *> *results) {
        typeof(self) me = weakSelf;
        if (!me || me->_similarGeneration != generation || me->_plan != plan) return;
        [panel setStatus:results.count ? [NSString stringWithFormat:POL(@"Найдено: %@. Результаты — в разделе «Похожие на фото»."), PONumber(results.count)]
                                       : POL(@"Ничего похожего не нашлось. Попробуйте снять часть галочек.") busy:NO];
        // Counted like everything else in the sidebar: among the ticked kinds.
        [me showSimilarItems:results title:nil];
    }];
}

#pragma mark - Moving and deleting what is shown

/// A name to offer for the folder, taken from what the grid is showing.
- (NSString *)suggestedFolderName {
    POFilter *filter = _sidebar.selectedFilter;
    if (filter.kind == POFilterKindPerson) return [self personWithKey:filter.folder].displayName ?: @"";
    if (filter.kind == POFilterKindNudity) return POL(@"Откровенные");
    if (filter.kind == POFilterKindSimilar) return POL(@"Похожие");
    if (filter.kind == POFilterKindObject) return [[filter.folder substringToIndex:1].localizedUppercaseString stringByAppendingString:[filter.folder substringFromIndex:1]];
    NSString *query = [_searchItem.searchField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return query.length ? [[query substringToIndex:1].localizedUppercaseString stringByAppendingString:[query substringFromIndex:1]] : @"";
}

- (IBAction)moveShownToFolder:(id)sender {
    [self askForFolderAndMoveItems:_content.grid.allItems];
}

- (IBAction)moveSelectionToFolder:(id)sender {
    [self askForFolderAndMoveItems:_content.grid.selectedItems];
}

- (void)askForFolderAndMoveItems:(NSArray<POPhotoItem *> *)items {
    if (!items.count || !_plan || _scanner || _organizing || self.window.attachedSheet) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:POL(@"Переместить %@ в папку"), POCount(items.count, POL(@"файл"), POL(@"файла"), POL(@"файлов"))];
    alert.informativeText = [NSString stringWithFormat:POL(@"Папка будет создана внутри «%@»; можно указать вложенную: «Люди/Мама». Файлы перемещаются, а не копируются, "
                                                       @"ничего не удаляется и не перезаписывается. Отменить — ⌘Z."), _plan.rootURL.lastPathComponent];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    field.stringValue = [self suggestedFolderName];
    field.placeholderString = POL(@"Название папки");
    alert.accessoryView = field;
    [alert addButtonWithTitle:POL(@"Переместить")];
    [alert addButtonWithTitle:POL(@"Отмена")];
    alert.window.initialFirstResponder = field;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        NSString *folder = [POPlan sanitizedFolderPath:field.stringValue];
        if (response != NSAlertFirstButtonReturn || !folder) return;
        // Put there by hand: organizing by date leaves the folder alone from now on.
        [self->_plan keepFolder:folder];
        [self moveItems:items toFolder:folder];
    }];
}

/// "Разложить…" of a section — screenshots, videos, a person, an object: everything shown into one folder named
/// after it, together or by year, month or day inside. Moved, the folder is kept out of organizing by date afterwards;
/// copied, it may go into any folder — an archive by years elsewhere, whose folders are filled up.
- (IBAction)arrangeShown:(id)sender {
    NSArray<POPhotoItem *> *items = _content.grid.allItems;
    if (!items.count || !_plan || _scanner || _organizing || self.window.attachedSheet) return;
    POFilter *filter = _sidebar.selectedFilter;
    NSString *name = filter.kind == POFilterKindScreenshots ? POL(@"Скриншоты")
                   : filter.kind == POFilterKindType ? filter.folder
                   : filter.kind == POFilterKindVideos ? POL(@"Видео")
                   : [self suggestedFolderName];
    POArrangeController *sheet = [[POArrangeController alloc] initWithItemCount:items.count name:name rootURL:_plan.rootURL];
    __weak typeof(self) weakSelf = self;
    sheet.completion = ^(POArrangeController *chosen) {
        typeof(self) me = weakSelf;
        if (!me || !me->_plan || me->_scanner || me->_organizing) return;
        [me arrangeItems:items as:chosen];
    };
    [self.window.contentViewController presentViewControllerAsSheet:sheet];
}

- (void)arrangeItems:(NSArray<POPhotoItem *> *)items as:(POArrangeController *)chosen {
    POPlan *plan = _plan;
    POFolderLayout layout = chosen.layout;
    BOOL copies = chosen.copies, skip = chosen.skipsSameContent;
    NSURL *destination = chosen.destinationURL;
    NSString *folder = [POPlan sanitizedFolderPath:chosen.folderName] ?: @"";
    if (!copies && !folder.length) return;
    // Put there by hand: organizing by date leaves the folder alone from now on (copies only when they are in the library).
    if (folder.length && [destination.URLByStandardizingPath.path isEqualToString:plan.rootURL.URLByStandardizingPath.path]) [plan keepFolder:folder];
    // The folders are worked out first, on the plan's own options (the month and day names).
    NSMapTable<POPhotoItem *, NSString *> *folders = [NSMapTable strongToStrongObjectsMapTable];
    for (POPhotoItem *item in items) {
        NSString *path = [plan folderForItem:item inFolder:folder layout:layout];
        while ([path hasPrefix:@"/"]) path = [path substringFromIndex:1];
        [folders setObject:path forKey:item];
    }
    POStopFlag *stop = copies ? [POStopFlag new] : nil;
    _copyStop = stop;
    [self beginMovingFiles];
    [_content showProgressWithText:copies ? POL(@"Копирование файлов…") : POL(@"Перемещение файлов…") fraction:0
                       cancelTitle:copies ? POL(@"Остановить") : nil];
    [self updateUI];
    NSString *actionName = [NSString stringWithFormat:copies ? POL(@"копирование в «%@»") : POL(@"перемещение в «%@»"),
                            folder.length ? folder : destination.lastPathComponent];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        void (^progress)(NSUInteger, NSUInteger) = ^(NSUInteger done, NSUInteger total) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *text = [NSString stringWithFormat:copies ? POL(@"Копирование файлов: %@ из %@") : POL(@"Перемещение файлов: %@ из %@"),
                                  PONumber(done), PONumber(total)];
                [self->_content showProgressWithText:text fraction:(double)done / total cancelTitle:copies ? POL(@"Остановить") : nil];
            });
        };
        POOrganizeResult *result;
        if (copies) {
            NSString *(^existing)(NSString *) = [POOrganizer existingYearFoldersIn:destination];
            result = [POOrganizer copyItems:items rootURL:destination skipSameContent:skip progress:progress
                                  cancelled:^BOOL { return stop.stopped; }
                                     folder:^NSString *(POPhotoItem *item) { return existing([folders objectForKey:item]); }];
        } else {
            result = [POOrganizer moveItems:items rootURL:plan.rootURL progress:progress folder:^NSString *(POPhotoItem *item) {
                return [folders objectForKey:item];
            }];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self didFinishMoveWithResult:result rootURL:destination actionName:actionName];
        });
    });
}

- (void)moveItems:(NSArray<POPhotoItem *> *)items toFolder:(NSString *)folder {
    if (!_plan || _scanner || _organizing) return;
    POPlan *plan = _plan;
    [self beginMovingFiles];
    [_content showProgressWithText:POL(@"Перемещение файлов…") fraction:0 cancellable:NO];
    [self updateUI];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        POOrganizeResult *result = [POOrganizer moveItems:items toFolder:folder rootURL:plan.rootURL progress:^(NSUInteger done, NSUInteger total) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *text = [NSString stringWithFormat:POL(@"Перемещение файлов: %@ из %@"), PONumber(done), PONumber(total)];
                [self->_content showProgressWithText:text fraction:(double)done / total cancellable:NO];
            });
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self didFinishMoveWithResult:result rootURL:plan.rootURL actionName:[NSString stringWithFormat:POL(@"перемещение в «%@»"), folder]];
        });
    });
}

/// Brings everything up to date after files were moved or removed by the app — without a rescan: the files
/// keep their dates, recognised objects, faces and fingerprints (all of which survive a move on the same disk).
- (void)applyRemovedItems:(NSArray<POPhotoItem *> *)removed moves:(NSArray<POMoveRecord *> *)moves {
    if (!_plan) return;
    [_plan removeItems:removed];
    [_plan itemsMovedFrom:[moves valueForKey:@"from"] to:[moves valueForKey:@"to"]];
    // Thumbnails are kept by path: another file may come to stand where one was.
    [POThumbnailCache.sharedCache forgetURLs:[[removed valueForKey:@"url"] arrayByAddingObjectsFromArray:[moves valueForKey:@"from"]]];
    if (removed.count) {
        NSSet<POPhotoItem *> *gone = [NSSet setWithArray:removed];
        NSPredicate *kept = [NSPredicate predicateWithBlock:^BOOL(POPhotoItem *item, NSDictionary *bindings) { return ![gone containsObject:item]; }];
        _similarItems = [_similarItems filteredArrayUsingPredicate:kept];
        _objectResults = [_objectResults filteredArrayUsingPredicate:kept];
        _placeItems = [_placeItems filteredArrayUsingPredicate:kept];
    }
    _suggester = nil;
    [_plan rebuild];
    [self reloadSidebar];
    [self updateGrid];
    [self updateUI];
    [self regroupPeople];
    [self regroupCopies];
}

/// YES when `url` lies in one of the library's folders.
- (BOOL)isInsideLibrary:(NSURL *)url {
    NSString *path = url.URLByStandardizingPath.path;
    for (NSURL *root in _rootURLs) {
        NSString *prefix = [root.URLByStandardizingPath.path stringByAppendingString:@"/"];
        if ([path compare:prefix options:NSCaseInsensitiveSearch range:NSMakeRange(0, MIN(path.length, prefix.length))] == NSOrderedSame) return YES;
    }
    return NO;
}

/// Common ending of every operation that moves files: undo, journal, status line, refresh, error report.
- (void)didFinishMoveWithResult:(POOrganizeResult *)result rootURL:(NSURL *)rootURL actionName:(NSString *)actionName {
    _organizing = NO;
    _copyStop = nil;
    if (result.records.count) {
        [self registerUndoOf:result actionName:actionName];
        [POOrganizer writeJournalForResult:result rootURL:rootURL];
    }
    NSUInteger count = result.records.count;
    // "Готово: перемещено 5 файлов. Отменить — ⌘Z", without the hint when nothing moved.
    NSString *(^done)(NSString *, NSString *, NSString *) = ^NSString *(NSString *one, NSString *few, NSString *many) {
        return [NSString stringWithFormat:count ? POL(@"Готово: %@ %@. Отменить — ⌘Z") : POL(@"Готово: %@ %@."), POPlural(count, one, few, many),
                POCount(count, POL(@"файл"), POL(@"файла"), POL(@"файлов"))];
    };
    if (result.copied) {
        NSString *message = done(POL(@"скопирован"), POL(@"скопировано"), POL(@"скопировано"));
        if (result.alreadyCopied) {
            message = [message stringByAppendingFormat:@"%@%@", count ? @". " : @" ",
                       [NSString stringWithFormat:POL(@"Пропущено — уже есть в папке назначения или это другой вариант того же снимка: %@."), PONumber(result.alreadyCopied)]];
        }
        if (result.stopped) message = [NSString stringWithFormat:@"%@ %@", POL(@"Копирование остановлено."), message];
        _lastMessage = message;
        [self showErrors:result.errors title:POL(@"Не все файлы удалось скопировать")];
        // The originals did not move. Copies made inside the library are new files in it.
        if ([self anyRecordInsideLibrary:result.records]) {
            [self startScan];
        } else {
            [self updateUI];
            [self startAnalysis];
        }
        return;
    }
    _lastMessage = done(POL(@"перемещён"), POL(@"перемещено"), POL(@"перемещено"));
    [self applyRemovedItems:@[] moves:result.records];
    [self showErrors:result.errors title:POL(@"Не все файлы удалось переместить")];
    [self startAnalysis];
}

- (BOOL)anyRecordInsideLibrary:(NSArray<POMoveRecord *> *)records {
    for (POMoveRecord *record in records) if ([self isInsideLibrary:record.to]) return YES;
    return NO;
}

/// ⌘Z undoes the run; the undo itself registers its inverse, so ⇧⌘Z does it again.
- (void)registerUndoOf:(POOrganizeResult *)result actionName:(NSString *)actionName {
    if (!_undo) _undo = [NSUndoManager new];
    [_undo registerUndoWithTarget:self handler:^(MainWindowController *target) {
        [target revert:result actionName:actionName];
    }];
    [_undo setActionName:actionName];
}

/// Files are about to move: the analysis (which reads them) stops, and starts again once they are in place.
- (void)beginMovingFiles {
    [self stopAnalysis];
    _organizing = YES;
}

/// Moves the selected files to the Trash, where they stay until the user empties it.
/// In the viewer it is the file on screen, and the viewer goes on to the next one (or back to the grid when none is left).
- (IBAction)trashSelection:(id)sender {
    if (_content.showsViewer) {
        POPhotoItem *current = _content.viewer.currentItem;
        if (current) [self trashItems:@[current]];
        return;
    }
    [self trashItems:_content.grid.selectedItems];
}

/// A few files go to the Trash at once; more (thousands of duplicates) in the background, with the library staying
/// on screen and the progress in the status line.
/// The duplicates organizing removes: only those whose original (or best version) is still there on the disk.
- (void)trashDuplicates:(NSArray<POPhotoItem *> *)duplicates {
    NSSet<POPhotoItem *> *doomed = [NSSet setWithArray:duplicates];
    NSMutableArray<POPhotoItem *> *safe = [NSMutableArray array];
    for (POPhotoItem *item in duplicates) {
        POPhotoItem *keeper = item.duplicateOf ?: item.betterCopy;
        if (keeper && [doomed containsObject:keeper]) keeper = keeper.betterCopy && ![doomed containsObject:keeper.betterCopy] ? keeper.betterCopy : nil;
        if (keeper && POIsStillThere(keeper) && [item.url checkResourceIsReachableAndReturnError:NULL]) [safe addObject:item];
    }
    if (safe.count) [self trashItems:safe];
}

- (void)trashItems:(NSArray<POPhotoItem *> *)items {
    [self trashItems:items folders:@[]];
}

/// `folders` go to the Trash whole, taking the files inside them along ("Дубликаты по папкам…").
- (void)trashItems:(NSArray<POPhotoItem *> *)items folders:(NSArray<NSURL *> *)folders {
    if (!items.count || !_plan || _scanner || _organizing) return;
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    NSMutableArray<POPhotoItem *> *trashedItems = [NSMutableArray array];
    NSMutableArray<NSString *> *folderPrefixes = [NSMutableArray array];
    for (NSURL *folder in folders) {
        NSError *error = nil;
        if ([NSFileManager.defaultManager trashItemAtURL:folder resultingItemURL:NULL error:&error]) {
            [folderPrefixes addObject:[folder.path stringByAppendingString:@"/"]];
        }
    }
    void (^trash)(POPhotoItem *) = ^(POPhotoItem *item) {
        for (NSString *prefix in folderPrefixes) {
            if (![item.url.path hasPrefix:prefix]) continue;
            // Gone with its folder.
            if (![NSFileManager.defaultManager fileExistsAtPath:item.url.path]) {
                @synchronized (trashedItems) { [trashedItems addObject:item]; }
                return;
            }
        }
        NSError *error = nil;
        if ([NSFileManager.defaultManager trashItemAtURL:item.url resultingItemURL:NULL error:&error]) {
            @synchronized (trashedItems) { [trashedItems addObject:item]; }
        } else {
            @synchronized (trashedItems) { [errors addObject:[NSString stringWithFormat:@"%@: %@", item.relativePath, error.localizedDescription]]; }
        }
    };
    // The viewer stays where it was: on the file that came after the one that went to the Trash.
    NSInteger viewerIndex = -1;
    if (_content.showsViewer && _content.viewer.currentItem) {
        viewerIndex = (NSInteger)[_content.grid.allItems indexOfObjectIdenticalTo:_content.viewer.currentItem];
        if (viewerIndex == NSNotFound) viewerIndex = -1;
    }
    void (^finish)(void) = ^{
        self->_lastMessage = [NSString stringWithFormat:POL(@"В Корзине: %@. Вернуть можно из Корзины в Finder."),
                              POCount(trashedItems.count, POL(@"файл"), POL(@"файла"), POL(@"файлов"))];
        [POThumbnailCache.sharedCache forgetURLs:[trashedItems valueForKey:@"url"]];
        [self applyRemovedItems:trashedItems moves:@[]];
        if (viewerIndex >= 0 && self->_content.showsViewer) {
            NSArray<POPhotoItem *> *left = self->_content.grid.allItems;
            if (!left.count) [self->_content.viewer close];
            else if (trashedItems.count) [self->_content.viewer showItems:left atIndex:MIN((NSUInteger)viewerIndex, left.count - 1)];
        }
        [self showErrors:errors title:POL(@"Не все файлы удалось переместить в Корзину")];
    };
    if (items.count <= 20) {
        for (POPhotoItem *item in items) trash(item);
        finish();
        return;
    }
    _organizing = YES;
    [self updateUI];
    NSUInteger total = items.count;
    [_content setStatusText:POL(@"Перемещение в Корзину…") canOrganize:NO];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [items enumerateObjectsUsingBlock:^(POPhotoItem *item, NSUInteger index, BOOL *stop) {
            @autoreleasepool {
                trash(item);
            }
            if ((index + 1) % 50 == 0 || index + 1 == total) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(self) me = weakSelf;
                    if (!me) return;
                    [me->_content setStatusText:[NSString stringWithFormat:POL(@"Перемещение в Корзину: %@ из %@"), PONumber(index + 1), PONumber(total)]
                                    canOrganize:NO];
                });
            }
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) me = weakSelf;
            if (!me) return;
            me->_organizing = NO;
            finish();
        });
    });
}

#pragma mark - Recognition

- (void)stopAnalysis {
    [_analyzer cancel];
    _analyzer = nil;
    [_regroupTimer invalidate];
    _regroupTimer = nil;
    [_content setAnalysisStatus:@""];
}

/// Recognises objects (and nudity, when enabled) in the background. Everything already analysed comes from
/// the saved results, so this is quick on a folder that was opened before.
- (void)startAnalysis {
    [self stopAnalysis];
    if (!_plan.items.count) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:POUnfinishedFolderKey];
        return;
    }
    BOOL detectsNudity = POSettings.detectsNudity;
    POAnalyzer *analyzer = [[POAnalyzer alloc] initWithItems:_plan.items];
    _analyzer = analyzer;
    NSString *notReady = detectsNudity && !POModel.selectedModel.isReady
        ? POL(@"Модель наготы не загружена — «Настройки»") : nil;
    [_content setAnalysisStatus:POL(@"Распознавание…")];
    _analysisSettings = [self analysisSettings];
    if (POSettings.groupsFaces && POModel.faceModel.isReady) {
        _regroupTimer = [NSTimer scheduledTimerWithTimeInterval:8 target:self selector:@selector(regroupTimerFired:) userInfo:nil repeats:YES];
    }
    __weak typeof(self) weakSelf = self;
    [analyzer startWithProgress:^(NSUInteger done, NSUInteger total) {
        typeof(self) me = weakSelf;
        if (!me || me->_analyzer != analyzer) return;
        [me->_content setAnalysisStatus:[NSString stringWithFormat:POL(@"Распознавание: %@ из %@"), PONumber(done), PONumber(total)]];
    } completion:^(NSString *errorMessage) {
        typeof(self) me = weakSelf;
        if (!me || me->_analyzer != analyzer) return;
        me->_analyzer = nil;
        [me->_regroupTimer invalidate];
        me->_regroupTimer = nil;
        [NSUserDefaults.standardUserDefaults removeObjectForKey:POUnfinishedFolderKey];
        [me analysisDidFinishWithMessage:errorMessage ?: notReady];
    }];
}

- (void)analysisDidFinishWithMessage:(NSString *)message {
    [_content setAnalysisStatus:message ?: @""];
    [self updateSearchSuggestions];
    [self reloadSidebar];
    [self regroupPeople];
    [self regroupCopies];
    [self loadPictureMarks];
    // Refreshing resets the scroll position, so the grid is only rebuilt when the new results change what it shows.
    if (_searchTokens.count || _sidebar.selectedFilter.kind == POFilterKindNudity || POSettings.detectsNudity) {
        [self updateGrid];
    }
}

/// What the analysis depends on: when none of it changes in the settings, a running analysis goes on (the same list
/// as on Windows, plus the forgetting of the results).
- (NSString *)analysisSettings {
    POModel *nudity = POModel.selectedModel;
    return [NSString stringWithFormat:@"%d|%d|%d|%d|%d|%d|%@|%d|%lu", POModel.pictureModel.isReady, POSettings.groupsFaces, POModel.faceModel.isReady, POSettings.analyzesObjects,
            POSettings.detectsNudity, nudity.isReady, nudity.identifier, POSettings.detectsNudity && nudity.isReady,
            (unsigned long)POAnalyzer.resultsGeneration];
}

- (void)settingsDidChange:(NSNotification *)notification {
    if (!_plan || _scanner || _organizing) return;
    if (!POSettings.detectsNudity && _sidebar.selectedFilter.kind == POFilterKindNudity) {
        [_sidebar selectFilter:[POFilter filterWithKind:POFilterKindAll folder:nil]];
    }
    if (!POSettings.groupsFaces) _people = @[];
    [self reloadSidebar];
    [self updateGrid];
    // People were turned on, the models arrived, the results were forgotten: look at the files again (what was already
    // found is kept). The language or the nudity threshold leave a running analysis alone.
    if (![[self analysisSettings] isEqualToString:_analysisSettings ?: @""]) [self startAnalysis];
}

#pragma mark - Viewer

- (IBAction)openSelectedItem:(id)sender {
    if (_content.showsResults) [_content.grid openSelectedOrFirstItem];
}

- (IBAction)closeViewer:(id)sender {
    if (_content.showsViewer) [_content.viewer close];
}

// ⌘+, ⌘− and ⌘0 zoom the picture in the viewer; over the grid they change the size of the thumbnails, as on Windows
// (⌘ and the scroll wheel too).
- (IBAction)zoomImageIn:(id)sender {
    if (_content.showsViewer) [_content.viewer zoomIn]; else _content.grid.cellWidth += 30;
}

- (IBAction)zoomImageOut:(id)sender {
    if (_content.showsViewer) [_content.viewer zoomOut]; else _content.grid.cellWidth -= 30;
}

- (IBAction)zoomImageToActualSize:(id)sender {
    if (_content.showsViewer) [_content.viewer zoomToActualSize]; else _content.grid.cellWidth = POGridViewController.defaultCellWidth;
}

- (IBAction)chooseGrouping:(NSMenuItem *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:MIN(MAX(sender.tag, 0), 2) forKey:POGroupingKey];
    _schemeItem.selectedIndex = [self grouping];
    [self updateGrid];
}

- (IBAction)zoomImageToFit:(id)sender { [_content.viewer zoomToFit]; }

#pragma mark - UI state

/// Something to do: files to put in place, or duplicates to take to the Trash ("Удалить дубликаты").
- (BOOL)canOrganize {
    return (_plan.pendingItems.count > 0 || _plan.duplicatesToRemove.count > 0) && !_scanner && !_organizing;
}

- (void)updateUI {
    BOOL busy = _scanner || _organizing;
    if (!busy) {
        if (_plan) {
            if (!_content.showsViewer) [_content showResults];   // the viewer stays open over a refresh
        } else {
            [_content showEmpty];
        }
    }
    BOOL showsSidebar = _plan != nil;
    if (_sidebarItem.collapsed == showsSidebar) _sidebarItem.collapsed = !showsSidebar;

    NSWindow *window = self.window;
    if (_rootURLs.count > 1) {
        // Several folders: the first by name and how many more; the subtitle lists them.
        window.title = [NSString stringWithFormat:POL(@"%@ и ещё %@"), _rootURL.lastPathComponent,
                        POCount(_rootURLs.count - 1, POL(@"папка"), POL(@"папки"), POL(@"папок"))];
        window.representedURL = nil;
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        for (NSURL *root in _rootURLs) [paths addObject:root.path.stringByAbbreviatingWithTildeInPath];
        window.subtitle = [paths componentsJoinedByString:@"  ·  "];
    } else {
        window.title = _rootURL ? _rootURL.lastPathComponent : @"Photo Organizer";
        window.representedURL = _rootURL;
        // The counts live in the clickable filter strip; the title names the folder, the subtitle says where it is.
        window.subtitle = _rootURL ? _rootURL.URLByDeletingLastPathComponent.path.stringByAbbreviatingWithTildeInPath : @"";
    }

    NSString *status;
    NSUInteger pending = _plan.pendingItems.count;
    if (_plan.items.count == 0) {
        status = POL(@"В этой папке нет фото и видео");
    } else if (pending > 0) {
        status = [NSString stringWithFormat:_plan.copiesFiles ? POL(@"Будет скопировано %@ из %@") : POL(@"Будет перемещено %@ из %@"),
                  PONumber(pending), PONumber(_plan.items.count)];
    } else {
        status = _lastMessage ?: POL(@"Все файлы уже лежат на своих местах");
    }
    [_content setStatusText:status canOrganize:[self canOrganize]];
    _schemeItem.enabled = _plan && !busy;
    _schemeItem.selectedIndex = [self grouping];
    [window.toolbar validateVisibleItems];
}

- (void)showErrors:(NSArray<NSString *> *)errors title:(NSString *)title {
    if (!errors.count) return;
    NSArray<NSString *> *shown = errors.count > 12 ? [errors subarrayWithRange:NSMakeRange(0, 12)] : errors;
    NSString *text = [shown componentsJoinedByString:@"\n"];
    if (errors.count > shown.count) text = [text stringByAppendingFormat:POL(@"\n… и ещё %@"), PONumber(errors.count - shown.count)];
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = title;
    alert.informativeText = text;
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

#pragma mark - Organizing

/// Shows the options and the resulting folder list; nothing moves until the sheet is confirmed.
- (IBAction)organize:(id)sender {
    if (!_plan || _scanner || _organizing || self.window.attachedSheet) return;
    // For organizing by person: files in which exactly one named person was recognised.
    NSMapTable<POPhotoItem *, NSString *> *names = [NSMapTable strongToStrongObjectsMapTable];
    NSHashTable<POPhotoItem *> *crowded = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for (POPerson *person in _people ?: @[]) {
        if (!person.isNamed) continue;
        for (POPhotoItem *item in person.items) {
            if ([crowded containsObject:item]) continue;
            if ([names objectForKey:item]) {
                [names removeObjectForKey:item];
                [crowded addObject:item];
            } else {
                [names setObject:person.displayName forKey:item];
            }
        }
    }
    _plan.personNames = names;
    [_plan rebuild];
    POOrganizeSheetController *sheet = [[POOrganizeSheetController alloc] initWithPlan:_plan];
    __weak typeof(self) weakSelf = self;
    sheet.onChange = ^{
        typeof(self) me = weakSelf;
        if (!me) return;
        me->_lastMessage = nil;
        [me reloadSidebar];
        [me updateGrid];
        [me updateUI];
    };
    sheet.completion = ^(BOOL confirmed) {
        typeof(self) me = weakSelf;
        if (!me) return;
        // The destination chosen stays for this library (until another set of folders is opened).
        me->_destinationURL = [me->_plan.rootURL.path isEqualToString:me->_rootURL.path] ? nil : me->_plan.rootURL;
        if (confirmed) [me applyPlan];
    };
    // A window of its own, which can be moved aside to look at the library.
    sheet.title = POL(@"Разложить по папкам");
    [self.window.contentViewController presentViewControllerAsModalWindow:sheet];
}

- (void)applyPlan {
    if (![self canOrganize]) return;
    POPlan *plan = _plan;
    BOOL copies = plan.copiesFiles;
    // Duplicates go to the Trash once the rest is in place ("Удалить дубликаты").
    NSArray<POPhotoItem *> *duplicates = plan.duplicatesToRemove;
    [self beginMovingFiles];
    [_content showProgressWithText:copies ? POL(@"Копирование файлов…") : POL(@"Перемещение файлов…") fraction:0 cancellable:NO];
    [self updateUI];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        POOrganizeResult *result = [POOrganizer applyPlan:plan progress:^(NSUInteger done, NSUInteger total) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *text = [NSString stringWithFormat:copies ? POL(@"Копирование файлов: %@ из %@") : POL(@"Перемещение файлов: %@ из %@"),
                                  PONumber(done), PONumber(total)];
                [self->_content showProgressWithText:text fraction:(double)done / total cancellable:NO];
            });
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self didFinishMoveWithResult:result rootURL:plan.rootURL
                               actionName:copies ? POL(@"копирование по папкам") : POL(@"раскладку по папкам")];
            [self trashDuplicates:duplicates];
        });
    });
}

/// While files are being moved ⌘Z is greyed out: an undo would move files at the same time on another thread.
- (NSUndoManager *)windowWillReturnUndoManager:(NSWindow *)window {
    static NSUndoManager *inert;
    if (!inert) inert = [NSUndoManager new];
    if (!_undo) _undo = [NSUndoManager new];
    return _organizing ? inert : _undo;
}

- (void)revert:(POOrganizeResult *)result actionName:(NSString *)actionName {
    // A scan running meanwhile is stopped, and done again once the files are back.
    BOOL rescan = _scanner != nil;
    [_scanner cancel];
    _scanner = nil;
    [self beginMovingFiles];
    [_content showProgressWithText:POL(@"Возвращаем файлы на место…") fraction:-1 cancellable:NO];
    [self updateUI];

    // The inverse is registered now, while the undo (or redo) is under way, so that it lands on the other stack; the
    // files it moves back are known only when they are back.
    NSMutableArray<POMoveRecord *> *inverse = [NSMutableArray array];
    if (!result.copied) {
        [_undo registerUndoWithTarget:self handler:^(MainWindowController *target) {
            if (inverse.count) [target revert:[POOrganizeResult resultWithMoves:inverse] actionName:actionName];
        }];
        [_undo setActionName:actionName];
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<POMoveRecord *> *moves = nil;
        NSArray<NSString *> *errors = [POOrganizer revert:result moves:&moves];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_organizing = NO;
            if (result.copied) {
                // Copies went to the Trash, the originals were never touched: nothing to redo. The library only had
                // the copies if they were made inside it.
                NSUInteger removed = result.records.count > errors.count ? result.records.count - errors.count : 0;
                self->_lastMessage = [NSString stringWithFormat:POL(@"Копии перемещены в Корзину: %@."),
                                      POCount(removed, POL(@"файл"), POL(@"файла"), POL(@"файлов"))];
                [self showErrors:errors title:POL(@"Не все копии удалось убрать")];
                if (rescan || [self anyRecordInsideLibrary:result.records]) {
                    [self startScan];
                } else {
                    [self updateUI];
                    [self startAnalysis];
                }
                return;
            }
            // The files moved back are a run of their own: undoing the undo moves them once more.
            [inverse addObjectsFromArray:moves ?: @[]];
            self->_lastMessage = [NSString stringWithFormat:POL(@"Готово: %@ %@."),
                                  POPlural(moves.count, POL(@"перемещён"), POL(@"перемещено"), POL(@"перемещено")),
                                  POCount(moves.count, POL(@"файл"), POL(@"файла"), POL(@"файлов"))];
            [self applyRemovedItems:@[] moves:moves ?: @[]];
            [self showErrors:errors title:POL(@"Не все файлы удалось вернуть")];
            if (rescan) [self startScan]; else [self startAnalysis];
        });
    });
}

#pragma mark - Drag & drop

- (NSURL *)droppedURL:(id<NSDraggingInfo>)sender {
    return [self droppedURLs:sender].firstObject;
}

- (NSArray<NSURL *> *)droppedURLs:(id<NSDraggingInfo>)sender {
    return [sender.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}] ?: @[];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    // A drag that started in this app's own grid is on its way out to Finder, not a folder to open.
    if (sender.draggingSource || _organizing || self.window.attachedSheet || ![self droppedURL:sender]) return NSDragOperationNone;
    [_content setDropHighlighted:YES];
    return NSDragOperationGeneric;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    [_content setDropHighlighted:NO];
}

- (void)draggingEnded:(id<NSDraggingInfo>)sender {
    [_content setDropHighlighted:NO];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSArray<NSURL *> *urls = [self droppedURLs:sender];
    [_content setDropHighlighted:NO];
    if (!urls.count || _organizing || sender.draggingSource) return NO;
    [NSApp activateIgnoringOtherApps:YES];
    // Folders dropped on the window: opened together, or — onto an open library — added to it.
    if (_plan && _rootURLs.count) [self loadFolders:[_rootURLs arrayByAddingObjectsFromArray:urls] keepDestination:YES];
    else [self loadFolders:urls];
    return YES;
}

@end
