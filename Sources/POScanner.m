#import "POScanner.h"
#import "POManualDates.h"
#import "POMediaTypes.h"
#import <ImageIO/ImageIO.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CommonCrypto/CommonDigest.h>
#import <stdatomic.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/param.h>
#import <sys/stat.h>

/// Parses "yyyy:MM:dd HH:mm:ss" (EXIF) or "yyyy-MM-ddTHH:mm:ss+zzzz" (QuickTime) as the wall-clock time where the
/// shot was taken, ignoring any UTC offset: a photo taken at 23:30 on holiday belongs to that day's folder. mktime is used instead of NSDateFormatter
/// because this runs concurrently for every file.
static NSDate *PODateFromEXIFString(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    int year = 0, month = 0, day = 0, hour = 0, minute = 0, second = 0;
    if (sscanf([value UTF8String], "%d%*1[:-]%d%*1[:-]%d%*1[ T]%d:%d:%d", &year, &month, &day, &hour, &minute, &second) < 3) return nil;
    if (year < 1900 || year > 2200 || month < 1 || month > 12 || day < 1 || day > 31) return nil;
    struct tm tm = {0};
    tm.tm_year = year - 1900;
    tm.tm_mon = month - 1;
    tm.tm_mday = day;
    // Some cameras write midnight as "24:00:00": it stays on its day (hour 23), as on Windows, instead of rolling over.
    tm.tm_hour = MIN(MAX(hour, 0), 23);
    tm.tm_min = MIN(MAX(minute, 0), 59);
    tm.tm_sec = MIN(MAX(second, 0), 59);
    tm.tm_isdst = -1;
    time_t time = mktime(&tm);
    if (time == (time_t)-1) return nil;
    // A day the month doesn't have (31 April) is a broken date, not the 1st of the next month.
    if (tm.tm_mday != day || tm.tm_mon != month - 1) return nil;
    return [NSDate dateWithTimeIntervalSince1970:time];
}

NSDate *PODateFromFileName(NSString *name) {
    static NSRegularExpression *dateExpression, *timeExpression;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // The separator between year and month must be repeated between month and day ("2022-09-09", "20220909").
        dateExpression = [NSRegularExpression regularExpressionWithPattern:@"(?<!\\d)((?:19|20)\\d{2})([-_.]?)(0[1-9]|1[0-2])\\2(0[1-9]|[12]\\d|3[01])"
                                                                   options:0 error:NULL];
        timeExpression = [NSRegularExpression regularExpressionWithPattern:@"^(?:[-_ T.]| at )?([01]\\d|2[0-3])[-_.:]?([0-5]\\d)[-_.:]?([0-5]\\d)"
                                                                   options:0 error:NULL];
    });
    NSString *base = name.stringByDeletingPathExtension;
    for (NSTextCheckingResult *match in [dateExpression matchesInString:base options:0 range:NSMakeRange(0, base.length)]) {
        NSString *rest = [base substringFromIndex:NSMaxRange(match.range)];
        NSTextCheckingResult *clock = [timeExpression firstMatchInString:rest options:0 range:NSMakeRange(0, rest.length)];
        // "2019123456": eight digits that merely look like a date inside a longer number.
        if (!clock && rest.length && isdigit([rest characterAtIndex:0])) continue;
        struct tm tm = {0};
        tm.tm_year = [base substringWithRange:[match rangeAtIndex:1]].intValue - 1900;
        tm.tm_mon = [base substringWithRange:[match rangeAtIndex:3]].intValue - 1;
        tm.tm_mday = [base substringWithRange:[match rangeAtIndex:4]].intValue;
        tm.tm_hour = 12;
        if (clock) {
            tm.tm_hour = [rest substringWithRange:[clock rangeAtIndex:1]].intValue;
            tm.tm_min = [rest substringWithRange:[clock rangeAtIndex:2]].intValue;
            tm.tm_sec = [rest substringWithRange:[clock rangeAtIndex:3]].intValue;
        }
        tm.tm_isdst = -1;
        int day = tm.tm_mday, month = tm.tm_mon;
        time_t seconds = mktime(&tm);
        if (seconds == (time_t)-1 || seconds > time(NULL) + 86400) continue;
        // "20230231" is a number that only looks like a date: mktime would make it 3 March.
        if (tm.tm_mday != day || tm.tm_mon != month) continue;
        return [NSDate dateWithTimeIntervalSince1970:seconds];
    }
    return nil;
}

/// Reads frame size, duration and recording date from the movie container.
/// "+51.2213+006.7877/" (ISO 6709, how QuickTime and Android store a video's location).
static BOOL POParseISO6709(NSString *text, double *latitude, double *longitude) {
    if (![text isKindOfClass:NSString.class]) return NO;
    double a = 0, b = 0;
    if (sscanf(text.UTF8String, "%lf%lf", &a, &b) != 2) return NO;
    if (fabs(a) > 90 || fabs(b) > 180 || (a == 0 && b == 0)) return NO;
    *latitude = a;
    *longitude = b;
    return YES;
}

