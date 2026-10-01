#import "POPhotoItem.h"
#import "POStrings.h"

PODatePrecision POItemDatePrecision(POPhotoItem *item) {
    switch (item.dateSource) {
        case PODateSourceManual: return item.manualPrecision;
        case PODateSourceNeighborsMonth: return PODatePrecisionMonth;
        default: return PODatePrecisionDay;
    }
}

NSString *POItemDateSourceText(POPhotoItem *item) {
    switch (item.dateSource) {
        case PODateSourceEXIF: return POL(@"Дата съёмки (из метаданных)");
        case PODateSourceName: return POL(@"Дата из имени файла");
        case PODateSourceNeighbors: return POL(@"Дата по соседним кадрам серии");
        case PODateSourceNeighborsMonth: return POL(@"Месяц по соседним кадрам серии");
        case PODateSourceManual: return POL(@"Дата задана вручную");
        case PODateSourceTakeout: return POL(@"Дата из Google Takeout (.json)");
        case PODateSourceCopy: return POL(@"Дата другой копии этого снимка");
        case PODateSourceFile: break;
    }
    return POL(@"Без даты");
}

NSString *POItemDateText(POPhotoItem *item, BOOL withTime) {
    static NSDateFormatter *day, *dayAndTime, *month, *year;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        day = [NSDateFormatter new];
        day.dateStyle = NSDateFormatterMediumStyle;
        dayAndTime = [NSDateFormatter new];
        dayAndTime.dateStyle = NSDateFormatterLongStyle;
        dayAndTime.timeStyle = NSDateFormatterShortStyle;
        month = [NSDateFormatter new];
        year = [NSDateFormatter new];
        for (NSDateFormatter *formatter in @[day, dayAndTime, month, year]) formatter.locale = POLocale();
        [month setLocalizedDateFormatFromTemplate:@"LLLLyyyy"];
        [year setLocalizedDateFormatFromTemplate:@"yyyy"];
    });
    @synchronized (day) {
        if (item.isUndated) return POL(@"Без даты");
        if (POItemDatePrecision(item) == PODatePrecisionYear) return [year stringFromDate:item.date];
        if (POItemDatePrecision(item) == PODatePrecisionMonth) return [month stringFromDate:item.date];
        return [(withTime ? dayAndTime : day) stringFromDate:item.date];
    }
}

@implementation POPhotoItem

- (instancetype)initWithURL:(NSURL *)url relativePath:(NSString *)relativePath {
    if ((self = [super init])) {
        _url = url;
        _relativePath = [relativePath copy];
        _currentFolder = [relativePath.stringByDeletingLastPathComponent copy];
        _date = NSDate.distantPast;
        _dateSource = PODateSourceFile;
    }
    return self;
}

- (void)movedToURL:(NSURL *)url relativePath:(NSString *)relativePath {
    _url = url;
    _relativePath = [relativePath copy];
    _currentFolder = [relativePath.stringByDeletingLastPathComponent copy];
}

- (BOOL)isUndated {
    return self.dateSource == PODateSourceFile;
}

- (BOOL)isDuplicate {
    return self.duplicateOf != nil;
}

- (BOOL)needsMove {
    // Not a literal comparison: the file system may hand names back in another Unicode normalization form
    // (HFS+) or letter case than the one the folder was created with.
    return self.destinationFolder != nil &&
        [self.destinationFolder compare:self.currentFolder options:NSCaseInsensitiveSearch] != NSOrderedSame;
}

@end
