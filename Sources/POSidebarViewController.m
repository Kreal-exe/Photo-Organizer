#import "POSidebarViewController.h"
#import "POStrings.h"

@implementation POFilter

+ (instancetype)filterWithKind:(POFilterKind)kind folder:(NSString *)folder {
    POFilter *filter = [POFilter new];
    filter->_kind = kind;
    filter->_folder = [folder copy];
    return filter;
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:POFilter.class]) return NO;
    POFilter *other = object;
    return other.kind == self.kind && (other.folder == self.folder || [other.folder isEqualToString:self.folder]);
}

- (NSUInteger)hash {
    return (NSUInteger)self.kind ^ self.folder.hash;
}

@end

@interface POSidebarRow : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *symbolName;
@property (nonatomic) NSInteger count;
@property (nonatomic, strong, nullable) POFilter *filter;   // nil for section headers
@property (nonatomic, copy, nullable) NSString *sectionKey;   // set on headers: identifies the section when it is collapsed
@property (nonatomic) BOOL showsAddButton;                    // header with a "+"
@property (nonatomic, strong, nullable) POPerson *person;   // set on people's rows: the row shows the face instead of a symbol
@end

@implementation POSidebarRow

+ (instancetype)headerWithTitle:(NSString *)title key:(NSString *)key {
    POSidebarRow *row = [POSidebarRow new];
    row.title = title;
    row.sectionKey = key;
    return row;
}

+ (instancetype)rowWithTitle:(NSString *)title symbolName:(NSString *)symbolName count:(NSInteger)count filter:(POFilter *)filter {
    POSidebarRow *row = [POSidebarRow new];
    row.title = title;
    row.symbolName = symbolName;
    row.count = count;
    row.filter = filter;
    return row;
}

@end

/// Regular row: icon, title and a trailing count.
@interface POSidebarCellView : NSTableCellView
@property (nonatomic, readonly) NSTextField *countLabel;
/// Side of the icon, in points.
@property (nonatomic) CGFloat iconSize;
@end

@implementation POSidebarCellView {
    NSLayoutConstraint *_iconWidth, *_iconHeight;
}

- (void)setIconSize:(CGFloat)iconSize {
    _iconSize = iconSize;
    _iconWidth.constant = _iconHeight.constant = iconSize;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        NSImageView *imageView = [NSImageView new];
        NSTextField *textField = [NSTextField labelWithString:@""];
        textField.lineBreakMode = NSLineBreakByTruncatingTail;
        _countLabel = [NSTextField labelWithString:@""];
        _countLabel.textColor = NSColor.secondaryLabelColor;
        _countLabel.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
        _countLabel.alignment = NSTextAlignmentRight;
        for (NSView *view in @[imageView, textField, _countLabel]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:view];
        }
        self.imageView = imageView;
        self.textField = textField;
        [textField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [_countLabel setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [NSLayoutConstraint activateConstraints:@[
            [imageView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
            [imageView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            (_iconWidth = [imageView.widthAnchor constraintEqualToConstant:22]),
            (_iconHeight = [imageView.heightAnchor constraintEqualToConstant:22]),
            [textField.leadingAnchor constraintEqualToAnchor:imageView.trailingAnchor constant:6],
            [textField.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_countLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:textField.trailingAnchor constant:6],
            [_countLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
            [_countLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}

@end

/// Section header: title, an optional "+" and a chevron showing whether the section is collapsed.
@interface POSidebarHeaderCellView : NSTableCellView
@property (nonatomic, readonly) NSImageView *chevron;
@property (nonatomic, readonly) NSButton *addButton;
@end

@implementation POSidebarHeaderCellView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        NSTextField *label = [NSTextField labelWithString:@""];
        label.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightSemibold];
        label.textColor = NSColor.tertiaryLabelColor;
        _chevron = [NSImageView new];
        _chevron.contentTintColor = NSColor.tertiaryLabelColor;
        _chevron.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:9 weight:NSFontWeightBold];
        _addButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:POL(@"Добавить фильтр")] target:nil action:NULL];
        _addButton.bordered = NO;
        _addButton.contentTintColor = NSColor.secondaryLabelColor;
        _addButton.toolTip = POL(@"Добавить фильтр по объекту");
        for (NSView *view in @[label, _chevron, _addButton]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:view];
        }
        self.textField = label;
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
            [label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4],
            [_chevron.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
            [_chevron.centerYAnchor constraintEqualToAnchor:label.centerYAnchor],
            [_addButton.trailingAnchor constraintEqualToAnchor:_chevron.leadingAnchor constant:-8],
            [_addButton.centerYAnchor constraintEqualToAnchor:label.centerYAnchor],
            [label.trailingAnchor constraintLessThanOrEqualToAnchor:_addButton.leadingAnchor constant:-4],
        ]];
    }
    return self;
}

