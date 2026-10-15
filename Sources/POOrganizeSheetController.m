#import "POOrganizeSheetController.h"
#import "POStrings.h"

@interface POOrganizeSheetController () <NSTableViewDataSource, NSTableViewDelegate>
@end

/// Lays out from the top, as a scrolled page does.
@interface POFlippedView : NSView
@end

@implementation POFlippedView
- (BOOL)isFlipped { return YES; }
@end

@implementation POOrganizeSheetController {
    NSView *_options, *_footer;   // for the size the window opens at
    BOOL _sized;
    POPlan *_plan;
    NSTextField *_destinationLabel;
    NSSegmentedControl *_modeControl;
    NSButton *_photosCheckbox, *_videosCheckbox, *_screenshotKindCheckbox, *_picturesCheckbox, *_collagesCheckbox;
    NSButton *_removeUnorganizedCheckbox;
    NSPopUpButton *_arrangementPopup;
    NSButton *_datesInsideCheckbox;
    NSPopUpButton *_schemePopup, *_yearPopup, *_monthPopup, *_dayPopup;
    NSButton *_nestedCheckbox;
    NSButton *_screenshotsCheckbox;
    NSTextField *_screenshotsField;
    NSPopUpButton *_screenshotsPlacePopup;
    NSButton *_removeDuplicatesCheckbox, *_duplicatesCheckbox;
    NSTextField *_duplicatesField;
    NSButton *_removeTinyCheckbox, *_tinyCheckbox;
    NSTextField *_tinyField;
    NSTableView *_tableView;
    NSButton *_resetButton;
    NSTextField *_summaryLabel;
    NSButton *_confirmButton;
}

- (instancetype)initWithPlan:(POPlan *)plan {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _plan = plan;
    }
    return self;
}

#pragma mark - View

- (NSPopUpButton *)popupWithTitles:(NSArray<NSString *> *)titles {
    NSPopUpButton *popup = [NSPopUpButton new];
    [popup addItemsWithTitles:titles];
    popup.target = self;
    popup.action = @selector(optionChanged:);
    return popup;
}

- (NSButton *)checkbox:(NSString *)title {
    return [NSButton checkboxWithTitle:title target:self action:@selector(optionChanged:)];
}

- (NSTextField *)folderField {
    NSTextField *field = [NSTextField textFieldWithString:@""];
    field.target = self;
    field.action = @selector(optionChanged:);
    [field.widthAnchor constraintEqualToConstant:180].active = YES;
    return field;
}

static NSTextField *POFormLabel(NSString *text) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.alignment = NSTextAlignmentRight;
    return label;
}

static NSStackView *PORow(NSArray<NSView *> *views) {
    NSStackView *row = [NSStackView stackViewWithViews:views];
    row.spacing = 8;
    return row;
}

/// A second line under a checkbox, set in by the width of the box, so that it reads as depending on it.
static NSStackView *POIndented(NSArray<NSView *> *views) {
    NSView *indent = [NSView new];
    [indent.widthAnchor constraintEqualToConstant:20].active = YES;
    return PORow([@[indent] arrayByAddingObjectsFromArray:views]);
}