static void POReadVideoMetadata(POPhotoItem *item) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:item.url options:nil];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (track) {
        CGSize size = CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform);
        item.pixelWidth = (NSInteger)round(fabs(size.width));
        item.pixelHeight = (NSInteger)round(fabs(size.height));
    }
    CMTime duration = asset.duration;
    if (CMTIME_IS_NUMERIC(duration)) item.duration = CMTimeGetSeconds(duration);
    AVMetadataItem *location = [AVMetadataItem metadataItemsFromArray:asset.metadata filteredByIdentifier:AVMetadataIdentifierQuickTimeMetadataLocationISO6709].firstObject
        ?: [AVMetadataItem metadataItemsFromArray:asset.metadata filteredByIdentifier:AVMetadataIdentifierQuickTimeUserDataLocationISO6709].firstObject
        ?: [AVMetadataItem metadataItemsFromArray:asset.commonMetadata filteredByIdentifier:AVMetadataCommonIdentifierLocation].firstObject;
    double latitude, longitude;
    if (POParseISO6709(location.stringValue, &latitude, &longitude)) {
        item.latitude = latitude;
        item.longitude = longitude;
        item.hasLocation = YES;
    }

    // The QuickTime key (written by iPhones and most cameras) holds local time; the container's own creation
    // time is UTC and often wrong. Containers written without a clock report 1904 or 1970 — those fall back
    // to the file date.
    AVMetadataItem *quickTimeDate = [AVMetadataItem metadataItemsFromArray:asset.metadata
                                                      filteredByIdentifier:AVMetadataIdentifierQuickTimeMetadataCreationDate].firstObject;
    NSDate *date = PODateFromEXIFString(quickTimeDate.stringValue) ?: asset.creationDate.dateValue;
    // Many older phones counted seconds from 1970 where QuickTime counts from 1904, so their videos claim to
    // be from the 1930s–50s; shifted by the 66 years between the two epochs they come out right.
    const NSTimeInterval epochGap = 2082844800;
    if (date && date.timeIntervalSince1970 < 631152000 && date.timeIntervalSince1970 + epochGap > 631152000 &&
        date.timeIntervalSince1970 + epochGap < NSDate.date.timeIntervalSince1970 + 86400) {
        date = [date dateByAddingTimeInterval:epochGap];
    }
    if (date && date.timeIntervalSince1970 > 631152000 /* 1990 */) {
        item.date = date;
        item.dateSource = PODateSourceEXIF;
    }
}

#pragma mark - Scan cache

/// What the scanner has read from each file of a folder — its metadata and content hash — kept in
/// ~/Library/Application Support/Photo Organizer/Scans, one file per folder. It is saved while the scan runs, so a
/// scan cut short (the app quit, the Mac turned off) goes on where it stopped, and a rescan reads only the files that
/// are new or changed (another size or modification time).
@interface POScanCache : NSObject
- (instancetype)initWithRootURL:(NSURL *)rootURL;
/// Puts what was read before into the item; NO when the file is new or has changed since.
- (BOOL)restoreMetadataOfItem:(POPhotoItem *)item;
- (NSString *)hashOfItem:(POPhotoItem *)item;
/// Call right after the embedded metadata was read, before the file and name dates are applied.
- (void)rememberMetadataOfItem:(POPhotoItem *)item;
- (void)rememberHash:(NSString *)hash ofItem:(POPhotoItem *)item;
- (void)save;
@end

@implementation POScanCache {
    NSURL *_fileURL;
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_records;   // relative path → record
    NSUInteger _unsaved;
    CFAbsoluteTime _lastSave;
}

- (instancetype)initWithRootURL:(NSURL *)rootURL {
    if ((self = [super init])) {
        NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                                                     appropriateForURL:nil create:YES error:NULL];
        NSURL *folder = [support URLByAppendingPathComponent:@"Photo Organizer/Scans" isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:NULL];
        NSData *path = [rootURL.path.precomposedStringWithCanonicalMapping dataUsingEncoding:NSUTF8StringEncoding];
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(path.bytes, (CC_LONG)path.length, digest);
        NSMutableString *name = [NSMutableString string];
        for (int i = 0; i < 8; i++) [name appendFormat:@"%02x", digest[i]];
        _fileURL = [folder URLByAppendingPathComponent:[name stringByAppendingString:@".plist"]];
        _records = [NSMutableDictionary dictionary];
        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfURL:_fileURL];
        if ([saved isKindOfClass:NSDictionary.class] && [saved[@"version"] isEqual:@1] && [saved[@"files"] isKindOfClass:NSDictionary.class]) {
            [saved[@"files"] enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *record, BOOL *stop) {
                if ([record isKindOfClass:NSDictionary.class]) self->_records[key] = [record mutableCopy];
            }];
        }
        _lastSave = CFAbsoluteTimeGetCurrent();
    }
    return self;
}

static const NSInteger POMetadataVersion = 2;

/// Size and modification time (to the nanosecond): when either changes, the file is read again.
static NSString *POFileStamp(POPhotoItem *item) {
    struct stat info;
    if (stat(item.url.fileSystemRepresentation, &info) != 0) return nil;
    return [NSString stringWithFormat:@"%lld-%ld.%09ld", (long long)info.st_size, (long)info.st_mtimespec.tv_sec, (long)info.st_mtimespec.tv_nsec];
}

/// The record of the file when it has not changed since it was made, or nil.
- (NSMutableDictionary *)currentRecordOf:(POPhotoItem *)item stamp:(NSString **)stampOut {
    NSString *stamp = POFileStamp(item);
    if (stampOut) *stampOut = stamp;
    if (!stamp) return nil;
    @synchronized (self) {
        NSMutableDictionary *record = _records[item.relativePath];
        return [record[@"stamp"] isEqual:stamp] ? record : nil;
    }
}