@end

static NSString *const POCollapsedSectionsKey = @"collapsedSidebarSections";
static NSString *const POSidebarScaleKey = @"sidebarScale";

@interface POSidebarViewController () <NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate>
@end

@implementation POSidebarViewController {
    NSTableView *_tableView;
    NSArray<POSidebarRow *> *_rows;
    NSSlider *_scaleSlider;
    POPlan *_plan;
    BOOL _updating;
}

- (void)loadView {
    _rows = @[];
    _selectedFilter = [POFilter filterWithKind:POFilterKindAll folder:nil];
    _nudityCount = -1;
    _similarCount = -1;
    _people = @[];
    _objectFilters = @[];

    _tableView = [NSTableView new];
    _tableView.style = NSTableViewStyleSourceList;
    _tableView.headerView = nil;
    _tableView.rowSizeStyle = NSTableViewRowSizeStyleCustom;
    _tableView.floatsGroupRows = NO;
    _tableView.allowsEmptySelection = NO;
    _tableView.dataSource = self;
    _tableView.target = self;
    _tableView.action = @selector(rowClicked:);
    _tableView.doubleAction = @selector(renameClickedPerson:);
    NSMenu *menu = [NSMenu new];
    [[menu addItemWithTitle:POL(@"Назвать…") action:@selector(renameClickedPerson:) keyEquivalent:@""] setTarget:self];
    [[menu addItemWithTitle:POL(@"Удалить фильтр") action:@selector(removeClickedObjectFilter:) keyEquivalent:@""] setTarget:self];
    [[menu addItemWithTitle:POL(@"Только фото без других людей") action:@selector(showClickedPersonAlone:) keyEquivalent:@""] setTarget:self];
    menu.delegate = self;
    _tableView.menu = menu;
    _tableView.delegate = self;
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    [_tableView addTableColumn:column];

    NSScrollView *scrollView = [NSScrollView new];
    scrollView.documentView = _tableView;
    scrollView.hasVerticalScroller = YES;
    scrollView.drawsBackground = NO;
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;

    CGFloat saved = [NSUserDefaults.standardUserDefaults doubleForKey:POSidebarScaleKey];
    _scale = saved >= 1 ? MIN(saved, 3) : 1;
    _scaleSlider = [NSSlider sliderWithValue:_scale minValue:1 maxValue:3 target:self action:@selector(scaleSliderChanged:)];
    _scaleSlider.controlSize = NSControlSizeMini;
    _scaleSlider.toolTip = POL(@"Размер строк и лиц в боковой панели (⌘+ и ⌘−)");
    _scaleSlider.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *container = [NSView new];
    [container addSubview:scrollView];
    [container addSubview:_scaleSlider];
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:container.topAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:_scaleSlider.topAnchor constant:-6],
        [_scaleSlider.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [_scaleSlider.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [_scaleSlider.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-10],
        [container.widthAnchor constraintGreaterThanOrEqualToConstant:190],
    ]];
    self.view = container;
}

