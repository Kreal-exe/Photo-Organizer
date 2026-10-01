#import "POGridViewController.h"
#import "POStrings.h"
#import "POThumbnailCache.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "POLabels.h"
#import "POActions.h"
#import <Quartz/Quartz.h>

static NSUserInterfaceItemIdentifier const POCellIdentifier = @"POPhotoCell";
static NSUserInterfaceItemIdentifier const POHeaderIdentifier = @"POSectionHeader";
static const CGFloat PODefaultCellWidth = 168;
static NSString *const POCellWidthKey = @"gridCellWidth";
static const CGFloat POCellCaptionHeight = 46;

#pragma mark - Section model

@implementation POGridSection

+ (instancetype)sectionWithTitle:(NSString *)title detail:(NSString *)detail symbolName:(NSString *)symbolName items:(NSArray<POPhotoItem *> *)items {
    POGridSection *section = [POGridSection new];
    section->_title = [title copy];
    section->_detail = [detail copy];
    section->_symbolName = [symbolName copy];
    section->_items = [items copy];
    return section;
}

@end

#pragma mark - Thumbnail view

/// Rounded, aspect-filled thumbnail. Colors are applied in -updateLayer so they follow light/dark mode.
@interface POThumbView : NSView
@property (nonatomic, strong, nullable) id image;   // CGImageRef
@property (nonatomic) BOOL showsActualSize;         // tiny images are shown unscaled so they look as small as they are
@property (nonatomic) BOOL selected;
@end

@implementation POThumbView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    }
    return self;
}

- (BOOL)wantsUpdateLayer { return YES; }

- (void)updateLayer {
    CALayer *layer = self.layer;
    CGFloat scale = self.window.backingScaleFactor ?: 2;
    layer.cornerRadius = 8;
    layer.cornerCurve = kCACornerCurveContinuous;
    layer.masksToBounds = YES;
    layer.backgroundColor = NSColor.quaternaryLabelColor.CGColor;
    layer.contents = self.image;
    layer.contentsScale = scale;
    layer.borderWidth = self.selected ? 3 : 0.5;
    layer.borderColor = (self.selected ? NSColor.controlAccentColor : NSColor.separatorColor).CGColor;

    BOOL fits = NO;
    if (self.image && self.showsActualSize) {
        CGImageRef image = (__bridge CGImageRef)self.image;
        fits = CGImageGetWidth(image) / scale <= NSWidth(self.bounds) && CGImageGetHeight(image) / scale <= NSHeight(self.bounds);
    }
    layer.contentsGravity = fits ? kCAGravityCenter : kCAGravityResizeAspectFill;
}

- (void)setImage:(id)image { _image = image; self.needsDisplay = YES; }
- (void)setShowsActualSize:(BOOL)showsActualSize { _showsActualSize = showsActualSize; self.needsDisplay = YES; }
- (void)setSelected:(BOOL)selected { _selected = selected; self.needsDisplay = YES; }

@end

#pragma mark - Badge

@interface POBadgeView : NSView
- (void)setText:(NSString *)text color:(NSColor *)color;
@end

@implementation POBadgeView {
    NSTextField *_label;
    NSColor *_color;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        _color = NSColor.systemGrayColor;
        _label = [NSTextField labelWithString:@""];
        _label.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
        _label.textColor = NSColor.whiteColor;
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_label];
        [NSLayoutConstraint activateConstraints:@[
            [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:6],
            [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
            [_label.topAnchor constraintEqualToAnchor:self.topAnchor constant:2],
            [_label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-2],
        ]];
    }
    return self;
}

- (BOOL)wantsUpdateLayer { return YES; }

- (void)updateLayer {
    self.layer.cornerRadius = NSHeight(self.bounds) / 2;
    self.layer.backgroundColor = _color.CGColor;
}

- (void)setText:(NSString *)text color:(NSColor *)color {
    _label.stringValue = text;
    _color = color;
    self.needsDisplay = YES;
}

@end

#pragma mark - Cell

@interface POPhotoCell : NSCollectionViewItem
- (void)configureWithItem:(POPhotoItem *)item showsOriginalBadge:(BOOL)showsOriginalBadge showsNudityScore:(BOOL)showsNudityScore;
@end

@implementation POPhotoCell {
    POThumbView *_thumb;
    POBadgeView *_badge;
    POBadgeView *_durationBadge;   // videos only
    NSTextField *_nameLabel;
    NSTextField *_detailLabel;
    NSString *_path;
    id _thumbnailToken;
}

static NSTextField *POCaptionLabel(NSFont *font, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:@""];
    label.font = font;
    label.textColor = color;
    label.alignment = NSTextAlignmentCenter;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

