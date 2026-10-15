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
    return (PONameTraits(item) & PONameTraitGooglePhotosCreation) != 0;
}

PONameTrait PONameTraits(POPhotoItem *item) {
    PONameTrait traits = item.nameTraits;
    if (traits & PONameTraitKnown) return traits;
    traits = PONameTraitKnown;
    NSString *base = item.url.lastPathComponent.stringByDeletingPathExtension.precomposedStringWithCanonicalMapping;
    if (POMatches(@"-(collage|photo_frame|animation|effects|mix|snippet|cinematic|stylized)(\\(\\d+\\))?$|^movie(\\(\\d+\\))?$", base)) {
        traits |= PONameTraitGooglePhotosCreation;
    }
    if (POMatches(@"^(img|vid|pxl|mvimg)_\\d{8}_\\d{6}|^\\d{8}_\\d{6}|^dsc", base)) traits |= PONameTraitCamera;
    if (POHasScreenshotName(item)) traits |= PONameTraitScreenshot;
    if (POMatches(@"^(rpreplay|screenrecording|screen recording|screen_recording|screenrecorder|запись экрана|record_screen)", base)) {
        traits |= PONameTraitScreenRecording;
    }
    if (POMatches(@"^(img|vid|aud|ptt|stk)-\\d{8}-wa\\d+", base) || POInFolder(item, @"whatsapp")) traits |= PONameTraitWhatsApp;
    if (POMatches(@"^(photo|video|file)_\\d{4}-\\d{2}-\\d{2}_\\d{2}-\\d{2}-\\d{2}|^telegram-(cloud|peer)-", base) || POInFolder(item, @"telegram")) {
        traits |= PONameTraitTelegram;
    }
    if (POMatches(@"^viber[_ ]", base) || POInFolder(item, @"viber")) traits |= PONameTraitViber;
    if (POInFolder(item, @"instagram")) traits |= PONameTraitInstagram;
    if (POMatches(@"^pano[_-]", base)) traits |= PONameTraitPanorama;
    item.nameTraits = traits;
    return traits;
}

BOOL POTakenByCamera(POPhotoItem *item) {
    return item.hasLocation || item.dateSource == PODateSourceEXIF || (PONameTraits(item) & PONameTraitCamera);
}

float POGraphicScore(NSDictionary<NSString *, NSNumber *> *labels) {
    // Labels of something drawn, printed or written as a whole — not "art", which a photo of a room with a picture
    // on the wall gets too.
    static NSArray<NSString *> *graphic;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        graphic = @[@"illustrations", @"cartoon", @"document", @"printed_page", @"handwriting", @"chart", @"diagram", @"newspaper",
                    @"receipt", @"whiteboard"];
    });
    float score = 0;
    for (NSString *label in graphic) score = MAX(score, labels[label].floatValue);
    return score;
}

BOOL POLooksPhotographed(NSDictionary<NSString *, NSNumber *> *labels) {
    static NSArray<NSString *> *subjects;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        subjects = @[@"people", @"adult", @"child", @"teen", @"baby", @"animal", @"cat", @"dog", @"bird", @"sky", @"outdoor", @"interior_room"];
    });
    for (NSString *subject in subjects) if (labels[subject].floatValue >= 0.7f) return YES;
    return NO;
}

NSUInteger POLetterCount(NSString *text) {
    NSUInteger letters = 0;
    for (NSUInteger i = 0; i < text.length; i++) letters += [NSCharacterSet.letterCharacterSet characterIsMember:[text characterAtIndex:i]];
    return letters;
}

BOOL POHasPostcardWords(NSString *text) {
    if (POLetterCount(text) < POPostcardLetters) return NO;
    static NSRegularExpression *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Stems, so that endings and the odd misread letter ("с юбипеем") still match.
        NSString *pattern = @"поздрав|с (днем|днём|дне)|праздник|юби[лп]е|рожд[еє]ств|р[оа]ждеств|пасх|воскрес|благо[св]л|благовещ|"
                             "сретен|покров|троиц|крещен|успени|икон|святи?[тео]|свят[оаы]|господ|бог[аеу ]|ангел|молитв|матрон|"
                             "желаю|желаем|пусть|счасть|здоровь|любв|радост|добр(ое|ого|ой|ых) (утр|дн|веч|ноч)|доброе|спокойной|"
                             "с новым год|наступающ|8 марта|именин|храни|сохрани|спаси|мира и|тепла|улыб|"
                             "вітаю|щаст|свят[аи]|будь здоров|happy (birthday|new year|easter)|merry|good morning|good night";
        words = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    return [words numberOfMatchesInString:text options:0 range:NSMakeRange(0, text.length)] >= 2;
}

