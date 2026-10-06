#import "POFolderDuplicatesController.h"
#import "POStrings.h"

/// Copies lying in the same folders: every set has a copy in each of them.
@interface POFolderGroup : NSObject
@property (nonatomic, copy) NSArray<NSString *> *folders;   // absolute paths
@property (nonatomic, strong) NSMutableArray<NSArray<POPhotoItem *> *> *sets;
@property (nonatomic) NSUInteger kept;
@property (nonatomic) BOOL included;
@property (nonatomic, strong) NSTextField *hint;
@property (nonatomic, strong) NSStackView *choices;
@end

@implementation POFolderGroup
@end

/// Lays out from the top, as a scrolled page does.
@interface POFolderDuplicatesDocument : NSView
@end

@implementation POFolderDuplicatesDocument
- (BOOL)isFlipped { return YES; }
@end

static NSString *POFolderOf(POPhotoItem *item) {
    return item.url.URLByDeletingLastPathComponent.path;
}

static BOOL POSameFolder(NSString *a, NSString *b) {
    return [a caseInsensitiveCompare:b] == NSOrderedSame;
}

@implementation POFolderDuplicatesController {
    NSArray<POFolderGroup *> *_groups;
    NSButton *_wholeFolders;
    NSTextField *_summary;
    NSButton *_removeButton;
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *_filesOnDisk;
}

- (instancetype)initWithSets:(NSArray<NSArray<POPhotoItem *> *> *)sets {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _filesOnDisk = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, POFolderGroup *> *byFolders = [NSMutableDictionary dictionary];
        for (NSArray<POPhotoItem *> *set in sets) {
            if (set.count < 2) continue;
            NSMutableOrderedSet<NSString *> *folders = [NSMutableOrderedSet orderedSet];
            for (POPhotoItem *item in set) {
                NSString *folder = POFolderOf(item);
                BOOL known = NO;
                for (NSString *other in folders) if ((known = POSameFolder(other, folder))) break;
                if (!known) [folders addObject:folder];
            }
            NSArray<NSString *> *sorted = [folders.array sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
            NSString *key = [sorted componentsJoinedByString:@"\n"].lowercaseString;
            POFolderGroup *group = byFolders[key];
            if (!group) {
                byFolders[key] = group = [POFolderGroup new];
                group.folders = sorted;
                group.sets = [NSMutableArray array];
                group.included = YES;
            }
            [group.sets addObject:set];
        }
        _groups = [byFolders.allValues sortedArrayUsingComparator:^NSComparisonResult(POFolderGroup *a, POFolderGroup *b) {
            if (a.sets.count != b.sets.count) return a.sets.count > b.sets.count ? NSOrderedAscending : NSOrderedDescending;
            return [a.folders.firstObject localizedCaseInsensitiveCompare:b.folders.firstObject];
        }];
        for (POFolderGroup *group in _groups) {
            // At first the folder that holds most of the originals the app chose.
            NSUInteger best = 0, bestCount = 0;
            for (NSUInteger index = 0; index < group.folders.count; index++) {
                NSUInteger count = 0;
                for (NSArray<POPhotoItem *> *set in group.sets) if (POSameFolder(POFolderOf(set.firstObject), group.folders[index])) count++;
                if (count > bestCount) { best = index; bestCount = count; }
            }
            group.kept = best;
        }
    }
    return self;
}

/// The folder as the user knows it: from the library folder's name down.
static NSString *POShownFolder(NSString *folder, NSArray<POPhotoItem *> *set) {
    for (POPhotoItem *item in set) {
        if (!POSameFolder(POFolderOf(item), folder)) continue;
        NSString *root = item.rootURL.lastPathComponent ?: @"";
        return item.currentFolder.length ? [root stringByAppendingPathComponent:item.currentFolder] : root;
    }
    return folder.lastPathComponent;
}

static NSTextField *PONoteLabel(NSString *text) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    label.textColor = NSColor.secondaryLabelColor;
    label.selectable = NO;
    label.preferredMaxLayoutWidth = 560;
    return label;
}

