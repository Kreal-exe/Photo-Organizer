#import "POSettingsWindowController.h"
#import "POStrings.h"
#import "POSettings.h"
#import "POModel.h"
#import "POMLXRuntime.h"
#import "POHuggingFace.h"
#import "POAnalyzer.h"
#import "POVKAlbum.h"
#import "POVKLoginWindowController.h"

static NSString *POSize(long long bytes) {
    return [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleFile];
}

static NSTextField *POHeading(NSString *text) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    return label;
}

static NSTextField *PONote(NSString *text) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    label.textColor = NSColor.secondaryLabelColor;
    label.selectable = NO;
    return label;
}

static const CGFloat POPaneWidth = 560;

/// A vertical pane whose wrapping labels span its width.
static NSStackView *POPane(NSArray<NSView *> *views) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.edgeInsets = NSEdgeInsetsMake(18, 20, 20, 20);
    for (NSView *view in views) {
        BOOL wraps = [view isKindOfClass:NSTextField.class] && ((NSTextField *)view).maximumNumberOfLines != 1;
        // Without this a wrapping label reports the height of a single line when the pane is measured.
        if (wraps) ((NSTextField *)view).preferredMaxLayoutWidth = POPaneWidth - 40;
        if (wraps || [view isKindOfClass:NSBox.class] || [view isKindOfClass:NSStackView.class]) {
            [view.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-40].active = YES;
        }
    }
    [stack.widthAnchor constraintEqualToConstant:POPaneWidth].active = YES;
    return stack;
}

#pragma mark - Model installer

/// The status line, button and progress bar that download one model (and the MLX runtime it needs).
@interface POModelInstaller : NSObject
- (instancetype)initWithModel:(POModel * (^)(void))model readyText:(NSString * (^)(void))readyText;
@property (nonatomic, readonly) NSView *view;
@property (nonatomic, readonly, getter=isBusy) BOOL busy;
/// Called when the busy state changes, so the owner can lock related controls.
@property (nonatomic, copy) void (^onChange)(void);
- (void)refresh;
@end

@implementation POModelInstaller {
    POModel * (^_model)(void);
    NSString * (^_readyText)(void);
    NSTextField *_statusLabel;
    NSButton *_downloadButton;
    NSButton *_revealButton;
    NSProgressIndicator *_progressBar;
    POHuggingFaceDownload *_download;   // non-nil while model files are being fetched
    BOOL _installingRuntime;
    NSString *_activity;
    NSString *_lastError;
}

