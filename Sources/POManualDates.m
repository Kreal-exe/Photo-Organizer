#import "POManualDates.h"
#import <sys/stat.h>

static NSURL *POStoreURL;

@implementation POManualDates

+ (NSURL *)storeURL {
    if (!POStoreURL) {
        NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                                                     appropriateForURL:nil create:YES error:NULL];
        POStoreURL = [support URLByAppendingPathComponent:@"Photo Organizer/dates.plist"];
    }
    return POStoreURL;
}

+ (void)setStoreURL:(NSURL *)url {
    POStoreURL = [url copy];
}

/// Stays the same when the file is moved or renamed on its disk; changes when it is edited.
static NSString *POKey(NSURL *url) {
    struct stat info;
    if (stat(url.fileSystemRepresentation, &info) != 0) return nil;
    return [NSString stringWithFormat:@"%d-%llu-%lld", info.st_dev, (unsigned long long)info.st_ino, (long long)info.st_size];
}

+ (NSMutableDictionary<NSString *, NSDictionary *> *)loadDates {
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfURL:self.storeURL];
    return [saved isKindOfClass:NSDictionary.class] ? [saved mutableCopy] : [NSMutableDictionary dictionary];
}

static void POApply(POPhotoItem *item, NSDictionary *entry) {
    item.date = [NSDate dateWithTimeIntervalSince1970:[entry[@"t"] doubleValue]];
    item.manualPrecision = [entry[@"p"] integerValue];
    item.dateSource = PODateSourceManual;
}

+ (void)applyToItems:(NSArray<POPhotoItem *> *)items {
    NSDictionary<NSString *, NSDictionary *> *dates = [self loadDates];
    if (!dates.count) return;
    for (POPhotoItem *item in items) {
        NSString *key = POKey(item.url);
        NSDictionary *entry = key ? dates[key] : nil;
        if (entry) POApply(item, entry);
    }
}

+ (void)setDate:(NSDate *)date precision:(PODatePrecision)precision forItems:(NSArray<POPhotoItem *> *)items {
    NSMutableDictionary<NSString *, NSDictionary *> *dates = [self loadDates];
    for (POPhotoItem *item in items) {
        NSString *key = POKey(item.url);
        if (!key) continue;
        if (date) {
            NSDictionary *entry = @{@"t": @(date.timeIntervalSince1970), @"p": @(precision)};
            dates[key] = entry;
            POApply(item, entry);
        } else {
            dates[key] = nil;
            if (item.dateSource == PODateSourceManual) {
                item.date = item.fileDate ?: item.date;
                item.dateSource = PODateSourceFile;
            }
        }
    }
    NSURL *store = self.storeURL;
    [NSFileManager.defaultManager createDirectoryAtURL:store.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    [dates writeToURL:store atomically:YES];
}

@end