- (void)loadView {
    // Header.
    NSTextField *title = [NSTextField labelWithString:POL(@"Разложить по папкам")];
    title.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    NSTextField *subtitle = [NSTextField wrappingLabelWithString:_plan.sourceURLs.count > 1
        ? [NSString stringWithFormat:POL(@"Файлы из %@ будут сложены в одну папку. Выберите, куда, как группировать файлы и как назвать папки."),
           POCount(_plan.sourceURLs.count, POL(@"папки"), POL(@"папок"), POL(@"папок"))]
        : POL(@"Выберите, куда сложить файлы, как их группировать и как назвать папки.")];
    subtitle.textColor = NSColor.secondaryLabelColor;

    // Where, and moved or copied.
    _destinationLabel = [NSTextField labelWithString:_plan.rootURL.path.stringByAbbreviatingWithTildeInPath];
    _destinationLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _destinationLabel.lineBreakMode = NSLineBreakByTruncatingHead;
    [_destinationLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_destinationLabel.widthAnchor constraintLessThanOrEqualToConstant:260].active = YES;
    NSButton *changeDestination = [NSButton buttonWithTitle:POL(@"Изменить…") target:self action:@selector(chooseDestination:)];
    _modeControl = [NSSegmentedControl segmentedControlWithLabels:@[POL(@"Переместить"), POL(@"Копировать")]
                                                    trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(modeChanged:)];
    _modeControl.toolTip = POL(@"Переместить — оригиналы переезжают в новые папки. Копировать — оригиналы остаются на месте, "
                               @"в папках появляются их копии (на диске APFS копии почти не занимают места).");

    // What: each kind when ticked — unticked, it stays where it is.
    _photosCheckbox = [self checkbox:POL(@"Фото")];
    _videosCheckbox = [self checkbox:POL(@"Видео")];
    _screenshotKindCheckbox = [self checkbox:POL(@"Скриншоты")];
    _screenshotKindCheckbox.toolTip = POL(@"Снимки экрана, и те, что пришли через мессенджер. Без галочки остаются на месте.");
    _picturesCheckbox = [self checkbox:POL(@"Картинки")];
    _picturesCheckbox.toolTip = POL(@"Открытки, мемы, рисунки, документы — то, что не фотография. Без галочки остаются на месте.");
    _collagesCheckbox = [self checkbox:POL(@"Коллажи")];
    _collagesCheckbox.toolTip = POL(@"Коллажи, рамки, анимации, фильмы и правки, которые сделал Google Фото. Без галочки остаются на месте.");
    NSStackView *kinds = [NSStackView stackViewWithViews:@[PORow(@[_photosCheckbox, _videosCheckbox, _screenshotKindCheckbox]),
                                                           PORow(@[_picturesCheckbox, _collagesCheckbox])]];
    kinds.orientation = NSUserInterfaceLayoutOrientationVertical;
    kinds.alignment = NSLayoutAttributeLeading;
    kinds.spacing = 6;
    for (NSStackView *row in kinds.arrangedSubviews) row.spacing = 16;
    _removeUnorganizedCheckbox = [self checkbox:POL(@"Неотмеченное — удалить в Корзину")];
    _removeUnorganizedCheckbox.toolTip = POL(@"Без галочки неотмеченные виды остаются на месте. С ней — уходят в Корзину (при переносе; при копировании ничего не удаляется), их можно вернуть оттуда.");

    // How.
    _arrangementPopup = [self popupWithTitles:@[POL(@"По датам"), POL(@"По типам"), POL(@"По людям"), POL(@"По форматам")]];
    _arrangementPopup.toolTip = POL(@"По типам: скриншоты, записи экрана, WhatsApp, Telegram, видео, анимации, панорамы, RAW, фото. По людям: фото, где узнан ровно один названный человек, — в папку с его именем, остальное по датам. По форматам: JPEG, HEIC, PNG, MOV…");
    _datesInsideCheckbox = [self checkbox:POL(@"Внутри — по датам")];
    _schemePopup = [self popupWithTitles:@[POL(@"По годам"), POL(@"По месяцам"), POL(@"По дням")]];
    _yearPopup = [self popupWithTitles:@[@"2024", POL(@"2024 год")]];
    _monthPopup = [self popupWithTitles:@[@"2024-03", POL(@"2024-03 Март"), POL(@"03 Март"), POL(@"Март 2024")]];
    _dayPopup = [self popupWithTitles:@[@"2024-03-15", @"15", POL(@"15 марта")]];
    _nestedCheckbox = [self checkbox:POL(@"Вкладывать папки друг в друга (год → месяц → день)")];

    // Screenshots, duplicates, thumbnails: what happens to each, and under it, set in, where they go otherwise.
    _screenshotsCheckbox = [self checkbox:POL(@"В отдельную папку")];
    _screenshotsField = [self folderField];
    _screenshotsPlacePopup = [self popupWithTitles:@[POL(@"Одна папка, даты внутри"), POL(@"Внутри папки каждой даты")]];
    _removeDuplicatesCheckbox = [self checkbox:POL(@"Удалить в Корзину")];
    _removeDuplicatesCheckbox.toolTip = POL(@"Точные копии и уменьшенные или пережатые версии снимка при переносе уходят в Корзину (при копировании — не копируются): раскладывается только оригинал или лучшая версия. Копия удаляется, только если её оригинал остаётся.");
    _duplicatesCheckbox = [self checkbox:POL(@"Иначе — в папку:")];
    _duplicatesField = [self folderField];
    _removeTinyCheckbox = [self checkbox:POL(@"Удалить в Корзину")];
    _removeTinyCheckbox.toolTip = POL(@"Уменьшенные копии других фото уходят в Корзину, только если их большая версия остаётся.");
    _tinyCheckbox = [self checkbox:POL(@"Иначе — в папку:")];
    _tinyField = [self folderField];

    // One column of labels, one of controls: every checkbox starts on the same line.
    NSGridView *form = [NSGridView gridViewWithViews:@[
        @[POFormLabel(POL(@"Куда сложить:")), PORow(@[_destinationLabel, changeDestination])],
        @[POFormLabel(POL(@"Файлы:")), _modeControl],
        @[POFormLabel(POL(@"Что раскладывать:")), kinds],
        @[NSGridCell.emptyContentView, _removeUnorganizedCheckbox],
        @[POFormLabel(POL(@"Раскладывать:")), PORow(@[_arrangementPopup, _datesInsideCheckbox])],
        @[POFormLabel(POL(@"Группировать:")), _schemePopup],
        @[POFormLabel(POL(@"Названия папок:")), PORow(@[_yearPopup, _monthPopup, _dayPopup])],
        @[NSGridCell.emptyContentView, _nestedCheckbox],
        @[POFormLabel(POL(@"Скриншоты:")), _screenshotsCheckbox],
        @[NSGridCell.emptyContentView, POIndented(@[_screenshotsField, _screenshotsPlacePopup])],
        @[POFormLabel(POL(@"Дубликаты:")), _removeDuplicatesCheckbox],
        @[NSGridCell.emptyContentView, POIndented(@[_duplicatesCheckbox, _duplicatesField])],
        @[POFormLabel(POL(@"Миниатюры:")), _removeTinyCheckbox],
        @[NSGridCell.emptyContentView, POIndented(@[_tinyCheckbox, _tinyField])],
    ]];
    form.rowAlignment = NSGridRowAlignmentFirstBaseline;
    form.rowSpacing = 10;
    form.columnSpacing = 10;
    [form columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [form columnAtIndex:1].xPlacement = NSGridCellPlacementLeading;
    // Room between the groups: where and what, how, and the special files.
    for (NSNumber *row in @[@2, @4, @8]) [form rowAtIndex:row.integerValue].topPadding = 10;
    // A grid takes whatever room it is given; it keeps its own size.
    NSSize formSize = form.fittingSize;
    [form.widthAnchor constraintEqualToConstant:formSize.width].active = YES;
    [form.heightAnchor constraintEqualToConstant:formSize.height].active = YES;

    // The options scroll when the window is shorter than they are.
    POFlippedView *document = [POFlippedView new];
    form.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview:form];
    NSScrollView *optionsScroller = [NSScrollView new];
    optionsScroller.hasVerticalScroller = YES;
    optionsScroller.autohidesScrollers = YES;
    optionsScroller.drawsBackground = NO;
    optionsScroller.documentView = document;
    document.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [form.topAnchor constraintEqualToAnchor:document.topAnchor],
        [form.leadingAnchor constraintEqualToAnchor:document.leadingAnchor],
        [form.trailingAnchor constraintEqualToAnchor:document.trailingAnchor],
        [form.bottomAnchor constraintEqualToAnchor:document.bottomAnchor],
        [document.topAnchor constraintEqualToAnchor:optionsScroller.contentView.topAnchor],
        [document.leadingAnchor constraintEqualToAnchor:optionsScroller.contentView.leadingAnchor],
        [optionsScroller.widthAnchor constraintEqualToConstant:formSize.width + 16],
    ]];

    // What it comes to: the folders, renamed by clicking.
    NSTextField *previewTitle = [NSTextField labelWithString:POL(@"Что получится")];
    previewTitle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _resetButton = [NSButton buttonWithTitle:POL(@"Сбросить названия") target:self action:@selector(resetNames:)];
    _resetButton.controlSize = NSControlSizeSmall;
    _resetButton.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    NSView *headerSpacer = [NSView new];
    [headerSpacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *previewHeader = [NSStackView stackViewWithViews:@[previewTitle, headerSpacer, _resetButton]];

    _tableView = [NSTableView new];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.usesAlternatingRowBackgroundColors = YES;
    _tableView.rowHeight = 24;
    _tableView.style = NSTableViewStyleInset;
    NSTableColumn *folderColumn = [[NSTableColumn alloc] initWithIdentifier:@"folder"];
    folderColumn.title = POL(@"Папка");
    folderColumn.resizingMask = NSTableColumnAutoresizingMask;
    NSTableColumn *countColumn = [[NSTableColumn alloc] initWithIdentifier:@"count"];
    countColumn.title = POL(@"Файлов");
    countColumn.width = 70;
    countColumn.resizingMask = NSTableColumnNoResizing;
    [_tableView addTableColumn:folderColumn];
    [_tableView addTableColumn:countColumn];
    _tableView.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    NSScrollView *tableScroller = [NSScrollView new];
    tableScroller.documentView = _tableView;
    tableScroller.hasVerticalScroller = YES;
    tableScroller.borderType = NSBezelBorder;
    NSTextField *hint = [NSTextField wrappingLabelWithString:
        POL(@"Щёлкните по названию, чтобы переименовать папку (можно с вложенностью: «Отпуск/Море»). "
        @"Одинаковые названия объединят папки, пустое вернёт исходное.")];
    hint.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    hint.textColor = NSColor.secondaryLabelColor;
    NSStackView *preview = [NSStackView stackViewWithViews:@[previewHeader, tableScroller, hint]];
    preview.orientation = NSUserInterfaceLayoutOrientationVertical;
    preview.alignment = NSLayoutAttributeLeading;
    preview.spacing = 6;
    for (NSView *wide in @[previewHeader, tableScroller, hint]) {
        [wide.widthAnchor constraintEqualToAnchor:preview.widthAnchor].active = YES;
    }
    [tableScroller setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    [tableScroller.widthAnchor constraintGreaterThanOrEqualToConstant:260].active = YES;

    // The buttons and what they will do.
    _summaryLabel = [NSTextField wrappingLabelWithString:@""];
    _summaryLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    NSButton *cancelButton = [NSButton buttonWithTitle:POL(@"Отмена") target:self action:@selector(cancel:)];
    cancelButton.keyEquivalent = @"\e";
    _confirmButton = [NSButton buttonWithTitle:POL(@"Разложить") target:self action:@selector(confirm:)];
    _confirmButton.keyEquivalent = @"\r";
    NSStackView *footer = [NSStackView stackViewWithViews:@[_summaryLabel, cancelButton, _confirmButton]];
    footer.spacing = 10;
    footer.alignment = NSLayoutAttributeBottom;
    [_summaryLabel setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_summaryLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    // Header on top, options on the left and the folders on the right, buttons below.
    NSView *root = [NSView new];
    NSArray<NSView *> *parts = @[title, subtitle, optionsScroller, preview, footer];
    for (NSView *part in parts) {
        part.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:part];
    }
    NSLayoutConstraint *optionsHeight = [optionsScroller.heightAnchor constraintEqualToConstant:formSize.height];
    optionsHeight.priority = NSLayoutPriorityDefaultLow - 1;   // as tall as the options, unless the window is smaller
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:root.topAnchor constant:20],
        [title.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [subtitle.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [subtitle.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20],
        [optionsScroller.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:18],
        [optionsScroller.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:12],
        [optionsScroller.heightAnchor constraintGreaterThanOrEqualToConstant:160],
        optionsHeight,
        [preview.topAnchor constraintEqualToAnchor:optionsScroller.topAnchor],
        [preview.leadingAnchor constraintEqualToAnchor:optionsScroller.trailingAnchor constant:16],
        [preview.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20],
        [preview.bottomAnchor constraintEqualToAnchor:optionsScroller.bottomAnchor],
        [footer.topAnchor constraintEqualToAnchor:optionsScroller.bottomAnchor constant:16],
        [footer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [footer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20],
        [footer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-20],
    ]];
    _options = form;
    _footer = footer;
    self.view = root;
    [self refresh];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    NSWindow *window = self.view.window;
    window.styleMask |= NSWindowStyleMaskResizable;
    window.contentMinSize = NSMakeSize(_options.fittingSize.width + 340, 360);
    // It opens at least half the screen each way — as tall as all the options when that fits, up to 90 % of the
    // screen — in the middle of it.
    if (_sized) return;
    _sized = YES;
    NSRect visible = (window.screen ?: NSScreen.mainScreen).visibleFrame;
    CGFloat contentHeight = 20 + 40 + 18 + _options.fittingSize.height + 16 + _footer.fittingSize.height + 20;
    CGFloat contentWidth = _options.fittingSize.width + 16 + 12 + 16 + 420 + 20;
    NSRect content = NSMakeRect(0, 0, MIN(MAX(contentWidth, visible.size.width * 0.5), visible.size.width),
                                MIN(MAX(contentHeight, visible.size.height * 0.5), visible.size.height * 0.9));
    NSRect frame = [window frameRectForContentRect:content];
    frame.size.height = MIN(frame.size.height, visible.size.height);
    frame.origin.x = NSMidX(visible) - frame.size.width / 2;
    frame.origin.y = NSMidY(visible) - frame.size.height / 2;
    [window setFrame:frame display:YES];
}

- (void)chooseDestination:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.canCreateDirectories = YES;
    panel.message = POL(@"Куда сложить файлы");
    panel.prompt = POL(@"Выбрать");
    panel.directoryURL = _plan.rootURL;
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        [self->_plan setDestinationURL:panel.URL];
        self->_destinationLabel.stringValue = self->_plan.rootURL.path.stringByAbbreviatingWithTildeInPath;
        [self planChanged];
    }];
}