- (NSView *)cardForGroup:(POFolderGroup *)group index:(NSUInteger)groupIndex {
    unsigned long long size = 0;
    for (NSArray<POPhotoItem *> *set in group.sets) size += set.firstObject.fileSize;
    NSString *files = POCount(group.sets.count, POL(@"одинаковый файл"), POL(@"одинаковых файла"), POL(@"одинаковых файлов"));
    NSString *title = group.folders.count == 1
        ? [NSString stringWithFormat:POL(@"%@ — копии в одной папке, останется по одному файлу"), files]
        : [NSString stringWithFormat:POL(@"%@ в %@ · %@"), files, POCount(group.folders.count, POL(@"папке"), POL(@"папках"), POL(@"папках")),
           [NSByteCountFormatter stringFromByteCount:(long long)size countStyle:NSByteCountFormatterCountStyleFile]];
    NSButton *include = [NSButton checkboxWithTitle:title target:self action:@selector(includeChanged:)];
    include.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];
    include.state = NSControlStateValueOn;
    include.tag = (NSInteger)groupIndex;

    NSMutableArray<NSView *> *choices = [NSMutableArray array];
    for (NSUInteger index = 0; index < group.folders.count; index++) {
        NSString *folder = group.folders[index];
        NSString *shown = POShownFolder(folder, group.sets.firstObject);
        if (group.folders.count == 1) {
            NSTextField *label = [NSTextField labelWithString:shown];
            label.textColor = NSColor.secondaryLabelColor;
            [choices addObject:label];
            continue;
        }
        NSButton *radio = [NSButton radioButtonWithTitle:[NSString stringWithFormat:POL(@"Оставить: %@"), shown] target:self action:@selector(keptChanged:)];
        radio.lineBreakMode = NSLineBreakByTruncatingMiddle;
        radio.toolTip = folder;
        radio.tag = (NSInteger)(groupIndex * 1000 + index);
        radio.state = index == group.kept ? NSControlStateValueOn : NSControlStateValueOff;
        [radio.widthAnchor constraintLessThanOrEqualToConstant:540].active = YES;
        [choices addObject:radio];
    }
    group.choices = [NSStackView stackViewWithViews:choices];
    group.choices.orientation = NSUserInterfaceLayoutOrientationVertical;
    group.choices.alignment = NSLayoutAttributeLeading;
    group.choices.spacing = 4;
    group.choices.edgeInsets = NSEdgeInsetsMake(0, 20, 0, 0);
    group.hint = PONoteLabel(@"");
    group.hint.hidden = YES;
    NSStackView *card = [NSStackView stackViewWithViews:@[include, group.choices, group.hint]];
    card.orientation = NSUserInterfaceLayoutOrientationVertical;
    card.alignment = NSLayoutAttributeLeading;
    card.spacing = 6;
    card.edgeInsets = NSEdgeInsetsMake(10, 12, 10, 12);
    card.wantsLayer = YES;
    card.layer.borderWidth = 1;
    card.layer.cornerRadius = 6;
    card.layer.borderColor = NSColor.separatorColor.CGColor;
    return card;
}

