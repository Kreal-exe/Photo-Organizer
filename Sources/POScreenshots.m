#import "POScreenshots.h"

/// Screens, as width × height in either orientation: phones, tablets, laptops and monitors.
static NSSet<NSString *> *POScreenSizes(void) {
    static NSSet<NSString *> *sizes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const int list[][2] = {
            // iPhone
            {640, 960}, {640, 1136}, {750, 1334}, {828, 1792}, {1080, 1920}, {1125, 2436}, {1170, 2532}, {1179, 2556}, {1206, 2622},
            {1242, 2208}, {1242, 2688}, {1284, 2778}, {1290, 2796}, {1320, 2868},
            // Android
            {720, 1280}, {720, 1600}, {1080, 2160}, {1080, 2220}, {1080, 2280}, {1080, 2340}, {1080, 2400}, {1080, 2408}, {1440, 2560},
            {1440, 2960}, {1440, 3040}, {1440, 3088}, {1440, 3120}, {1440, 3200}, {1260, 2800}, {1220, 2712}, {1256, 2760},
            // iPad
            {1536, 2048}, {1620, 2160}, {1640, 2360}, {1668, 2224}, {1668, 2388}, {1488, 2266}, {2048, 2732}, {2064, 2752},
            // Computers
            {1280, 800}, {1366, 768}, {1440, 900}, {1536, 864}, {1680, 1050}, {1920, 1080}, {1920, 1200}, {2560, 1080}, {2560, 1440},
            {2560, 1600}, {2880, 1800}, {2940, 1912}, {3024, 1964}, {3456, 2234}, {3840, 2160}, {5120, 2880},
        };
        NSMutableSet<NSString *> *set = [NSMutableSet set];
        for (size_t i = 0; i < sizeof(list) / sizeof(list[0]); i++) {
            [set addObject:[NSString stringWithFormat:@"%dx%d", list[i][0], list[i][1]]];
            [set addObject:[NSString stringWithFormat:@"%dx%d", list[i][1], list[i][0]]];
        }
        sizes = set;
    });
    return sizes;
}

BOOL POIsScreenshot(POPhotoItem *item) {
    if (item.isVideo) return NO;
    static NSRegularExpression *name;
    static NSSet<NSString *> *folders;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        name = [NSRegularExpression regularExpressionWithPattern:@"^(screenshot|screen shot|screen_shot|screencap|снимок экрана|скриншот|скрин|scr_|scrn_)|screenshot"
                                                         options:NSRegularExpressionCaseInsensitive error:NULL];
        folders = [NSSet setWithArray:@[@"screenshots", @"screen shots", @"screenshot", @"скриншоты", @"снимки экрана", @"screencaps"]];
    });
    NSString *base = item.url.lastPathComponent.stringByDeletingPathExtension.precomposedStringWithCanonicalMapping;
    if ([name firstMatchInString:base options:0 range:NSMakeRange(0, base.length)]) return YES;
    for (NSString *folder in [item.currentFolder componentsSeparatedByString:@"/"]) {
        if ([folders containsObject:folder.lowercaseString.precomposedStringWithCanonicalMapping]) return YES;
    }
    if (![item.url.pathExtension.lowercaseString isEqualToString:@"png"] || item.pixelWidth <= 0 || item.pixelHeight <= 0) return NO;
    if ([POScreenSizes() containsObject:[NSString stringWithFormat:@"%ldx%ld", (long)item.pixelWidth, (long)item.pixelHeight]]) return YES;
    // Phones keep getting new screens: anything as tall as a phone is one too.
    double tall = (double)MAX(item.pixelWidth, item.pixelHeight) / MIN(item.pixelWidth, item.pixelHeight);
    return tall >= 1.9 && MIN(item.pixelWidth, item.pixelHeight) >= 600;
}