#pragma mark - Model ↔ controls

- (void)refresh {
    [_arrangementPopup selectItemAtIndex:_plan.arrangement];
    _datesInsideCheckbox.state = _plan.datesInside ? NSControlStateValueOn : NSControlStateValueOff;
    _datesInsideCheckbox.enabled = _plan.arrangement != POArrangementDate;
    _photosCheckbox.state = _plan.organizesPhotos ? NSControlStateValueOn : NSControlStateValueOff;
    _videosCheckbox.state = _plan.organizesVideos ? NSControlStateValueOn : NSControlStateValueOff;
    _picturesCheckbox.state = _plan.organizesPictures ? NSControlStateValueOn : NSControlStateValueOff;
    _collagesCheckbox.state = _plan.organizesCollages ? NSControlStateValueOn : NSControlStateValueOff;
    _screenshotKindCheckbox.state = _plan.organizesScreenshots ? NSControlStateValueOn : NSControlStateValueOff;
    _removeUnorganizedCheckbox.state = _plan.removesUnorganized ? NSControlStateValueOn : NSControlStateValueOff;
    _removeUnorganizedCheckbox.enabled = !_plan.copiesFiles;
    _screenshotsCheckbox.state = _plan.separateScreenshots ? NSControlStateValueOn : NSControlStateValueOff;
    _screenshotsField.stringValue = _plan.screenshotsFolderName;
    _screenshotsField.enabled = _plan.separateScreenshots;
    [_screenshotsPlacePopup selectItemAtIndex:_plan.screenshotsInEachDate ? 1 : 0];
    _screenshotsPlacePopup.enabled = _plan.separateScreenshots;
    [_schemePopup selectItemAtIndex:_plan.scheme];
    [_yearPopup selectItemAtIndex:_plan.yearStyle];
    [_monthPopup selectItemAtIndex:_plan.monthStyle];
    [_dayPopup selectItemAtIndex:_plan.dayStyle];
    _monthPopup.enabled = _plan.scheme >= POSchemeYearMonth;
    _dayPopup.enabled = _plan.scheme >= POSchemeYearMonthDay;
    _nestedCheckbox.state = _plan.nested ? NSControlStateValueOn : NSControlStateValueOff;
    _nestedCheckbox.enabled = _plan.scheme != POSchemeYear;
    _removeDuplicatesCheckbox.state = _plan.removesDuplicates ? NSControlStateValueOn : NSControlStateValueOff;
    _duplicatesCheckbox.state = _plan.separateDuplicates ? NSControlStateValueOn : NSControlStateValueOff;
    _duplicatesField.stringValue = _plan.duplicatesFolderName;
    // What goes to the Trash needs no folder of its own: the line under it only counts when it is not ticked.
    _duplicatesCheckbox.enabled = !_plan.removesDuplicates;
    _duplicatesField.enabled = _plan.separateDuplicates && !_plan.removesDuplicates;
    _removeTinyCheckbox.state = _plan.removesTiny ? NSControlStateValueOn : NSControlStateValueOff;
    _tinyCheckbox.state = _plan.separateTiny ? NSControlStateValueOn : NSControlStateValueOff;
    _tinyField.stringValue = _plan.tinyFolderName;
    _tinyCheckbox.enabled = !_plan.removesTiny;
    _tinyField.enabled = _plan.separateTiny && !_plan.removesTiny;
    _resetButton.hidden = !_plan.hasCustomNames;
    [_tableView reloadData];

    BOOL copies = _plan.copiesFiles;
    _modeControl.selectedSegment = copies ? 1 : 0;
    NSUInteger pending = _plan.pendingItems.count;
    NSString *what = pending
        ? [NSString stringWithFormat:copies ? POL(@"Будет скопировано %@ из %@ в %@.") : POL(@"Будет перемещено %@ из %@ в %@."),
           PONumber(pending), PONumber(_plan.items.count), POCount(_plan.groups.count, POL(@"папку"), POL(@"папки"), POL(@"папок"))]
        : POL(@"Все файлы уже лежат на своих местах.");
    NSUInteger toTrash = _plan.duplicatesToRemove.count + _plan.unorganizedToRemove.count;
    if (toTrash) {
        what = [what stringByAppendingFormat:POL(@" В Корзину: %@."), PONumber(toTrash)];
    }
    if (_plan.merging && !copies) {
        what = [what stringByAppendingFormat:POL(@" Что уже лежит в «%@», остаётся как есть; из других папок добавляется только то, чего в ней нет, а копии того, что в ней есть, идут в Корзину."),
                _plan.rootURL.lastPathComponent];
    }
    _summaryLabel.stringValue = [what stringByAppendingString:copies
        ? POL(@" Оригиналы остаются на месте; копии ничего не перезаписывают, уже скопированные файлы пропускаются. Отменить — ⌘Z.")
        : toTrash
        ? POL(@" Оригиналы перемещаются, а не копируются; ничего не перезаписывается, удалённое можно вернуть из Корзины. Отменить перенос — ⌘Z.")
        : POL(@" Оригиналы перемещаются, а не копируются; ничего не удаляется и не перезаписывается. Отменить — ⌘Z.")];
    _confirmButton.title = copies ? POL(@"Скопировать") : POL(@"Разложить");
    _confirmButton.enabled = pending > 0 || toTrash > 0;
}