- (void)loadView {
    NSTextField *title = [NSTextField labelWithString:POL(@"Дубликаты по папкам")];
    title.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    NSTextField *intro = PONoteLabel(POL(@"Одинаковые файлы собраны по папкам, в которых они лежат. Для каждой группы выберите папку, которая останется, — "
                                         @"копии из остальных папок будут перемещены в Корзину."));
    NSTextField *first = PONoteLabel(POL(@"Сначала выбрана папка, где больше файлов, которые приложение считает оригиналами: не из папок вроде «Копии» "
                                         @"или «Backup», с самой ранней датой съёмки, с самым коротким путём."));
    _wholeFolders = [NSButton checkboxWithTitle:POL(@"Папки, в которых останутся только копии, удалять целиком") target:self action:@selector(update)];
    _wholeFolders.state = NSControlStateValueOn;

    NSMutableArray<NSView *> *cards = [NSMutableArray array];
    for (NSUInteger index = 0; index < _groups.count; index++) [cards addObject:[self cardForGroup:_groups[index] index:index]];
    NSStackView *list = [NSStackView stackViewWithViews:cards];
    list.orientation = NSUserInterfaceLayoutOrientationVertical;
    list.alignment = NSLayoutAttributeLeading;
    list.spacing = 8;
    list.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *card in cards) [card.widthAnchor constraintEqualToAnchor:list.widthAnchor].active = YES;
    POFolderDuplicatesDocument *document = [POFolderDuplicatesDocument new];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview:list];
    NSScrollView *scroller = [NSScrollView new];
    scroller.hasVerticalScroller = YES;
    scroller.autohidesScrollers = YES;
    scroller.drawsBackground = NO;
    scroller.documentView = document;
    NSLayoutConstraint *wanted = [scroller.heightAnchor constraintEqualToAnchor:document.heightAnchor];
    wanted.priority = NSLayoutPriorityDefaultLow - 1;   // as tall as the list, up to the limit below
    [NSLayoutConstraint activateConstraints:@[
        [list.topAnchor constraintEqualToAnchor:document.topAnchor],
        [list.leadingAnchor constraintEqualToAnchor:document.leadingAnchor],
        [list.trailingAnchor constraintEqualToAnchor:document.trailingAnchor],
        [list.bottomAnchor constraintEqualToAnchor:document.bottomAnchor],
        [document.leadingAnchor constraintEqualToAnchor:scroller.contentView.leadingAnchor],
        [document.trailingAnchor constraintEqualToAnchor:scroller.contentView.trailingAnchor],
        [document.topAnchor constraintEqualToAnchor:scroller.contentView.topAnchor],
        [scroller.heightAnchor constraintLessThanOrEqualToConstant:420],
        wanted,
    ]];

    _summary = [NSTextField wrappingLabelWithString:@""];
    _summary.preferredMaxLayoutWidth = 560;
    NSButton *cancel = [NSButton buttonWithTitle:POL(@"Отмена") target:self action:@selector(cancel:)];
    cancel.keyEquivalent = @"\e";
    _removeButton = [NSButton buttonWithTitle:POL(@"Переместить в Корзину") target:self action:@selector(remove:)];
    _removeButton.keyEquivalent = @"\r";
    NSStackView *buttons = [NSStackView stackViewWithViews:@[[NSView new], cancel, _removeButton]];

    NSStackView *stack = [NSStackView stackViewWithViews:@[title, intro, first, _wholeFolders, scroller, _summary, buttons]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    [stack setCustomSpacing:12 afterView:_wholeFolders];
    [stack setCustomSpacing:16 afterView:_summary];
    for (NSView *wide in @[scroller, buttons]) [wide.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-40].active = YES;
    [stack.widthAnchor constraintEqualToConstant:640].active = YES;
    self.view = stack;
    [self update];
}

- (void)includeChanged:(NSButton *)sender {
    POFolderGroup *group = _groups[(NSUInteger)sender.tag];
    group.included = sender.state == NSControlStateValueOn;
    for (NSView *choice in group.choices.arrangedSubviews) {
        if ([choice isKindOfClass:NSButton.class]) ((NSButton *)choice).enabled = group.included;
    }
    [self update];
}

