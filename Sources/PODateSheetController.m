#import "PODateSheetController.h"
#import "POStrings.h"

@implementation PODateSheetController {
    NSUInteger _count;
    NSArray<PODateSuggestion *> *_suggestions;
    NSDate *_initialDate;
    BOOL _canRemove;
    NSMutableArray<NSButton *> *_radios;   // one per suggestion, then "Другая дата"
    NSPopUpButton *_precisionPopup;
    NSDatePicker *_datePicker;
}

- (instancetype)initWithItemCount:(NSUInteger)count suggestions:(NSArray<PODateSuggestion *> *)suggestions
                      initialDate:(NSDate *)date canRemove:(BOOL)canRemove {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _count = count;
        _suggestions = [suggestions copy];
        _initialDate = date;
        _canRemove = canRemove;
        _radios = [NSMutableArray array];
    }
    return self;
}

- (void)loadView {
    NSTextField *title = [NSTextField labelWithString:[NSString stringWithFormat:POL(@"Дата для %@"),
                                                       POCount(_count, POL(@"файла"), POL(@"файлов"), POL(@"файлов"))]];
    title.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    NSTextField *note = [NSTextField wrappingLabelWithString:POL(@"Дата запоминается приложением и используется для раскладки по папкам; сами файлы не изменяются. "
                                                                @"Если известен только год или месяц — так и укажите: файл попадёт в папку года (месяца), а не в выдуманный день.")];
    note.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    note.textColor = NSColor.secondaryLabelColor;
    note.selectable = NO;
    note.preferredMaxLayoutWidth = 440;

    NSMutableArray<NSView *> *rows = [NSMutableArray arrayWithObjects:title, note, nil];
    if (_suggestions.count) {
        NSTextField *heading = [NSTextField labelWithString:POL(@"Подсказки:")];
        heading.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
        [rows addObject:heading];
    }
    for (PODateSuggestion *suggestion in _suggestions) {
        NSString *text = [NSString stringWithFormat:@"%@ — %@", suggestion.dateText, suggestion.reason];
        NSButton *radio = [NSButton radioButtonWithTitle:text target:self action:@selector(choiceChanged:)];
        radio.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [radio.widthAnchor constraintLessThanOrEqualToConstant:440].active = YES;
        [_radios addObject:radio];
        [rows addObject:radio];
    }
    NSButton *custom = [NSButton radioButtonWithTitle:POL(@"Указать:") target:self action:@selector(choiceChanged:)];
    [_radios addObject:custom];
    _precisionPopup = [NSPopUpButton new];
    [_precisionPopup addItemsWithTitles:@[POL(@"день"), POL(@"месяц"), POL(@"только год")]];
    _precisionPopup.target = self;
    _precisionPopup.action = @selector(precisionChanged:);
    _datePicker = [NSDatePicker new];
    _datePicker.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
    _datePicker.datePickerElements = NSDatePickerElementFlagYearMonthDay;
    _datePicker.locale = POLocale();
    _datePicker.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    _datePicker.dateValue = _initialDate ?: NSDate.date;
    _datePicker.maxDate = NSDate.date;
    _datePicker.target = self;
    _datePicker.action = @selector(pickerChanged:);
    [rows addObject:[NSStackView stackViewWithViews:@[custom, _precisionPopup, _datePicker]]];

    NSButton *cancel = [NSButton buttonWithTitle:POL(@"Отмена") target:self action:@selector(cancel:)];
    cancel.keyEquivalent = @"\e";
    NSButton *apply = [NSButton buttonWithTitle:POL(@"Задать") target:self action:@selector(apply:)];
    apply.keyEquivalent = @"\r";
    NSMutableArray<NSView *> *buttons = [NSMutableArray array];
    if (_canRemove) [buttons addObject:[NSButton buttonWithTitle:POL(@"Убрать заданную дату") target:self action:@selector(remove:)]];
    [buttons addObjectsFromArray:@[[NSView new], cancel, apply]];
    NSStackView *buttonRow = [NSStackView stackViewWithViews:buttons];
    [rows addObject:buttonRow];

    NSStackView *stack = [NSStackView stackViewWithViews:rows];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    [stack setCustomSpacing:14 afterView:note];
    [stack setCustomSpacing:18 afterView:rows[rows.count - 2]];
    [buttonRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-40].active = YES;
    [stack.widthAnchor constraintEqualToConstant:480].active = YES;
    self.view = stack;
    _radios.firstObject.state = NSControlStateValueOn;
}

- (void)choiceChanged:(NSButton *)sender {
    for (NSButton *radio in _radios) radio.state = radio == sender ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)precisionChanged:(id)sender {
    [self choiceChanged:_radios.lastObject];
    NSDatePickerElementFlags elements = NSDatePickerElementFlagYearMonthDay;
    if (_precisionPopup.indexOfSelectedItem >= 1) elements = NSDatePickerElementFlagYearMonth;
    _datePicker.datePickerElements = elements;
}

- (void)pickerChanged:(id)sender {
    [self choiceChanged:_radios.lastObject];
}

- (void)finishWithDate:(NSDate *)date precision:(PODatePrecision)precision remove:(BOOL)remove {
    [self.presentingViewController dismissViewController:self];
    if (self.completion) self.completion(date, precision, remove);
}

- (void)apply:(id)sender {
    for (NSUInteger i = 0; i < _suggestions.count; i++) {
        if (_radios[i].state == NSControlStateValueOn) {
            [self finishWithDate:_suggestions[i].date precision:_suggestions[i].precision remove:NO];
            return;
        }
    }
    PODatePrecision precision = _precisionPopup.indexOfSelectedItem == 2 ? PODatePrecisionYear
                              : _precisionPopup.indexOfSelectedItem == 1 ? PODatePrecisionMonth : PODatePrecisionDay;
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    NSDateComponents *c = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:_datePicker.dateValue];
    if (precision >= PODatePrecisionMonth) c.day = 1;
    if (precision >= PODatePrecisionYear) c.month = 1;
    c.hour = 12;
    [self finishWithDate:[calendar dateFromComponents:c] precision:precision remove:NO];
}

- (void)remove:(id)sender {
    [self finishWithDate:NSDate.date precision:PODatePrecisionDay remove:YES];
}

- (void)cancel:(id)sender {
    [self.presentingViewController dismissViewController:self];
}

@end