- (instancetype)initWithModel:(POModel * (^)(void))model readyText:(NSString * (^)(void))readyText {
    if (!(self = [super init])) return nil;
    _model = [model copy];
    _readyText = [readyText copy];
    _statusLabel = [NSTextField wrappingLabelWithString:@""];
    _statusLabel.selectable = NO;
    _statusLabel.preferredMaxLayoutWidth = POPaneWidth - 40;
    _downloadButton = [NSButton buttonWithTitle:POL(@"Загрузить") target:self action:@selector(downloadOrCancel:)];
    _revealButton = [NSButton buttonWithTitle:POL(@"Показать в Finder") target:self action:@selector(reveal:)];
    _progressBar = [NSProgressIndicator new];
    _progressBar.style = NSProgressIndicatorStyleBar;
    _progressBar.minValue = 0;
    _progressBar.maxValue = 1;
    _progressBar.controlSize = NSControlSizeSmall;
    [_progressBar setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[_downloadButton, _revealButton, _progressBar]];
    NSStackView *stack = [NSStackView stackViewWithViews:@[_statusLabel, buttons]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    [_statusLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [buttons.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    _view = stack;
    return self;
}

- (BOOL)isBusy {
    return _download || _installingRuntime;
}

- (void)refresh {
    POModel *model = _model();
    BOOL busy = self.isBusy;
    BOOL downloaded = model.snapshotURL != nil;
    BOOL needsRuntime = model.backend == POModelBackendMLX && !POMLXRuntime.isInstalled;
    NSString *status;
    NSColor *color = NSColor.labelColor;
    if (busy) {
        status = _activity ?: POL(@"Загрузка…");
    } else if (_lastError) {
        status = _lastError;
        color = NSColor.systemRedColor;
    } else if (!model.isSupported) {
        status = POL(@"MLX работает только на Mac с Apple Silicon.");
    } else if (downloaded && !needsRuntime) {
        status = _readyText();
        color = NSColor.systemGreenColor;
    } else if (downloaded) {
        status = POL(@"Модель загружена. Осталось установить среду MLX: отдельный Python с пакетом mlx (около 200 МБ) в папке данных приложения.");
    } else if (needsRuntime) {
        status = [NSString stringWithFormat:POL(@"Не загружена. Понадобится модель (%@) и среда MLX — отдельный Python с пакетом mlx (около 200 МБ)."), POSize(model.byteSize)];
    } else {
        status = [NSString stringWithFormat:POL(@"Не загружена (%@)."), POSize(model.byteSize)];
    }
    _statusLabel.stringValue = status;
    _statusLabel.textColor = color;
    _downloadButton.title = busy ? POL(@"Отменить") : (downloaded ? POL(@"Установить MLX") : POL(@"Загрузить"));
    _downloadButton.hidden = !model.isSupported || (!busy && downloaded && !needsRuntime);
    _downloadButton.enabled = !_installingRuntime;   // pip can't be interrupted half-way without leaving a mess
    _revealButton.hidden = !downloaded;
    _progressBar.hidden = !busy;
}

- (void)changed {
    [self refresh];
    if (self.onChange) self.onChange();
}

- (void)reveal:(id)sender {
    NSURL *snapshot = _model().snapshotURL;
    if (snapshot) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[snapshot]];
}

- (void)downloadOrCancel:(id)sender {
    if (_download) {
        [_download cancel];
        return;
    }
    _lastError = nil;
    POModel *model = _model();
    if (model.snapshotURL) {
        [self installRuntimeIfNeededForModel:model];
        return;
    }
    _activity = POL(@"Загрузка модели с Hugging Face…");
    _progressBar.indeterminate = YES;
    [_progressBar startAnimation:nil];
    POHuggingFaceDownload *download = [[POHuggingFaceDownload alloc] initWithRepo:model.identifier files:model.files];
    _download = download;
    __weak typeof(self) weakSelf = self;
    [download startWithProgress:^(int64_t received, int64_t total) {
        typeof(self) me = weakSelf;
        if (!me || me->_download != download) return;
        me->_progressBar.indeterminate = NO;
        me->_progressBar.doubleValue = total > 0 ? (double)received / total : 0;
        me->_activity = [NSString stringWithFormat:POL(@"Загрузка модели: %@ из %@"), POSize(received), POSize(total)];
        me->_statusLabel.stringValue = me->_activity;
    } completion:^(NSURL *snapshot, NSError *error) {
        typeof(self) me = weakSelf;
        if (!me) return;
        me->_download = nil;
        if (error) {
            BOOL cancelled = [error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled;
            me->_lastError = cancelled ? nil : [POL(@"Не удалось загрузить модель: ") stringByAppendingString:error.localizedDescription];
            [me changed];
            return;
        }
        [me installRuntimeIfNeededForModel:model];
    }];
    [self changed];
}

- (void)installRuntimeIfNeededForModel:(POModel *)model {
    if (model.backend != POModelBackendMLX || POMLXRuntime.isInstalled) {
        [self changed];
        [POSettings didChange];   // the model became usable: lets the main window start analysing
        return;
    }
    _installingRuntime = YES;
    _activity = POL(@"Установка среды MLX…");
    _progressBar.indeterminate = YES;
    [_progressBar startAnimation:nil];
    [self changed];
    __weak typeof(self) weakSelf = self;
    [POMLXRuntime installWithLog:^(NSString *line) {
        typeof(self) me = weakSelf;
        if (!me) return;
        me->_activity = [POL(@"Установка среды MLX: ") stringByAppendingString:line.length > 90 ? [line substringToIndex:90] : line];
        me->_statusLabel.stringValue = me->_activity;
    } completion:^(NSError *error) {
        typeof(self) me = weakSelf;
        if (!me) return;
        me->_installingRuntime = NO;
        me->_lastError = error.localizedDescription;
        [me changed];
        if (!error) [POSettings didChange];
    }];
}

@end

#pragma mark - Window

@implementation POSettingsWindowController {
    NSTabViewController *_tabs;
    NSPopUpButton *_languagePopup;
    NSTextField *_languageNote;

    NSButton *_objectsCheckbox;
    NSButton *_facesCheckbox;
    POModelInstaller *_faceInstaller;

    NSButton *_nudityCheckbox;
    NSTextField *_processorLabel;
    NSPopUpButton *_modelPopup;
    NSTextField *_modelDetailLabel;
    POModelInstaller *_nudityInstaller;
    NSSlider *_thresholdSlider;
    NSTextField *_thresholdLabel;

    NSTextField *_vkLinkField;
    NSTextField *_vkFolderLabel;
    NSTextField *_vkAccountLabel;
    NSButton *_vkLoginButton;
    NSButton *_vkNewestCheckbox;
    NSButton *_vkDownloadButton;
    NSButton *_vkRevealButton;
    NSProgressIndicator *_vkProgressBar;
    NSTextField *_vkStatusLabel;
    POVKAlbum *_vkDownload;   // non-nil while an album is being downloaded
}

+ (POSettingsWindowController *)sharedController {
    static POSettingsWindowController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [POSettingsWindowController new]; });
    return shared;
}

/// Every pane gets the height of the tallest one, so the window keeps its size when switching tabs.
- (NSTabViewItem *)tabWithTitle:(NSString *)title symbol:(NSString *)symbol pane:(NSView *)pane height:(CGFloat)height {
    NSView *container = [NSView new];
    pane.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:pane];
    [NSLayoutConstraint activateConstraints:@[
        [pane.topAnchor constraintEqualToAnchor:container.topAnchor],
        [pane.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [pane.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [container.heightAnchor constraintEqualToConstant:height],
    ]];
    NSViewController *controller = [NSViewController new];
    controller.view = container;
    controller.title = title;
    controller.preferredContentSize = NSMakeSize(POPaneWidth, height);
    NSTabViewItem *item = [NSTabViewItem tabViewItemWithViewController:controller];
    item.label = title;
    item.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title];
    return item;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, POPaneWidth, 300)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    if (!(self = [super initWithWindow:window])) return nil;
    __weak typeof(self) weakSelf = self;
    NSString *cache = POHuggingFace.cacheURL.path.stringByAbbreviatingWithTildeInPath;

    // General
    _languagePopup = [NSPopUpButton new];
    [_languagePopup addItemsWithTitles:@[POL(@"Как в системе"), POL(@"Русский"), @"English"]];
    _languagePopup.target = self;
    _languagePopup.action = @selector(languageChanged:);
    _languageNote = PONote(@"");
    NSStackView *languageRow = [NSStackView stackViewWithViews:@[[NSTextField labelWithString:POL(@"Язык:")], _languagePopup]];
    NSView *general = POPane(@[POHeading(POL(@"Язык")), languageRow, _languageNote,
                               POHeading(POL(@"Сканирование")),
                               PONote(POL(@"Дата съёмки берётся из метаданных файла; если её нет — из имени файла (20220909_145141.mp4), из соседних кадров той же серии "
                                          @"(IMG_0667 → IMG_0669) или из названия папки с годом («Photos from 2018»). Дата создания файла — только в последнюю очередь.")),
                               PONote(POL(@"Миниатюры — это уменьшенные копии других фото папки, хотя бы вдвое меньше оригинала. "
                                          @"Маленькая картинка, у которой нет большой версии, миниатюрой не считается."))]);

    // Recognition
    _objectsCheckbox = [NSButton checkboxWithTitle:POL(@"Распознавать, что изображено на фото и видео") target:self action:@selector(toggleObjects:)];
    NSButton *resetButton = [NSButton buttonWithTitle:POL(@"Распознать заново…") target:self action:@selector(resetResults:)];
    resetButton.controlSize = NSControlSizeSmall;
    resetButton.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    resetButton.toolTip = POL(@"Забыть сохранённые результаты распознавания и проанализировать файлы ещё раз");
    NSBox *separator = [NSBox new];
    separator.boxType = NSBoxSeparator;
    _facesCheckbox = [NSButton checkboxWithTitle:POL(@"Находить лица и группировать фото по людям") target:self action:@selector(toggleFaces:)];
    _faceInstaller = [[POModelInstaller alloc] initWithModel:^{ return POModel.faceModel; } readyText:^{
        return POSettings.groupsFaces ? POL(@"Модель лиц готова. Люди появятся в боковой панели после анализа.")
                                      : POL(@"Модель лиц готова. Включите галочку выше, чтобы начать.");
    }];
    NSView *recognition = POPane(@[
        POHeading(POL(@"Объекты")), _objectsCheckbox,
        PONote(POL(@"Использует распознавание, встроенное в macOS: ничего загружать не нужно. После анализа ищите через поле поиска в окне («море», «собака», "
               @"«документ») или по образцу: «Правка» → «Поиск по фото…». Поиск идёт среди того, что выбрано в полосе фильтров, — все файлы, только фото или только видео.")),
        resetButton, separator,
        POHeading(POL(@"Лица")), _facesCheckbox,
        PONote([NSString stringWithFormat:POL(@"Лица находит macOS, а отличает людей друг от друга модель %@ (%@, huggingface.co/%@, лицензия %@). "
                @"Группе можно дать имя двойным щелчком в боковой панели, а её файлы — переместить в отдельную папку. Пока только фото, без видео."),
                POModel.faceModel.title, POSize(POModel.faceModel.byteSize), POModel.faceModel.identifier, POModel.faceModel.license]),
        _faceInstaller.view,
        PONote([NSString stringWithFormat:POL(@"Модели хранятся в общем кэше Hugging Face (%@) и работают на этом Mac — файлы никуда не отправляются."), cache]),
    ]);
    [(NSStackView *)recognition setCustomSpacing:14 afterView:resetButton];
    [(NSStackView *)recognition setCustomSpacing:14 afterView:separator];

    // Nudity
    _nudityCheckbox = [NSButton checkboxWithTitle:POL(@"Искать откровенные фото и видео") target:self action:@selector(toggleNudity:)];
    _processorLabel = PONote(@"");
    _modelPopup = [NSPopUpButton new];
    _modelPopup.target = self;
    _modelPopup.action = @selector(modelChanged:);
    _modelPopup.autoenablesItems = NO;
    for (POModel *model in POModel.allModels) {
        NSString *title = [NSString stringWithFormat:@"%@ — %@ · %@%@", model.title,
                           model.backend == POModelBackendMLX ? @"MLX" : @"Core ML", POSize(model.byteSize),
                           model == POModel.recommendedModel ? POL(@" (рекомендуется)") : @""];
        [_modelPopup addItemWithTitle:title];
        _modelPopup.lastItem.enabled = model.isSupported;
    }
    NSStackView *modelRow = [NSStackView stackViewWithViews:@[[NSTextField labelWithString:POL(@"Модель:")], _modelPopup]];
    _modelDetailLabel = PONote(@"");
    _nudityInstaller = [[POModelInstaller alloc] initWithModel:^{ return POModel.selectedModel; } readyText:^{
        return POSettings.detectsNudity ? POL(@"Готова к работе. Находки появятся в разделе «Откровенные» после анализа.")
                                        : POL(@"Готова к работе. Включите галочку выше, чтобы начать поиск.");
    }];
    _thresholdSlider = [NSSlider sliderWithValue:POSettings.nudityThreshold minValue:0.1 maxValue:0.95 target:self action:@selector(thresholdChanged:)];
    _thresholdSlider.continuous = YES;
    [_thresholdSlider.widthAnchor constraintEqualToConstant:220].active = YES;
    _thresholdLabel = [NSTextField labelWithString:@""];
    _thresholdLabel.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular];
    NSStackView *thresholdRow = [NSStackView stackViewWithViews:@[[NSTextField labelWithString:POL(@"Порог:")], _thresholdSlider, _thresholdLabel]];
    thresholdRow.toolTip = POL(@"Файл попадает в «Откровенные», если модель уверена не меньше чем на столько. Ниже порог — больше находок и больше ложных.");
    NSView *nudity = POPane(@[
        POHeading(POL(@"Распознавание наготы")), _nudityCheckbox, _processorLabel, modelRow, _modelDetailLabel, _nudityInstaller.view, thresholdRow,
        PONote([NSString stringWithFormat:
            POL(@"Необязательная функция. Модели загружаются с Hugging Face в общий кэш %@ и работают на этом Mac — файлы никуда не отправляются. "
            @"Модели ошибаются: пляжные, детские фото и живопись могут попасть в находки, поэтому приложение только показывает их, а что с ними делать, решаете вы."), cache]),
    ]);
    [(NSStackView *)nudity setCustomSpacing:12 afterView:_processorLabel];

    // VK
    _vkLinkField = [NSTextField textFieldWithString:@""];
    _vkLinkField.placeholderString = @"https://vk.ru/album123456_000";
    _vkLinkField.target = self;
    _vkLinkField.action = @selector(vkLinkChanged:);
    _vkFolderLabel = [NSTextField labelWithString:@""];
    _vkFolderLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _vkFolderLabel.textColor = NSColor.secondaryLabelColor;
    [_vkFolderLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *chooseFolder = [NSButton buttonWithTitle:POL(@"Выбрать…") target:self action:@selector(vkChooseFolder:)];
    _vkAccountLabel = [NSTextField labelWithString:@""];
    _vkLoginButton = [NSButton buttonWithTitle:POL(@"Войти в VK…") target:self action:@selector(vkLoginOrOut:)];
    _vkNewestCheckbox = [NSButton checkboxWithTitle:POL(@"Нумеровать с самых новых (так VK показывает «Сохранённые фотографии»)") target:nil action:NULL];
    _vkNewestCheckbox.state = NSControlStateValueOn;
    _vkDownloadButton = [NSButton buttonWithTitle:POL(@"Скачать") target:self action:@selector(vkDownloadOrCancel:)];
    _vkRevealButton = [NSButton buttonWithTitle:POL(@"Показать в Finder") target:self action:@selector(vkReveal:)];
    _vkProgressBar = [NSProgressIndicator new];
    _vkProgressBar.style = NSProgressIndicatorStyleBar;
    _vkProgressBar.minValue = 0;
    _vkProgressBar.maxValue = 1;
    _vkProgressBar.controlSize = NSControlSizeSmall;
    _vkProgressBar.hidden = YES;
    [_vkProgressBar setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    _vkStatusLabel = [NSTextField wrappingLabelWithString:@""];
    _vkStatusLabel.selectable = YES;
    _vkStatusLabel.preferredMaxLayoutWidth = POPaneWidth - 40;
    NSGridView *vkForm = [NSGridView gridViewWithViews:@[
        @[[NSTextField labelWithString:POL(@"Ссылка на альбом:")], _vkLinkField],
        @[[NSTextField labelWithString:POL(@"Сохранить в:")], [NSStackView stackViewWithViews:@[chooseFolder, _vkFolderLabel]]],
        @[[NSTextField labelWithString:POL(@"Аккаунт:")], [NSStackView stackViewWithViews:@[_vkLoginButton, _vkAccountLabel]]],
    ]];
    vkForm.rowAlignment = NSGridRowAlignmentFirstBaseline;
    vkForm.rowSpacing = 8;
    [vkForm columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [_vkLinkField.widthAnchor constraintEqualToConstant:360].active = YES;
    NSView *vk = POPane(@[
        POHeading(POL(@"Скачать альбом VK")),
        PONote(POL(@"Скачивает все фото альбома в оригинальном размере и называет их по порядку в альбоме: 001.jpg, 002.jpg… "
                   @"Уже скачанные файлы пропускаются, так что прерванную загрузку можно продолжить.")),
        vkForm,
        PONote(POL(@"VK не даёт программам читать альбомы без входа, а доступ к фото через свои приложения разработчиков (dev.vk.com) почти никому не выдаёт. "
                   @"Поэтому приложение открывает vk.ru в своём окне: вы входите как обычно, и загрузка идёт от вашего имени, тем же способом, каким сайт VK показывает вам ваши фото. "
                   @"Пароль приложение не видит; доступ хранится в связке ключей этого Mac и отправляется только в VK. Это не официальный способ VK — если VK его изменит, загрузка перестанет работать.")),
        _vkNewestCheckbox,
        [NSStackView stackViewWithViews:@[_vkDownloadButton, _vkRevealButton, _vkProgressBar]],
        _vkStatusLabel,
    ]);

    void (^refresh)(void) = ^{ [weakSelf refresh]; };
    _faceInstaller.onChange = refresh;
    _nudityInstaller.onChange = refresh;

    // Measured with the longest texts in place.
    [self refresh];
    CGFloat height = MAX(MAX(general.fittingSize.height, vk.fittingSize.height), MAX(recognition.fittingSize.height, nudity.fittingSize.height)) + 24;
    _tabs = [NSTabViewController new];
    _tabs.tabStyle = NSTabViewControllerTabStyleToolbar;
    [_tabs addTabViewItem:[self tabWithTitle:POL(@"Основные") symbol:@"gearshape" pane:general height:height]];
    [_tabs addTabViewItem:[self tabWithTitle:POL(@"Распознавание") symbol:@"sparkle.magnifyingglass" pane:recognition height:height]];
    [_tabs addTabViewItem:[self tabWithTitle:POL(@"Нагота") symbol:@"eye.slash" pane:nudity height:height]];
    [_tabs addTabViewItem:[self tabWithTitle:@"VK" symbol:@"square.and.arrow.down" pane:vk height:height]];
    window.contentViewController = _tabs;
    window.title = POL(@"Настройки");
    window.toolbarStyle = NSWindowToolbarStylePreference;
    [window setContentSize:NSMakeSize(POPaneWidth, height)];
    [self refresh];
    [window center];
    return self;
}

- (void)showPaneAtIndex:(NSInteger)index {
    _tabs.selectedTabViewItemIndex = MIN(MAX(index, 0), (NSInteger)_tabs.tabViewItems.count - 1);
    [self showWindow:nil];
}

- (void)showWindow:(id)sender {
    [self refresh];
    [super showWindow:sender];
}

#pragma mark - State

- (void)refresh {
    NSString *language = POSettings.language;
    [_languagePopup selectItemAtIndex:!language ? 0 : ([language isEqualToString:@"ru"] ? 1 : 2)];

    _objectsCheckbox.state = POSettings.analyzesObjects ? NSControlStateValueOn : NSControlStateValueOff;
    _facesCheckbox.state = POSettings.groupsFaces ? NSControlStateValueOn : NSControlStateValueOff;
    _facesCheckbox.enabled = POModel.faceModel.isSupported;
    [_faceInstaller refresh];

    POModel *model = POModel.selectedModel;
    _nudityCheckbox.state = POSettings.detectsNudity ? NSControlStateValueOn : NSControlStateValueOff;
    [_modelPopup selectItemAtIndex:[POModel.allModels indexOfObject:model]];
    _modelPopup.enabled = !_nudityInstaller.isBusy;
    POModel *recommended = POModel.recommendedModel;
    _processorLabel.stringValue = POMLXRuntime.isSupported
        ? [NSString stringWithFormat:POL(@"Процессор: %@ (Apple Silicon). Для него лучше всего подходят модели MLX; рекомендуется %@."),
           POMLXRuntime.processorName, recommended.title]
        : [NSString stringWithFormat:POL(@"Процессор: %@ (Intel). MLX на нём не работает, поэтому рекомендуется модель Core ML — %@."),
           POMLXRuntime.processorName, recommended.title];
    _modelDetailLabel.stringValue = [NSString stringWithFormat:POL(@"%@\nhuggingface.co/%@ · лицензия %@"), model.summary, model.identifier, model.license];
    [_nudityInstaller refresh];
    NSString *vkFolder = [NSUserDefaults.standardUserDefaults stringForKey:@"vkFolder"];
    _vkFolderLabel.stringValue = vkFolder.stringByAbbreviatingWithTildeInPath ?: POL(@"папка не выбрана");
    BOOL signedIn = POVKSavedToken().length > 0;
    NSString *userID = [NSUserDefaults.standardUserDefaults stringForKey:@"vkUserID"];
    _vkAccountLabel.stringValue = signedIn ? (userID.length ? [NSString stringWithFormat:POL(@"вход выполнен (id%@)"), userID] : POL(@"вход выполнен"))
                                           : POL(@"вход не выполнен");
    _vkAccountLabel.textColor = signedIn ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
    _vkLoginButton.title = signedIn ? POL(@"Выйти") : POL(@"Войти в VK…");
    _vkDownloadButton.enabled = signedIn || _vkDownload != nil;
    _vkDownloadButton.title = _vkDownload ? POL(@"Остановить") : POL(@"Скачать");
    _vkRevealButton.hidden = vkFolder == nil;
    _vkProgressBar.hidden = _vkDownload == nil;
    _thresholdSlider.doubleValue = POSettings.nudityThreshold;
    _thresholdLabel.stringValue = [NSString stringWithFormat:@"%.0f %%", POSettings.nudityThreshold * 100];
}

#pragma mark - Actions

- (void)languageChanged:(NSPopUpButton *)sender {
    POSettings.language = sender.indexOfSelectedItem == 0 ? nil : (sender.indexOfSelectedItem == 1 ? @"ru" : @"en");
    _languageNote.stringValue = POL(@"Язык сменится после перезапуска приложения.");
}

- (void)toggleObjects:(NSButton *)sender {
    POSettings.analyzesObjects = sender.state == NSControlStateValueOn;
}

- (void)toggleFaces:(NSButton *)sender {
    POSettings.groupsFaces = sender.state == NSControlStateValueOn;
    [self refresh];
}

- (void)toggleNudity:(NSButton *)sender {
    POSettings.detectsNudity = sender.state == NSControlStateValueOn;
    [self refresh];
}

- (void)modelChanged:(NSPopUpButton *)sender {
    POSettings.nudityModelIdentifier = POModel.allModels[sender.indexOfSelectedItem].identifier;
    [self refresh];
}

- (void)thresholdChanged:(NSSlider *)sender {
    _thresholdLabel.stringValue = [NSString stringWithFormat:@"%.0f %%", sender.doubleValue * 100];
    // Applied when the mouse is released, so the main window isn't refreshed for every pixel of the drag.
    if (NSApp.currentEvent.type == NSEventTypeLeftMouseDragged) return;
    POSettings.nudityThreshold = round(sender.doubleValue * 100) / 100;
}

#pragma mark - VK

- (void)vkLinkChanged:(id)sender {
    // VK lists the service albums newest first and ordinary albums in their own order.
    NSString *owner, *album;
    if ([POVKAlbum parseAlbumURL:_vkLinkField.stringValue owner:&owner album:&album]) {
        BOOL service = [@[@"saved", @"wall", @"profile"] containsObject:album];
        _vkNewestCheckbox.state = service ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)vkLoginOrOut:(id)sender {
    if (POVKSavedToken().length) {
        [POVKLoginWindowController signOut];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"vkUserID"];
        [self refresh];
        return;
    }
    POVKLoginWindowController *login = POVKLoginWindowController.sharedController;
    __weak typeof(self) weakSelf = self;
    login.onLogin = ^(NSString *userID) {
        [NSUserDefaults.standardUserDefaults setObject:userID forKey:@"vkUserID"];
        typeof(self) me = weakSelf;
        if (!me) return;
        me->_vkStatusLabel.stringValue = POL(@"Вход выполнен. Вставьте ссылку на альбом и нажмите «Скачать».");
        me->_vkStatusLabel.textColor = NSColor.systemGreenColor;
        [me refresh];
    };
    [login showWindow:nil];
}

- (void)vkChooseFolder:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.canCreateDirectories = YES;
    panel.prompt = POL(@"Выбрать");
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        [NSUserDefaults.standardUserDefaults setObject:panel.URL.path forKey:@"vkFolder"];
        [self refresh];
    }];
}

