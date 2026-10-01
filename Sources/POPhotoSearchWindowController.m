#import "POPhotoSearchWindowController.h"
#import "POStrings.h"
#import "POSimilaritySearch.h"
#import "POAnalyzer.h"
#import "POLabels.h"

static const NSUInteger POMaximumWords = 10;

/// Image well that takes a dropped file and reports its URL.
@interface PODropImageView : NSImageView
@property (nonatomic, copy) void (^onDrop)(NSURL *url);
@end

@implementation PODropImageView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    }
    return self;
}

- (NSURL *)urlFrom:(id<NSDraggingInfo>)sender {
    return [sender.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}].firstObject;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return [self urlFrom:sender] ? NSDragOperationCopy : NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSURL *url = [self urlFrom:sender];
    if (url && self.onDrop) self.onDrop(url);
    return url != nil;
}

@end

@implementation POPhotoSearchWindowController {
    PODropImageView *_imageView;
    NSTextField *_hintLabel;
    NSTextField *_wordsTitle;
    NSStackView *_wordsStack;
    NSButton *_searchButton;
    NSProgressIndicator *_spinner;
    NSTextField *_statusLabel;
    id _image;                                 // CGImageRef of the example
    NSArray<NSString *> *_labels;              // identifiers, in the order of the checkboxes
    NSUInteger _loadGeneration;
}

+ (POPhotoSearchWindowController *)sharedController {
    static POPhotoSearchWindowController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [POPhotoSearchWindowController new]; });
    return shared;
}

- (instancetype)init {
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 340, 520)
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
                                                  backing:NSBackingStoreBuffered
                                                    defer:YES];
    if (!(self = [super initWithWindow:panel])) return nil;
    panel.title = POL(@"Поиск по фото");
    panel.floatingPanel = YES;
    panel.hidesOnDeactivate = NO;
    panel.becomesKeyOnlyIfNeeded = YES;

    _imageView = [PODropImageView new];
    _imageView.imageFrameStyle = NSImageFrameGrayBezel;
    _imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [_imageView.heightAnchor constraintEqualToConstant:200].active = YES;
    __weak typeof(self) weakSelf = self;
    _imageView.onDrop = ^(NSURL *url) { [weakSelf loadImageAtURL:url]; };

    _hintLabel = [NSTextField wrappingLabelWithString:POL(@"Перетащите сюда фото предмета, места или сцены (или вставьте его — ⌘V). Приложение опишет его словами, а потом найдёт в открытой папке "
                                                      @"файлы с тем же описанием и расставит их по внешнему сходству.")];
    _hintLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _hintLabel.textColor = NSColor.secondaryLabelColor;
    _hintLabel.selectable = NO;

    _wordsTitle = [NSTextField labelWithString:POL(@"Искать по словам:")];
    _wordsTitle.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    _wordsStack = [NSStackView new];
    _wordsStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    _wordsStack.alignment = NSLayoutAttributeLeading;
    _wordsStack.spacing = 4;

    _searchButton = [NSButton buttonWithTitle:POL(@"Найти похожие") target:self action:@selector(search:)];
    _searchButton.keyEquivalent = @"\r";
    _spinner = [NSProgressIndicator new];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.displayedWhenStopped = NO;
    NSStackView *buttonRow = [NSStackView stackViewWithViews:@[_searchButton, _spinner]];
    _statusLabel = [NSTextField wrappingLabelWithString:@""];
    _statusLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _statusLabel.textColor = NSColor.secondaryLabelColor;
    _statusLabel.selectable = NO;

    NSStackView *stack = [NSStackView stackViewWithViews:@[_imageView, _hintLabel, _wordsTitle, _wordsStack, buttonRow, _statusLabel]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.edgeInsets = NSEdgeInsetsMake(16, 16, 16, 16);
    for (NSView *wide in @[_imageView, _hintLabel, _statusLabel]) {
        [wide.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-32].active = YES;
    }
    [stack.widthAnchor constraintEqualToConstant:340].active = YES;
    panel.contentView = stack;
    [self showWords:@{}];
    [panel center];
    return self;
}