- (void)loadView {
    NSView *view = [NSView new];
    _thumb = [POThumbView new];
    _thumb.translatesAutoresizingMaskIntoConstraints = NO;
    _badge = [POBadgeView new];
    _badge.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel = POCaptionLabel([NSFont systemFontOfSize:12], NSColor.labelColor);
    _detailLabel = POCaptionLabel([NSFont systemFontOfSize:11], NSColor.secondaryLabelColor);
    _durationBadge = [POBadgeView new];
    _durationBadge.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *subview in @[_thumb, _badge, _durationBadge, _nameLabel, _detailLabel]) [view addSubview:subview];

    [NSLayoutConstraint activateConstraints:@[
        [_thumb.topAnchor constraintEqualToAnchor:view.topAnchor constant:6],
        [_thumb.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:6],
        [_thumb.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-6],
        [_thumb.heightAnchor constraintEqualToAnchor:_thumb.widthAnchor],
        [_badge.topAnchor constraintEqualToAnchor:_thumb.topAnchor constant:7],
        [_badge.leadingAnchor constraintEqualToAnchor:_thumb.leadingAnchor constant:7],
        [_durationBadge.bottomAnchor constraintEqualToAnchor:_thumb.bottomAnchor constant:-7],
        [_durationBadge.leadingAnchor constraintEqualToAnchor:_thumb.leadingAnchor constant:7],
        [_nameLabel.topAnchor constraintEqualToAnchor:_thumb.bottomAnchor constant:6],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:_thumb.leadingAnchor],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:_thumb.trailingAnchor],
        [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:1],
        [_detailLabel.leadingAnchor constraintEqualToAnchor:_thumb.leadingAnchor],
        [_detailLabel.trailingAnchor constraintEqualToAnchor:_thumb.trailingAnchor],
    ]];
    self.view = view;
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    _thumb.selected = selected;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [POThumbnailCache.sharedCache cancel:_thumbnailToken];
    _thumbnailToken = nil;
    _path = nil;
    _thumb.image = nil;
}

- (void)configureWithItem:(POPhotoItem *)item showsOriginalBadge:(BOOL)showsOriginalBadge showsNudityScore:(BOOL)showsNudityScore {
    NSString *date = POItemDateText(item, NO);
    NSString *dimensions = item.pixelWidth > 0 ? [NSString stringWithFormat:@"%ld×%ld", (long)item.pixelWidth, (long)item.pixelHeight] : POL(@"не читается");
    // Copies often share a file name, so the duplicates view shows where each one lives.
    _nameLabel.stringValue = showsOriginalBadge ? item.relativePath : item.url.lastPathComponent;
    _detailLabel.stringValue = [NSString stringWithFormat:@"%@ · %@", date, dimensions];

    NSNumber *nudityScore = showsNudityScore ? item.nudityScore : nil;
    if (nudityScore) {
        [_badge setText:[NSString stringWithFormat:@"%.0f %%", nudityScore.doubleValue * 100] color:NSColor.systemPinkColor];
    } else if (item.isDuplicate) {
        [_badge setText:POL(@"Дубликат") color:NSColor.systemOrangeColor];
    } else if (item.isTiny) {
        [_badge setText:POL(@"Миниатюра") color:NSColor.systemPurpleColor];
    } else if (showsOriginalBadge && item.betterCopy) {
        [_badge setText:POL(@"Хуже качеством") color:NSColor.systemOrangeColor];
    } else if (showsOriginalBadge && item.bestOfCopies) {
        [_badge setText:POL(@"Лучшее качество") color:NSColor.systemGreenColor];
    } else if (showsOriginalBadge && item.duplicates.count) {
        [_badge setText:POL(@"Оригинал") color:NSColor.systemGreenColor];
    }
    _badge.hidden = !(nudityScore || item.isDuplicate || item.isTiny ||
                      (showsOriginalBadge && (item.duplicates.count || item.betterCopy || item.bestOfCopies)));

    _durationBadge.hidden = !item.isVideo;
    if (item.isVideo) {
        NSInteger seconds = (NSInteger)round(item.duration);
        NSString *duration = seconds >= 3600
            ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(seconds / 3600), (long)(seconds / 60 % 60), (long)(seconds % 60)]
            : [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
        [_durationBadge setText:[@"▶ " stringByAppendingString:duration] color:[NSColor colorWithWhite:0 alpha:0.6]];
    }

    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:item.relativePath];
    [lines addObject:[NSString stringWithFormat:@"%@, %@", dimensions,
                      [NSByteCountFormatter stringFromByteCount:(long long)item.fileSize countStyle:NSByteCountFormatterCountStyleFile]]];
    [lines addObject:[NSString stringWithFormat:@"%@: %@", POItemDateSourceText(item), date]];
    if (item.isCloudOnly) [lines addObject:POL(@"Не загружен из iCloud: дата взята из файла, на дубликаты не проверялся")];
    NSDictionary<NSString *, NSNumber *> *labels = item.labels;
    if (labels.count) {
        NSArray<NSString *> *sorted = [labels keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
        if (sorted.count > 8) sorted = [sorted subarrayWithRange:NSMakeRange(0, 8)];
        NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSet];
        for (NSString *label in sorted) [names addObject:POLabelDisplayName(label)];
        [lines addObject:[POL(@"На снимке: ") stringByAppendingString:[names.array componentsJoinedByString:@", "]]];
    }
    if (item.nudityScore) [lines addObject:[NSString stringWithFormat:POL(@"Оценка откровенности: %.0f %%"), item.nudityScore.doubleValue * 100]];
    if (item.duplicateOf) [lines addObject:[NSString stringWithFormat:POL(@"Копия файла %@"), item.duplicateOf.relativePath]];
    if (item.destinationFolder) {
        [lines addObject:item.needsMove ? [NSString stringWithFormat:@"→ %@/", item.destinationFolder] : POL(@"Уже на месте")];
    }
    self.view.toolTip = [lines componentsJoinedByString:@"\n"];

    [POThumbnailCache.sharedCache cancel:_thumbnailToken];
    NSString *path = item.url.path;
    _path = path;
    _thumb.image = nil;
    _thumb.showsActualSize = item.isTiny;
    __weak typeof(self) weakSelf = self;
    _thumbnailToken = [POThumbnailCache.sharedCache thumbnailForURL:item.url
                                                               size:280
                                                              scale:NSScreen.mainScreen.backingScaleFactor ?: 2
                                                         completion:^(CGImageRef image) {
        typeof(self) cell = weakSelf;
        if (cell && [cell->_path isEqualToString:path]) cell->_thumb.image = (__bridge id)image;
    }];
}