- (void)vkReveal:(id)sender {
    NSString *folder = [NSUserDefaults.standardUserDefaults stringForKey:@"vkFolder"];
    if (folder) [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:folder isDirectory:YES]];
}

- (void)vkDownloadOrCancel:(id)sender {
    if (_vkDownload) {
        [_vkDownload cancel];
        return;
    }
    [self.window makeFirstResponder:nil];   // commits a link or token that is still being typed
    NSString *folder = [NSUserDefaults.standardUserDefaults stringForKey:@"vkFolder"];
    if (!folder) {
        _vkStatusLabel.stringValue = POL(@"Сначала выберите папку, куда сохранять.");
        return;
    }
    POVKAlbum *download = [[POVKAlbum alloc] initWithLink:_vkLinkField.stringValue
                                                    token:POVKSavedToken() ?: @""
                                                   folder:[NSURL fileURLWithPath:folder isDirectory:YES]
                                              newestFirst:_vkNewestCheckbox.state == NSControlStateValueOn];
    _vkDownload = download;
    _vkProgressBar.indeterminate = YES;
    [_vkProgressBar startAnimation:nil];
    _vkStatusLabel.textColor = NSColor.labelColor;
    _vkStatusLabel.stringValue = POL(@"Получаем список фотографий…");
    [self refresh];
    __weak typeof(self) weakSelf = self;
    [download startWithProgress:^(NSUInteger done, NSUInteger total) {
        typeof(self) me = weakSelf;
        if (!me || me->_vkDownload != download) return;
        me->_vkProgressBar.indeterminate = NO;
        me->_vkProgressBar.doubleValue = total ? (double)done / total : 0;
        me->_vkStatusLabel.stringValue = [NSString stringWithFormat:POL(@"Скачивание: %lu из %lu"), (unsigned long)done, (unsigned long)total];
    } completion:^(BOOL success, NSString *message) {
        typeof(self) me = weakSelf;
        if (!me) return;
        me->_vkDownload = nil;
        me->_vkStatusLabel.stringValue = message;
        me->_vkStatusLabel.textColor = success ? NSColor.systemGreenColor : NSColor.systemRedColor;
        [me refresh];
    }];
}

- (void)resetResults:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = POL(@"Распознать все файлы заново?");
    alert.informativeText = POL(@"Сохранённые результаты распознавания объектов, лиц и наготы будут забыты, и открытая папка проанализируется ещё раз. "
                            @"Сами фото и видео не затрагиваются.");
    [alert addButtonWithTitle:POL(@"Распознать заново")];
    [alert addButtonWithTitle:POL(@"Отмена")];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        [POAnalyzer removeAllCachedResults];
        [POSettings didChange];
    }];
}

@end