- (BOOL)restoreMetadataOfItem:(POPhotoItem *)item {
    NSDictionary *record;
    @synchronized (self) {
        record = [[self currentRecordOf:item stamp:NULL] copy];
    }
    // Version 2: pixel sizes of photos turned by their EXIF orientation, and no impossible dates; older records are read again.
    if (![record[@"read"] boolValue] || [record[@"v"] integerValue] < POMetadataVersion) return NO;
    NSArray<NSNumber *> *size = record[@"size"];
    if ([size isKindOfClass:NSArray.class] && size.count == 2) {
        item.pixelWidth = size[0].integerValue;
        item.pixelHeight = size[1].integerValue;
    }
    item.duration = [record[@"duration"] doubleValue];
    NSDate *date = record[@"date"];
    if ([date isKindOfClass:NSDate.class]) {
        item.date = date;
        item.dateSource = PODateSourceEXIF;
    }
    NSArray<NSNumber *> *place = record[@"place"];
    if ([place isKindOfClass:NSArray.class] && place.count == 2) {
        item.latitude = place[0].doubleValue;
        item.longitude = place[1].doubleValue;
        item.hasLocation = YES;
    }
    return YES;
}

- (NSString *)hashOfItem:(POPhotoItem *)item {
    @synchronized (self) {
        NSString *hash = [self currentRecordOf:item stamp:NULL][@"hash"];
        return [hash isKindOfClass:NSString.class] ? hash : nil;
    }
}

/// Call while holding the lock.
- (NSMutableDictionary *)recordToUpdateFor:(POPhotoItem *)item {
    NSString *stamp;
    NSMutableDictionary *record = [self currentRecordOf:item stamp:&stamp];
    if (!stamp) return nil;
    if (!record) {
        record = [NSMutableDictionary dictionaryWithObject:stamp forKey:@"stamp"];
        _records[item.relativePath] = record;
    }
    return record;
}

- (void)rememberMetadataOfItem:(POPhotoItem *)item {
    if (item.isCloudOnly) return;
    @synchronized (self) {
        NSMutableDictionary *record = [self recordToUpdateFor:item];
        if (!record) return;
        record[@"read"] = @YES;
        record[@"v"] = @(POMetadataVersion);
        record[@"size"] = @[@(item.pixelWidth), @(item.pixelHeight)];
        if (item.duration > 0) record[@"duration"] = @(item.duration);
        if (item.dateSource == PODateSourceEXIF && item.date) record[@"date"] = item.date;
        if (item.hasLocation) record[@"place"] = @[@(item.latitude), @(item.longitude)];
        [self didChange];
    }
}

- (void)rememberHash:(NSString *)hash ofItem:(POPhotoItem *)item {
    if (!hash) return;
    @synchronized (self) {
        NSMutableDictionary *record = [self recordToUpdateFor:item];
        if (!record) return;
        record[@"hash"] = hash;
        [self didChange];
    }
}

/// Saved every few seconds while the scan runs, so quitting loses little. Call while holding the lock.
- (void)didChange {
    _unsaved++;
    if (_unsaved >= 200 && CFAbsoluteTimeGetCurrent() - _lastSave > 5) [self save];
}

- (void)save {
    @synchronized (self) {
        if (!_unsaved) return;
        NSDictionary *plist = @{@"version": @1, @"files": _records};
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        [data writeToURL:_fileURL atomically:YES];
        _unsaved = 0;
        _lastSave = CFAbsoluteTimeGetCurrent();
    }
}

@end

static void POReadEmbeddedMetadata(POPhotoItem *item);

static void POReadMetadata(POPhotoItem *item, POScanCache *cache) {
    NSDate *fileDate = item.date;   // the earlier of the file system's creation and modification dates
    // What an earlier scan read from an unchanged file is not read again.
    if (item.isCloudOnly || ![cache restoreMetadataOfItem:item]) {
        POReadEmbeddedMetadata(item);
        [cache rememberMetadataOfItem:item];
    }
    // A file can't have been shot after it was created. Re-encoding, rotating or exporting a video stamps the
    // container with the time of the export while the file often keeps its original creation date — so an
    // embedded date more than a day later than the file's own is an editing date, and the file date is closer.
    if (item.dateSource == PODateSourceEXIF && [item.date timeIntervalSinceDate:fileDate] > 86400 &&
        fileDate.timeIntervalSince1970 > 631152000 /* 1990: FAT and broken clocks report earlier */) {
        item.date = fileDate;
        item.dateSource = PODateSourceFile;
    }
    // Cameras and messengers put the capture time into the name, and it survives what the other dates don't:
    // a re-encoded or rotated video gets a fresh creation date both in the file system and inside the container.
    // So the name wins over the file date, and over an embedded date that is more than a day later.
    NSDate *nameDate = PODateFromFileName(item.url.lastPathComponent);
    if (nameDate && (item.dateSource == PODateSourceFile || [item.date timeIntervalSinceDate:nameDate] > 86400)) {
        item.date = nameDate;
        item.dateSource = PODateSourceName;
    }
}

