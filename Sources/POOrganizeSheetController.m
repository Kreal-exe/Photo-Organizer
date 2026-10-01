#import "POOrganizeSheetController.h"
#import "POStrings.h"

@interface POOrganizeSheetController () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation POOrganizeSheetController {
    POPlan *_plan;
    NSPopUpButton *_schemePopup;
    NSPopUpButton *_yearPopup;
    NSPopUpButton *_monthPopup;
    NSPopUpButton *_dayPopup;
    NSButton *_nestedCheckbox;
    NSButton *_duplicatesCheckbox;
    NSTextField *_duplicatesField;
    NSButton *_tinyCheckbox;
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

- (NSTextField *)folderField {
    NSTextField *field = [NSTextField textFieldWithString:@""];
    field.target = self;
    field.action = @selector(optionChanged:);
    [field.widthAnchor constraintEqualToConstant:200].active = YES;
    return field;
}

static NSTextField *POFormLabel(NSString *text) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.alignment = NSTextAlignmentRight;
    return label;
}

- (void)loadView {
    NSTextField *title = [NSTextField labelWithString:POL(@"Разложить по папкам")];
    title.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    NSTextField *subtitle = [NSTextField wrappingLabelWithString:
        [NSString stringWithFormat:POL(@"Папки будут созданы внутри «%@». Выберите, как группировать файлы и как назвать папки."), _plan.rootURL.lastPathComponent]];
    subtitle.textColor = NSColor.secondaryLabelColor;

    _schemePopup = [self popupWithTitles:@[POL(@"По годам"), POL(@"По месяцам"), POL(@"По дням")]];
    _yearPopup = [self popupWithTitles:@[@"2024", POL(@"2024 год")]];
    _monthPopup = [self popupWithTitles:@[@"2024-03", POL(@"2024-03 Март"), POL(@"03 Март"), POL(@"Март 2024")]];
    _dayPopup = [self popupWithTitles:@[@"2024-03-15", @"15", POL(@"15 марта")]];
    _nestedCheckbox = [NSButton checkboxWithTitle:POL(@"Вкладывать папки друг в друга (год → месяц → день)") target:self action:@selector(optionChanged:)];
    _duplicatesCheckbox = [NSButton checkboxWithTitle:POL(@"Дубликаты — в папку:") target:self action:@selector(optionChanged:)];
    _duplicatesField = [self folderField];
    _tinyCheckbox = [NSButton checkboxWithTitle:POL(@"Миниатюры — в папку:") target:self action:@selector(optionChanged:)];
    _tinyField = [self folderField];

    NSGridView *form = [NSGridView gridViewWithViews:@[
        @[POFormLabel(POL(@"Группировать:")), _schemePopup],
        @[POFormLabel(POL(@"Название года:")), _yearPopup],
        @[POFormLabel(POL(@"Название месяца:")), _monthPopup],
        @[POFormLabel(POL(@"Название дня:")), _dayPopup],
        @[NSGridCell.emptyContentView, _nestedCheckbox],
        @[_duplicatesCheckbox, _duplicatesField],
        @[_tinyCheckbox, _tinyField],
    ]];
    form.rowAlignment = NSGridRowAlignmentFirstBaseline;
    form.rowSpacing = 8;
    form.columnSpacing = 8;
    [form columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [form columnAtIndex:1].xPlacement = NSGridCellPlacementLeading;

    NSTextField *previewTitle = [NSTextField labelWithString:POL(@"Что получится")];
    previewTitle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _resetButton = [NSButton buttonWithTitle:POL(@"Сбросить названия") target:self action:@selector(resetNames:)];
    _resetButton.controlSize = NSControlSizeSmall;
    _resetButton.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    NSStackView *previewHeader = [NSStackView stackViewWithViews:@[previewTitle, [NSView new], _resetButton]];

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

    NSScrollView *scrollView = [NSScrollView new];
    scrollView.documentView = _tableView;
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSBezelBorder;
    [scrollView.heightAnchor constraintEqualToConstant:210].active = YES;

    NSTextField *hint = [NSTextField wrappingLabelWithString:
        POL(@"Щёлкните по названию, чтобы переименовать папку (можно с вложенностью: «Отпуск/Море»). "
        @"Одинаковые названия объединят папки, пустое вернёт исходное.")];
    hint.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    hint.textColor = NSColor.secondaryLabelColor;

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

    NSStackView *stack = [NSStackView stackViewWithViews:@[title, subtitle, form, previewHeader, scrollView, hint, footer]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    [stack setCustomSpacing:4 afterView:title];
    [stack setCustomSpacing:16 afterView:subtitle];
    [stack setCustomSpacing:18 afterView:form];
    [stack setCustomSpacing:6 afterView:scrollView];
    [stack setCustomSpacing:16 afterView:hint];
    for (NSView *wide in @[subtitle, previewHeader, scrollView, hint, footer]) {
        [wide.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-40].active = YES;
    }
    [stack.widthAnchor constraintEqualToConstant:600].active = YES;
    self.view = stack;
    [self refresh];
}

#pragma mark - Model ↔ controls

- (void)refresh {
    [_schemePopup selectItemAtIndex:_plan.scheme];
    [_yearPopup selectItemAtIndex:_plan.yearStyle];
    [_monthPopup selectItemAtIndex:_plan.monthStyle];
    [_dayPopup selectItemAtIndex:_plan.dayStyle];
    _monthPopup.enabled = _plan.scheme >= POSchemeYearMonth;
    _dayPopup.enabled = _plan.scheme >= POSchemeYearMonthDay;
    _nestedCheckbox.state = _plan.nested ? NSControlStateValueOn : NSControlStateValueOff;
    _nestedCheckbox.enabled = _plan.scheme != POSchemeYear;
    _duplicatesCheckbox.state = _plan.separateDuplicates ? NSControlStateValueOn : NSControlStateValueOff;
    _duplicatesField.stringValue = _plan.duplicatesFolderName;
    _duplicatesField.enabled = _plan.separateDuplicates;
    _tinyCheckbox.state = _plan.separateTiny ? NSControlStateValueOn : NSControlStateValueOff;
    _tinyField.stringValue = _plan.tinyFolderName;
    _tinyField.enabled = _plan.separateTiny;
    _resetButton.hidden = !_plan.hasCustomNames;
    [_tableView reloadData];

    NSUInteger pending = _plan.pendingItems.count;
    NSString *what = pending
        ? [NSString stringWithFormat:POL(@"Будет перемещено %@ из %@ в %@."), PONumber(pending), PONumber(_plan.items.count),
           POCount(_plan.groups.count, POL(@"папку"), POL(@"папки"), POL(@"папок"))]
        : POL(@"Все файлы уже лежат на своих местах.");
    _summaryLabel.stringValue = [what stringByAppendingString:
        POL(@" Оригиналы перемещаются, а не копируются; ничего не удаляется и не перезаписывается. Отменить — ⌘Z.")];
    _confirmButton.enabled = pending > 0;
}

- (void)planChanged {
    [_plan rebuild];
    [_plan saveOptionsToDefaults];
    [self refresh];
    if (self.onChange) self.onChange();
}

- (void)optionChanged:(id)sender {
    _plan.scheme = _schemePopup.indexOfSelectedItem;
    _plan.yearStyle = _yearPopup.indexOfSelectedItem;
    _plan.monthStyle = _monthPopup.indexOfSelectedItem;
    _plan.dayStyle = _dayPopup.indexOfSelectedItem;
    _plan.nested = _nestedCheckbox.state == NSControlStateValueOn;
    _plan.separateDuplicates = _duplicatesCheckbox.state == NSControlStateValueOn;
    _plan.separateTiny = _tinyCheckbox.state == NSControlStateValueOn;
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
    if (_plan.pendingItems.count) [self finish:YES];
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
