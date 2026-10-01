#import "POViewerViewController.h"
#import "POStrings.h"
#import <AVKit/AVKit.h>
#import <ImageIO/ImageIO.h>

/// Longest side, in pixels, an image is decoded at. Decoded memory grows with pixel count rather than file
/// size, so very large originals are downsampled by ImageIO instead of being decoded in full.
static const NSInteger POViewerMaxPixelSize = 6000;

enum { POKeyLeft = 123, POKeyRight = 124, POKeyEscape = 53, POKeySpace = 49 };

#pragma mark - Views

/// Keeps the image centred when it is smaller than the visible area.
@interface POCenteringClipView : NSClipView
@end

@implementation POCenteringClipView

- (NSRect)constrainBoundsRect:(NSRect)proposedBounds {
    NSRect bounds = [super constrainBoundsRect:proposedBounds];
    NSRect document = self.documentView.frame;
    if (NSWidth(document) < NSWidth(bounds)) bounds.origin.x = NSMidX(document) - NSWidth(bounds) / 2;
    if (NSHeight(document) < NSHeight(bounds)) bounds.origin.y = NSMidY(document) - NSHeight(bounds) / 2;
    return bounds;
}

@end

@protocol POViewerKeyHandling <NSObject>
- (BOOL)handleKeyDown:(NSEvent *)event;
- (void)handleDoubleClick:(NSEvent *)event;
@end

/// Root view: takes keyboard focus and sees every key press and click its subviews (the player, the scroll
/// view) don't use.
@interface POViewerRootView : NSView
@property (nonatomic, weak) id<POViewerKeyHandling> keyHandler;
@end

@implementation POViewerRootView

- (BOOL)acceptsFirstResponder { return YES; }

- (void)keyDown:(NSEvent *)event {
    if (![self.keyHandler handleKeyDown:event]) [super keyDown:event];
}

- (void)mouseDown:(NSEvent *)event {
    if (event.clickCount == 2) {
        [self.keyHandler handleDoubleClick:event];
    } else {
        [super mouseDown:event];
    }
}

@end

#pragma mark - Controller

@interface POViewerViewController () <POViewerKeyHandling>
@end

@implementation POViewerViewController {
    NSArray<POPhotoItem *> *_items;
    NSUInteger _index;
    NSUInteger _loadGeneration;   // drops image loads that finish after the user moved on
    dispatch_queue_t _decodeQueue;
    BOOL _fitsWindow;             // image follows the window size until the user zooms

    NSTextField *_nameLabel;
    NSTextField *_infoLabel;
    NSTextField *_counterLabel;
    NSButton *_previousButton;
    NSButton *_nextButton;
    NSView *_stage;
    NSScrollView *_scrollView;
    NSImageView *_imageView;
    AVPlayerView *_playerView;
    NSTextField *_messageLabel;
    NSProgressIndicator *_spinner;
}

static NSButton *POBarButton(NSString *symbol, NSString *toolTip, id target, SEL action) {
    NSButton *button = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:toolTip] target:target action:action];
    button.bezelStyle = NSBezelStyleAccessoryBarAction;
    button.toolTip = toolTip;
    return button;
}