/// Reads pixel size and capture date from the image header without decoding the image.
static void POReadEmbeddedMetadata(POPhotoItem *item) {
    if (item.isCloudOnly) return;
    if (item.isVideo) {
        POReadVideoMetadata(item);
        return;
    }
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)item.url, NULL);
    if (!source) return;
    NSDictionary *options = @{(id)kCGImageSourceShouldCache: @NO};
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, (__bridge CFDictionaryRef)options));
    CFRelease(source);
    if (!properties) return;

    item.pixelWidth = [properties[(id)kCGImagePropertyPixelWidth] integerValue];
    item.pixelHeight = [properties[(id)kCGImagePropertyPixelHeight] integerValue];
    // Orientations 5–8 turn the picture by a quarter: it is shown, and compared with its copies, the other way round.
    NSInteger orientation = [properties[(id)kCGImagePropertyOrientation] integerValue];
    if (orientation >= 5 && orientation <= 8) {
        NSInteger width = item.pixelWidth;
        item.pixelWidth = item.pixelHeight;
        item.pixelHeight = width;
    }

    NSDictionary *gps = properties[(id)kCGImagePropertyGPSDictionary];
    NSNumber *latitude = gps[(id)kCGImagePropertyGPSLatitude], *longitude = gps[(id)kCGImagePropertyGPSLongitude];
    if ([latitude isKindOfClass:NSNumber.class] && [longitude isKindOfClass:NSNumber.class] &&
        (latitude.doubleValue != 0 || longitude.doubleValue != 0) && latitude.doubleValue <= 90 && longitude.doubleValue <= 180) {
        BOOL south = [gps[(id)kCGImagePropertyGPSLatitudeRef] isEqual:@"S"], west = [gps[(id)kCGImagePropertyGPSLongitudeRef] isEqual:@"W"];
        item.latitude = south ? -latitude.doubleValue : latitude.doubleValue;
        item.longitude = west ? -longitude.doubleValue : longitude.doubleValue;
        item.hasLocation = YES;
    }

    NSDictionary *exif = properties[(id)kCGImagePropertyExifDictionary];
    NSDictionary *tiff = properties[(id)kCGImagePropertyTIFFDictionary];
    NSDate *date = PODateFromEXIFString(exif[(id)kCGImagePropertyExifDateTimeOriginal])
        ?: PODateFromEXIFString(exif[(id)kCGImagePropertyExifDateTimeDigitized])
        ?: PODateFromEXIFString(tiff[(id)kCGImagePropertyTIFFDateTime]);
    if (date) {
        item.date = date;
        item.dateSource = PODateSourceEXIF;
    }
}

