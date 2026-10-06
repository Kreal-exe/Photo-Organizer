// Draws the 1024×1024 app icon. Resources/AppIcon.icns is made from it by hand, only when the icon changes:
//   clang -fobjc-arc -framework Cocoa Tools/make_icon.m -o /tmp/make-icon && /tmp/make-icon /tmp/icon.png
//   mkdir /tmp/AppIcon.iconset; for s in 16 32 128 256 512; do sips -z $s $s /tmp/icon.png --out /tmp/AppIcon.iconset/icon_${s}x$s.png;
//     sips -z $((s*2)) $((s*2)) /tmp/icon.png --out /tmp/AppIcon.iconset/icon_${s}x$s@2x.png; done
//   iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
#import <Cocoa/Cocoa.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: make-icon output.png\n");
            return 1;
        }
        const CGFloat size = 1024;
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                           pixelsWide:size
                                                                           pixelsHigh:size
                                                                        bitsPerSample:8
                                                                      samplesPerPixel:4
                                                                             hasAlpha:YES
                                                                             isPlanar:NO
                                                                       colorSpaceName:NSDeviceRGBColorSpace
                                                                          bytesPerRow:0
                                                                         bitsPerPixel:0];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];

        // Apple's icon grid: an 824pt rounded square centred on the 1024pt canvas, with a soft drop shadow.
        NSRect plate = NSMakeRect(100, 100, 824, 824);
        NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:plate xRadius:185 yRadius:185];
        [NSGraphicsContext saveGraphicsState];
        NSShadow *shadow = [NSShadow new];
        shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.3];
        shadow.shadowOffset = NSMakeSize(0, -12);
        shadow.shadowBlurRadius = 28;
        [shadow set];
        [NSColor.whiteColor setFill];
        [shape fill];
        [NSGraphicsContext restoreGraphicsState];

        NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.36 green:0.72 blue:1.00 alpha:1]
                                                             endingColor:[NSColor colorWithSRGBRed:0.20 green:0.30 blue:0.86 alpha:1]];
        [gradient drawInBezierPath:shape angle:-90];

        NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:400 weight:NSFontWeightMedium];
        configuration = [configuration configurationByApplyingConfiguration:
                         [NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.whiteColor]]];
        NSImage *symbol = [[NSImage imageWithSystemSymbolName:@"photo.stack" accessibilityDescription:nil]
                           imageWithSymbolConfiguration:configuration];
        NSSize symbolSize = symbol.size;
        CGFloat scale = MIN(540 / symbolSize.width, 540 / symbolSize.height);
        NSSize drawn = NSMakeSize(symbolSize.width * scale, symbolSize.height * scale);
        [symbol drawInRect:NSMakeRect(NSMidX(plate) - drawn.width / 2, NSMidY(plate) - drawn.height / 2, drawn.width, drawn.height)
                  fromRect:NSZeroRect
                 operation:NSCompositingOperationSourceOver
                  fraction:1];

        [NSGraphicsContext.currentContext flushGraphics];
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        return [png writeToFile:@(argv[1]) atomically:YES] ? 0 : 1;
    }
}