BOOL POHasCaption(NSString *text) {
    if (!text.length) return NO;
    static NSRegularExpression *words, *whole;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        words = [NSRegularExpression regularExpressionWithPattern:@"\\p{L}{3,}" options:0 error:NULL];
        // One alphabet, and a vowel of it.
        whole = [NSRegularExpression regularExpressionWithPattern:@"^(?=[а-яёіїєґ]+$).*[аеёиоуыэюяіїє]|^(?=[a-z]+$).*[aeiouy]"
                                                          options:0 error:NULL];
    });
    NSString *lower = text.lowercaseString;
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    for (NSTextCheckingResult *match in [words matchesInString:lower options:0 range:NSMakeRange(0, lower.length)]) {
        [found addObject:[lower substringWithRange:match.range]];
    }
    if (found.count < 4) return NO;
    NSUInteger clean = 0;
    for (NSString *word in found) clean += [whole firstMatchInString:word options:0 range:NSMakeRange(0, word.length)] != nil;
    return [NSSet setWithArray:found].count >= 0.6 * found.count && clean >= 0.95 * found.count;
}

BOOL POIsPictureByLabels(POPhotoItem *item) {
    NSDictionary<NSString *, NSNumber *> *labels = item.labels;
    float graphic = POGraphicScore(labels);
    if (!POLooksPhotographed(labels)) return graphic >= 0.6f;
    return graphic >= 0.9f || (graphic >= 0.3f && POHasPostcardWords(item.text));
}

BOOL POIsCollage(POPhotoItem *item) {
    // A video is a video, whatever Google Photos made it from (a snippet, a cinematic photo, a movie).
    if (item.isVideo) return NO;
    if (PONameTraits(item) & PONameTraitGooglePhotosCreation) return YES;
    if (POTakenByCamera(item) || item.pictureMark) return NO;
    NSNumber *collage = item.collageScore, *picture = item.pictureScore;
    if (!collage || !picture) return NO;
    // The likeliest of the three kinds, and likely enough.
    float c = collage.floatValue, p = picture.floatValue;
    return c >= 0.65f && c > p;
}

/// How sure MobileCLIP must be that a file is a picture; with a postcard's wishes read in it, likely is enough.
static const float POPictureSure = 0.85f, POPictureLikely = 0.6f, POPictureCertain = 0.97f, POPictureSuspected = 0.3f,
                   POPictureSuspectedWithPeople = 0.45f;
const float POPictureCaptioned = 0.15f;
/// Letters of a text that is the picture itself rather than a caption.
static const NSUInteger POLongText = 200;

BOOL POIsPicture(POPhotoItem *item) {
    NSNumber *mark = item.pictureMark;
    if (mark && !item.isVideo) return mark.boolValue;
    if (POIsCollage(item)) return YES;
    // What a camera took is a photo, whatever is in it (a painting on the wall, a document).
    if (item.isVideo || POIsScreenshot(item) || POTakenByCamera(item)) return NO;
    NSNumber *score = item.pictureScore;
    if (score) {
        float picture = score.floatValue;
        BOOL wishes = POHasPostcardWords(item.text), caption = POHasCaption(item.text);
        // People, animals or a landscape seen surely by the labels: a family photo or a church.
        BOOL photographed = POLooksPhotographed(item.labels);
        // Sure: a picture — where a photo would be seen, only all but certain or written on (a caption, a card's
        // wishes; not any writing: a banner or a monument behind people is read as a repetition or a jumble).
        if (picture >= POPictureSure) return !photographed || picture >= POPictureCertain || wishes || caption;
        // Likely, and written on.
        if (picture >= POPictureLikely) return wishes || caption;
        // Even not much like a picture, a caption above or below an image sent from the web makes one ("Так цветёт
        // папоротник!!!") — a band at its edge, not what is written in the scene (a T-shirt, a book, a diploma); where
        // people are seen too (a crowd under "Передавай по цепочке!"), CLIP must suspect it a little more.
        if (picture < POPictureCaptioned || !caption) return NO;
        // A long text that reads as one — a message passed on, a poem — is the picture itself.
        if (picture >= POPictureSuspected && POLetterCount(item.text) >= POLongText) return YES;
        // With people in it, a card's wishes on the band ("С юбилеем…") say so even when CLIP doubts.
        return item.textAtEdge.boolValue && (!photographed || picture >= POPictureSuspectedWithPeople ||
                                             (wishes && picture >= POPictureSuspected));
    }
    return POIsPictureByLabels(item);
}

NSString *POTypeFolder(POPhotoItem *item) {
    PONameTrait traits = PONameTraits(item);
    NSString *extension = item.url.pathExtension.lowercaseString;
    if (POIsCollage(item)) return POL(@"Коллажи");
    if (POIsPicture(item)) return POL(@"Картинки");
    if (POIsScreenshot(item)) return POL(@"Скриншоты");
    if (item.isVideo && (traits & PONameTraitScreenRecording)) return POL(@"Записи экрана");
    if (traits & PONameTraitWhatsApp) return @"WhatsApp";
    if (traits & PONameTraitTelegram) return @"Telegram";
    if (traits & PONameTraitViber) return @"Viber";
    if (traits & PONameTraitInstagram) return @"Instagram";
    if (item.isVideo) return POL(@"Видео");
    if ([extension isEqualToString:@"gif"]) return POL(@"Анимации");
    if ([PORawExtensions() containsObject:extension]) return @"RAW";
    if (traits & PONameTraitPanorama) return POL(@"Панорамы");
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
