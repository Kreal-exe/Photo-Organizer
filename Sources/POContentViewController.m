#import "POContentViewController.h"
#import "POActions.h"
#import "POScanner.h"
#import "POStrings.h"

#pragma mark - Drop frame

/// Dashed rounded frame used by the empty state and by the drag-over overlay.
@interface PODropFrameView : NSView
@property (nonatomic) BOOL highlighted;
@property (nonatomic) BOOL dimsBackground;   // overlay mode: fades whatever is underneath
@end

@implementation PODropFrameView

- (void)setHighlighted:(BOOL)highlighted {
    _highlighted = highlighted;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    if (self.dimsBackground) {
        [[NSColor.windowBackgroundColor colorWithAlphaComponent:0.85] setFill];
        NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
    }
    // safeAreaRect excludes the strip covered by the toolbar.
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.safeAreaRect, 24, 24) xRadius:18 yRadius:18];
    if (self.highlighted) {
        [[NSColor.controlAccentColor colorWithAlphaComponent:0.10] setFill];
        [path fill];
    }
    const CGFloat dash[] = {9, 6};
    [path setLineDash:dash count:2 phase:0];
    path.lineWidth = 2;
    [(self.highlighted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor) setStroke];
    [path stroke];
}

@end

#pragma mark - Helpers

static NSTextField *POLabel(NSString *text, NSFont *font, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = font;
    label.textColor = color;
    label.alignment = NSTextAlignmentCenter;
    return label;
}

static void POPinEdges(NSView *view, NSView *container) {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [view.topAnchor constraintEqualToAnchor:container.topAnchor],
        [view.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];
}

static NSStackView *POCenteredStack(NSArray<NSView *> *views, NSView *container) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.leadingAnchor constant:48],
    ]];
    return stack;
}

#pragma mark - Controller

@implementation POContentViewController {
    PODropFrameView *_emptyView;
    NSView *_progressView;
    NSProgressIndicator *_progressBar;
    NSTextField *_progressLabel;
    NSButton *_cancelButton;
    NSView *_resultsView;
    NSSegmentedControl *_filterControl;
    NSButton *_cleanupButton;
    NSButton *_soloCheckbox;
    NSStackView *_stripExtras;
    NSTextField *_analysisLabel;
    NSTextField *_statusLabel;
    NSButton *_setDateButton;
    NSButton *_backToMapButton;
    NSButton *_extraButton;
    NSButton *_acceptSuggestionsButton;
    NSButton *_organizeButton;
    PODropFrameView *_dropOverlay;
}

- (void)loadView {
    NSView *root = [NSView new];
    _grid = [POGridViewController new];
    [self addChildViewController:_grid];

    _viewer = [POViewerViewController new];
    [self addChildViewController:_viewer];
    __weak typeof(self) weakSelf = self;
    _viewer.onClose = ^(POPhotoItem *item) {
        [weakSelf showResults];
        if (item) [weakSelf.grid revealItem:item];
    };
    _grid.onOpen = ^(NSArray<POPhotoItem *> *items, NSUInteger index) {
        typeof(self) me = weakSelf;
        if (!me) return;
        [me showView:me->_viewer.view];
        [me->_viewer showItems:items atIndex:index];
    };

    _resultsView = [self makeResultsView];
    _progressView = [self makeProgressView];
    _emptyView = [self makeEmptyView];
    _dropOverlay = [self makeDropOverlay];
    for (NSView *view in @[_resultsView, _viewer.view, _progressView, _emptyView, _dropOverlay]) {
        [root addSubview:view];
        POPinEdges(view, root);
    }
    self.view = root;
    [self showEmpty];
}