- (void)setPlan:(POPlan *)plan selecting:(POFilter *)filter {
    (void)self.view;
    _plan = plan;
    NSMutableArray<POSidebarRow *> *rows = [NSMutableArray array];
    if (plan) {
        [rows addObject:[POSidebarRow rowWithTitle:POL(@"Медиатека")
                                        symbolName:@"photo.on.rectangle"
                                             count:plan.items.count
                                            filter:[POFilter filterWithKind:POFilterKindAll folder:nil]]];
        if (self.suggestedCount > 0) {
            [rows addObject:[POSidebarRow rowWithTitle:POL(@"Предполагаемые даты")
                                            symbolName:@"calendar.badge.clock"
                                                 count:self.suggestedCount
                                                filter:[POFilter filterWithKind:POFilterKindSuggested folder:nil]]];
        }
        [rows addObject:[POSidebarRow rowWithTitle:POL(@"Поиск по объектам")
                                        symbolName:@"text.magnifyingglass"
                                             count:-1
                                            filter:[POFilter filterWithKind:POFilterKindObjectSearch folder:nil]]];
        // Always there: selecting it is how the search by photo is found and started.
        [rows addObject:[POSidebarRow rowWithTitle:POL(@"Поиск по фото")
                                        symbolName:@"photo.badge.magnifyingglass"
                                             count:self.similarCount
                                            filter:[POFilter filterWithKind:POFilterKindSimilar folder:nil]]];
        [rows addObject:[POSidebarRow rowWithTitle:POL(@"Карта")
                                        symbolName:@"map"
                                             count:self.locatedCount
                                            filter:[POFilter filterWithKind:POFilterKindMap folder:nil]]];
        if (self.people.count) {
            [rows addObject:[POSidebarRow headerWithTitle:POL(@"Люди") key:@"people"]];
            // The long tail of people seen in a handful of photos would bury everything below.
            for (POPerson *person in [self.people subarrayWithRange:NSMakeRange(0, MIN(self.people.count, 30))]) {
                POSidebarRow *row = [POSidebarRow rowWithTitle:person.displayName
                                                    symbolName:person.isNamed ? @"person.crop.circle.fill" : @"person.crop.circle"
                                                         count:person.items.count
                                                        filter:[POFilter filterWithKind:POFilterKindPerson folder:person.key]];
                row.person = person;
                [rows addObject:row];
            }
        }
        POSidebarRow *objectsHeader = [POSidebarRow headerWithTitle:POL(@"Объекты") key:@"objects"];
        objectsHeader.showsAddButton = YES;
        [rows addObject:objectsHeader];
        for (NSDictionary *objectFilter in self.objectFilters) {
            [rows addObject:[POSidebarRow rowWithTitle:objectFilter[@"query"]
                                            symbolName:@"tag"
                                                 count:[objectFilter[@"count"] integerValue]
                                                filter:[POFilter filterWithKind:POFilterKindObject folder:objectFilter[@"query"]]]];
        }
        [rows addObject:[POSidebarRow headerWithTitle:POL(@"Проверить") key:@"attention"]];
        [rows addObject:[POSidebarRow rowWithTitle:POL(@"Без даты")
                                        symbolName:@"calendar.badge.exclamationmark"
                                             count:self.undatedCount
                                            filter:[POFilter filterWithKind:POFilterKindUndated folder:nil]]];
        [rows addObject:[POSidebarRow rowWithTitle:POL(@"Дубликаты")
                                        symbolName:@"square.on.square"
                                             count:plan.duplicateItems.count + self.similarCopyCount
                                            filter:[POFilter filterWithKind:POFilterKindDuplicates folder:nil]]];
        [rows addObject:[POSidebarRow rowWithTitle:POL(@"Миниатюры")
                                        symbolName:@"arrow.down.right.and.arrow.up.left"
                                             count:plan.tinyItems.count
                                            filter:[POFilter filterWithKind:POFilterKindTiny folder:nil]]];
        if (self.nudityCount >= 0) {
            [rows addObject:[POSidebarRow rowWithTitle:POL(@"Откровенные")
                                            symbolName:@"eye.slash"
                                                 count:self.nudityCount
                                                filter:[POFilter filterWithKind:POFilterKindNudity folder:nil]]];
        }
    }
    // Rows of collapsed sections are left out; their headers stay.
    NSArray<NSString *> *collapsed = [NSUserDefaults.standardUserDefaults stringArrayForKey:POCollapsedSectionsKey] ?: @[];
    NSMutableArray<POSidebarRow *> *visible = [NSMutableArray array];
    BOOL hidden = NO;
    for (POSidebarRow *row in rows) {
        if (!row.filter) hidden = [collapsed containsObject:row.sectionKey];
        if (!row.filter || !hidden) [visible addObject:row];
    }
    rows = visible;
    _rows = rows;

    _updating = YES;
    [_tableView reloadData];
    NSUInteger selected = [rows indexOfObjectPassingTest:^BOOL(POSidebarRow *row, NSUInteger index, BOOL *stop) {
        return row.filter && [row.filter isEqual:filter];
    }];
    if (selected == NSNotFound) selected = 0;
    if (rows.count) {
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:selected] byExtendingSelection:NO];
        _selectedFilter = rows[selected].filter;
    }
    _updating = NO;
}