@end

#pragma mark - Section header

@interface POSectionHeaderView : NSView <NSCollectionViewElement>
- (void)configureWithSection:(POGridSection *)section;
@end

@implementation POSectionHeaderView {
    NSImageView *_icon;
    NSTextField *_titleLabel;
    NSTextField *_detailLabel;
    NSButton *_actionButton;
    void (^_action)(void);
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        // Opaque-looking background so photos scrolling underneath a pinned header don't show through.
        NSVisualEffectView *background = [NSVisualEffectView new];
        background.material = NSVisualEffectMaterialContentBackground;
        background.blendingMode = NSVisualEffectBlendingModeWithinWindow;
        background.translatesAutoresizingMaskIntoConstraints = NO;

        _icon = [NSImageView new];
        _icon.contentTintColor = NSColor.secondaryLabelColor;
        _icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium];
        _titleLabel = [NSTextField labelWithString:@""];
        _titleLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _detailLabel = [NSTextField labelWithString:@""];
        _detailLabel.font = [NSFont systemFontOfSize:12];
        _detailLabel.textColor = NSColor.secondaryLabelColor;
        [_titleLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

        _actionButton = [NSButton buttonWithTitle:@"" target:self action:@selector(runAction:)];
        _actionButton.controlSize = NSControlSizeSmall;
        _actionButton.bezelColor = NSColor.controlAccentColor;
        _actionButton.hidden = YES;
        NSStackView *stack = [NSStackView stackViewWithViews:@[_icon, _titleLabel, _detailLabel, _actionButton]];
        stack.spacing = 7;
        stack.alignment = NSLayoutAttributeFirstBaseline;
        stack.translatesAutoresizingMaskIntoConstraints = NO;

        [self addSubview:background];
        [self addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [background.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [background.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [background.topAnchor constraintEqualToAnchor:self.topAnchor],
            [background.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
            [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-8],
            [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}

- (void)configureWithSection:(POGridSection *)section {
    _icon.image = [NSImage imageWithSystemSymbolName:section.symbolName accessibilityDescription:nil];
    _titleLabel.stringValue = section.title;
    _detailLabel.stringValue = section.detail;
    _action = section.action;
    _actionButton.hidden = !section.actionTitle || !section.action;
    _actionButton.title = section.actionTitle ?: @"";
}

- (void)runAction:(id)sender {
    if (_action) _action();
}

@end

#pragma mark - Collection view

@protocol POCollectionViewActions <NSObject>
- (void)openSelection:(nullable id)sender;
- (void)togglePreviewPanel:(nullable id)sender;
@end

@interface POCollectionView : NSCollectionView
@property (nonatomic, weak) id<POCollectionViewActions> actionTarget;
@end

@implementation POCollectionView

- (void)keyDown:(NSEvent *)event {
    if ([event.charactersIgnoringModifiers isEqualToString:@" "]) {
        [self.actionTarget togglePreviewPanel:self];
    } else {
        [super keyDown:event];
    }
}

- (void)mouseDown:(NSEvent *)event {
    // Handled before NSCollectionView's own tracking, which treats a click on a selected item as the possible
    // start of a drag and would delay or swallow the second click.
    NSIndexPath *indexPath = [self indexPathForItemAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (event.clickCount == 2 && indexPath) {
        [self deselectAll:nil];
        [self selectItemsAtIndexPaths:[NSSet setWithObject:indexPath] scrollPosition:NSCollectionViewScrollPositionNone];
        [self.actionTarget openSelection:self];
        return;
    }
    [super mouseDown:event];
}

/// Right-clicking an unselected photo selects it first, like Finder does.
- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSIndexPath *indexPath = [self indexPathForItemAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (!indexPath) return nil;
    if (![self.selectionIndexPaths containsObject:indexPath]) {
        [self deselectAll:nil];
        [self selectItemsAtIndexPaths:[NSSet setWithObject:indexPath] scrollPosition:NSCollectionViewScrollPositionNone];
    }
    return self.menu;
}

@end

#pragma mark - Controller

@interface POGridViewController () <NSCollectionViewDataSource, NSCollectionViewDelegate, POCollectionViewActions,
                                    QLPreviewPanelDataSource, QLPreviewPanelDelegate>
@end

/// The grid's container: a drop target for an image while the grid is in "search by photo" mode.
@interface POGridDropView : NSView
@property (nonatomic, copy) void (^onImageDropped)(NSURL *url);
@property (nonatomic) BOOL highlighted;
@end

@implementation POGridDropView

- (NSURL *)imageURLFrom:(id<NSDraggingInfo>)sender {
    if (!self.onImageDropped || sender.draggingSource) return nil;   // not the grid's own files going out
    NSURL *url = [sender.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}].firstObject;
    NSString *type = nil;
    [url getResourceValue:&type forKey:NSURLTypeIdentifierKey error:NULL];
    return type && [[UTType typeWithIdentifier:type] conformsToType:UTTypeImage] ? url : nil;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    if (![self imageURLFrom:sender]) return NSDragOperationNone;
    self.highlighted = YES;
    return NSDragOperationCopy;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    self.highlighted = NO;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    self.highlighted = NO;
    NSURL *url = [self imageURLFrom:sender];
    if (url) self.onImageDropped(url);
    return url != nil;
}

- (void)setHighlighted:(BOOL)highlighted {
    _highlighted = highlighted;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    if (!self.highlighted) return;
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 12, 12) xRadius:14 yRadius:14];
    const CGFloat dash[] = {9, 6};
    [path setLineDash:dash count:2 phase:0];
    path.lineWidth = 3;
    [NSColor.controlAccentColor setStroke];
    [path stroke];
}

@end

@interface POGridViewController ()
/// Width of the year strip while it is shown, 0 otherwise.
@property (nonatomic, readonly) CGFloat yearBarWidth;
@end

@implementation POGridViewController {
    POCollectionView *_collectionView;
    NSArray<POGridSection *> *_sections;
    BOOL _showsOriginalBadge;
    NSArray<NSURL *> *_previewURLs;
    NSVisualEffectView *_yearBar;          // jump-to-year strip along the right edge
    NSStackView *_yearStack;
    NSTextField *_placeholderLabel;
    NSArray<NSIndexPath *> *_yearStarts;
    NSInteger _jumpedYear;        // the year last chosen in the strip, and the scroll position it left the grid at
    CGFloat _jumpedOffset;    // for each button of _yearStack: the first photo of that year
}

- (void)setCellWidth:(CGFloat)cellWidth {
    cellWidth = MIN(MAX(cellWidth, 90), 480);
    if (cellWidth == _cellWidth) return;
    _cellWidth = cellWidth;
    [NSUserDefaults.standardUserDefaults setDouble:cellWidth forKey:POCellWidthKey];
    [_collectionView.collectionViewLayout invalidateLayout];
}

- (void)loadView {
    _sections = @[];
    CGFloat savedWidth = [NSUserDefaults.standardUserDefaults doubleForKey:POCellWidthKey];
    _cellWidth = savedWidth >= 90 ? MIN(savedWidth, 480) : PODefaultCellWidth;
    _collectionView = [POCollectionView new];
    _collectionView.collectionViewLayout = [self makeLayout];
    _collectionView.dataSource = self;
    _collectionView.delegate = self;
    _collectionView.actionTarget = self;
    _collectionView.selectable = YES;
    _collectionView.allowsMultipleSelection = YES;
    // Selected files can be dragged to Finder or another app: Finder moves them within the volume and copies
    // across volumes (⌥ forces a copy). Dropping them back onto this window does nothing.
    [_collectionView setDraggingSourceOperationMask:NSDragOperationCopy | NSDragOperationMove | NSDragOperationGeneric forLocal:NO];
    [_collectionView setDraggingSourceOperationMask:NSDragOperationNone forLocal:YES];
    [_collectionView registerClass:POPhotoCell.class forItemWithIdentifier:POCellIdentifier];
    [_collectionView registerClass:POSectionHeaderView.class
        forSupplementaryViewOfKind:NSCollectionElementKindSectionHeader
                    withIdentifier:POHeaderIdentifier];

    NSMenu *menu = [NSMenu new];
    [[menu addItemWithTitle:POL(@"Открыть") action:@selector(openSelection:) keyEquivalent:@""] setTarget:self];
    [[menu addItemWithTitle:POL(@"Быстрый просмотр") action:@selector(togglePreviewPanel:) keyEquivalent:@""] setTarget:self];
    [[menu addItemWithTitle:POL(@"Открыть в программе по умолчанию") action:@selector(openSelectionExternally:) keyEquivalent:@""] setTarget:self];
    [[menu addItemWithTitle:POL(@"Показать в Finder") action:@selector(revealSelection:) keyEquivalent:@""] setTarget:self];
    [[menu addItemWithTitle:POL(@"Скопировать путь") action:@selector(copySelectionPaths:) keyEquivalent:@""] setTarget:self];
    [menu addItem:NSMenuItem.separatorItem];
    // These go up the responder chain to the window controller, which owns the files.
    [menu addItemWithTitle:POL(@"Показать в медиатеке по дате") action:@selector(showInLibrary:) keyEquivalent:@""];
    [menu addItemWithTitle:POL(@"Задать дату…") action:@selector(setDateForSelection:) keyEquivalent:@""];
    [menu addItemWithTitle:POL(@"Найти похожие") action:@selector(findSimilarToSelection:) keyEquivalent:@""];
    [menu addItemWithTitle:POL(@"Найти этот предмет на других фото…") action:@selector(findObjectInSelection:) keyEquivalent:@""];
    [menu addItemWithTitle:POL(@"Переместить в папку…") action:@selector(moveSelectionToFolder:) keyEquivalent:@""];
    [menu addItemWithTitle:POL(@"Переместить в Корзину") action:@selector(trashSelection:) keyEquivalent:@""];
    _collectionView.menu = menu;

    NSScrollView *scrollView = [NSScrollView new];
    scrollView.documentView = _collectionView;
    scrollView.hasVerticalScroller = YES;
    // The parent pins this view below the toolbar, which keeps pinned section headers visible.
    scrollView.automaticallyAdjustsContentInsets = NO;
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    // A plain container, so the year strip can float above the scroll view rather than inside it.
    POGridDropView *container = [POGridDropView new];
    [container registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    [container addSubview:scrollView];
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:container.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
    ]];
    self.view = container;

    // Years down the right edge, like the scrubber in Photos: a click jumps to the first photo of that year.
    _yearStack = [NSStackView new];
    _yearStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    _yearStack.spacing = 0;
    _yearStack.edgeInsets = NSEdgeInsetsMake(8, 10, 8, 10);
    _yearStack.translatesAutoresizingMaskIntoConstraints = NO;
    _yearBar = [NSVisualEffectView new];
    _yearBar.material = NSVisualEffectMaterialPopover;
    _yearBar.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    _yearBar.state = NSVisualEffectStateActive;
    _yearBar.wantsLayer = YES;
    _yearBar.layer.cornerRadius = 10;
    _yearBar.translatesAutoresizingMaskIntoConstraints = NO;
    _yearBar.hidden = YES;
    [_yearBar addSubview:_yearStack];
    [container addSubview:_yearBar positioned:NSWindowAbove relativeTo:scrollView];
    _placeholderLabel = [NSTextField wrappingLabelWithString:@""];
    _placeholderLabel.font = [NSFont systemFontOfSize:17 weight:NSFontWeightMedium];
    _placeholderLabel.textColor = NSColor.secondaryLabelColor;
    _placeholderLabel.alignment = NSTextAlignmentCenter;
    _placeholderLabel.selectable = NO;
    _placeholderLabel.hidden = YES;
    _placeholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_placeholderLabel positioned:NSWindowAbove relativeTo:scrollView];
    [NSLayoutConstraint activateConstraints:@[
        [_placeholderLabel.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [_placeholderLabel.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [_placeholderLabel.widthAnchor constraintLessThanOrEqualToConstant:460],
    ]];
    [NSLayoutConstraint activateConstraints:@[
        [_yearStack.topAnchor constraintEqualToAnchor:_yearBar.topAnchor],
        [_yearStack.bottomAnchor constraintEqualToAnchor:_yearBar.bottomAnchor],
        [_yearStack.leadingAnchor constraintEqualToAnchor:_yearBar.leadingAnchor],
        [_yearStack.trailingAnchor constraintEqualToAnchor:_yearBar.trailingAnchor],
        [_yearBar.trailingAnchor constraintEqualToAnchor:scrollView.trailingAnchor constant:-16],
        [_yearBar.centerYAnchor constraintEqualToAnchor:scrollView.centerYAnchor],
        [_yearBar.topAnchor constraintGreaterThanOrEqualToAnchor:scrollView.topAnchor constant:44],
        [_yearBar.bottomAnchor constraintLessThanOrEqualToAnchor:scrollView.bottomAnchor constant:-8],
    ]];
    scrollView.contentView.postsBoundsChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(gridDidScroll:)
                                               name:NSViewBoundsDidChangeNotification object:scrollView.contentView];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setPlaceholder:(NSString *)placeholder {
    _placeholder = [placeholder copy];
    (void)self.view;
    [self updatePlaceholder];
}

- (void)setOnImageDropped:(void (^)(NSURL *))onImageDropped {
    _onImageDropped = [onImageDropped copy];
    ((POGridDropView *)self.view).onImageDropped = onImageDropped;
}

- (void)updatePlaceholder {
    NSUInteger count = 0;
    for (POGridSection *section in _sections) count += section.items.count;
    _placeholderLabel.stringValue = _placeholder ?: @"";
    _placeholderLabel.hidden = !_placeholder.length || count > 0;
}

#pragma mark Years

/// Rebuilds the year strip: one button per year, pointing at the first photo of that year in display order.
/// A year that turns up again later (the thumbnails and duplicates folders at the end, say) is not a new entry,
/// and a list that covers a single year needs no strip.
- (void)rebuildYearBar {
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    NSMutableArray<NSNumber *> *years = [NSMutableArray array];
    NSMutableArray<NSIndexPath *> *starts = [NSMutableArray array];
    NSInteger last = 0;
    for (NSUInteger section = 0; section < _sections.count; section++) {
        NSArray<POPhotoItem *> *items = _sections[section].items;
        for (NSUInteger index = 0; index < items.count; index++) {
            if (items[index].isUndated) continue;   // their date is only the file's
            NSInteger year = [calendar component:NSCalendarUnitYear fromDate:items[index].date];
            if (year <= last) continue;
            last = year;
            [years addObject:@(year)];
            [starts addObject:[NSIndexPath indexPathForItem:index inSection:section]];
        }
    }
    _yearStarts = starts;
    _jumpedYear = -1;
    for (NSView *view in _yearStack.arrangedSubviews.copy) [view removeFromSuperview];
    BOOL wasHidden = _yearBar.hidden;
    _yearBar.hidden = years.count < 2;
    if (_yearBar.hidden) {
        if (!wasHidden) [_collectionView.collectionViewLayout invalidateLayout];
        return;
    }
    for (NSUInteger i = 0; i < years.count; i++) {
        NSButton *button = [NSButton buttonWithTitle:years[i].stringValue target:self action:@selector(jumpToYear:)];
        button.bordered = NO;
        button.tag = (NSInteger)i;
        button.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
        button.contentTintColor = NSColor.secondaryLabelColor;
        button.toolTip = [NSString stringWithFormat:POL(@"Перейти к %@ году"), years[i]];
        [button.heightAnchor constraintEqualToConstant:22].active = YES;
        [_yearStack addArrangedSubview:button];
    }
    [_collectionView.collectionViewLayout invalidateLayout];
    // Which year is on screen is known only once the grid has been laid out.
    dispatch_async(dispatch_get_main_queue(), ^{ [self highlightVisibleYear]; });
}

- (CGFloat)yearBarWidth {
    return _yearBar.hidden ? 0 : _yearBar.fittingSize.width;
}

- (void)jumpToYear:(NSButton *)sender {
    NSUInteger index = (NSUInteger)sender.tag;
    if (index >= _yearStarts.count) return;
    NSIndexPath *start = _yearStarts[index];
    NSCollectionViewLayoutAttributes *attributes = [_collectionView.collectionViewLayout layoutAttributesForItemAtIndexPath:start];
    if (!attributes) return;
    // The first photo of a section leaves room for the section's header above it; one further down goes to the top.
    CGFloat y = MAX(0, NSMinY(attributes.frame) - (start.item == 0 ? 44 : 40));
    [_collectionView scrollPoint:NSMakePoint(0, y)];
    // The year asked for stays lit while the grid stays where the jump left it, even when the grid could not
    // scroll that far (the last years, at the very bottom).
    _jumpedYear = sender.tag;
    _jumpedOffset = NSMinY(_collectionView.visibleRect);
    [self highlightYearAtIndex:sender.tag];
}

- (void)gridDidScroll:(NSNotification *)notification {
    [self highlightVisibleYear];
}

/// The year of the topmost visible section is shown in the accent colour.
- (void)highlightVisibleYear {
    if (_yearBar.hidden) return;
    // The current year is the last one whose first photo is at or above the top of the visible area. Worked out
    // from the layout itself, which is up to date at once, unlike the list of visible cells after a jump.
    if (_jumpedYear >= 0 && fabs(NSMinY(_collectionView.visibleRect) - _jumpedOffset) < 1) {
        [self highlightYearAtIndex:_jumpedYear];
        return;
    }
    _jumpedYear = -1;
    CGFloat top = NSMinY(_collectionView.visibleRect) + 60;
    NSInteger current = 0;
    for (NSUInteger i = 0; i < _yearStarts.count; i++) {
        NSCollectionViewLayoutAttributes *attributes = [_collectionView.collectionViewLayout layoutAttributesForItemAtIndexPath:_yearStarts[i]];
        if (attributes && NSMinY(attributes.frame) <= top) current = (NSInteger)i;
    }
    [self highlightYearAtIndex:current];
}

- (void)highlightYearAtIndex:(NSInteger)current {
    for (NSButton *button in _yearStack.arrangedSubviews) {
        BOOL isCurrent = button.tag == current;
        button.contentTintColor = isCurrent ? NSColor.controlAccentColor : NSColor.secondaryLabelColor;
        button.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:isCurrent ? NSFontWeightBold : NSFontWeightRegular];
    }
}

- (NSCollectionViewLayout *)makeLayout {
    __weak typeof(self) weakSelf = self;
    return [[NSCollectionViewCompositionalLayout alloc] initWithSectionProvider:
            ^NSCollectionLayoutSection *(NSInteger sectionIndex, id<NSCollectionLayoutEnvironment> environment) {
        const CGFloat inset = 10;
        // Room on the right for the year strip, so it never covers a photo.
        CGFloat trailing = weakSelf.yearBarWidth > 0 ? weakSelf.yearBarWidth + 26 : inset;
        CGFloat minimum = weakSelf.cellWidth ?: PODefaultCellWidth;
        CGFloat width = MAX(environment.container.effectiveContentSize.width - inset - trailing, minimum);
        NSInteger columns = MAX(1, (NSInteger)floor(width / minimum));
        CGFloat cellWidth = floor(width / columns);

        NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:
            [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0 / columns]
                                           heightDimension:[NSCollectionLayoutDimension fractionalHeightDimension:1]]];
        NSCollectionLayoutGroup *row = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:
            [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1]
                                           heightDimension:[NSCollectionLayoutDimension absoluteDimension:cellWidth + POCellCaptionHeight]]
                                                                                      subitem:item
                                                                                        count:columns];
        NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:row];
        section.contentInsets = NSDirectionalEdgeInsetsMake(2, inset, 18, trailing);

        NSCollectionLayoutBoundarySupplementaryItem *header = [NSCollectionLayoutBoundarySupplementaryItem
            boundarySupplementaryItemWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1]
                                                                                 heightDimension:[NSCollectionLayoutDimension absoluteDimension:38]]
                                        elementKind:NSCollectionElementKindSectionHeader
                                          alignment:NSRectAlignmentTop];
        header.pinToVisibleBounds = YES;
        section.boundarySupplementaryItems = @[header];
        return section;
    }];
}