static NSString *POHashFile(NSURL *url, atomic_bool *cancelled) {
    int fd = open(url.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return nil;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    const size_t bufferSize = 1 << 20;
    uint8_t *buffer = malloc(bufferSize);
    ssize_t count;
    while ((count = read(fd, buffer, bufferSize)) > 0) {
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
        if (atomic_load(cancelled)) break;
    }
    free(buffer);
    close(fd);
    if (count != 0) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

NSString *POContentHashOfFile(NSURL *url) {
    atomic_bool never = false;
    return POHashFile(url, &never);
}

/// Splits "IMG_0668" into the series name "IMG_" and the counter 668. NO for names that don't end in a number.
static BOOL POSeriesOfName(NSString *name, NSString **series, long long *counter) {
    NSString *base = name.stringByDeletingPathExtension;
    NSUInteger end = base.length, start = end;
    while (start > 0 && isdigit([base characterAtIndex:start - 1])) start--;
    if (start == end || end - start > 9) return NO;
    *series = [base substringToIndex:start].lowercaseString;
    *counter = [base substringFromIndex:start].longLongValue;
    return YES;
}

/// Gives files that have no date of their own (only the file system's) the date of their neighbours — but only
/// when that is safe: the file sits in a numbered camera series (IMG_0667, IMG_0668, IMG_0669) in the same
/// folder, between two files whose dates are known from their metadata or name, and those two were shot within
/// three days of each other. A file whose own date already fits between them is left alone.
static void PODateFromNeighbors(NSArray<POPhotoItem *> *items) {
    NSMutableDictionary<NSString *, NSMutableArray<NSArray *> *> *groups = [NSMutableDictionary dictionary];
    for (POPhotoItem *item in items) {
        NSString *series;
        long long counter;
        if (!POSeriesOfName(item.url.lastPathComponent, &series, &counter)) continue;
        NSString *key = [NSString stringWithFormat:@"%@\n%@", item.currentFolder, series];
        NSMutableArray *group = groups[key];
        if (!group) groups[key] = group = [NSMutableArray array];
        [group addObject:@[@(counter), item]];
    }
    for (NSMutableArray<NSArray *> *group in groups.allValues) {
        if (group.count < 3) continue;
        [group sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
        NSInteger count = group.count;
        for (NSInteger index = 0; index < count; index++) {
            POPhotoItem *item = group[index][1];
            if (item.dateSource != PODateSourceFile) continue;
            POPhotoItem *before = nil, *after = nil;
            long long beforeCounter = 0, afterCounter = 0, counter = [group[index][0] longLongValue];
            for (NSInteger i = index - 1; i >= 0 && !before; i--) {
                POPhotoItem *candidate = group[i][1];
                if (candidate.dateSource == PODateSourceEXIF || candidate.dateSource == PODateSourceName || candidate.dateSource == PODateSourceTakeout) {
                    before = candidate;
                    beforeCounter = [group[i][0] longLongValue];
                }
            }
            for (NSInteger i = index + 1; i < count && !after; i++) {
                POPhotoItem *candidate = group[i][1];
                if (candidate.dateSource == PODateSourceEXIF || candidate.dateSource == PODateSourceName || candidate.dateSource == PODateSourceTakeout) {
                    after = candidate;
                    afterCounter = [group[i][0] longLongValue];
                }
            }
            if (!before || !after || beforeCounter >= counter || afterCounter <= counter) continue;
            NSTimeInterval span = [after.date timeIntervalSinceDate:before.date];
            if (span < 0) continue;
            if ([item.date compare:before.date] != NSOrderedAscending && [item.date compare:after.date] != NSOrderedDescending) continue;
            if (span > 3 * 86400) {
                // Too far apart to guess the day, but when both are from the same month, so is everything between.
                NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
                NSDateComponents *first = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:before.date];
                NSDateComponents *last = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:after.date];
                if (first.year != last.year || first.month != last.month) continue;
                first.day = 1;
                first.hour = 12;
                item.date = [calendar dateFromComponents:first];
                item.dateSource = PODateSourceNeighborsMonth;
                continue;
            }
            double position = (double)(counter - beforeCounter) / (double)(afterCounter - beforeCounter);
            item.date = [before.date dateByAddingTimeInterval:span * position];
            item.dateSource = PODateSourceNeighbors;
        }
    }
}

/// Google Takeout writes a .json next to every photo with the moment Google Photos knew it was taken
/// ("photoTakenTime"), even when the photo itself has lost its metadata. Its name is the photo's, more or less
/// ("IMG_1.JPG.json", "IMG_1.JPG.supplemental-metadata.json", cut short for long names, "IMG_1.JPG(1).json" for
/// "IMG_1(1).JPG"), so the files are matched by the "title" written inside instead.
///
/// When no title is the file's own name, the file is one Takeout gave no .json of its own: its name cut to 47
/// characters while the title is whole ("…_com.ftband.m.jpg" for "…_com.ftband.mono.jpg"), a numbered copy of a file
/// that has one ("…(1).jpg"), an edited copy ("IMG_1-отредактировано.jpg", "IMG_1-EFFECTS.jpg") or the video of a Live
/// Photo ("IMG_1.MP4" next to "IMG_1.HEIC"). It then takes the .json of that file — for a cut name, only when every
/// title it could be the start of says the same.
static NSString *POTakeoutKeyForPath(NSString *path, NSDictionary<NSString *, id> *known,
                                     NSDictionary<NSString *, NSSet<NSString *> *> *titlesByFolder, BOOL video) {
    static NSRegularExpression *copyNumber, *edit;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        copyNumber = [NSRegularExpression regularExpressionWithPattern:@"\\(\\d+\\)$" options:0 error:NULL];
        edit = [NSRegularExpression regularExpressionWithPattern:@"-(edited|отредактировано|изменено|bearbeitet|modifié|editado|modificato|bewerkt|"
                                                                 @"edytowane|redigeret|redigerad|muokattu|collage|photo_frame|animation|effects|mix|"
                                                                 @"snippet|cinematic|stylized)$" options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    NSString *key = path.lowercaseString.precomposedStringWithCanonicalMapping;
    if (known[key]) return key;
    NSString *folder = key.stringByDeletingLastPathComponent, *extension = key.pathExtension;
    NSString *base = key.lastPathComponent.stringByDeletingPathExtension;
    NSString *(^strip)(NSRegularExpression *, NSString *) = ^NSString *(NSRegularExpression *expression, NSString *text) {
        return [expression stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
    };
    NSString *(^named)(NSString *) = ^NSString *(NSString *name) {
        NSString *candidate = [folder stringByAppendingPathComponent:extension.length ? [name stringByAppendingPathExtension:extension] : name];
        return known[candidate] ? candidate : nil;
    };
    base = strip(copyNumber, base);
    if (named(base)) return named(base);
    for (NSString *stripped = strip(edit, base); ![stripped isEqualToString:base]; stripped = strip(edit, base)) {
        base = stripped;
        if (named(base)) return named(base);
    }
    NSSet<NSString *> *titles = titlesByFolder[folder];
    if (video) {
        for (NSString *title in titles) {
            if ([title.stringByDeletingPathExtension isEqualToString:base]) return [folder stringByAppendingPathComponent:title];
        }
    }
    if (base.length >= 30) {
        NSString *found = nil;
        for (NSString *title in titles) {
            if (![title.pathExtension isEqualToString:extension] || ![title hasPrefix:base]) continue;
            NSString *candidate = [folder stringByAppendingPathComponent:title];
            if (found && ![known[found] isEqual:known[candidate]]) return nil;
            found = candidate;
        }
        return found;
    }
    return nil;
}

/// The year of the Google Takeout folder a file is in ("Фото 2023 г", "Photos from 2023") for a file nothing else
/// dates: Takeout sorts by the date Google Photos gives a file, so the year is Google's own. Only the year — the file
/// goes into that year's folder, not into a month — and a copy with a date of its own still wins (see POSimilarCopies).
static void PODateFromTakeoutFolders(NSArray<POPhotoItem *> *items) {
    // "Фото 2023 г", "Photos from 2023", "Фото за 2023" (Google Takeout), or a folder named by the year itself: "2023",
    // "2023 год", "2023 г" — the year folders this app makes among them.
    NSRegularExpression *folder = [NSRegularExpression regularExpressionWithPattern:@"^(?:(?:photos from|фото за|фото) )?(\\d{4})(?: ?г\\.?| год)?$"
                                                                            options:NSRegularExpressionCaseInsensitive error:NULL];
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    for (POPhotoItem *item in items) {
        if (!item.isUndated) continue;
        // The folder itself, or one it is in ("2023/2023-05"): the nearest one named by a year.
        NSInteger year = 0;
        for (NSString *part in [item.currentFolder componentsSeparatedByString:@"/"].reverseObjectEnumerator) {
            NSString *name = part.precomposedStringWithCanonicalMapping;
            NSTextCheckingResult *match = name.length ? [folder firstMatchInString:name options:0 range:NSMakeRange(0, name.length)] : nil;
            if (!match) continue;
            year = [name substringWithRange:[match rangeAtIndex:1]].integerValue;
            break;
        }
        if (year < 1990 || year > 2100) continue;
        NSDateComponents *components = [NSDateComponents new];
        components.year = year; components.month = 7; components.day = 1; components.hour = 12;
        item.date = [calendar dateFromComponents:components];
        item.dateSource = PODateSourceTakeoutFolder;
    }
}

static void PODateFromTakeoutSidecars(NSArray<POPhotoItem *> *items, NSArray<NSURL *> *sidecars) {
    if (!sidecars.count) return;
    NSRegularExpression *copyNumber = [NSRegularExpression regularExpressionWithPattern:@"\\((\\d+)\\)\\.json$" options:NSRegularExpressionCaseInsensitive error:NULL];
    NSMutableDictionary<NSString *, NSDate *> *dates = [NSMutableDictionary dictionary];   // folder/lowercased file name → date
    NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *places = [NSMutableDictionary dictionary];   // same key → @[lat, lon]
    NSMutableDictionary<NSString *, NSURL *> *files = [NSMutableDictionary dictionary];   // same key → the .json itself
    for (NSURL *url in sidecars) {
        NSData *data = [NSData dataWithContentsOfURL:url];
        NSDictionary *json = data.length < 1000000 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if (![json isKindOfClass:NSDictionary.class] || ![json[@"title"] isKindOfClass:NSString.class]) continue;
        NSDictionary *taken = [json[@"photoTakenTime"] isKindOfClass:NSDictionary.class] ? json[@"photoTakenTime"] : nil;
        double timestamp = [taken[@"timestamp"] doubleValue];
        NSDictionary *geo = [json[@"geoData"] isKindOfClass:NSDictionary.class] ? json[@"geoData"] : nil;
        double latitude = [geo[@"latitude"] doubleValue], longitude = [geo[@"longitude"] doubleValue];
        BOOL hasPlace = (latitude != 0 || longitude != 0) && fabs(latitude) <= 90 && fabs(longitude) <= 180;
        NSString *title = json[@"title"];
        NSString *name = url.lastPathComponent;
        NSTextCheckingResult *match = [copyNumber firstMatchInString:name options:0 range:NSMakeRange(0, name.length)];
        if (match) {
            NSString *number = [name substringWithRange:[match rangeAtIndex:1]];
            title = [NSString stringWithFormat:@"%@(%@)%@%@", title.stringByDeletingPathExtension, number,
                     title.pathExtension.length ? @"." : @"", title.pathExtension];
        }
        NSString *key = [[url.path.stringByDeletingLastPathComponent stringByAppendingPathComponent:title] lowercaseString];
        key = key.precomposedStringWithCanonicalMapping;
        files[key] = url;
        if (timestamp < 631152000 && !hasPlace) continue;   // before 1990: missing or zero
        if (timestamp >= 631152000) dates[key] = [NSDate dateWithTimeIntervalSince1970:timestamp];
        if (hasPlace) places[key] = @[@(latitude), @(longitude)];
    }
    NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *titlesByFolder = [NSMutableDictionary dictionary];
    for (NSString *key in files) {
        NSString *folder = key.stringByDeletingLastPathComponent;
        if (!titlesByFolder[folder]) titlesByFolder[folder] = [NSMutableSet set];
        [titlesByFolder[folder] addObject:key.lastPathComponent];
    }
    for (POPhotoItem *item in items) {
        NSString *key = POTakeoutKeyForPath(item.url.path, dates, titlesByFolder, item.isVideo)
                     ?: POTakeoutKeyForPath(item.url.path, places, titlesByFolder, item.isVideo) ?: @"";
        NSArray<NSNumber *> *place = places[key];
        if (place && !item.hasLocation) {
            item.latitude = place[0].doubleValue;
            item.longitude = place[1].doubleValue;
            item.hasLocation = YES;
        }
        if (item.dateSource == PODateSourceEXIF) continue;   // the camera's own record is more exact
        NSDate *date = dates[key];
        if (!date) continue;
        item.date = date;
        item.dateSource = PODateSourceTakeout;
    }
}

@implementation POScanner {
    NSMutableArray<NSURL *> *_sidecars;   // .json files met while enumerating (Google Takeout metadata)
    atomic_bool _cancelled;
    atomic_uint_fast64_t _done;
}

+ (NSArray<NSURL *> *)normalizedRootURLs:(NSArray<NSURL *> *)urls {
    // The directory enumerator reports canonical paths (/private/var/… rather than /var/…), so the roots have to be
    // canonical too for relative paths to be computed correctly.
    NSMutableArray<NSURL *> *canonical = [NSMutableArray array];
    for (NSURL *url in urls) {
        NSURL *root = url;
        char resolved[PATH_MAX];
        if (realpath(url.fileSystemRepresentation, resolved)) root = [NSURL fileURLWithFileSystemRepresentation:resolved isDirectory:YES relativeToURL:nil];
        BOOL known = NO;
        for (NSURL *other in canonical) known = known || [other.path isEqualToString:root.path];
        if (!known) [canonical addObject:root];
    }
    NSMutableArray<NSURL *> *outer = [NSMutableArray array];
    for (NSURL *root in canonical) {
        BOOL inside = NO;
        for (NSURL *other in canonical) {
            if (other != root && [root.path hasPrefix:[other.path stringByAppendingString:@"/"]]) inside = YES;
        }
        if (!inside) [outer addObject:root];
    }
    return outer;
}

- (instancetype)initWithRootURL:(NSURL *)rootURL {
    return [self initWithRootURLs:@[rootURL]];
}

- (instancetype)initWithRootURLs:(NSArray<NSURL *> *)rootURLs {
    if ((self = [super init])) {
        _rootURLs = [POScanner normalizedRootURLs:rootURLs];
        _rootURL = _rootURLs.firstObject;
        _sidecars = [NSMutableArray array];
        _deprioritizedFolders = @[];
    }
    return self;
}

- (void)cancel {
    atomic_store(&_cancelled, true);
}

- (void)startWithProgress:(POScanProgress)progress completion:(void (^)(NSArray<POPhotoItem *> *))completion {
    POScanProgress mainProgress = progress ? ^(POScanPhase phase, NSUInteger done, NSUInteger total) {
        dispatch_async(dispatch_get_main_queue(), ^{ progress(phase, done, total); });
    } : nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<POPhotoItem *> *items = [self scanWithProgress:mainProgress];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(items); });
    });
}