- (void)setScale:(CGFloat)scale {
    (void)self.view;
    scale = MIN(MAX(scale, 1), 3);
    if (scale == _scale) return;
    _scale = scale;
    _scaleSlider.doubleValue = scale;
    [NSUserDefaults.standardUserDefaults setDouble:scale forKey:POSidebarScaleKey];
    NSInteger selected = _tableView.selectedRow;
    _updating = YES;
    [_tableView reloadData];   // row heights, icon sizes and fonts all depend on the scale
    if (selected >= 0) [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:selected] byExtendingSelection:NO];
    _updating = NO;
}

- (void)scaleSliderChanged:(NSSlider *)sender {
    self.scale = sender.doubleValue;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    return _rows[row].filter ? round(28 * _scale) : 28;
}

- (void)selectFilter:(POFilter *)filter {
    [self setPlan:_plan selecting:filter];
}

#pragma mark - Table view

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _rows.count;
}

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row {
    return _rows[row].filter == nil;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return _rows[row].filter != nil;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    POSidebarRow *model = _rows[row];
    if (!model.filter) {
        POSidebarHeaderCellView *cell = [tableView makeViewWithIdentifier:@"header" owner:self];
        if (!cell) {
            cell = [POSidebarHeaderCellView new];
            cell.identifier = @"header";
            cell.addButton.target = self;
            cell.addButton.action = @selector(addObjectFilter:);
        }
        BOOL collapsed = [[NSUserDefaults.standardUserDefaults stringArrayForKey:POCollapsedSectionsKey] containsObject:model.sectionKey];
        cell.textField.stringValue = model.title;
        cell.chevron.image = [NSImage imageWithSystemSymbolName:collapsed ? @"chevron.right" : @"chevron.down" accessibilityDescription:nil];
        cell.addButton.hidden = !model.showsAddButton;
        cell.toolTip = collapsed ? POL(@"Щёлкните, чтобы развернуть") : POL(@"Щёлкните, чтобы свернуть");
        return cell;
    }

    POSidebarCellView *cell = [tableView makeViewWithIdentifier:@"row" owner:self];
    if (!cell) {
        cell = [POSidebarCellView new];
        cell.identifier = @"row";
    }
    cell.textField.stringValue = model.title;
    // Text grows slower than the icons: the point of enlarging is to make the faces out.
    cell.textField.font = [NSFont systemFontOfSize:round(13 * (1 + (_scale - 1) * 0.3))];
    cell.iconSize = round(22 * _scale);
    cell.imageView.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:round(14 * _scale) weight:NSFontWeightRegular];
    cell.imageView.image = [NSImage imageWithSystemSymbolName:model.symbolName accessibilityDescription:nil];
    cell.countLabel.stringValue = model.count >= 0 ? PONumber(model.count) : @"";
    // A person's row shows their face in a circle; the symbol stays until the face has been cut out (or if it can't be).
    cell.imageView.wantsLayer = YES;
    cell.imageView.layer.masksToBounds = YES;
    cell.imageView.layer.cornerRadius = 0;
    cell.imageView.imageScaling = NSImageScaleProportionallyDown;
    cell.objectValue = model;
    if (model.person) {
        __weak POSidebarCellView *weakCell = cell;
        [POPeople faceThumbnailForPerson:model.person completion:^(NSImage *thumbnail) {
            POSidebarCellView *current = weakCell;
            if (!thumbnail || current.objectValue != model) return;   // the cell has been reused for another row
            current.imageView.image = thumbnail;
            current.imageView.imageScaling = NSImageScaleAxesIndependently;
            current.imageView.layer.cornerRadius = current.iconSize / 2;
        }];
    }
    return cell;
}