- (void)setSections:(NSArray<POGridSection *> *)sections showsOriginalBadge:(BOOL)showsOriginalBadge {
    [self setSections:sections showsOriginalBadge:showsOriginalBadge keepScroll:NO];
}

- (void)setSections:(NSArray<POGridSection *> *)sections showsOriginalBadge:(BOOL)showsOriginalBadge keepScroll:(BOOL)keepScroll {
    (void)self.view;
    NSPoint position = _collectionView.visibleRect.origin;
    _sections = [sections copy];
    _showsOriginalBadge = showsOriginalBadge;
    [_collectionView reloadData];
    if (keepScroll) {
        [_collectionView layoutSubtreeIfNeeded];
        [_collectionView scrollPoint:position];
    } else {
        [_collectionView scrollPoint:NSZeroPoint];
    }
    [self rebuildYearBar];
    [self updatePlaceholder];
    [self selectionDidChange];
}

#pragma mark Data source

- (NSInteger)numberOfSectionsInCollectionView:(NSCollectionView *)collectionView {
    return _sections.count;
}

- (NSInteger)collectionView:(NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return _sections[section].items.count;
}

- (NSCollectionViewItem *)collectionView:(NSCollectionView *)collectionView itemForRepresentedObjectAtIndexPath:(NSIndexPath *)indexPath {
    POPhotoCell *cell = [collectionView makeItemWithIdentifier:POCellIdentifier forIndexPath:indexPath];
    [cell configureWithItem:_sections[indexPath.section].items[indexPath.item] showsOriginalBadge:_showsOriginalBadge showsNudityScore:self.showsNudityScores];
    return cell;
}