- (void)resizeToFit {
    NSWindow *window = self.window;
    NSSize size = window.contentView.fittingSize;
    NSRect frame = [window frameRectForContentRect:NSMakeRect(0, 0, size.width, size.height)];
    frame.origin = NSMakePoint(NSMinX(window.frame), NSMaxY(window.frame) - NSHeight(frame));
    [window setFrame:frame display:YES];
}

- (void)showWords:(NSDictionary<NSString *, NSNumber *> *)labels {
    NSArray<NSString *> *sorted = [labels keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
    if (sorted.count > POMaximumWords) sorted = [sorted subarrayWithRange:NSMakeRange(0, POMaximumWords)];
    _labels = sorted;
    for (NSView *view in _wordsStack.arrangedSubviews.copy) [view removeFromSuperview];
    for (NSString *label in sorted) {
        NSString *title = [NSString stringWithFormat:@"%@ — %.0f %%", POLabelDisplayName(label), labels[label].doubleValue * 100];
        NSButton *checkbox = [NSButton checkboxWithTitle:title target:nil action:NULL];
        checkbox.state = NSControlStateValueOn;
        [_wordsStack addArrangedSubview:checkbox];
    }
    BOOL hasImage = _image != nil;
    _wordsTitle.hidden = !hasImage;
    _wordsTitle.stringValue = sorted.count ? POL(@"Искать по словам:") : POL(@"Слов для этого фото не нашлось — сравним со всеми фото по виду.");
    _wordsStack.hidden = sorted.count == 0;
    _searchButton.enabled = hasImage;
    [self resizeToFit];
}

- (void)loadImageAtURL:(NSURL *)url {
    [self loadImageAtURL:url searchWhenReady:NO];
}

- (void)loadImageAtURL:(NSURL *)url searchWhenReady:(BOOL)searchWhenReady {
    NSUInteger generation = ++_loadGeneration;
    [self setStatus:POL(@"Описываем фото…") busy:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CGImageRef image = [POSimilaritySearch newImageWithContentsOfURL:url];
        NSDictionary<NSString *, NSNumber *> *labels = image ? [POAnalyzer labelsForImage:image] : @{};
        id retained = CFBridgingRelease(image);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_loadGeneration) return;
            if (!retained) {
                [self setStatus:POL(@"Этот файл не открывается как изображение.") busy:NO];
                return;
            }
            self->_image = retained;
            CGImageRef cgImage = (__bridge CGImageRef)retained;
            self->_imageView.image = [[NSImage alloc] initWithCGImage:cgImage size:NSMakeSize(CGImageGetWidth(cgImage), CGImageGetHeight(cgImage))];
            [self showWords:labels];
            if (searchWhenReady) [self search:nil];
            [self setStatus:@"" busy:NO];
        });
    });
}

/// ⌘V: a copied image file, or a picture copied from a browser or Preview.
- (void)paste:(id)sender {
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    NSURL *url = [pasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}].firstObject;
    if (url) {
        [self loadImageAtURL:url];
        return;
    }
    NSImage *image = [pasteboard readObjectsForClasses:@[NSImage.class] options:nil].firstObject;
    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgImage) {
        [self setStatus:POL(@"В буфере обмена нет картинки.") busy:NO];
        return;
    }
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
    NSURL *file = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:@"photo-organizer-pasted.png"];
    if ([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToURL:file atomically:YES]) [self loadImageAtURL:file];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action == @selector(paste:)) {
        return [NSPasteboard.generalPasteboard canReadObjectForClasses:@[NSURL.class, NSImage.class] options:nil];
    }
    return YES;
}

- (void)search:(id)sender {
    if (!_image || !self.onSearch) return;
    NSMutableArray<NSString *> *chosen = [NSMutableArray array];
    NSArray<NSButton *> *checkboxes = (NSArray<NSButton *> *)_wordsStack.arrangedSubviews;
    for (NSUInteger index = 0; index < checkboxes.count && index < _labels.count; index++) {
        if (checkboxes[index].state == NSControlStateValueOn) [chosen addObject:_labels[index]];
    }
    self.onSearch((__bridge CGImageRef)_image, chosen);
}

- (void)setStatus:(NSString *)status busy:(BOOL)busy {
    _statusLabel.stringValue = status;
    _searchButton.enabled = !busy && _image != nil;
    if (busy) [_spinner startAnimation:nil]; else [_spinner stopAnimation:nil];
    [self resizeToFit];
}

@end