- (PODropFrameView *)makeEmptyView {
    PODropFrameView *view = [PODropFrameView new];

    NSImageView *icon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"photo.on.rectangle.angled" accessibilityDescription:nil]];
    icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:64 weight:NSFontWeightLight];
    icon.contentTintColor = NSColor.secondaryLabelColor;

    NSTextField *title = POLabel(POL(@"Перетащите сюда папку с фото и видео"), [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold], NSColor.labelColor);
    NSTextField *subtitle = POLabel(POL(@"Фото и видео будут отсортированы по дате съёмки и разложены по папкам.\nДубликаты и миниатюры найдутся автоматически — до вашего подтверждения ничего не перемещается."),
                                    [NSFont systemFontOfSize:13], NSColor.secondaryLabelColor);
    subtitle.maximumNumberOfLines = 0;

    NSButton *button = [NSButton buttonWithTitle:POL(@"Выбрать папку…") target:nil action:@selector(openDocument:)];
    button.controlSize = NSControlSizeLarge;
    button.keyEquivalent = @"\r";

    NSStackView *stack = POCenteredStack(@[icon, title, subtitle, button], view);
    [stack setCustomSpacing:18 afterView:icon];
    [stack setCustomSpacing:22 afterView:subtitle];
    return view;
}

- (NSView *)makeProgressView {
    NSView *view = [NSView new];
    _progressBar = [NSProgressIndicator new];
    _progressBar.style = NSProgressIndicatorStyleBar;
    _progressBar.minValue = 0;
    _progressBar.maxValue = 1;
    [_progressBar.widthAnchor constraintEqualToConstant:320].active = YES;

    _progressLabel = POLabel(@"", [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular], NSColor.secondaryLabelColor);
    _cancelButton = [NSButton buttonWithTitle:POL(@"Отменить") target:nil action:@selector(cancelScan:)];
    _cancelButton.keyEquivalent = @"\e";

    NSStackView *stack = POCenteredStack(@[_progressBar, _progressLabel, _cancelButton], view);
    [stack setCustomSpacing:16 afterView:_progressLabel];
    return view;
}

