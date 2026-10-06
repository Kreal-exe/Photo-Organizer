#import "POArrangeController.h"
#import "POStrings.h"

static NSString *const POArrangeLayoutKey = @"arrangeLayout";
static NSString *const POArrangeCopiesKey = @"arrangeCopies";
static NSString *const POArrangeSkipKey = @"arrangeSkipCopies";
static NSString *const POArrangeDestinationKey = @"arrangeDestination";

@implementation POArrangeController {
    NSUInteger _count;
    NSString *_defaultName;
    NSURL *_rootURL;
    NSURL *_chosenURL;            // where copies go
    NSTextField *_note;
    NSSegmentedControl *_modeControl;
    NSStackView *_copyOptions;
    NSTextField *_destinationLabel;
    NSButton *_skipCheckbox;
    NSTextField *_nameLabel;
    NSTextField *_nameField;
    NSPopUpButton *_layoutPopup;
}

- (instancetype)initWithItemCount:(NSUInteger)count name:(NSString *)name rootURL:(NSURL *)rootURL {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _count = count;
        _defaultName = [name copy] ?: @"";
        _rootURL = rootURL;
        NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:POArrangeDestinationKey];
        BOOL isDirectory = NO;
        _chosenURL = saved && [NSFileManager.defaultManager fileExistsAtPath:saved isDirectory:&isDirectory] && isDirectory
            ? [NSURL fileURLWithPath:saved isDirectory:YES] : rootURL;
    }
    return self;
}

static NSTextField *POSmallLabel(NSString *text) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.textColor = NSColor.secondaryLabelColor;
    return label;
}