- (NSView *)collectionView:(NSCollectionView *)collectionView
    viewForSupplementaryElementOfKind:(NSCollectionViewSupplementaryElementKind)kind
                          atIndexPath:(NSIndexPath *)indexPath {
    POSectionHeaderView *header = [collectionView makeSupplementaryViewOfKind:kind withIdentifier:POHeaderIdentifier forIndexPath:indexPath];
    [header configureWithSection:_sections[indexPath.section]];
    return header;
}

#pragma mark Dragging files out

- (BOOL)collectionView:(NSCollectionView *)collectionView canDragItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths withEvent:(NSEvent *)event {
    return YES;
}

- (id<NSPasteboardWriting>)collectionView:(NSCollectionView *)collectionView pasteboardWriterForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section >= (NSInteger)_sections.count || indexPath.item >= (NSInteger)_sections[indexPath.section].items.count) return nil;
    return _sections[indexPath.section].items[indexPath.item].url;
}

- (void)collectionView:(NSCollectionView *)collectionView draggingSession:(NSDraggingSession *)session
          endedAtPoint:(NSPoint)screenPoint dragOperation:(NSDragOperation)operation {
    if (operation == NSDragOperationNone || !self.onFilesMovedAway) return;
    // The destination decides between moving and copying, and may finish a moment after the drop.
    NSArray<NSURL *> *urls = [session.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}] ?: @[];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        for (NSURL *url in urls) {
            if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) {
                if (self.onFilesMovedAway) self.onFilesMovedAway();
                return;
            }
        }
    });
}