/// A click on a section header collapses or expands the section.
- (void)rowClicked:(id)sender {
    NSInteger row = _tableView.clickedRow;
    if (row < 0 || row >= (NSInteger)_rows.count || _rows[row].filter || !_rows[row].sectionKey) return;
    NSString *key = _rows[row].sectionKey;
    NSMutableArray<NSString *> *collapsed = [[NSUserDefaults.standardUserDefaults stringArrayForKey:POCollapsedSectionsKey] ?: @[] mutableCopy];
    if ([collapsed containsObject:key]) [collapsed removeObject:key]; else [collapsed addObject:key];
    [NSUserDefaults.standardUserDefaults setObject:collapsed forKey:POCollapsedSectionsKey];

    POFilter *before = _selectedFilter;
    [self setPlan:_plan selecting:before];
    // Collapsing the section that held the selection moves the selection to "all files".
    if (![_selectedFilter isEqual:before]) [self.delegate sidebar:self didSelectFilter:_selectedFilter];
}

- (void)addObjectFilter:(NSButton *)sender {
    [self.delegate sidebar:self addObjectFilterFromView:sender];
}

- (void)removeClickedObjectFilter:(id)sender {
    NSInteger row = _tableView.clickedRow;
    POFilter *filter = row >= 0 && row < (NSInteger)_rows.count ? _rows[row].filter : nil;
    if (filter.kind == POFilterKindObject) [self.delegate sidebar:self removeObjectFilter:filter.folder];
}

- (POPerson *)clickedPerson {
    NSInteger row = _tableView.clickedRow;
    POFilter *filter = row >= 0 && row < (NSInteger)_rows.count ? _rows[row].filter : nil;
    if (filter.kind != POFilterKindPerson) return nil;
    for (POPerson *person in self.people) {
        if ([person.key isEqualToString:filter.folder]) return person;
    }
    return nil;
}

- (void)renameClickedPerson:(id)sender {
    POPerson *person = [self clickedPerson];
    if (person) [self.delegate sidebar:self renamePerson:person];
}

/// The menu only makes sense on a person's row.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    NSInteger row = _tableView.clickedRow;
    POFilter *filter = row >= 0 && row < (NSInteger)_rows.count ? _rows[row].filter : nil;
    menu.itemArray[0].hidden = [self clickedPerson] == nil;
    menu.itemArray[1].hidden = filter.kind != POFilterKindObject;
    menu.itemArray[2].hidden = [self clickedPerson] == nil;
}

- (void)showClickedPersonAlone:(id)sender {
    POPerson *person = [self clickedPerson];
    if (person) [self.delegate sidebar:self showOnlyPersonAlone:person];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (_updating) return;
    NSInteger row = _tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)_rows.count || !_rows[row].filter) return;
    _selectedFilter = _rows[row].filter;
    [self.delegate sidebar:self didSelectFilter:_selectedFilter];
}

@end