- (NSArray<POPhotoItem *> *)scanWithProgress:(POScanProgress)progress {
    NSMutableArray<POPhotoItem *> *items = [self enumerateMediaWithProgress:progress];
    if (atomic_load(&_cancelled)) return nil;

    // What earlier scans of these folders read is reused: a cache per folder.
    NSMutableDictionary<NSString *, POScanCache *> *caches = [NSMutableDictionary dictionary];
    for (NSURL *root in self.rootURLs) caches[root.path] = [[POScanCache alloc] initWithRootURL:root];
    [self forEach:items phase:POScanPhaseMetadata progress:progress work:^(POPhotoItem *item) {
        POReadMetadata(item, caches[item.rootURL.path]);
    }];
    for (POScanCache *cache in caches.allValues) [cache save];
    if (atomic_load(&_cancelled)) return nil;

    PODateFromTakeoutSidecars(items, _sidecars);
    PODateFromNeighbors(items);
    PODateFromTakeoutFolders(items);
    [POManualDates applyToItems:items];

    [self findDuplicatesIn:items caches:caches progress:progress];
    for (POScanCache *cache in caches.allValues) [cache save];
    if (atomic_load(&_cancelled)) return nil;

    [items sortUsingComparator:^NSComparisonResult(POPhotoItem *a, POPhotoItem *b) {
        return [a.date compare:b.date] ?: [a.relativePath localizedStandardCompare:b.relativePath];
    }];
    return items;
}

