#import "POMediaTypes.h"
#import "POScreenshots.h"
#import "POStrings.h"

static BOOL POMatches(NSString *pattern, NSString *text) {
    static NSMutableDictionary<NSString *, NSRegularExpression *> *expressions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ expressions = [NSMutableDictionary dictionary]; });
    NSRegularExpression *expression;
    @synchronized (expressions) {
        expression = expressions[pattern];
        if (!expression) {
            expression = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:NULL];
            expressions[pattern] = expression;
        }
    }
    return [expression firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil;
}

/// Camera RAW formats: scanned as photos, and organized by type into "RAW". The same list as on Windows.
static NSSet<NSString *> *PORawExtensions(void) {
    static NSSet<NSString *> *raw;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        raw = [NSSet setWithArray:@[@"dng", @"cr2", @"cr3", @"crw", @"nef", @"nrw", @"arw", @"srf", @"sr2", @"raf", @"orf", @"rw2", @"pef",
                                    @"srw", @"x3f", @"3fr", @"erf", @"kdc", @"rwl", @"iiq", @"mrw", @"dcr", @"mos", @"mef", @"raw"]];
    });
    return raw;
}

static BOOL POInFolder(POPhotoItem *item, NSString *name) {
    for (NSString *folder in [item.currentFolder componentsSeparatedByString:@"/"]) {
        if ([folder rangeOfString:name options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

BOOL POIsGooglePhotosCreation(POPhotoItem *item) {
    NSString *base = item.url.lastPathComponent.stringByDeletingPathExtension.precomposedStringWithCanonicalMapping;
    return POMatches(@"-(collage|photo_frame|animation|effects|mix|snippet|cinematic|stylized)(\\(\\d+\\))?$|^movie(\\(\\d+\\))?$", base);
}

BOOL POIsPicture(POPhotoItem *item) {
    if (POIsGooglePhotosCreation(item)) return YES;
    // What a camera took is a photo, whatever is in it (a painting on the wall, a document): a capture date of its
    // own, a place, or a camera's name (IMG_20180117_181128, 20220909_145141, PXL_…, DSC…).
    if (item.isVideo || item.hasLocation || item.dateSource == PODateSourceEXIF || POIsScreenshot(item)) return NO;
    NSString *base = item.url.lastPathComponent.stringByDeletingPathExtension;
    if (POMatches(@"^(img|vid|pxl|mvimg)_\\d{8}_\\d{6}|^\\d{8}_\\d{6}|^dsc", base)) return NO;
    // Labels of something drawn, printed or written as a whole — not "art", which a photo of a room with a picture
    // on the wall gets too.
    static NSArray<NSString *> *graphic;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        graphic = @[@"illustrations", @"cartoon", @"document", @"printed_page", @"handwriting", @"chart", @"diagram", @"newspaper",
                    @"receipt", @"whiteboard"];
    });
    NSDictionary<NSString *, NSNumber *> *labels = item.labels;
    float score = 0;
    for (NSString *label in graphic) score = MAX(score, labels[label].floatValue);
    return score >= 0.6f;
}

NSString *POTypeFolder(POPhotoItem *item) {
    NSString *base = item.url.lastPathComponent.stringByDeletingPathExtension.precomposedStringWithCanonicalMapping;
    NSString *extension = item.url.pathExtension.lowercaseString;
    if (POIsGooglePhotosCreation(item)) return POL(@"Коллажи");
    if (POIsPicture(item)) return POL(@"Картинки");
    if (POIsScreenshot(item)) return POL(@"Скриншоты");
    if (item.isVideo && POMatches(@"^(rpreplay|screenrecording|screen recording|screen_recording|screenrecorder|запись экрана|record_screen)", base)) {
        return POL(@"Записи экрана");
    }
    if (POMatches(@"^(img|vid|aud|ptt|stk)-\\d{8}-wa\\d+", base) || POInFolder(item, @"whatsapp")) return @"WhatsApp";
    if (POMatches(@"^(photo|video|file)_\\d{4}-\\d{2}-\\d{2}_\\d{2}-\\d{2}-\\d{2}|^telegram-(cloud|peer)-", base) || POInFolder(item, @"telegram")) return @"Telegram";
    if (POMatches(@"^viber[_ ]", base) || POInFolder(item, @"viber")) return @"Viber";
    if (POInFolder(item, @"instagram")) return @"Instagram";
    if (item.isVideo) return POL(@"Видео");
    if ([extension isEqualToString:@"gif"]) return POL(@"Анимации");
    if ([PORawExtensions() containsObject:extension]) return @"RAW";
    if (POMatches(@"^pano[_-]", base)) return POL(@"Панорамы");
    // A panorama is wide and large: a narrow tall strip (a crop, a long picture from a messenger) is not one.
    if (item.pixelHeight > 0 && item.pixelWidth >= 2500 && (double)item.pixelWidth / item.pixelHeight >= 2.5) return POL(@"Панорамы");
    return POL(@"Фото");
}

NSString *POFormatFolder(POPhotoItem *item) {
    NSString *extension = item.url.pathExtension.uppercaseString;
    if ([@[@"JPG", @"JPEG", @"JPE"] containsObject:extension]) return @"JPEG";
    if ([@[@"TIF", @"TIFF"] containsObject:extension]) return @"TIFF";
    if ([@[@"HEIC", @"HEIF"] containsObject:extension]) return @"HEIC";
    return extension.length ? extension : POL(@"Без расширения");
}

POMediaFileKind POMediaKindOfExtension(NSString *extension) {
    static NSSet<NSString *> *images, *videos;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        images = [[NSSet setWithArray:@[@"jpg", @"jpeg", @"jpe", @"jfif", @"png", @"gif", @"bmp", @"tif", @"tiff", @"webp", @"heic", @"heif",
                                        @"avif", @"psd", @"ico", @"jp2", @"jxl"]] setByAddingObjectsFromSet:PORawExtensions()];
        // Not ".ts": it is far more often a TypeScript file than a video.
        videos = [NSSet setWithArray:@[@"mp4", @"m4v", @"mov", @"qt", @"avi", @"mkv", @"3gp", @"3g2", @"mts", @"m2ts", @"wmv", @"webm",
                                       @"mpg", @"mpeg", @"flv"]];
    });
    NSString *lower = extension.lowercaseString;
    if ([images containsObject:lower]) return POMediaFileKindImage;
    if ([videos containsObject:lower]) return POMediaFileKindVideo;
    return POMediaFileKindNone;
}