- (void)modeChanged:(id)sender {
    _plan.copiesFiles = _modeControl.selectedSegment == 1;
    [self planChanged];
}

- (void)planChanged {
    [_plan rebuild];
    [_plan saveOptionsToDefaults];
    [self refresh];
    if (self.onChange) self.onChange();
}

- (void)optionChanged:(id)sender {
    _plan.arrangement = _arrangementPopup.indexOfSelectedItem;
    _plan.datesInside = _datesInsideCheckbox.state == NSControlStateValueOn;
    _plan.organizesPhotos = _photosCheckbox.state == NSControlStateValueOn;
    _plan.organizesVideos = _videosCheckbox.state == NSControlStateValueOn;
    _plan.organizesPictures = _picturesCheckbox.state == NSControlStateValueOn;
    _plan.organizesCollages = _collagesCheckbox.state == NSControlStateValueOn;
    _plan.organizesScreenshots = _screenshotKindCheckbox.state == NSControlStateValueOn;
    _plan.removesUnorganized = _removeUnorganizedCheckbox.state == NSControlStateValueOn;
    _plan.separateScreenshots = _screenshotsCheckbox.state == NSControlStateValueOn;
    _plan.screenshotsInEachDate = _screenshotsPlacePopup.indexOfSelectedItem == 1;
    _plan.screenshotsFolderName = _screenshotsField.stringValue;
    _plan.scheme = _schemePopup.indexOfSelectedItem;
    _plan.yearStyle = _yearPopup.indexOfSelectedItem;
    _plan.monthStyle = _monthPopup.indexOfSelectedItem;
    _plan.dayStyle = _dayPopup.indexOfSelectedItem;
    _plan.nested = _nestedCheckbox.state == NSControlStateValueOn;
    _plan.separateDuplicates = _duplicatesCheckbox.state == NSControlStateValueOn;
    _plan.removesDuplicates = _removeDuplicatesCheckbox.state == NSControlStateValueOn;
    _plan.separateTiny = _tinyCheckbox.state == NSControlStateValueOn;
    _plan.removesTiny = _removeTinyCheckbox.state == NSControlStateValueOn;
    _plan.duplicatesFolderName = _duplicatesField.stringValue;
    _plan.tinyFolderName = _tinyField.stringValue;
    [self planChanged];
}