#pragma mark - Phases

- (NSMutableArray<POPhotoItem *> *)enumerateMediaWithProgress:(POScanProgress)progress {
    NSMutableArray<POPhotoItem *> *items = [NSMutableArray array];
    [_sidecars removeAllObjects];
    for (NSURL *root in self.rootURLs) {
        if (atomic_load(&_cancelled)) break;
        [self enumerateRoot:root into:items progress:progress];
    }
    return items;
}

- (void)enumerateRoot:(NSURL *)rootURL into:(NSMutableArray<POPhotoItem *> *)items progress:(POScanProgress)progress {
    NSArray<NSURLResourceKey> *keys = @[NSURLIsRegularFileKey, NSURLFileSizeKey,
                                        NSURLCreationDateKey, NSURLContentModificationDateKey];
    NSDirectoryEnumerator<NSURL *> *enumerator =
        [NSFileManager.defaultManager enumeratorAtURL:rootURL
                           includingPropertiesForKeys:keys
                                              options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants
                                         errorHandler:^BOOL(NSURL *url, NSError *error) { return YES; }];
    NSString *rootPrefix = [rootURL.path stringByAppendingString:@"/"];
    // What other systems keep on a drive: Windows' Recycle Bin and restore points, a Synology's thumbnails (the same
    // list as on Windows; hidden folders such as .thumbnails are skipped anyway).
    static NSSet<NSString *> *skipped;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ skipped = [NSSet setWithArray:@[@"$recycle.bin", @"system volume information", @"@eadir", @".thumbnails"]]; });
    for (NSURL *url in enumerator) {
        if (atomic_load(&_cancelled)) break;
        NSDictionary<NSURLResourceKey, id> *values = [url resourceValuesForKeys:keys error:NULL];
        if (![values[NSURLIsRegularFileKey] boolValue]) {
            if ([skipped containsObject:url.lastPathComponent.lowercaseString]) [enumerator skipDescendants];
            continue;
        }
        if ([url.pathExtension caseInsensitiveCompare:@"json"] == NSOrderedSame) {
            [_sidecars addObject:url];
            continue;
        }
        // One list of formats, the same as on Windows (see POMediaKindOfExtension).
        POMediaFileKind kind = POMediaKindOfExtension(url.pathExtension);
        if (kind == POMediaFileKindNone) continue;
        BOOL isVideo = kind == POMediaFileKindVideo;

        NSString *path = url.path;
        if (![path hasPrefix:rootPrefix]) continue;
        POPhotoItem *item = [[POPhotoItem alloc] initWithURL:url relativePath:[path substringFromIndex:rootPrefix.length] rootURL:rootURL];
        item.video = isVideo;
        struct stat info;
        item.cloudOnly = lstat(url.fileSystemRepresentation, &info) == 0 && (info.st_flags & SF_DATALESS) != 0;
        item.fileSize = [values[NSURLFileSizeKey] unsignedLongLongValue];
        // Copying a file resets its creation date but keeps the modification date, so the earlier one is the better guess.
        NSDate *created = values[NSURLCreationDateKey], *modified = values[NSURLContentModificationDateKey];
        item.date = (created && modified) ? [created earlierDate:modified] : (created ?: modified ?: NSDate.date);
        item.fileDate = item.date;
        [items addObject:item];
        if (progress && items.count % 50 == 0) progress(POScanPhaseEnumerating, items.count, 0);
    }
}

