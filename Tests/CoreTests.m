// End-to-end check of the non-UI core against a temporary folder of generated images: `make test`.
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "POScanner.h"
#import "POPlan.h"
#import "POOrganizer.h"
#import "POSimilarCopies.h"
#import "POVKAlbum.h"
#import "POManualDates.h"
#import "PODateSuggestions.h"
#import <CommonCrypto/CommonDigest.h>

static int failures = 0;

#define CHECK(condition, ...) \
    do { \
        if (!(condition)) { \
            failures++; \
            NSLog(@"FAIL %s:%d  %s  %@", __FILE_NAME__, __LINE__, #condition, [NSString stringWithFormat:@"" __VA_ARGS__]); \
        } \
    } while (0)

static void WriteImage(NSURL *url, UTType *type, size_t width, size_t height, CGFloat gray, NSString *exifDate) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGContextSetRGBFillColor(context, gray, gray * 0.5, 1 - gray, 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSDictionary *properties = exifDate ? @{(id)kCGImagePropertyExifDictionary: @{(id)kCGImagePropertyExifDateTimeOriginal: exifDate}} : @{};
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)type.identifier, 1, NULL);
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)properties);
    CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
}

/// Writes a one-second 320×240 QuickTime movie whose metadata carries `creationDate` (ISO 8601).
static BOOL WriteVideo(NSURL *url, NSString *creationDate) {
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeQuickTimeMovie error:NULL];
    AVMutableMetadataItem *date = [AVMutableMetadataItem metadataItem];
    date.keySpace = AVMetadataKeySpaceQuickTimeMetadata;
    date.key = AVMetadataQuickTimeMetadataKeyCreationDate;
    date.value = creationDate;
    writer.metadata = @[date];
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                   outputSettings:@{AVVideoCodecKey: AVVideoCodecTypeH264, AVVideoWidthKey: @320, AVVideoHeightKey: @240}];
    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                                                         sourcePixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                                                                                                       (id)kCVPixelBufferWidthKey: @320,
                                                                                                       (id)kCVPixelBufferHeightKey: @240}];
    [writer addInput:input];
    if (![writer startWriting]) return NO;
    [writer startSessionAtSourceTime:kCMTimeZero];
    for (int frame = 0; frame <= 10; frame++) {
        while (!input.readyForMoreMediaData) usleep(1000);
        CVPixelBufferRef buffer = NULL;
        CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer);
        if (!buffer) return NO;
        CVPixelBufferLockBaseAddress(buffer, 0);
        memset(CVPixelBufferGetBaseAddress(buffer), 20 * frame, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer));
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        [adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(frame, 10)];
        CVPixelBufferRelease(buffer);
    }
    [input markAsFinished];
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(finished); }];
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
    return writer.status == AVAssetWriterStatusCompleted;
}

/// A picture with enough structure to fingerprint: `seed` picks the layout, so equal seeds look alike.
static void WritePattern(NSURL *url, size_t width, size_t height, unsigned seed, CGFloat quality, NSString *exifDate) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    srand(seed);
    for (int i = 0; i < 40; i++) {
        CGContextSetRGBFillColor(context, rand() % 100 / 100.0, rand() % 100 / 100.0, rand() % 100 / 100.0, 1);
        CGContextFillRect(context, CGRectMake(width * (rand() % 100 / 100.0), height * (rand() % 100 / 100.0), width * 0.3, height * 0.3));
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSMutableDictionary *properties = [@{(id)kCGImageDestinationLossyCompressionQuality: @(quality)} mutableCopy];
    if (exifDate) properties[(id)kCGImagePropertyExifDictionary] = @{(id)kCGImagePropertyExifDateTimeOriginal: exifDate};
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)UTTypeJPEG.identifier, 1, NULL);
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)properties);
    CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
}

static POPlan *Scan(NSURL *root) {
    POScanner *scanner = [[POScanner alloc] initWithRootURL:root];
    scanner.deprioritizedFolders = @[POPlan.defaultDuplicatesFolderName];
    NSArray<POPhotoItem *> *items = [scanner scanWithProgress:nil];
    POPlan *plan = [[POPlan alloc] initWithRootURL:scanner.rootURL items:items];
    [plan rebuild];
    return plan;
}

static NSArray<NSString *> *Tree(NSURL *root) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *rootPath = root.URLByResolvingSymlinksInPath.path;
    for (NSString *path in [NSFileManager.defaultManager enumeratorAtPath:rootPath]) {
        BOOL isDirectory = NO;
        [NSFileManager.defaultManager fileExistsAtPath:[rootPath stringByAppendingPathComponent:path] isDirectory:&isDirectory];
        [paths addObject:isDirectory ? [path stringByAppendingString:@"/"] : path];
    }
    return [paths sortedArrayUsingSelector:@selector(compare:)];
}