#pragma mark Selection & actions

- (NSArray<POPhotoItem *> *)selectedItems {
    NSArray<NSIndexPath *> *indexPaths = [_collectionView.selectionIndexPaths.allObjects sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<POPhotoItem *> *items = [NSMutableArray array];
    for (NSIndexPath *indexPath in indexPaths) {
        if (indexPath.section < (NSInteger)_sections.count && indexPath.item < (NSInteger)_sections[indexPath.section].items.count) {
            [items addObject:_sections[indexPath.section].items[indexPath.item]];
        }
    }
    return items;
}

- (NSArray<POPhotoItem *> *)allItems {
    NSMutableOrderedSet<POPhotoItem *> *items = [NSMutableOrderedSet orderedSet];
    for (POGridSection *section in _sections) [items addObjectsFromArray:section.items];
    return items.array;
}

- (BOOL)hasKeyboardFocus {
    return self.viewLoaded && self.view.window.firstResponder == _collectionView;
}

/// ⌘C puts the selected files on the pasteboard, so ⌘V in Finder copies them and a text field gets their paths.
- (void)copy:(id)sender {
    NSArray<NSURL *> *urls = [self selectedURLs];
    if (!urls.count) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard writeObjects:urls];
}

- (void)copySelectionPaths:(id)sender {
    NSArray<NSString *> *paths = [[self selectedURLs] valueForKey:@"path"];
    if (!paths.count) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:[paths componentsJoinedByString:@"\n"] forType:NSPasteboardTypeString];
}

