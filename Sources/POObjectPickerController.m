#import "POObjectPickerController.h"
#import "POStrings.h"

/// The photo, fitted into the view, with a frame the user draws by dragging. Everything outside it is dimmed.
@interface POSelectionView : NSView
@property (nonatomic) CGImageRef image;
/// In image pixels, origin top-left; CGRectNull when nothing is selected.
@property (nonatomic) CGRect selection;
@property (nonatomic, copy) void (^onChange)(void);
@end

@implementation POSelectionView {
    NSPoint _dragStart;
}

- (BOOL)isFlipped { return YES; }

- (void)dealloc {
    CGImageRelease(_image);
}

- (void)setImage:(CGImageRef)image {
    CGImageRetain(image);
    CGImageRelease(_image);
    _image = image;
    self.needsDisplay = YES;
}

/// Where the image is drawn, in view coordinates.
- (NSRect)imageFrame {
    CGFloat width = CGImageGetWidth(_image), height = CGImageGetHeight(_image);
    if (width <= 0 || height <= 0) return NSZeroRect;
    CGFloat scale = MIN(NSWidth(self.bounds) / width, NSHeight(self.bounds) / height);
    NSSize size = NSMakeSize(width * scale, height * scale);
    return NSMakeRect((NSWidth(self.bounds) - size.width) / 2, (NSHeight(self.bounds) - size.height) / 2, size.width, size.height);
}

- (CGFloat)scale {
    return NSWidth([self imageFrame]) / MAX(1, CGImageGetWidth(_image));
}

- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.blackColor setFill];
    NSRectFill(self.bounds);
    if (!_image) return;
    NSRect frame = [self imageFrame];
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    // The view is flipped; CGContextDrawImage draws bottom-up.
    CGContextTranslateCTM(context, NSMinX(frame), NSMaxY(frame));
    CGContextScaleCTM(context, 1, -1);
    CGContextDrawImage(context, CGRectMake(0, 0, NSWidth(frame), NSHeight(frame)), _image);
    CGContextRestoreGState(context);
    if (CGRectIsNull(_selection)) return;
    CGFloat scale = [self scale];
    NSRect box = NSMakeRect(NSMinX(frame) + _selection.origin.x * scale, NSMinY(frame) + _selection.origin.y * scale,
                            _selection.size.width * scale, _selection.size.height * scale);
    // Everything around the frame is dimmed: four bands above, below, left and right of it.
    NSRect bands[4] = {
        NSMakeRect(NSMinX(frame), NSMinY(frame), NSWidth(frame), NSMinY(box) - NSMinY(frame)),
        NSMakeRect(NSMinX(frame), NSMaxY(box), NSWidth(frame), NSMaxY(frame) - NSMaxY(box)),
        NSMakeRect(NSMinX(frame), NSMinY(box), NSMinX(box) - NSMinX(frame), NSHeight(box)),
        NSMakeRect(NSMaxX(box), NSMinY(box), NSMaxX(frame) - NSMaxX(box), NSHeight(box)),
    };
    CGContextSetRGBFillColor(context, 0, 0, 0, 0.65);
    for (int i = 0; i < 4; i++) {
        if (bands[i].size.width > 0 && bands[i].size.height > 0) CGContextFillRect(context, NSRectToCGRect(bands[i]));
    }
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:box xRadius:4 yRadius:4];
    outline.lineWidth = 3;
    [NSColor.controlAccentColor setStroke];
    [outline stroke];
}

/// A view point as image pixels, kept inside the image.
- (NSPoint)imagePointFor:(NSPoint)point {
    NSRect frame = [self imageFrame];
    CGFloat scale = [self scale];
    CGFloat x = MIN(MAX(point.x, NSMinX(frame)), NSMaxX(frame)), y = MIN(MAX(point.y, NSMinY(frame)), NSMaxY(frame));
    return NSMakePoint((x - NSMinX(frame)) / scale, (y - NSMinY(frame)) / scale);
}