- (NSView *)makeResultsView {
    NSView *view = [NSView new];
    NSView *gridView = _grid.view;
    gridView.translatesAutoresizingMaskIntoConstraints = NO;

    _filterControl = [NSSegmentedControl segmentedControlWithLabels:@[POL(@"Все"), POL(@"Фото"), POL(@"Видео")]
                                                       trackingMode:NSSegmentSwitchTrackingSelectOne
                                                             target:nil
                                                             action:@selector(selectQuickFilter:)];
    _filterControl.segmentStyle = NSSegmentStyleRounded;
    _filterControl.segmentDistribution = NSSegmentDistributionFit;
    _filterControl.translatesAutoresizingMaskIntoConstraints = NO;

    _cleanupButton = [NSButton buttonWithTitle:POL(@"Удалить дубликаты…") target:nil action:@selector(removeDuplicates:)];
    _cleanupButton.toolTip = POL(@"Переместить в Корзину все копии, оставив в каждом наборе оригинал или файл лучшего качества");
    _cleanupButton.hidden = YES;
    _soloCheckbox = [NSButton checkboxWithTitle:POL(@"Без других людей") target:nil action:@selector(toggleSoloPerson:)];
    _soloCheckbox.toolTip = POL(@"Показывать только фото, на которых нет никого, кроме этого человека");
    _soloCheckbox.hidden = YES;
    // A stack drops hidden views from the layout, so whichever of these is shown sits next to the filters.
    _setDateButton = [NSButton buttonWithTitle:POL(@"Задать дату…") target:nil action:@selector(setDateForSelection:)];
    _setDateButton.toolTip = POL(@"Задать дату выбранным файлам (или всем показанным, если ничего не выбрано)");
    _setDateButton.hidden = YES;
    _acceptSuggestionsButton = [NSButton buttonWithTitle:POL(@"Принять подсказки…") target:nil action:@selector(acceptDateSuggestions:)];
    _acceptSuggestionsButton.toolTip = POL(@"Дать каждому файлу дату по лучшей подсказке: соседние файлы, имя файла, название папки");
    _acceptSuggestionsButton.hidden = YES;
    _backToMapButton = [NSButton buttonWithTitle:POL(@"К карте") image:[NSImage imageWithSystemSymbolName:@"map" accessibilityDescription:nil]
                                         target:nil action:@selector(backToMap:)];
    _backToMapButton.imagePosition = NSImageLeading;
    _backToMapButton.hidden = YES;
    _extraButton = [NSButton buttonWithTitle:@"" target:nil action:NULL];
    _extraButton.hidden = YES;
    _stripExtras = [NSStackView stackViewWithViews:@[_extraButton, _backToMapButton, _cleanupButton, _soloCheckbox, _setDateButton, _acceptSuggestionsButton]];
    _stripExtras.spacing = 12;
    _stripExtras.translatesAutoresizingMaskIntoConstraints = NO;

    _analysisLabel = [NSTextField labelWithString:@""];
    _analysisLabel.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
    _analysisLabel.textColor = NSColor.secondaryLabelColor;
    _analysisLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _analysisLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_analysisLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSBox *separator = [NSBox new];
    separator.boxType = NSBoxSeparator;
    separator.translatesAutoresizingMaskIntoConstraints = NO;

    _statusLabel = [NSTextField labelWithString:@""];
    _statusLabel.textColor = NSColor.secondaryLabelColor;
    _statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_statusLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_statusLabel setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

    _organizeButton = [NSButton buttonWithTitle:POL(@"Разложить по папкам") target:nil action:@selector(organize:)];
    _organizeButton.keyEquivalent = @"\r";

    NSSlider *sizeSlider = [NSSlider sliderWithValue:_grid.cellWidth minValue:90 maxValue:480 target:self action:@selector(thumbnailSizeChanged:)];
    sizeSlider.controlSize = NSControlSizeSmall;
    sizeSlider.toolTip = POL(@"Размер миниатюр в сетке");
    [sizeSlider.widthAnchor constraintEqualToConstant:110].active = YES;

    NSStackView *bar = [NSStackView stackViewWithViews:@[_statusLabel, sizeSlider, _organizeButton]];
    bar.spacing = 16;
    bar.edgeInsets = NSEdgeInsetsMake(0, 16, 0, 16);
    bar.translatesAutoresizingMaskIntoConstraints = NO;

    _map = [POMapViewController new];
    [self addChildViewController:_map];
    NSView *mapView = _map.view;
    mapView.translatesAutoresizingMaskIntoConstraints = NO;
    mapView.hidden = YES;
    for (NSView *subview in @[_filterControl, _stripExtras, _analysisLabel, gridView, mapView, separator, bar]) [view addSubview:subview];
    [NSLayoutConstraint activateConstraints:@[
        [mapView.topAnchor constraintEqualToAnchor:gridView.topAnchor],
        [mapView.bottomAnchor constraintEqualToAnchor:gridView.bottomAnchor],
        [mapView.leadingAnchor constraintEqualToAnchor:gridView.leadingAnchor],
        [mapView.trailingAnchor constraintEqualToAnchor:gridView.trailingAnchor],
    ]];
    [NSLayoutConstraint activateConstraints:@[
        // Below the toolbar rather than underneath it, so pinned section headers stay visible.
        [_filterControl.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor constant:10],
        [_filterControl.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:18],
        [_stripExtras.leadingAnchor constraintEqualToAnchor:_filterControl.trailingAnchor constant:12],
        [_stripExtras.centerYAnchor constraintEqualToAnchor:_filterControl.centerYAnchor],
        [_analysisLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_stripExtras.trailingAnchor constant:12],
        [_analysisLabel.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-18],
        [_analysisLabel.centerYAnchor constraintEqualToAnchor:_filterControl.centerYAnchor],
        [gridView.topAnchor constraintEqualToAnchor:_filterControl.bottomAnchor constant:10],
        [gridView.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [gridView.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [gridView.bottomAnchor constraintEqualToAnchor:separator.topAnchor],
        [separator.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [separator.bottomAnchor constraintEqualToAnchor:bar.topAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
        [bar.heightAnchor constraintEqualToConstant:52],
    ]];
    return view;
}

- (PODropFrameView *)makeDropOverlay {
    PODropFrameView *overlay = [PODropFrameView new];
    overlay.dimsBackground = YES;
    overlay.highlighted = YES;
    overlay.hidden = YES;
    NSImageView *icon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"square.and.arrow.down" accessibilityDescription:nil]];
    icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:44 weight:NSFontWeightLight];
    icon.contentTintColor = NSColor.controlAccentColor;
    NSTextField *title = POLabel(POL(@"Отпустите, чтобы открыть папку"), [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold], NSColor.labelColor);
    POCenteredStack(@[icon, title], overlay);
    return overlay;
}

#pragma mark - States

- (void)showView:(NSView *)visible {
    (void)self.view;
    for (NSView *view in @[_emptyView, _progressView, _resultsView, _viewer.view]) view.hidden = view != visible;
    if (visible != _viewer.view) [_viewer stop];
    if (visible != _progressView) [_progressBar stopAnimation:nil];
}

- (BOOL)showsResults {
    return self.viewLoaded && !_resultsView.hidden;
}

- (BOOL)showsViewer {
    return self.viewLoaded && !_viewer.view.hidden;
}

- (void)showEmpty {
    [self showView:_emptyView];
}

- (void)showResults {
    [self showView:_resultsView];
}

- (void)showProgressWithText:(NSString *)text fraction:(double)fraction cancellable:(BOOL)cancellable {
    [self showView:_progressView];
    _progressLabel.stringValue = text;
    _cancelButton.hidden = !cancellable;
    _progressBar.indeterminate = fraction < 0;
    if (fraction < 0) {
        [_progressBar startAnimation:nil];
    } else {
        _progressBar.doubleValue = fraction;
    }
}

- (void)thumbnailSizeChanged:(NSSlider *)sender {
    _grid.cellWidth = sender.doubleValue;
}

- (void)setStatusText:(NSString *)text canOrganize:(BOOL)canOrganize {
    (void)self.view;
    _statusLabel.stringValue = text;
    _statusLabel.toolTip = text;
    _organizeButton.enabled = canOrganize;
}

- (void)setQuickFilterCounts:(NSArray<NSNumber *> *)counts selected:(POQuickFilter)selected {
    (void)self.view;
    NSArray<NSString *> *titles = @[POL(@"Все"), POL(@"Фото"), POL(@"Видео")];
    for (NSInteger segment = 0; segment < 3; segment++) {
        NSInteger count = segment < (NSInteger)counts.count ? counts[segment].integerValue : 0;
        [_filterControl setLabel:[NSString stringWithFormat:@"%@  %@", titles[segment], PONumber(count)] forSegment:segment];
        [_filterControl setEnabled:count > 0 || segment == POQuickFilterAll || segment == selected forSegment:segment];
    }
    _filterControl.selectedSegment = selected;
}

- (void)setShowsMap:(BOOL)showsMap {
    (void)self.view;
    _showsMap = showsMap;
    _map.view.hidden = !showsMap;
    _grid.view.hidden = showsMap;
}

- (void)setExtraButtonTitle:(NSString *)title action:(SEL)action {
    (void)self.view;
    _extraButton.hidden = title == nil;
    _extraButton.title = title ?: @"";
    _extraButton.action = action;
}

- (void)setShowsBackToMap:(BOOL)shows {
    (void)self.view;
    _backToMapButton.hidden = !shows;
}

- (void)setShowsDateButtons:(BOOL)shows canAcceptSuggestions:(BOOL)canAccept {
    (void)self.view;
    _setDateButton.hidden = !shows;
    _acceptSuggestionsButton.hidden = !shows || !canAccept;
}

- (void)setSoloCheckboxVisible:(BOOL)visible on:(BOOL)on {
    (void)self.view;
    _soloCheckbox.hidden = !visible;
    _soloCheckbox.state = on ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)setCleanupButtonTitle:(NSString *)title {
    (void)self.view;
    _cleanupButton.hidden = title == nil;
    if (title) _cleanupButton.title = title;
}

- (void)setAnalysisStatus:(NSString *)text {
    (void)self.view;
    _analysisLabel.stringValue = text;
    _analysisLabel.toolTip = text;
}


- (void)setDropHighlighted:(BOOL)highlighted {
    (void)self.view;
    if (_emptyView.hidden) {
        _dropOverlay.hidden = !highlighted;
    } else {
        _emptyView.highlighted = highlighted;
    }
    if (!highlighted) {
        _dropOverlay.hidden = YES;
        _emptyView.highlighted = NO;
    }
}

@end