/// SHA-256 of every file under `root`, sorted: equal before and after means no file was lost, added or altered.
static NSArray<NSString *> *ContentFingerprint(NSURL *root) {
    NSMutableArray<NSString *> *hashes = [NSMutableArray array];
    for (NSURL *url in [NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:nil options:0 errorHandler:nil]) {
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (!data) continue;   // directory
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
        [hashes addObject:[[NSData dataWithBytes:digest length:sizeof digest] base64EncodedStringWithOptions:0]];
    }
    return [hashes sortedArrayUsingSelector:@selector(compare:)];
}

int main(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *root = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[@"po-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [fm createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:NULL];

        NSURL *a = [root URLByAppendingPathComponent:@"a.jpg"];
        WriteImage(a, UTTypeJPEG, 1200, 900, 0.2, @"2021:06:15 10:00:00");
        [fm createDirectoryAtURL:[root URLByAppendingPathComponent:@"trip"] withIntermediateDirectories:YES attributes:nil error:NULL];

        [fm copyItemAtURL:a toURL:[root URLByAppendingPathComponent:@"trip/a copy.jpg"] error:NULL];
        // Same name as the original in another folder: must not overwrite anything when both land in one place.
        WriteImage([root URLByAppendingPathComponent:@"trip/a.jpg"], UTTypeJPEG, 1000, 800, 0.4, @"2021:12:31 23:59:59");
        // Small, but not a copy of anything: an ordinary photo, not a thumbnail.
        WriteImage([root URLByAppendingPathComponent:@"trip/thumb.jpg"], UTTypeJPEG, 160, 120, 0.6, @"2023:01:02 03:04:05");
        NSURL *png = [root URLByAppendingPathComponent:@"deep/er/shot.png"];
        WriteImage(png, UTTypePNG, 800, 600, 0.8, nil);
        NSDate *fileDate = [NSDate dateWithTimeIntervalSince1970:1551960000]; // 7 March 2019, noon UTC
        [fm setAttributes:@{NSFileCreationDate: fileDate, NSFileModificationDate: fileDate} ofItemAtPath:png.path error:NULL];
        // Small frame size on purpose: a video must never be flagged as a thumbnail.
        CHECK(WriteVideo([root URLByAppendingPathComponent:@"trip/clip.mov"], @"2020-08-09T12:00:00+0000"));
        [@"not a photo" writeToURL:[root URLByAppendingPathComponent:@"trip/notes.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];

        NSArray<NSString *> *before = Tree(root);
        NSArray<NSString *> *fingerprint = ContentFingerprint(root);

        // Scan
        POPlan *plan = Scan(root);
        CHECK(plan.items.count == 6, @"%lu items", plan.items.count);
        POPhotoItem *clip = [plan.items filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"video == YES"]].firstObject;
        CHECK([clip.relativePath isEqualToString:@"trip/clip.mov"], @"%@", clip.relativePath);
        CHECK(clip.pixelWidth == 320 && clip.pixelHeight == 240 && !clip.isTiny, @"%ld×%ld", clip.pixelWidth, clip.pixelHeight);
        CHECK(clip.duration > 0.5 && clip.duration < 2, @"%f", clip.duration);
        CHECK(plan.duplicateItems.count == 1, @"%lu duplicates", plan.duplicateItems.count);
        CHECK([plan.duplicateItems.firstObject.relativePath isEqualToString:@"trip/a copy.jpg"], @"%@", plan.duplicateItems.firstObject.relativePath);
        CHECK([plan.duplicateItems.firstObject.duplicateOf.relativePath isEqualToString:@"a.jpg"]);
        CHECK(plan.tinyItems.count == 0);
        for (POPhotoItem *item in plan.items) {
            BOOL isPNG = [item.relativePath hasSuffix:@".png"];
            CHECK(item.dateSource == (isPNG ? PODateSourceFile : PODateSourceEXIF), @"%@", item.relativePath);
            CHECK(item.pixelWidth > 0, @"%@", item.relativePath);
        }

        // Plan: by year (default)
        NSArray<NSString *> *folders = [plan.groups valueForKey:@"folder"];
        NSArray<NSString *> *expected = @[@"2020", @"2021", @"2023", POPlan.undatedFolderName, POPlan.defaultDuplicatesFolderName];
        CHECK([folders isEqualToArray:expected], @"%@", folders);
        CHECK(plan.pendingItems.count == 6);

        // Plan: other schemes and options
        plan.scheme = POSchemeYearMonthDay;
        plan.separateDuplicates = NO;
        plan.separateTiny = NO;
        [plan rebuild];
        folders = [plan.groups valueForKey:@"folder"];
        expected = @[@"2020/2020-08/2020-08-09", @"2021/2021-06/2021-06-15", @"2021/2021-12/2021-12-31", @"2023/2023-01/2023-01-02", POPlan.undatedFolderName];
        CHECK([folders isEqualToArray:expected], @"%@", folders);
        plan.scheme = POSchemeYear;
        plan.separateDuplicates = YES;
        plan.separateTiny = YES;
        [plan rebuild];

        // Apply
        POOrganizeResult *result = [POOrganizer applyPlan:plan progress:nil];
        CHECK(result.errors.count == 0, @"%@", result.errors);
        CHECK(result.records.count == 6);
        NSArray<NSString *> *after = Tree(root);
        expected = @[@"Без даты/", @"Без даты/shot.png", @"2020/", @"2020/clip.mov", @"2021/", @"2021/a (2).jpg", @"2021/a.jpg",
                     @"2023/", @"2023/thumb.jpg", @"trip/", @"trip/notes.txt", @"Дубликаты/", @"Дубликаты/a copy.jpg"];
        expected = [expected sortedArrayUsingSelector:@selector(compare:)];
        CHECK([[after valueForKey:@"precomposedStringWithCanonicalMapping"] isEqualToArray:[expected valueForKey:@"precomposedStringWithCanonicalMapping"]], @"%@", after);

        CHECK([ContentFingerprint(root) isEqualToArray:fingerprint]);

        // A file that changed after the scan is left alone.
        {
            NSURL *changing = [root URLByAppendingPathComponent:@"late.jpg"];
            WriteImage(changing, UTTypeJPEG, 900, 700, 0.9, @"2018:01:01 00:00:00");
            POPlan *stale = Scan(root);
            CHECK(stale.pendingItems.count == 1, @"%lu", stale.pendingItems.count);
            [@"overwritten meanwhile" writeToURL:changing atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            POOrganizeResult *skipped = [POOrganizer applyPlan:stale progress:nil];
            CHECK(skipped.records.count == 0 && skipped.errors.count == 1, @"%@", skipped.errors);
            CHECK([NSFileManager.defaultManager fileExistsAtPath:changing.path]);
            [NSFileManager.defaultManager removeItemAtURL:changing error:NULL];
        }

        // Naming options and custom folder names.
        {
            POPlan *named = Scan(root);
            named.scheme = POSchemeYearMonth;
            named.yearStyle = POYearStyleWord;
            named.monthStyle = POMonthStyleNumberName;
            named.duplicatesFolderName = @" Копии/: ";
            [named rebuild];
            NSArray<NSString *> *names = [named.groups valueForKey:@"folder"];
            NSArray<NSString *> *wanted = @[@"2020 год/08 Август", @"2021 год/06 Июнь", @"2021 год/12 Декабрь",
                                            @"2023 год/01 Январь", POPlan.undatedFolderName, @"Копии"];
            CHECK([names isEqualToArray:wanted], @"%@", names);

            [named setCustomName:@"/../Свадьба//фото/" forGroup:named.groups[1]];
            [named setCustomName:@"Свадьба/фото" forGroup:named.groups[2]];
            [named rebuild];
            names = [named.groups valueForKey:@"folder"];
            wanted = @[@"2020 год/08 Август", @"Свадьба/фото", @"2023 год/01 Январь", POPlan.undatedFolderName, @"Копии"];
            CHECK([names isEqualToArray:wanted], @"%@", names);
            CHECK(named.groups[1].items.count == 2 && named.hasCustomNames);

            [named setCustomName:@"" forGroup:named.groups[1]];
            named.nested = NO;
            [named rebuild];
            CHECK(!named.hasCustomNames);
            CHECK([[named.groups.firstObject folder] isEqualToString:@"08 Август"], @"%@", [named.groups.firstObject folder]);
        }

        // A second scan finds everything in place.
        POPlan *second = Scan(root);
        CHECK(second.items.count == 6 && second.pendingItems.count == 0, @"%lu pending", second.pendingItems.count);
        CHECK(second.duplicateItems.count == 1 && [second.duplicateItems.firstObject.relativePath hasPrefix:POPlan.defaultDuplicatesFolderName],
              @"%@", second.duplicateItems.firstObject.relativePath);

        // Undo restores the original tree exactly.
        NSArray<NSString *> *revertErrors = [POOrganizer revert:result];
        CHECK(revertErrors.count == 0, @"%@", revertErrors);
        CHECK([Tree(root) isEqualToArray:before], @"%@", Tree(root));
        CHECK([ContentFingerprint(root) isEqualToArray:fingerprint]);

        // Dates in file names
        {
            NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
            NSDictionary<NSString *, NSString *> *cases = @{
                @"20220909_145141.mp4": @"2022-9-9 14:51:41",
                @"IMG-20190305-WA0007.jpg": @"2019-3-5 12:0:0",
                @"PXL_20210704_183015123.jpg": @"2021-7-4 18:30:15",
                @"Screenshot 2023-01-02 at 03.04.05.png": @"2023-1-2 3:4:5",
                @"2018.12.31 party.jpg": @"2018-12-31 12:0:0",
            };
            for (NSString *name in cases) {
                NSDateComponents *c = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour |
                                                           NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:PODateFromFileName(name) ?: NSDate.distantPast];
                NSString *got = [NSString stringWithFormat:@"%ld-%ld-%ld %ld:%ld:%ld", c.year, c.month, c.day, c.hour, c.minute, c.second];
                CHECK([got isEqualToString:cases[name]], @"%@ → %@", name, got);
            }
            for (NSString *name in @[@"IMG_0001.jpg", @"2019123456.jpg", @"20221309_101010.jpg", @"photo-2019-1231.jpg", @"20990101_000000.mp4"]) {
                CHECK(PODateFromFileName(name) == nil, @"%@", name);
            }

            // A re-encoded video: metadata says 2024, the name says 2022 — the name wins. EXIF earlier than the name stays.
            NSURL *dated = [root URLByAppendingPathComponent:@"named"];
            [fm createDirectoryAtURL:dated withIntermediateDirectories:YES attributes:nil error:NULL];
            CHECK(WriteVideo([dated URLByAppendingPathComponent:@"20220909_145141.mov"], @"2024-05-05T10:00:00+0000"));
            WriteImage([dated URLByAppendingPathComponent:@"edit 2023-03-03.jpg"], UTTypeJPEG, 900, 700, 0.3, @"2021:02:02 08:00:00");
            // Re-encoded and renamed: metadata says 2024, but the file has existed since 2019.
            NSURL *old = [dated URLByAppendingPathComponent:@"export.mov"];
            CHECK(WriteVideo(old, @"2024-05-05T10:00:00+0000"));
            NSDate *created = [NSDate dateWithTimeIntervalSince1970:1551960000];
            [fm setAttributes:@{NSFileCreationDate: created} ofItemAtPath:old.path error:NULL];
            POPlan *named = Scan(dated);
            for (POPhotoItem *item in named.items) {
                NSInteger year = [calendar component:NSCalendarUnitYear fromDate:item.date];
                BOOL isExport = [item.relativePath isEqualToString:@"export.mov"];
                CHECK(year == (isExport ? 2019 : item.isVideo ? 2022 : 2021), @"%@ → %ld", item.relativePath, year);
                CHECK(item.dateSource == (isExport ? PODateSourceFile : item.isVideo ? PODateSourceName : PODateSourceEXIF), @"%@", item.relativePath);
            }
            [fm removeItemAtURL:dated error:NULL];
        }

        // Dates from neighbours in a numbered series
        {
            NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
            NSURL *series = [root URLByAppendingPathComponent:@"series"];
            WriteImage([series URLByAppendingPathComponent:@"IMG_0010.jpg"], UTTypeJPEG, 900, 700, 0.1, @"2017:07:01 10:00:00");
            WriteImage([series URLByAppendingPathComponent:@"IMG_0011.png"], UTTypePNG, 900, 700, 0.2, nil);    // between → dated
            WriteImage([series URLByAppendingPathComponent:@"IMG_0014.jpg"], UTTypeJPEG, 900, 700, 0.3, @"2017:07:02 10:00:00");
            WriteImage([series URLByAppendingPathComponent:@"IMG_0015.png"], UTTypePNG, 900, 700, 0.4, nil);    // neighbours a year apart → left alone
            WriteImage([series URLByAppendingPathComponent:@"IMG_0020.jpg"], UTTypeJPEG, 900, 700, 0.5, @"2018:09:09 10:00:00");
            WriteImage([series URLByAppendingPathComponent:@"IMG_0021.png"], UTTypePNG, 900, 700, 0.6, nil);    // nothing after it → left alone
            WriteImage([series URLByAppendingPathComponent:@"scan.png"], UTTypePNG, 900, 700, 0.7, nil);        // not in a series
            NSInteger thisYear = [calendar component:NSCalendarUnitYear fromDate:NSDate.date];
            for (POPhotoItem *item in Scan(series).items) {
                NSInteger year = [calendar component:NSCalendarUnitYear fromDate:item.date];
                if ([item.relativePath isEqualToString:@"IMG_0011.png"]) {
                    CHECK(year == 2017 && item.dateSource == PODateSourceNeighbors, @"%@ → %ld", item.relativePath, year);
                } else if ([item.relativePath hasSuffix:@".png"]) {
                    CHECK(year == thisYear && item.dateSource == PODateSourceFile, @"%@ → %ld", item.relativePath, year);
                }
            }
            [fm removeItemAtURL:series error:NULL];
        }

        // Files with no date anywhere are undated (not guessed into a year); suggestions and manual dates.
        {
            NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
            POManualDates.storeURL = [root URLByAppendingPathComponent:@"dates.plist"];
            NSURL *takeout = [root URLByAppendingPathComponent:@"takeout"];
            WriteImage([takeout URLByAppendingPathComponent:@"Photos from 2018/IMG_1.jpg"], UTTypeJPEG, 900, 700, 0.1, @"2018:06:01 10:00:00");
            WriteImage([takeout URLByAppendingPathComponent:@"Photos from 2018/IMG_2.png"], UTTypePNG, 900, 700, 0.2, nil);   // between June and September shots
            WriteImage([takeout URLByAppendingPathComponent:@"Photos from 2018/IMG_3.jpg"], UTTypeJPEG, 900, 700, 0.3, @"2018:09:20 10:00:00");
            WriteImage([takeout URLByAppendingPathComponent:@"Photos from 2018/z.png"], UTTypePNG, 900, 700, 0.4, nil);   // only the folder knows
            WriteImage([takeout URLByAppendingPathComponent:@"misc/meme.png"], UTTypePNG, 900, 700, 0.5, nil);            // nothing at all
            POPlan *dated = Scan(takeout);
            [dated rebuild];
            PODateSuggester *suggester = [[PODateSuggester alloc] initWithItems:dated.items];
            for (POPhotoItem *item in dated.items) {
                NSString *name = item.url.lastPathComponent;
                PODateSuggestion *best = [suggester bestSuggestionForItem:item];
                if ([name hasSuffix:@".jpg"]) {
                    CHECK(!item.isUndated && !best, @"%@", name);
                    continue;
                }
                CHECK(item.isUndated && [item.destinationFolder isEqualToString:POPlan.undatedFolderName], @"%@ %@", name, item.destinationFolder);
                NSDateComponents *c = best ? [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:best.date] : nil;
                if ([name isEqualToString:@"IMG_2.png"]) {
                    CHECK(best.kind == PODateSuggestionNeighbors && best.precision == PODatePrecisionYear && c.year == 2018, @"%@ %@", best.reason, best.date);
                } else if ([name isEqualToString:@"z.png"]) {
                    CHECK(best.kind == PODateSuggestionFolderName && best.precision == PODatePrecisionYear && c.year == 2018, @"%@", best.reason);
                } else {
                    CHECK(!best && [suggester suggestionsForItem:item].lastObject.kind == PODateSuggestionFileDate, @"%@", best.reason);
                }
            }

            // A date given by hand is kept, survives a rescan and a rename, and puts the file into its year.
            POPhotoItem *meme = [dated.items filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"relativePath ENDSWITH 'meme.png'"]].firstObject;
            NSDateComponents *may2015 = [NSDateComponents new];
            may2015.year = 2015; may2015.month = 5; may2015.day = 1; may2015.hour = 12;
            [POManualDates setDate:[calendar dateFromComponents:may2015] precision:PODatePrecisionMonth forItems:@[meme]];
            [fm moveItemAtURL:meme.url toURL:[meme.url.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"renamed.png"] error:NULL];
            POPlan *again = Scan(takeout);
            again.scheme = POSchemeYearMonthDay;
            [again rebuild];
            POPhotoItem *renamed = [again.items filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"relativePath ENDSWITH 'renamed.png'"]].firstObject;
            CHECK(renamed.dateSource == PODateSourceManual && !renamed.isUndated && [renamed.destinationFolder isEqualToString:@"2015/2015-05"], @"%@", renamed.destinationFolder);
            [POManualDates setDate:nil precision:PODatePrecisionDay forItems:@[renamed]];
            CHECK(renamed.isUndated);
            [fm removeItemAtURL:takeout error:NULL];
        }

        // Google Takeout .json sidecars, months from distant neighbours, dates shared between copies.
        {
            NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
            NSURL *export = [root URLByAppendingPathComponent:@"export"];
            WriteImage([export URLByAppendingPathComponent:@"Photos from 2018/a.png"], UTTypePNG, 900, 700, 0.1, nil);
            WriteImage([export URLByAppendingPathComponent:@"Photos from 2018/a(1).png"], UTTypePNG, 900, 700, 0.15, nil);
            NSString *json = @"{\"title\": \"a.png\", \"photoTakenTime\": {\"timestamp\": \"1526385600\"}}";        // 15 May 2018
            [json writeToURL:[export URLByAppendingPathComponent:@"Photos from 2018/a.png.supplemental-metadata.json"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            NSString *copyJSON = @"{\"title\": \"a.png\", \"photoTakenTime\": {\"timestamp\": \"1530403200\"}}";   // 1 July 2018
            [copyJSON writeToURL:[export URLByAppendingPathComponent:@"Photos from 2018/a.png(1).json"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            WriteImage([export URLByAppendingPathComponent:@"cam/IMG_0100.jpg"], UTTypeJPEG, 900, 700, 0.2, @"2016:03:02 10:00:00");
            WriteImage([export URLByAppendingPathComponent:@"cam/IMG_0101.png"], UTTypePNG, 900, 700, 0.3, nil);
            WriteImage([export URLByAppendingPathComponent:@"cam/IMG_0102.jpg"], UTTypeJPEG, 900, 700, 0.4, @"2016:03:25 10:00:00");
            POPlan *plan = Scan(export);
            plan.scheme = POSchemeYearMonthDay;
            [plan rebuild];
            for (POPhotoItem *item in plan.items) {
                NSDateComponents *c = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:item.date];
                if ([item.relativePath hasSuffix:@"/a.png"]) {
                    CHECK(item.dateSource == PODateSourceTakeout && c.year == 2018 && c.month == 5, @"%@ %@", item.relativePath, item.date);
                } else if ([item.relativePath hasSuffix:@"a(1).png"]) {
                    CHECK(item.dateSource == PODateSourceTakeout && c.year == 2018 && c.month == 7, @"%@ %@", item.relativePath, item.date);
                } else if ([item.relativePath hasSuffix:@"IMG_0101.png"]) {
                    // 23 days apart: no day, but certainly March 2016 — and the plan stops at the month folder.
                    CHECK(item.dateSource == PODateSourceNeighborsMonth && c.year == 2016 && c.month == 3, @"%@", item.date);
                    CHECK([item.destinationFolder isEqualToString:@"2016/2016-03"], @"%@", item.destinationFolder);
                }
            }
            [fm removeItemAtURL:export error:NULL];

            // A look-alike copy without a date gets the date of the copy that has one.
            NSURL *shared = [root URLByAppendingPathComponent:@"shared"];
            WritePattern([shared URLByAppendingPathComponent:@"original.jpg"], 2000, 1500, 11, 0.9, @"2014:08:09 15:00:00");
            WritePattern([shared URLByAppendingPathComponent:@"^ABCDEF.jpg"], 1280, 960, 11, 0.8, nil);
            POPlan *copies = Scan(shared);
            for (POPhotoItem *item in copies.items) {
                CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)item.url, NULL);
                CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)@{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES, (id)kCGImageSourceThumbnailMaxPixelSize: @512});
                item.visualHash = [POSimilarCopies visualHashOfImage:image];
                CGImageRelease(image);
                CFRelease(source);
            }
            CHECK([POSimilarCopies shareDatesInSets:[POSimilarCopies setsInItems:copies.items]] == 1);
            for (POPhotoItem *item in copies.items) {
                CHECK([calendar component:NSCalendarUnitYear fromDate:item.date] == 2014, @"%@ %@", item.relativePath, item.date);
            }
            [fm removeItemAtURL:shared error:NULL];
        }

        // After a move, the Trash or an undo the plan follows the files without a rescan.
        {
            NSURL *live = [root URLByAppendingPathComponent:@"live"];
            WriteImage([live URLByAppendingPathComponent:@"one.jpg"], UTTypeJPEG, 900, 700, 0.1, @"2017:07:01 10:00:00");
            [fm copyItemAtURL:[live URLByAppendingPathComponent:@"one.jpg"] toURL:[live URLByAppendingPathComponent:@"one copy.jpg"] error:NULL];
            [fm copyItemAtURL:[live URLByAppendingPathComponent:@"one.jpg"] toURL:[live URLByAppendingPathComponent:@"one copy 2.jpg"] error:NULL];
            WriteImage([live URLByAppendingPathComponent:@"two.jpg"], UTTypeJPEG, 900, 700, 0.2, @"2018:07:01 10:00:00");
            POPlan *plan = Scan(live);
            CHECK(plan.duplicateItems.count == 2);
            POPhotoItem *original = plan.duplicateItems.firstObject.duplicateOf;
            [plan removeItems:@[original]];   // the original went to the Trash: a copy takes its place
            CHECK(plan.items.count == 3 && plan.duplicateItems.count == 1, @"%lu %lu", plan.items.count, plan.duplicateItems.count);
            POPhotoItem *keeper = plan.duplicateItems.firstObject.duplicateOf;
            CHECK(keeper && !keeper.isDuplicate && keeper.duplicates.count == 1);

            POOrganizeResult *moved = [POOrganizer moveItems:plan.items toFolder:@"Сюда" rootURL:plan.rootURL progress:nil];
            [plan itemsMovedFrom:[moved.records valueForKey:@"from"] to:[moved.records valueForKey:@"to"]];
            [plan rebuild];
            for (POPhotoItem *item in plan.items) {
                CHECK([item.currentFolder isEqualToString:@"Сюда"] && [fm fileExistsAtPath:item.url.path], @"%@", item.relativePath);
            }
            NSArray<POMoveRecord *> *back = nil;
            CHECK([POOrganizer revert:moved moves:&back].count == 0 && back.count == moved.records.count);
            [plan itemsMovedFrom:[back valueForKey:@"from"] to:[back valueForKey:@"to"]];
            for (POPhotoItem *item in plan.items) {
                CHECK([item.currentFolder isEqualToString:@""] && [fm fileExistsAtPath:item.url.path], @"%@", item.relativePath);
            }
            [fm removeItemAtURL:live error:NULL];
        }

        // Moving a hand-picked list into one folder, and back.
        {
            NSURL *pick = [root URLByAppendingPathComponent:@"pick"];
            WriteImage([pick URLByAppendingPathComponent:@"one.jpg"], UTTypeJPEG, 900, 700, 0.1, @"2017:07:01 10:00:00");
            WriteImage([pick URLByAppendingPathComponent:@"sub/two.jpg"], UTTypeJPEG, 900, 700, 0.2, @"2017:07:01 11:00:00");
            WriteImage([pick URLByAppendingPathComponent:@"Собаки/three.jpg"], UTTypeJPEG, 900, 700, 0.3, @"2017:07:01 12:00:00");
            NSArray<NSString *> *pickBefore = Tree(pick);
            POPlan *picked = Scan(pick);
            POOrganizeResult *moved = [POOrganizer moveItems:picked.items toFolder:@"Собаки" rootURL:picked.rootURL progress:nil];
            CHECK(moved.errors.count == 0 && moved.records.count == 2, @"%@ %lu", moved.errors, moved.records.count);
            NSArray<NSString *> *wanted = [@[@"Собаки/", @"Собаки/one.jpg", @"Собаки/two.jpg", @"Собаки/three.jpg"] sortedArrayUsingSelector:@selector(compare:)];
            CHECK([[Tree(pick) valueForKey:@"precomposedStringWithCanonicalMapping"] isEqualToArray:[wanted valueForKey:@"precomposedStringWithCanonicalMapping"]], @"%@", Tree(pick));
            CHECK([POOrganizer revert:moved].count == 0);
            CHECK([Tree(pick) isEqualToArray:pickBefore], @"%@", Tree(pick));
            [fm removeItemAtURL:pick error:NULL];
        }

        // Look-alike copies: a resized and a recompressed version are found, the best one is kept; two different
        // shots are not confused even when they look the same.
        {
            NSURL *copies = [root URLByAppendingPathComponent:@"copies"];
            WritePattern([copies URLByAppendingPathComponent:@"full.jpg"], 2000, 1500, 7, 0.95, @"2020:01:01 10:00:00");
            WritePattern([copies URLByAppendingPathComponent:@"small.jpg"], 800, 600, 7, 0.9, nil);
            WritePattern([copies URLByAppendingPathComponent:@"squeezed.jpg"], 2000, 1500, 7, 0.3, nil);
            WritePattern([copies URLByAppendingPathComponent:@"thumb.jpg"], 320, 240, 7, 0.8, nil);
            WritePattern([copies URLByAppendingPathComponent:@"other.jpg"], 2000, 1500, 99, 0.9, @"2020:01:01 10:00:00");
            WritePattern([copies URLByAppendingPathComponent:@"burst1.jpg"], 1600, 1200, 5, 0.9, @"2021:05:05 12:00:00");
            WritePattern([copies URLByAppendingPathComponent:@"burst2.jpg"], 1600, 1200, 5, 0.9, @"2021:05:05 12:00:09");
            POPlan *plan = Scan(copies);
            for (POPhotoItem *item in plan.items) {
                CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)item.url, NULL);
                CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)@{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES, (id)kCGImageSourceThumbnailMaxPixelSize: @512});
                item.visualHash = [POSimilarCopies visualHashOfImage:image];
                CHECK(item.visualHash != nil, @"%@", item.relativePath);
                CGImageRelease(image);
                CFRelease(source);
            }
            NSArray<NSArray<POPhotoItem *> *> *sets = [POSimilarCopies setsInItems:plan.items];
            CHECK(sets.count == 1, @"%lu sets", sets.count);
            NSArray<NSString *> *names = [sets.firstObject valueForKey:@"relativePath"];
            NSArray<NSString *> *wanted = @[@"full.jpg", @"squeezed.jpg", @"small.jpg", @"thumb.jpg"];
            CHECK([names isEqualToArray:wanted], @"%@", names);
            CHECK(sets.firstObject.firstObject.bestOfCopies && sets.firstObject.lastObject.betterCopy == sets.firstObject.firstObject);
            // The 800- and 320-pixel copies are thumbnails of the 2000-pixel original; the recompressed one is a duplicate.
            NSArray<NSString *> *tiny = [[[plan.items filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"tiny == YES"]]
                                          valueForKey:@"relativePath"] sortedArrayUsingSelector:@selector(compare:)];
            CHECK([tiny isEqualToArray:(@[@"small.jpg", @"thumb.jpg"])], @"%@", tiny);
            [plan rebuild];
            NSArray<NSString *> *groups = [plan.groups valueForKey:@"folder"];
            CHECK([groups isEqualToArray:(@[@"2020", @"2021", POPlan.defaultTinyFolderName, POPlan.defaultDuplicatesFolderName])], @"%@", groups);
            [fm removeItemAtURL:copies error:NULL];
        }

        // VK album links and choosing the original among a photo's sizes
        {
            NSString *owner, *album;
            CHECK([POVKAlbum parseAlbumURL:@"https://vk.ru/album123456_000" owner:&owner album:&album] && [owner isEqual:@"123456"] && [album isEqual:@"saved"], @"%@ %@", owner, album);
            CHECK([POVKAlbum parseAlbumURL:@"vk.com/album-12345_678?rev=1" owner:&owner album:&album] && [owner isEqual:@"-12345"] && [album isEqual:@"678"], @"%@ %@", owner, album);
            CHECK([POVKAlbum parseAlbumURL:@"https://m.vk.com/album1_0" owner:&owner album:&album] && [album isEqual:@"profile"]);
            CHECK([POVKAlbum parseAlbumURL:@"https://vk.ru/album1_00" owner:&owner album:&album] && [album isEqual:@"wall"]);
            CHECK(![POVKAlbum parseAlbumURL:@"https://vk.ru/id1" owner:&owner album:&album]);
            NSDictionary *photo = @{@"sizes": @[@{@"type": @"m", @"url": @"https://x/m.jpg", @"width": @130, @"height": @97},
                                               @{@"type": @"w", @"url": @"https://x/w.jpg?size=2560x1920", @"width": @2560, @"height": @1920},
                                               @{@"type": @"z", @"url": @"https://x/z.jpg", @"width": @1280, @"height": @960}]};
            CHECK([[POVKAlbum originalURLOfPhoto:photo].absoluteString isEqual:@"https://x/w.jpg?size=2560x1920"]);
            NSDictionary *withOriginal = @{@"sizes": photo[@"sizes"], @"orig_photo": @{@"url": @"https://x/orig.png", @"width": @4000, @"height": @3000}};
            CHECK([[POVKAlbum originalURLOfPhoto:withOriginal].absoluteString isEqual:@"https://x/orig.png"]);
            NSDictionary *old = @{@"sizes": @[@{@"type": @"s", @"url": @"https://x/s.jpg", @"width": @0, @"height": @0},
                                             @{@"type": @"y", @"url": @"https://x/y.jpg", @"width": @0, @"height": @0}]};
            CHECK([[POVKAlbum originalURLOfPhoto:old].absoluteString isEqual:@"https://x/y.jpg"]);
            CHECK([[POVKAlbum fileNameForIndex:7 ofCount:1200 url:[NSURL URLWithString:@"https://x/a/b.PNG?size=1x1"]] isEqual:@"0007.png"]);
            CHECK([[POVKAlbum fileNameForIndex:12 ofCount:40 url:[NSURL URLWithString:@"https://x/a/b"]] isEqual:@"012.jpg"]);
        }

        // Cancellation
        POScanner *cancelled = [[POScanner alloc] initWithRootURL:root];
        [cancelled cancel];
        CHECK([cancelled scanWithProgress:nil] == nil);

        [fm removeItemAtURL:root error:NULL];
        NSLog(@"%@", failures ? [NSString stringWithFormat:@"%d check(s) FAILED", failures] : @"All core checks passed");
    }
    return failures ? 1 : 0;
}
