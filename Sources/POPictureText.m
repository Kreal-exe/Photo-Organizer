#import "POPictureText.h"
#import <Vision/Vision.h>

// Enough for the text of a phone screenshot (1170–1290 pixels across) and a page; larger only costs time.
const NSInteger POTextPixelSize = 2000;

/// Labels (Vision's identifiers) of pictures that usually carry text.
static NSSet<NSString *> *POTextLabels(void) {
    static NSSet<NSString *> *labels;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        labels = [NSSet setWithArray:@[@"document", @"printed_page", @"handwriting", @"screenshot", @"receipt", @"sign", @"street_sign",
                                       @"newspaper", @"book", @"whiteboard", @"chart", @"diagram", @"map", @"computer", @"laptop", @"phone",
                                       @"television", @"storefront", @"graffiti", @"text", @"menu", @"poster"]];
    });
    return labels;
}

BOOL POWorthReadingText(POPhotoItem *item, NSDictionary<NSString *, NSNumber *> *labels) {
    if (item.isVideo) return NO;
    NSString *extension = item.url.pathExtension.lowercaseString;
    if ([@[@"png", @"webp", @"bmp", @"gif"] containsObject:extension]) return YES;
    if (item.pixelWidth > 0 && item.pixelHeight > 0) {
        double tall = (double)MAX(item.pixelWidth, item.pixelHeight) / MIN(item.pixelWidth, item.pixelHeight);
        if (tall >= 1.9) return YES;   // phone screenshots are about 2.17 : 1, photos 4 : 3 or 16 : 9
    }
    for (NSString *label in labels) {
        if ([POTextLabels() containsObject:label]) return YES;
    }
    return NO;
}

/// One pass of Vision's text recognition; nil when it failed.
static NSArray<NSString *> *PORecognizedLines(CGImageRef image, NSArray<NSString *> *languages) {
    VNRecognizeTextRequest *request = [VNRecognizeTextRequest new];
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    // Correction guesses at words the dictionary knows; the search wants what is written, and it costs time.
    request.usesLanguageCorrection = NO;
    if (languages.count) request.recognitionLanguages = languages;
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    NSError *error = nil;
    if (![handler performRequests:@[request] error:&error]) return nil;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (VNRecognizedTextObservation *observation in request.results) {
        NSString *line = [observation topCandidates:1].firstObject.string;
        if (line.length) [lines addObject:line];
    }
    return lines;
}

/// Russian and English where this macOS reads them (Russian came with macOS 13), asked for once.
static NSArray<NSString *> *POTextLanguages(void) {
    static NSArray<NSString *> *languages;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        VNRecognizeTextRequest *probe = [VNRecognizeTextRequest new];
        probe.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        NSArray<NSString *> *supported = [probe supportedRecognitionLanguagesAndReturnError:NULL] ?: @[];
        NSMutableArray<NSString *> *wanted = [NSMutableArray array];
        for (NSString *language in @[@"ru-RU", @"en-US"]) if ([supported containsObject:language]) [wanted addObject:language];
        languages = wanted;
    });
    return languages;
}

NSString *POTextInImage(CGImageRef image) {
    if (!image) return @"";
    // One pass reads both languages; only when this macOS refuses the pair is each read on its own.
    NSArray<NSString *> *languages = POTextLanguages();
    NSArray<NSString *> *lines = PORecognizedLines(image, languages);
    if (!lines && languages.count > 1) {
        NSMutableArray<NSString *> *merged = [NSMutableArray array];
        BOOL anyPass = NO;
        for (NSString *language in languages) {
            NSArray<NSString *> *found = PORecognizedLines(image, @[language]);
            if (!found) continue;
            anyPass = YES;
            for (NSString *line in found) if (![merged containsObject:line]) [merged addObject:line];
        }
        lines = anyPass ? merged : nil;
    }
    if (!lines) lines = PORecognizedLines(image, @[]);   // Vision's own default
    if (!lines) return nil;
    return [[lines componentsJoinedByString:@"\n"].lowercaseString stringByReplacingOccurrencesOfString:@"ё" withString:@"е"];
}