- (NSArray<NSURL *> *)selectedURLs {
    NSArray<NSIndexPath *> *indexPaths = [_collectionView.selectionIndexPaths.allObjects sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSIndexPath *indexPath in indexPaths) {
        if (indexPath.section < (NSInteger)_sections.count && indexPath.item < (NSInteger)_sections[indexPath.section].items.count) {
            [urls addObject:_sections[indexPath.section].items[indexPath.item].url];
        }
    }
    return urls;
}

- (void)collectionView:(NSCollectionView *)collectionView didSelectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths {
    [self selectionDidChange];
}

- (void)collectionView:(NSCollectionView *)collectionView didDeselectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths {
    [self selectionDidChange];
}

- (void)selectionDidChange {
    _previewURLs = [self selectedURLs];
    if (QLPreviewPanel.sharedPreviewPanelExists && QLPreviewPanel.sharedPreviewPanel.dataSource == self) {
        [QLPreviewPanel.sharedPreviewPanel reloadData];
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    return _collectionView.selectionIndexPaths.count > 0;
}

- (void)openSelection:(id)sender {
    NSIndexPath *first = [_collectionView.selectionIndexPaths.allObjects sortedArrayUsingSelector:@selector(compare:)].firstObject;
    if (!first || !self.onOpen || first.section >= (NSInteger)_sections.count) return;
    NSMutableArray<POPhotoItem *> *items = [NSMutableArray array];
    NSUInteger index = 0;
    for (NSInteger section = 0; section < (NSInteger)_sections.count; section++) {
        if (section == first.section) index = items.count + first.item;
        [items addObjectsFromArray:_sections[section].items];
    }
    self.onOpen(items, index);
}

- (void)openSelectedOrFirstItem {
    if (!_collectionView.selectionIndexPaths.count) {
        for (NSInteger section = 0; section < (NSInteger)_sections.count; section++) {
            if (!_sections[section].items.count) continue;
            [_collectionView selectItemsAtIndexPaths:[NSSet setWithObject:[NSIndexPath indexPathForItem:0 inSection:section]]
                                      scrollPosition:NSCollectionViewScrollPositionNone];
            break;
        }
    }
    [self openSelection:nil];
}

- (void)openSelectionExternally:(id)sender {
    for (NSURL *url in [self selectedURLs]) [NSWorkspace.sharedWorkspace openURL:url];
}

- (void)revealItem:(POPhotoItem *)item {
    for (NSInteger section = 0; section < (NSInteger)_sections.count; section++) {
        NSUInteger index = [_sections[section].items indexOfObjectIdenticalTo:item];
        if (index == NSNotFound) continue;
        NSSet<NSIndexPath *> *indexPaths = [NSSet setWithObject:[NSIndexPath indexPathForItem:index inSection:section]];
        [_collectionView deselectAll:nil];
        [_collectionView selectItemsAtIndexPaths:indexPaths scrollPosition:NSCollectionViewScrollPositionCenteredVertically];
        [self selectionDidChange];
        [self.view.window makeFirstResponder:_collectionView];
        return;
    }
}

- (void)revealSelection:(id)sender {
    NSArray<NSURL *> *urls = [self selectedURLs];
    if (urls.count) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:urls];
}