- (void)loadView {
    _items = @[];
    _decodeQueue = dispatch_queue_create("photo-organizer.viewer.decode", DISPATCH_QUEUE_SERIAL);

    POViewerRootView *root = [POViewerRootView new];
    root.keyHandler = self;

    // Bar
    NSButton *backButton = [NSButton buttonWithTitle:POL(@"Назад") image:[NSImage imageWithSystemSymbolName:@"chevron.left" accessibilityDescription:nil]
                                              target:self action:@selector(close)];
    backButton.bezelStyle = NSBezelStyleAccessoryBarAction;
    backButton.imagePosition = NSImageLeading;
    backButton.toolTip = POL(@"Вернуться к сетке (Esc)");
    _nameLabel = [NSTextField labelWithString:@""];
    _nameLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _infoLabel = [NSTextField labelWithString:@""];
    _infoLabel.font = [NSFont systemFontOfSize:11];
    _infoLabel.textColor = NSColor.secondaryLabelColor;
    _infoLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    NSStackView *titles = [NSStackView stackViewWithViews:@[_nameLabel, _infoLabel]];
    titles.orientation = NSUserInterfaceLayoutOrientationVertical;
    titles.alignment = NSLayoutAttributeLeading;
    titles.spacing = 1;
    for (NSTextField *label in @[_nameLabel, _infoLabel]) {
        [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    // The titles take all spare width, which pushes the buttons to the trailing edge.
    [titles setHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    _counterLabel = [NSTextField labelWithString:@""];
    _counterLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    _counterLabel.textColor = NSColor.secondaryLabelColor;
    _previousButton = POBarButton(@"chevron.left", POL(@"Предыдущий (←)"), self, @selector(showPrevious:));
    _nextButton = POBarButton(@"chevron.right", POL(@"Следующий (→)"), self, @selector(showNext:));
    NSButton *fitButton = POBarButton(@"arrow.up.left.and.arrow.down.right", POL(@"По размеру окна / 100 % (двойной щелчок)"), self, @selector(toggleZoom:));
    NSButton *revealButton = POBarButton(@"folder", POL(@"Показать в Finder"), self, @selector(revealInFinder:));

    NSStackView *bar = [NSStackView stackViewWithViews:@[backButton, titles, _counterLabel, _previousButton, _nextButton, fitButton, revealButton]];
    bar.spacing = 8;
    bar.edgeInsets = NSEdgeInsetsMake(0, 12, 0, 12);
    [bar setCustomSpacing:14 afterView:backButton];
    [bar setCustomSpacing:14 afterView:_nextButton];
    bar.translatesAutoresizingMaskIntoConstraints = NO;

    // Stage
    _stage = [NSView new];
    _stage.wantsLayer = YES;
    _stage.layer.backgroundColor = NSColor.blackColor.CGColor;
    _stage.translatesAutoresizingMaskIntoConstraints = NO;

    _imageView = [NSImageView new];
    _imageView.imageScaling = NSImageScaleAxesIndependently;
    _imageView.animates = YES;
    _scrollView = [NSScrollView new];
    _scrollView.contentView = [POCenteringClipView new];
    _scrollView.documentView = _imageView;
    _scrollView.drawsBackground = NO;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = YES;
    _scrollView.autohidesScrollers = YES;
    _scrollView.allowsMagnification = YES;
    _scrollView.minMagnification = 0.02;
    _scrollView.maxMagnification = 16;
    _scrollView.automaticallyAdjustsContentInsets = NO;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(userDidMagnify:)
                                               name:NSScrollViewDidEndLiveMagnifyNotification object:_scrollView];

    _playerView = [AVPlayerView new];
    _playerView.controlsStyle = AVPlayerViewControlsStyleFloating;

    _messageLabel = [NSTextField labelWithString:@""];
    _messageLabel.textColor = [NSColor colorWithWhite:1 alpha:0.7];
    _messageLabel.font = [NSFont systemFontOfSize:14];
    _spinner = [NSProgressIndicator new];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.displayedWhenStopped = NO;
    _spinner.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    for (NSView *view in @[_scrollView, _playerView]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [_stage addSubview:view];
        [NSLayoutConstraint activateConstraints:@[
            [view.leadingAnchor constraintEqualToAnchor:_stage.leadingAnchor],
            [view.trailingAnchor constraintEqualToAnchor:_stage.trailingAnchor],
            [view.topAnchor constraintEqualToAnchor:_stage.topAnchor],
            [view.bottomAnchor constraintEqualToAnchor:_stage.bottomAnchor],
        ]];
    }
    for (NSView *view in @[_messageLabel, _spinner]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [_stage addSubview:view];
        [NSLayoutConstraint activateConstraints:@[
            [view.centerXAnchor constraintEqualToAnchor:_stage.centerXAnchor],
            [view.centerYAnchor constraintEqualToAnchor:_stage.centerYAnchor],
        ]];
    }

    [root addSubview:bar];
    [root addSubview:_stage];
    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [bar.heightAnchor constraintEqualToConstant:44],
        [_stage.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [_stage.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_stage.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_stage.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];
    self.view = root;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLayout {
    [super viewDidLayout];
    if (_fitsWindow) [self fitImage];
}

#pragma mark - Showing items

- (POPhotoItem *)currentItem {
    return _index < _items.count ? _items[_index] : nil;
}

- (void)showItems:(NSArray<POPhotoItem *> *)items atIndex:(NSUInteger)index {
    (void)self.view;
    _items = [items copy];
    _index = MIN(index, items.count ? items.count - 1 : 0);
    [self showCurrentItem];
    [self.view.window makeFirstResponder:self.view];
}

- (void)stop {
    _loadGeneration++;
    [_playerView.player pause];
    _playerView.player = nil;
    _imageView.image = nil;
    [_spinner stopAnimation:nil];
}

- (void)showCurrentItem {
    [self stop];
    POPhotoItem *item = [self currentItem];
    _messageLabel.stringValue = @"";
    _scrollView.hidden = item.isVideo;
    _playerView.hidden = !item.isVideo;
    if (!item) return;

    NSMutableArray<NSString *> *info = [NSMutableArray arrayWithObject:POItemDateText(item, YES)];
    if (item.pixelWidth > 0) [info addObject:[NSString stringWithFormat:@"%ld×%ld", (long)item.pixelWidth, (long)item.pixelHeight]];
    [info addObject:[NSByteCountFormatter stringFromByteCount:(long long)item.fileSize countStyle:NSByteCountFormatterCountStyleFile]];
    if (item.isDuplicate) [info addObject:POL(@"дубликат")];
    if (item.isTiny) [info addObject:POL(@"миниатюра")];
    if (item.destinationFolder) [info addObject:item.needsMove ? [@"→ " stringByAppendingString:item.destinationFolder] : POL(@"уже на месте")];
    _nameLabel.stringValue = item.relativePath;
    _infoLabel.stringValue = [info componentsJoinedByString:@" · "];
    _counterLabel.stringValue = [NSString stringWithFormat:POL(@"%@ из %@"), PONumber(_index + 1), PONumber(_items.count)];
    _previousButton.enabled = _index > 0;
    _nextButton.enabled = _index + 1 < _items.count;

    if (item.isVideo) {
        AVPlayer *player = [AVPlayer playerWithURL:item.url];
        _playerView.player = player;
        [player play];
    } else {
        [self loadImageForItem:item];
    }
}

- (void)loadImageForItem:(POPhotoItem *)item {
    NSUInteger generation = _loadGeneration;
    NSURL *url = item.url;
    CGFloat scale = self.view.window.backingScaleFactor ?: 2;
    [_spinner startAnimation:nil];

    // One decode at a time: a serial queue keeps fast ←/→ presses from piling up full-size decodes.
    dispatch_async(_decodeQueue, ^{
        NSImage *image = nil;
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, (__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCache: @NO});
        BOOL animated = source && CGImageSourceGetCount(source) > 1 && [url.pathExtension.lowercaseString isEqualToString:@"gif"];
        if (source && !animated) {
            NSDictionary *options = @{
                (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                (id)kCGImageSourceCreateThumbnailWithTransform: @YES,   // applies the EXIF orientation
                (id)kCGImageSourceThumbnailMaxPixelSize: @(POViewerMaxPixelSize),
                (id)kCGImageSourceShouldCacheImmediately: @YES,          // decode here, not on the main thread
            };
            CGImageRef decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
            if (decoded) {
                image = [[NSImage alloc] initWithCGImage:decoded
                                                    size:NSMakeSize(CGImageGetWidth(decoded) / scale, CGImageGetHeight(decoded) / scale)];
                CGImageRelease(decoded);
            }
        }
        if (source) CFRelease(source);
        // Animated GIFs and formats ImageIO can't thumbnail (SVG, …) go through NSImage.
        if (!image) image = [[NSImage alloc] initWithContentsOfURL:url];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_loadGeneration) return;
            [self->_spinner stopAnimation:nil];
            if (!image || image.size.width <= 0 || image.size.height <= 0) {
                self->_messageLabel.stringValue = POL(@"Не удалось открыть файл");
                return;
            }
            self->_imageView.image = image;
            self->_scrollView.magnification = 1;
            [self->_imageView setFrameSize:image.size];
            self->_fitsWindow = YES;
            [self fitImage];
        });
    });
}

#pragma mark - Zoom

/// The magnification at which the whole image is visible; never enlarges small images.
- (CGFloat)fittingMagnification {
    NSSize image = _imageView.frame.size, available = _scrollView.frame.size;
    if (image.width <= 0 || image.height <= 0 || available.width <= 0 || available.height <= 0) return 1;
    return MIN(1, MIN(available.width / image.width, available.height / image.height));
}

- (void)fitImage {
    if (!_imageView.image) return;
    _scrollView.magnification = [self fittingMagnification];
}

- (void)userDidMagnify:(NSNotification *)notification {
    _fitsWindow = NO;
}

- (void)toggleZoom:(id)sender {
    [self toggleZoomAtPoint:NSMakePoint(NSMidX(_imageView.bounds), NSMidY(_imageView.bounds))];
}

- (void)handleDoubleClick:(NSEvent *)event {
    [self toggleZoomAtPoint:[_imageView convertPoint:event.locationInWindow fromView:nil]];
}

/// Switches between "fit the window" and 100 %, keeping `center` (image coordinates) under the cursor.
- (void)toggleZoomAtPoint:(NSPoint)center {
    if (!_imageView.image || _scrollView.hidden) return;
    CGFloat fitting = [self fittingMagnification];
    BOOL isFitted = fabs(_scrollView.magnification - fitting) < 0.001;
    _fitsWindow = !isFitted;
    // Already at 100 % when fitted (a small image): zoom in instead of doing nothing.
    CGFloat target = isFitted ? (fitting < 1 ? 1 : 2) : fitting;
    [_scrollView.animator setMagnification:target centeredAtPoint:center];
}

- (BOOL)canZoom {
    return _imageView.image != nil && !_scrollView.hidden;
}

- (void)zoomBy:(CGFloat)factor {
    if (!self.canZoom) return;
    _fitsWindow = NO;
    NSRect visible = _scrollView.documentVisibleRect;
    CGFloat target = MIN(MAX(_scrollView.magnification * factor, _scrollView.minMagnification), _scrollView.maxMagnification);
    [_scrollView.animator setMagnification:target centeredAtPoint:NSMakePoint(NSMidX(visible), NSMidY(visible))];
}

- (void)zoomIn { [self zoomBy:1.5]; }
- (void)zoomOut { [self zoomBy:1 / 1.5]; }

- (void)zoomToActualSize {
    if (!self.canZoom) return;
    _fitsWindow = NO;
    NSRect visible = _scrollView.documentVisibleRect;
    [_scrollView.animator setMagnification:1 centeredAtPoint:NSMakePoint(NSMidX(visible), NSMidY(visible))];
}

- (void)zoomToFit {
    if (!self.canZoom) return;
    _fitsWindow = YES;
    _scrollView.animator.magnification = [self fittingMagnification];
}

#pragma mark - Actions

- (void)showPrevious:(id)sender {
    if (_index == 0) return;
    _index--;
    [self showCurrentItem];
}

- (void)showNext:(id)sender {
    if (_index + 1 >= _items.count) return;
    _index++;
    [self showCurrentItem];
}

- (void)revealInFinder:(id)sender {
    POPhotoItem *item = [self currentItem];
    if (item) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[item.url]];
}

- (void)close {
    POPhotoItem *item = [self currentItem];
    [self stop];
    if (self.onClose) self.onClose(item);
}

- (BOOL)handleKeyDown:(NSEvent *)event {
    switch (event.keyCode) {
        case POKeyLeft: [self showPrevious:nil]; return YES;
        case POKeyRight: [self showNext:nil]; return YES;
        case POKeyEscape: [self close]; return YES;
        case POKeySpace: {
            AVPlayer *player = _playerView.player;
            if (!player) return NO;
            if (player.rate == 0) [player play]; else [player pause];
            return YES;
        }
        default: return NO;
    }
}

@end