- (void)resetNames:(id)sender {
    [_plan removeCustomNames];
    [self planChanged];
}

- (void)folderNameEdited:(NSTextField *)sender {
    NSInteger row = [_tableView rowForView:sender];
    if (row < 0 || row >= (NSInteger)_plan.groups.count) return;
    POGroup *group = _plan.groups[row];
    if ([sender.stringValue isEqualToString:group.folder]) return;
    [_plan setCustomName:sender.stringValue forGroup:group];
    [self planChanged];
}

#pragma mark - Buttons

- (void)finish:(BOOL)confirmed {
    [self.presentingViewController dismissViewController:self];
    if (self.completion) self.completion(confirmed);
}

- (void)cancel:(id)sender {
    [self finish:NO];
}

- (void)confirm:(id)sender {
    // Commits a folder name that is still being typed.
    if (![self.view.window makeFirstResponder:nil]) return;
    // Files to put in place, or only duplicates to take to the Trash ("Удалить дубликаты").
    if (_plan.pendingItems.count || _plan.duplicatesToRemove.count || _plan.unorganizedToRemove.count) [self finish:YES];
}

#pragma mark - Table view

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _plan.groups.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    POGroup *group = _plan.groups[row];
    BOOL isFolderColumn = [tableColumn.identifier isEqualToString:@"folder"];
    NSTableCellView *cell = [tableView makeViewWithIdentifier:tableColumn.identifier owner:self];
    if (!cell) {
        cell = [NSTableCellView new];
        cell.identifier = tableColumn.identifier;
        NSTextField *field = [NSTextField labelWithString:@""];
        field.translatesAutoresizingMaskIntoConstraints = NO;
        field.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [cell addSubview:field];
        cell.textField = field;
        NSLayoutXAxisAnchor *leading = cell.leadingAnchor;
        CGFloat leadingGap = 2;
        if (isFolderColumn) {
            field.editable = YES;
            field.target = self;
            field.action = @selector(folderNameEdited:);
            NSImageView *icon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"folder" accessibilityDescription:nil]];
            icon.contentTintColor = NSColor.controlAccentColor;
            icon.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:icon];
            cell.imageView = icon;
            [NSLayoutConstraint activateConstraints:@[
                [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
                [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
                [icon.widthAnchor constraintEqualToConstant:18],
            ]];
            leading = icon.trailingAnchor;
            leadingGap = 5;
        } else {
            field.alignment = NSTextAlignmentRight;
            field.textColor = NSColor.secondaryLabelColor;
            field.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular];
        }
        [NSLayoutConstraint activateConstraints:@[
            [field.leadingAnchor constraintEqualToAnchor:leading constant:leadingGap],
            [field.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
            [field.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    cell.textField.stringValue = isFolderColumn ? group.folder : PONumber(group.items.count);
    return cell;
}

@end