- (void)togglePreviewPanel:(id)sender {
    if (QLPreviewPanel.sharedPreviewPanelExists && QLPreviewPanel.sharedPreviewPanel.isVisible) {
        [QLPreviewPanel.sharedPreviewPanel orderOut:nil];
    } else if (_collectionView.selectionIndexPaths.count) {
        _previewURLs = [self selectedURLs];
        [QLPreviewPanel.sharedPreviewPanel makeKeyAndOrderFront:nil];
    }
}

#pragma mark Quick Look

- (BOOL)acceptsPreviewPanelControl:(QLPreviewPanel *)panel {
    return YES;
}

- (void)beginPreviewPanelControl:(QLPreviewPanel *)panel {
    panel.dataSource = self;
    panel.delegate = self;
}

- (void)endPreviewPanelControl:(QLPreviewPanel *)panel {
    panel.dataSource = nil;
    panel.delegate = nil;
}

- (NSInteger)numberOfPreviewItemsInPreviewPanel:(QLPreviewPanel *)panel {
    return _previewURLs.count;
}

- (id<QLPreviewItem>)previewPanel:(QLPreviewPanel *)panel previewItemAtIndex:(NSInteger)index {
    return _previewURLs[index];
}

/// Lets the arrow keys keep moving the grid selection while the panel is open.
- (BOOL)previewPanel:(QLPreviewPanel *)panel handleEvent:(NSEvent *)event {
    if (event.type == NSEventTypeKeyDown) {
        [_collectionView keyDown:event];
        return YES;
    }
    return NO;
}

@end