- (void)loadView {
    NSTextField *title = [NSTextField labelWithString:POL(@"Разложить по папке")];
    title.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    _note = [NSTextField wrappingLabelWithString:@""];
    _note.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _note.textColor = NSColor.secondaryLabelColor;
    _note.selectable = NO;
    _note.preferredMaxLayoutWidth = 440;

    _modeControl = [NSSegmentedControl segmentedControlWithLabels:@[POL(@"Переместить"), POL(@"Копировать")]
                                                    trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(modeChanged:)];
    _modeControl.selectedSegment = [NSUserDefaults.standardUserDefaults boolForKey:POArrangeCopiesKey] ? 1 : 0;

    // Copies may go anywhere — another disk with an archive by years of its own, which is filled up.
    _destinationLabel = [NSTextField labelWithString:@""];
    _destinationLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _destinationLabel.lineBreakMode = NSLineBreakByTruncatingHead;
    [_destinationLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *choose = [NSButton buttonWithTitle:POL(@"Выбрать…") target:self action:@selector(chooseDestination:)];
    NSStackView *where = [NSStackView stackViewWithViews:@[POSmallLabel(POL(@"Куда")), _destinationLabel, choose]];
    where.spacing = 8;
    id skip = [NSUserDefaults.standardUserDefaults objectForKey:POArrangeSkipKey];
    _skipCheckbox = [NSButton checkboxWithTitle:POL(@"Не копировать то, что уже есть в папке назначения (сравнивается содержимое файлов)") target:nil action:NULL];
    _skipCheckbox.state = !skip || [skip boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    _copyOptions = [NSStackView stackViewWithViews:@[where, _skipCheckbox]];
    _copyOptions.orientation = NSUserInterfaceLayoutOrientationVertical;
    _copyOptions.alignment = NSLayoutAttributeLeading;
    _copyOptions.spacing = 8;
    [where.widthAnchor constraintEqualToAnchor:_copyOptions.widthAnchor].active = YES;

    _nameLabel = POSmallLabel(POL(@"Название папки"));
    _nameField = [NSTextField textFieldWithString:_defaultName];
    _nameField.placeholderString = POL(@"Название папки");
    _layoutPopup = [NSPopUpButton new];
    [_layoutPopup addItemsWithTitles:@[POL(@"Все файлы вместе"), POL(@"По годам"), POL(@"По месяцам"), POL(@"По дням")]];
    [_layoutPopup selectItemAtIndex:MIN(MAX([NSUserDefaults.standardUserDefaults integerForKey:POArrangeLayoutKey], 0), 3)];

    NSButton *cancel = [NSButton buttonWithTitle:POL(@"Отмена") target:self action:@selector(cancel:)];
    cancel.keyEquivalent = @"\e";
    NSButton *arrange = [NSButton buttonWithTitle:POL(@"Разложить") target:self action:@selector(arrange:)];
    arrange.keyEquivalent = @"\r";
    NSStackView *buttons = [NSStackView stackViewWithViews:@[[NSView new], cancel, arrange]];

    NSStackView *stack = [NSStackView stackViewWithViews:@[title, _note, _modeControl, _copyOptions, _nameLabel, _nameField,
                                                           POSmallLabel(POL(@"Внутри папки")), _layoutPopup, buttons]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    [stack setCustomSpacing:12 afterView:_note];
    [stack setCustomSpacing:12 afterView:_modeControl];
    [stack setCustomSpacing:14 afterView:_copyOptions];
    [stack setCustomSpacing:14 afterView:_nameField];
    [stack setCustomSpacing:20 afterView:_layoutPopup];
    for (NSView *wide in @[_copyOptions, _nameField, buttons]) {
        [wide.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-40].active = YES;
    }
    [stack.widthAnchor constraintEqualToConstant:520].active = YES;
    self.view = stack;
    [self update];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    [self.view.window makeFirstResponder:_nameField];
}

- (BOOL)copies {
    return _modeControl.selectedSegment == 1;
}

- (BOOL)skipsSameContent {
    return _skipCheckbox.state == NSControlStateValueOn;
}

- (NSString *)folderName {
    return _nameField.stringValue;
}

- (POFolderLayout)layout {
    return (POFolderLayout)MAX(_layoutPopup.indexOfSelectedItem, 0);
}

- (NSURL *)destinationURL {
    return self.copies ? _chosenURL : _rootURL;
}

- (BOOL)isLibraryFolder:(NSURL *)url {
    return [url.URLByStandardizingPath.path isEqualToString:_rootURL.URLByStandardizingPath.path];
}

- (void)update {
    BOOL copies = self.copies;
    _copyOptions.hidden = !copies;
    // Copies go straight into the chosen folder's own year folders unless a folder is asked for; moves need one.
    if (copies && [_nameField.stringValue isEqualToString:_defaultName]) _nameField.stringValue = @"";
    else if (!copies && ![_nameField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length) _nameField.stringValue = _defaultName;
    _nameLabel.stringValue = copies ? POL(@"Подпапка (необязательно — без неё годы будут прямо в выбранной папке)") : POL(@"Название папки");
    _destinationLabel.stringValue = _chosenURL.path.stringByAbbreviatingWithTildeInPath;
    _destinationLabel.toolTip = _chosenURL.path;
    NSString *files = POCount(_count, POL(@"файл"), POL(@"файла"), POL(@"файлов"));
    files = [[files substringToIndex:1].localizedUppercaseString stringByAppendingString:[files substringFromIndex:1]];
    _note.stringValue = copies
        ? [NSString stringWithFormat:POL(@"%@ будут скопированы, оригиналы останутся на месте. Папки, которые уже есть (в том числе годы — «2015» или «2015 год»), "
                                        @"дополняются: ни один файл не заменяется, при совпадении имени копия получит имя «… (2)». Название папки можно оставить "
                                        @"пустым — тогда годы прямо в выбранной папке."), files]
        : [NSString stringWithFormat:POL(@"%@ будут перемещены в папку внутри «%@». Потом общая раскладка по датам эту папку не трогает."),
           files, _rootURL.lastPathComponent];
}

- (void)modeChanged:(id)sender {
    [self update];
}

- (void)chooseDestination:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.canCreateDirectories = YES;
    panel.message = POL(@"Куда копировать");
    panel.prompt = POL(@"Выбрать");
    panel.directoryURL = _chosenURL;
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        self->_chosenURL = panel.URL;
        [self update];
    }];
}

- (void)arrange:(id)sender {
    // Without a name the files go straight into the chosen folder (its year folders) — only when copying elsewhere.
    if (![POPlan sanitizedFolderPath:_nameField.stringValue] && !(self.copies && ![self isLibraryFolder:_chosenURL])) {
        [self.view.window makeFirstResponder:_nameField];
        NSBeep();
        return;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setInteger:self.layout forKey:POArrangeLayoutKey];
    [defaults setBool:self.copies forKey:POArrangeCopiesKey];
    [defaults setBool:self.skipsSameContent forKey:POArrangeSkipKey];
    if (self.copies) [defaults setObject:_chosenURL.path forKey:POArrangeDestinationKey];
    [self.presentingViewController dismissViewController:self];
    if (self.completion) self.completion(self);
}

- (void)cancel:(id)sender {
    [self.presentingViewController dismissViewController:self];
}

@end