- (void)forEach:(NSArray<POPhotoItem *> *)items phase:(POScanPhase)phase progress:(POScanProgress)progress work:(void (^)(POPhotoItem *item))work {
    NSUInteger total = items.count;
    if (total == 0) return;
    atomic_store(&_done, 0);
    if (progress) progress(phase, 0, total);
    dispatch_apply(total, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
        if (atomic_load(&self->_cancelled)) return;
        @autoreleasepool {
            work(items[index]);
        }
        NSUInteger done = (NSUInteger)atomic_fetch_add(&self->_done, 1) + 1;
        if (progress && (done % 20 == 0 || done == total)) progress(phase, done, total);
    });
}

- (void)findDuplicatesIn:(NSArray<POPhotoItem *> *)items caches:(NSDictionary<NSString *, POScanCache *> *)caches progress:(POScanProgress)progress {
    // Only files that share their size with another file can be identical, so only those get hashed.
    NSMutableDictionary<NSNumber *, NSMutableArray<POPhotoItem *> *> *bySize = [NSMutableDictionary dictionary];
    for (POPhotoItem *item in items) {
        if (item.fileSize == 0 || item.isCloudOnly) continue;
        NSNumber *key = @(item.fileSize);
        NSMutableArray *bucket = bySize[key];
        if (!bucket) bySize[key] = bucket = [NSMutableArray array];
        [bucket addObject:item];
    }
    NSMutableArray<POPhotoItem *> *candidates = [NSMutableArray array];
    for (NSArray<POPhotoItem *> *bucket in bySize.allValues) {
        if (bucket.count > 1) [candidates addObjectsFromArray:bucket];
    }

    [self forEach:candidates phase:POScanPhaseDuplicates progress:progress work:^(POPhotoItem *item) {
        POScanCache *cache = caches[item.rootURL.path];
        item.contentHash = [cache hashOfItem:item];
        if (item.contentHash) return;
        item.contentHash = POHashFile(item.url, &self->_cancelled);
        [cache rememberHash:item.contentHash ofItem:item];
    }];
    if (atomic_load(&_cancelled)) return;

    NSMutableDictionary<NSString *, NSMutableArray<POPhotoItem *> *> *byHash = [NSMutableDictionary dictionary];
    for (POPhotoItem *item in candidates) {
        if (!item.contentHash) continue;
        NSString *key = [NSString stringWithFormat:@"%llu-%@", item.fileSize, item.contentHash];
        NSMutableArray *bucket = byHash[key];
        if (!bucket) byHash[key] = bucket = [NSMutableArray array];
        [bucket addObject:item];
    }
    for (NSMutableArray<POPhotoItem *> *bucket in byHash.allValues) {
        if (bucket.count < 2) continue;
        [bucket sortUsingComparator:^NSComparisonResult(POPhotoItem *a, POPhotoItem *b) {
            return [self compareAsOriginal:a with:b];
        }];
        POPhotoItem *original = bucket.firstObject;
        NSArray<POPhotoItem *> *copies = [bucket subarrayWithRange:NSMakeRange(1, bucket.count - 1)];
        original.duplicates = copies;
        for (POPhotoItem *copy in copies) copy.duplicateOf = original;
    }
}

/// Orders a duplicate set so that the file most likely to be the original comes first.
- (NSComparisonResult)compareAsOriginal:(POPhotoItem *)a with:(POPhotoItem *)b {
    BOOL aDeprioritized = [self.deprioritizedFolders containsObject:a.relativePath.pathComponents.firstObject];
    BOOL bDeprioritized = [self.deprioritizedFolders containsObject:b.relativePath.pathComponents.firstObject];
    if (aDeprioritized != bDeprioritized) return aDeprioritized ? NSOrderedDescending : NSOrderedAscending;
    NSComparisonResult byDate = [a.date compare:b.date];
    if (byDate != NSOrderedSame) return byDate;
    // "IMG_1.jpg" beats "IMG_1 copy.jpg" and "Backup/IMG_1.jpg".
    if (a.relativePath.length != b.relativePath.length) {
        return a.relativePath.length < b.relativePath.length ? NSOrderedAscending : NSOrderedDescending;
    }
    return [a.relativePath localizedStandardCompare:b.relativePath];
}

@end