- (void)mouseDown:(NSEvent *)event {
    _dragStart = [self imagePointFor:[self convertPoint:event.locationInWindow fromView:nil]];
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint point = [self imagePointFor:[self convertPoint:event.locationInWindow fromView:nil]];
    self.selection = CGRectMake(MIN(point.x, _dragStart.x), MIN(point.y, _dragStart.y), fabs(point.x - _dragStart.x), fabs(point.y - _dragStart.y));
    self.needsDisplay = YES;
    if (self.onChange) self.onChange();
}

- (void)resetCursorRects {
    [self addCursorRect:[self imageFrame] cursor:NSCursor.crosshairCursor];
}

@end

@implementation POObjectPickerController {
    POSelectionView *_selectionView;
    NSButton *_findButton;
    CGRect _initialRect;
    CGImageRef _image;
}

- (instancetype)initWithImage:(CGImageRef)image initialRect:(CGRect)initialRect {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _image = CGImageRetain(image);
        _initialRect = initialRect;
    }
    return self;
}

- (void)dealloc {
    CGImageRelease(_image);
}

- (void)loadView {
    NSTextField *title = [NSTextField labelWithString:POL(@"Выделите предмет, который нужно найти")];
    title.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    NSTextField *note = [NSTextField wrappingLabelWithString:POL(@"Обведите его рамкой, потянув мышью. Чем плотнее рамка, тем точнее поиск: фото ищутся по тому, "
                                                                @"как выглядит именно этот предмет, а не по словам.")];
    note.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    note.textColor = NSColor.secondaryLabelColor;
    note.selectable = NO;
    note.preferredMaxLayoutWidth = 620;

    _selectionView = [POSelectionView new];
    _selectionView.image = _image;
    _selectionView.selection = _initialRect;
    _selectionView.translatesAutoresizingMaskIntoConstraints = NO;
    CGFloat aspect = (CGFloat)CGImageGetHeight(_image) / MAX(1, CGImageGetWidth(_image));
    [_selectionView.widthAnchor constraintEqualToConstant:620].active = YES;
    [_selectionView.heightAnchor constraintEqualToConstant:MIN(MAX(620 * aspect, 240), 520)].active = YES;
    __weak typeof(self) weakSelf = self;
    _selectionView.onChange = ^{ [weakSelf updateButton]; };

    NSButton *whole = [NSButton buttonWithTitle:POL(@"Всё фото") target:self action:@selector(selectWhole:)];
    NSButton *cancel = [NSButton buttonWithTitle:POL(@"Отмена") target:self action:@selector(cancel:)];
    cancel.keyEquivalent = @"\e";
    _findButton = [NSButton buttonWithTitle:POL(@"Найти") target:self action:@selector(find:)];
    _findButton.keyEquivalent = @"\r";
    NSStackView *buttons = [NSStackView stackViewWithViews:@[whole, [NSView new], cancel, _findButton]];

    NSStackView *stack = [NSStackView stackViewWithViews:@[title, note, _selectionView, buttons]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    [buttons.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-40].active = YES;
    self.view = stack;
    [self updateButton];
}

- (void)updateButton {
    CGRect selection = _selectionView.selection;
    _findButton.enabled = !CGRectIsNull(selection) && selection.size.width >= 16 && selection.size.height >= 16;
}

- (void)selectWhole:(id)sender {
    _selectionView.selection = CGRectMake(0, 0, CGImageGetWidth(_image), CGImageGetHeight(_image));
    _selectionView.needsDisplay = YES;
    [self updateButton];
}

- (void)cancel:(id)sender {
    [self.presentingViewController dismissViewController:self];
}

- (void)find:(id)sender {
    CGRect rect = _selectionView.selection;
    [self.presentingViewController dismissViewController:self];
    if (self.completion) self.completion(rect);
}

@end