- (void)keptChanged:(NSButton *)sender {
    POFolderGroup *group = _groups[(NSUInteger)sender.tag / 1000];
    group.kept = (NSUInteger)sender.tag % 1000;
    for (NSView *choice in group.choices.arrangedSubviews) {
        if ([choice isKindOfClass:NSButton.class]) ((NSButton *)choice).state = choice == sender ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [self update];
}

- (NSArray<POPhotoItem *> *)victims {
    NSMutableArray<POPhotoItem *> *victims = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (POFolderGroup *group in _groups) {
        if (!group.included) continue;
        NSString *kept = group.folders[group.kept];
        for (NSArray<POPhotoItem *> *set in group.sets) {
            // The set is in the app's order (its chosen original first): the first file in the kept folder stays.
            POPhotoItem *stays = nil;
            for (POPhotoItem *item in set) if (POSameFolder(POFolderOf(item), kept)) { stays = item; break; }
            // The file that stays must still be there, as it was, or the set would lose its last copy.
            NSDictionary *attributes = stays ? [fm attributesOfItemAtPath:stays.url.path error:NULL] : nil;
            if (!attributes || [attributes[NSFileSize] unsignedLongLongValue] != stays.fileSize) continue;
            for (POPhotoItem *item in set) if (item != stays) [victims addObject:item];
        }
    }
    return victims;
}

- (NSArray<NSURL *> *)foldersToRemove {
    return _wholeFolders.state == NSControlStateValueOn ? [self emptiedFoldersFor:[self victims]] : @[];
}

- (NSArray<NSURL *> *)emptiedFoldersFor:(NSArray<POPhotoItem *> *)victims {
    NSMutableSet<NSString *> *going = [NSMutableSet set], *roots = [NSMutableSet set];
    NSMutableOrderedSet<NSString *> *folders = [NSMutableOrderedSet orderedSet];
    for (POPhotoItem *item in victims) {
        [going addObject:item.url.path.lowercaseString];
        if (item.rootURL) [roots addObject:item.rootURL.path.lowercaseString];
        [folders addObject:POFolderOf(item)];
    }
    NSMutableArray<NSString *> *emptied = [NSMutableArray array];
    for (NSString *folder in folders) {
        if ([roots containsObject:folder.lowercaseString]) continue;
        NSArray<NSString *> *files = [self filesOnDiskIn:folder];
        if (!files.count) continue;
        BOOL all = YES;
        for (NSString *file in files) if (!(all = [going containsObject:file.lowercaseString])) break;
        if (all) [emptied addObject:folder];
    }
    NSMutableArray<NSURL *> *outer = [NSMutableArray array];
    for (NSString *folder in emptied) {
        BOOL inside = NO;
        for (NSString *other in emptied) {
            if ((inside = [folder.lowercaseString hasPrefix:[other.lowercaseString stringByAppendingString:@"/"]])) break;
        }
        if (!inside) [outer addObject:[NSURL fileURLWithPath:folder isDirectory:YES]];
    }
    return outer;
}

/// The files in the folder and the folders inside it, without the system's own little files; empty when it can't be
/// looked through (what can't be looked through is not removed).
- (NSArray<NSString *> *)filesOnDiskIn:(NSString *)folder {
    NSArray<NSString *> *known = _filesOnDisk[folder];
    if (known) return known;
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    __block BOOL failed = NO;
    NSDirectoryEnumerator<NSURL *> *enumerator = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:folder isDirectory:YES]
                                                                   includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0
                                                                                 errorHandler:^BOOL(NSURL *url, NSError *error) { failed = YES; return NO; }];
    for (NSURL *url in enumerator) {
        NSNumber *isDirectory = nil;
        [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
        if (isDirectory.boolValue) continue;
        // Only the system's own little files are ignored; anything else (.edits, hidden files) keeps the folder.
        NSString *leaf = url.lastPathComponent;
        if ([@[@"Thumbs.db", @"desktop.ini", @".DS_Store", @"Icon\r"] containsObject:leaf] || [leaf hasPrefix:@"._"]) continue;
        [files addObject:url.path];
    }
    if (failed) [files removeAllObjects];
    return _filesOnDisk[folder] = files;
}

- (void)update {
    NSArray<POPhotoItem *> *victims = [self victims];
    NSArray<NSURL *> *folders = [self foldersToRemove];
    for (POFolderGroup *group in _groups) {
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        if (group.included) {
            for (NSString *folder in group.folders) {
                for (NSURL *whole in folders) {
                    if (!POSameFolder(folder, whole.path) && ![folder.lowercaseString hasPrefix:[whole.path.lowercaseString stringByAppendingString:@"/"]]) continue;
                    [lines addObject:[NSString stringWithFormat:POL(@"В папке «%@» не останется ничего, кроме этих копий, — она уйдёт в Корзину целиком."),
                                      POShownFolder(folder, group.sets.firstObject)]];
                    break;
                }
            }
        }
        group.hint.stringValue = [lines componentsJoinedByString:@"\n"];
        group.hint.hidden = lines.count == 0;
    }
    unsigned long long bytes = 0;
    for (POPhotoItem *item in victims) bytes += item.fileSize;
    NSString *summary = victims.count == 0 ? POL(@"Ничего не выбрано.")
        : [NSString stringWithFormat:POL(@"В Корзину: %@, освободится %@. Вернуть можно из Корзины."),
           POCount(victims.count, POL(@"файл"), POL(@"файла"), POL(@"файлов")),
           [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile]];
    if (victims.count && folders.count) summary = [summary stringByAppendingFormat:@" %@", [NSString stringWithFormat:POL(@"Папок целиком: %@."), PONumber(folders.count)]];
    _summary.stringValue = summary;
    _removeButton.enabled = victims.count > 0;
}

- (void)remove:(id)sender {
    NSArray<POPhotoItem *> *victims = [self victims];
    NSArray<NSURL *> *folders = [self foldersToRemove];
    [self.presentingViewController dismissViewController:self];
    if (victims.count && self.completion) self.completion(victims, folders);
}

- (void)cancel:(id)sender {
    [self.presentingViewController dismissViewController:self];
}

@end
