#import "AppDelegate.h"
#import "POStrings.h"
#import "MainWindowController.h"
#import "POActions.h"
#import "POSettingsWindowController.h"
#import "POModel.h"
#import "POHuggingFace.h"
#import "POSettings.h"

@interface AppDelegate () <NSMenuDelegate>
@end

@implementation AppDelegate {
    MainWindowController *_windowController;
    NSArray<NSURL *> *_pendingURLs;   // folders passed at launch, before the window exists
    POHuggingFaceDownload *_pictureModelDownload;   // non-nil while MobileCLIP is being fetched
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    NSApp.mainMenu = [self makeMainMenu];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    for (NSURL *url in NSDocumentController.sharedDocumentController.recentDocumentURLs) {
        NSMenuItem *item = [menu addItemWithTitle:url.lastPathComponent action:@selector(openRecentFolder:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = url;
        item.toolTip = url.path.stringByAbbreviatingWithTildeInPath;
        NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:url.path];
        icon.size = NSMakeSize(16, 16);
        item.image = icon;
    }
    if (menu.numberOfItems) [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *clear = [menu addItemWithTitle:POL(@"Очистить меню") action:@selector(clearRecentFolders:) keyEquivalent:@""];
    clear.target = self;
    clear.enabled = NSDocumentController.sharedDocumentController.recentDocumentURLs.count > 0;
}

- (void)openRecentFolder:(NSMenuItem *)sender {
    NSURL *url = sender.representedObject;
    if (url) [_windowController loadFolders:@[url]];
}

- (void)clearRecentFolders:(id)sender {
    [NSDocumentController.sharedDocumentController clearRecentDocuments:sender];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action == @selector(clearRecentFolders:)) return NSDocumentController.sharedDocumentController.recentDocumentURLs.count > 0;
    return YES;
}

/// MobileCLIP, which tells pictures and collages from photos, is small (23 MB) and needed by everyone: it is fetched on
/// its own at launch, and the open folder is recognised again once it is there (the settings change). Tried again at
/// the next launch when the download fails, offline say.
- (void)downloadPictureModelIfNeeded {
    POModel *model = POModel.pictureModel;
    if (model.snapshotURL || _pictureModelDownload) return;
    POHuggingFaceDownload *download = [[POHuggingFaceDownload alloc] initWithRepo:model.identifier files:model.files];
    _pictureModelDownload = download;
    [download startWithProgress:nil completion:^(NSURL *snapshot, NSError *error) {
        self->_pictureModelDownload = nil;
        if (snapshot) [POSettings didChange];
    }];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _windowController = [MainWindowController new];
    [_windowController showWindow:nil];
    [self downloadPictureModelIfNeeded];
    if (_pendingURLs.count) {
        [_windowController loadFolders:_pendingURLs];
        _pendingURLs = nil;
        return;
    }
    // The app quit while folders were still being scanned or recognised: it goes on from where it stopped.
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:POUnfinishedFolderKey];
    NSArray *paths = [saved isKindOfClass:NSArray.class] ? saved : [saved isKindOfClass:NSString.class] ? @[saved] : @[];
    NSMutableArray<NSURL *> *folders = [NSMutableArray array];
    for (NSString *path in paths) {
        BOOL isDirectory = NO;
        if ([path isKindOfClass:NSString.class] && [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory) {
            [folders addObject:[NSURL fileURLWithPath:path isDirectory:YES]];
        }
    }
    if (folders.count) [_windowController loadFolders:folders];
}

/// Folder dropped on the Dock icon, opened with "Open With", or passed to `open -a`.
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    NSArray<NSURL *> *files = [urls filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isFileURL == YES"]];
    if (!files.count) return;
    if (_windowController) {
        [_windowController.window makeKeyAndOrderFront:nil];
        [_windowController loadFolders:files];
    } else {
        _pendingURLs = files;
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return YES;
}

- (void)showSettings:(id)sender {
    [POSettingsWindowController.sharedController showWindow:nil];
}

- (void)showNuditySettings:(id)sender {
    [POSettingsWindowController.sharedController showPaneAtIndex:2];
}

#pragma mark - Menu

static NSMenuItem *POItem(NSMenu *menu, NSString *title, SEL action, NSString *key) {
    return [menu addItemWithTitle:title action:action keyEquivalent:key];
}

static NSMenu *POSubmenu(NSMenu *mainMenu, NSString *title) {
    NSMenuItem *item = [mainMenu addItemWithTitle:title action:NULL keyEquivalent:@""];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
    item.submenu = menu;
    return menu;
}

- (NSMenu *)makeMainMenu {
    NSString *appName = @"Photo Organizer";
    NSMenu *mainMenu = [NSMenu new];

    NSMenu *appMenu = POSubmenu(mainMenu, appName);
    POItem(appMenu, [POL(@"О программе ") stringByAppendingString:appName], @selector(orderFrontStandardAboutPanel:), @"");
    [appMenu addItem:NSMenuItem.separatorItem];
    POItem(appMenu, POL(@"Настройки…"), @selector(showSettings:), @",").target = self;
    POItem(appMenu, POL(@"Распознавание наготы и модели…"), @selector(showNuditySettings:), @"").target = self;
    [appMenu addItem:NSMenuItem.separatorItem];
    NSMenu *servicesMenu = [NSMenu new];
    POItem(appMenu, POL(@"Службы"), NULL, @"").submenu = servicesMenu;
    NSApp.servicesMenu = servicesMenu;
    [appMenu addItem:NSMenuItem.separatorItem];
    POItem(appMenu, [POL(@"Скрыть ") stringByAppendingString:appName], @selector(hide:), @"h");
    POItem(appMenu, POL(@"Скрыть остальные"), @selector(hideOtherApplications:), @"h").keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    POItem(appMenu, POL(@"Показать все"), @selector(unhideAllApplications:), @"");
    [appMenu addItem:NSMenuItem.separatorItem];
    POItem(appMenu, [POL(@"Завершить ") stringByAppendingString:appName], @selector(terminate:), @"q");

    NSMenu *fileMenu = POSubmenu(mainMenu, POL(@"Файл"));
    POItem(fileMenu, POL(@"Открыть папку…"), @selector(openDocument:), @"o");
    // The folders opened lately (macOS keeps the list, see -loadFolders:); filled each time the menu opens.
    NSMenu *recentMenu = [[NSMenu alloc] initWithTitle:POL(@"Открыть недавние")];
    recentMenu.delegate = self;
    POItem(fileMenu, POL(@"Открыть недавние"), NULL, @"").submenu = recentMenu;
    POItem(fileMenu, POL(@"Добавить папку…"), @selector(addFolder:), @"O");
    POItem(fileMenu, POL(@"Убрать папку из разбора…"), @selector(removeFolder:), @"");
    POItem(fileMenu, POL(@"Пересканировать"), @selector(rescan:), @"r");
    POItem(fileMenu, POL(@"Показать папку в Finder"), @selector(revealRootInFinder:), @"R");
    [fileMenu addItem:NSMenuItem.separatorItem];
    POItem(fileMenu, POL(@"Разложить по папкам…"), @selector(organize:), @"\r");
    // ⌘M minimises the window on a Mac: moving takes ⇧⌘M (the selection) and ⌥⇧⌘M (everything shown).
    POItem(fileMenu, POL(@"Переместить в папку…"), @selector(moveSelectionToFolder:), @"M");
    POItem(fileMenu, POL(@"Переместить показанное в папку…"), @selector(moveShownToFolder:), @"M").keyEquivalentModifierMask =
        NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption;
    POItem(fileMenu, POL(@"Переместить в Корзину"), @selector(trashSelection:), @"\b");
    POItem(fileMenu, POL(@"Удалить дубликаты…"), @selector(removeDuplicates:), @"");
    POItem(fileMenu, POL(@"Дубликаты по папкам…"), @selector(removeDuplicatesByFolder:), @"");
    [fileMenu addItem:NSMenuItem.separatorItem];
    POItem(fileMenu, POL(@"Задать дату…"), @selector(setDateForSelection:), @"d");
    [fileMenu addItem:NSMenuItem.separatorItem];
    POItem(fileMenu, POL(@"Закрыть"), @selector(performClose:), @"w");

    NSMenu *editMenu = POSubmenu(mainMenu, POL(@"Правка"));
    POItem(editMenu, POL(@"Отменить"), @selector(undo:), @"z");
    POItem(editMenu, POL(@"Повторить"), @selector(redo:), @"Z");
    [editMenu addItem:NSMenuItem.separatorItem];
    // Text fields (search, settings, dialogs) only get ⌘X / ⌘C / ⌘V / ⌘A when the menu has these items.
    POItem(editMenu, POL(@"Вырезать"), @selector(cut:), @"x");
    POItem(editMenu, POL(@"Скопировать"), @selector(copy:), @"c");
    POItem(editMenu, POL(@"Вставить"), @selector(paste:), @"v");
    POItem(editMenu, POL(@"Удалить"), @selector(delete:), @"");
    POItem(editMenu, POL(@"Выбрать все"), @selector(selectAll:), @"a");
    [editMenu addItem:NSMenuItem.separatorItem];
    POItem(editMenu, POL(@"Найти…"), @selector(focusSearch:), @"f");
    POItem(editMenu, POL(@"Поиск по фото…"), @selector(showPhotoSearch:), @"F");

    NSMenu *viewMenu = POSubmenu(mainMenu, POL(@"Вид"));
    NSString *up = [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey];
    NSString *down = [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey];
    POItem(viewMenu, POL(@"Открыть в просмотре"), @selector(openSelectedItem:), down);
    POItem(viewMenu, POL(@"Вернуться к сетке"), @selector(closeViewer:), up);
    [viewMenu addItem:NSMenuItem.separatorItem];
    NSArray<NSString *> *groupings = @[POL(@"По годам"), POL(@"По месяцам"), POL(@"По дням")];
    for (NSInteger index = 0; index < 3; index++) {
        POItem(viewMenu, groupings[index], @selector(chooseGrouping:), [NSString stringWithFormat:@"%ld", (long)index + 1]).tag = index;
    }
    [viewMenu addItem:NSMenuItem.separatorItem];
    POItem(viewMenu, POL(@"Увеличить"), @selector(zoomImageIn:), @"+");
    POItem(viewMenu, POL(@"Уменьшить"), @selector(zoomImageOut:), @"-");
    POItem(viewMenu, POL(@"Реальный размер"), @selector(zoomImageToActualSize:), @"0");
    POItem(viewMenu, POL(@"По размеру окна"), @selector(zoomImageToFit:), @"9");
    [viewMenu addItem:NSMenuItem.separatorItem];
    POItem(viewMenu, POL(@"Показать/скрыть боковую панель"), @selector(toggleSidebar:), @"s").keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    POItem(viewMenu, POL(@"Полноэкранный режим"), @selector(toggleFullScreen:), @"f").keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;

    NSMenu *windowMenu = POSubmenu(mainMenu, POL(@"Окно"));
    POItem(windowMenu, POL(@"Свернуть"), @selector(performMiniaturize:), @"m");
    POItem(windowMenu, POL(@"Изменить масштаб"), @selector(performZoom:), @"");
    NSApp.windowsMenu = windowMenu;

    return mainMenu;
}

@end
