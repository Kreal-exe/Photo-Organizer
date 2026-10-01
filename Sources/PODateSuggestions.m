#import "PODateSuggestions.h"
#import "POStrings.h"

@interface PODateSuggestion ()
- (instancetype)initWithKind:(PODateSuggestionKind)kind date:(NSDate *)date precision:(PODatePrecision)precision reason:(NSString *)reason;
@end

static NSCalendar *POGregorian(void) {
    static NSCalendar *calendar;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian]; });
    return calendar;
}

/// Noon of the first day of the year / month, or of the day itself: the date stored for a less precise date.
static NSDate *PONormalized(NSDate *date, PODatePrecision precision) {
    NSDateComponents *c = [POGregorian() components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:date];
    if (precision >= PODatePrecisionMonth) c.day = 1;
    if (precision >= PODatePrecisionYear) c.month = 1;
    c.hour = 12;
    return [POGregorian() dateFromComponents:c];
}

@implementation PODateSuggestion

- (instancetype)initWithKind:(PODateSuggestionKind)kind date:(NSDate *)date precision:(PODatePrecision)precision reason:(NSString *)reason {
    if ((self = [super init])) {
        _kind = kind;
        _precision = precision;
        _date = precision == PODatePrecisionDay && kind == PODateSuggestionFileDate ? date : PONormalized(date, precision);
        _reason = [reason copy];
        POPhotoItem *probe = [[POPhotoItem alloc] initWithURL:[NSURL fileURLWithPath:@"/"] relativePath:@"x"];
        probe.date = _date;
        probe.dateSource = PODateSourceManual;
        probe.manualPrecision = precision;
        _dateText = [POItemDateText(probe, NO) copy];
    }
    return self;
}

- (BOOL)isSameAs:(PODateSuggestion *)other {
    return other.precision == self.precision && [PONormalized(other.date, self.precision) isEqualToDate:PONormalized(self.date, self.precision)];
}

@end

static BOOL POHasRealDate(POPhotoItem *item) {
    return !item.isUndated;
}

/// "2019", "2019-05", "2019_05", "05.2019" as a year (and month) in a name; nil when there is none or more than one.
static NSDateComponents *POYearInName(NSString *name) {
    static NSRegularExpression *expression;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:@"(?<!\\d)(19[89]\\d|20[0-4]\\d)(?:[-_.](0[1-9]|1[0-2]))?(?!\\d)" options:0 error:NULL];
    });
    NSArray<NSTextCheckingResult *> *matches = [expression matchesInString:name options:0 range:NSMakeRange(0, name.length)];
    if (matches.count != 1) return nil;
    NSDateComponents *components = [NSDateComponents new];
    components.year = [name substringWithRange:[matches[0] rangeAtIndex:1]].integerValue;
    NSRange month = [matches[0] rangeAtIndex:2];
    components.month = month.location == NSNotFound ? 0 : [name substringWithRange:month].integerValue;
    if (components.year > [POGregorian() component:NSCalendarUnitYear fromDate:NSDate.date]) return nil;
    return components;
}

static PODateSuggestion *POSuggestionFromComponents(NSDateComponents *found, PODateSuggestionKind kind, NSString *reason) {
    NSDateComponents *components = [NSDateComponents new];
    components.year = found.year;
    components.month = found.month ?: 1;
    components.day = 1;
    components.hour = 12;
    return [[PODateSuggestion alloc] initWithKind:kind date:[POGregorian() dateFromComponents:components]
                                        precision:found.month ? PODatePrecisionMonth : PODatePrecisionYear reason:reason];
}

@implementation PODateSuggester {
    NSDictionary<NSString *, NSArray<POPhotoItem *> *> *_folders;   // folder → its files, ordered by name
}

- (instancetype)initWithItems:(NSArray<POPhotoItem *> *)items {
    if ((self = [super init])) {
        NSMutableDictionary<NSString *, NSMutableArray<POPhotoItem *> *> *folders = [NSMutableDictionary dictionary];
        for (POPhotoItem *item in items) {
            NSMutableArray *list = folders[item.currentFolder];
            if (!list) folders[item.currentFolder] = list = [NSMutableArray array];
            [list addObject:item];
        }
        for (NSMutableArray<POPhotoItem *> *list in folders.allValues) {
            [list sortUsingComparator:^NSComparisonResult(POPhotoItem *a, POPhotoItem *b) {
                return [a.url.lastPathComponent localizedStandardCompare:b.url.lastPathComponent];
            }];
        }
        _folders = folders;
    }
    return self;
}

/// "img_" for "IMG_1711.JPG": the name without its trailing number; nil for names that don't end in one.
static NSString *POSeriesPrefix(POPhotoItem *item) {
    NSString *base = item.url.lastPathComponent.stringByDeletingPathExtension;
    NSUInteger end = base.length;
    while (end > 0 && isdigit([base characterAtIndex:end - 1])) end--;
    if (end == base.length || end == 0) return nil;
    return [base substringToIndex:end].lowercaseString;
}

/// The nearest dated files before and after `item` in its folder (by name), from the same numbered series
/// (IMG_1699 … IMG_1711 … IMG_1754): what they have in common. Names that are not numbered (hashes, VK ids) say
/// nothing about order, so they get no suggestion of this kind.
- (PODateSuggestion *)neighbourSuggestionForItem:(POPhotoItem *)item {
    NSArray<POPhotoItem *> *list = _folders[item.currentFolder];
    NSUInteger index = [list indexOfObjectIdenticalTo:item];
    if (index == NSNotFound) return nil;
    POPhotoItem *before = nil, *after = nil;
    NSString *series = POSeriesPrefix(item);
    if (!series) return nil;
    for (NSInteger i = (NSInteger)index - 1; i >= 0 && !before; i--) {
        if (POHasRealDate(list[i]) && [POSeriesPrefix(list[i]) isEqualToString:series]) before = list[i];
    }
    for (NSUInteger i = index + 1; i < list.count && !after; i++) {
        if (POHasRealDate(list[i]) && [POSeriesPrefix(list[i]) isEqualToString:series]) after = list[i];
    }
    if (!before || !after) return nil;
    NSCalendar *calendar = POGregorian();
    NSDateComponents *a = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:before.date];
    NSDateComponents *b = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:after.date];
    if (a.year != b.year) return nil;
    PODatePrecision precision = a.month != b.month ? PODatePrecisionYear : (a.day != b.day ? PODatePrecisionMonth : PODatePrecisionDay);
    // A file can't be more precise than the least precise of its two neighbours.
    precision = MAX(precision, MAX(POItemDatePrecision(before), POItemDatePrecision(after)));
    NSString *reason = [NSString stringWithFormat:POL(@"как у соседних файлов %@ и %@"), before.url.lastPathComponent, after.url.lastPathComponent];
    return [[PODateSuggestion alloc] initWithKind:PODateSuggestionNeighbors date:before.date precision:precision reason:reason];
}

- (NSArray<PODateSuggestion *> *)suggestionsForItem:(POPhotoItem *)item {
    if (!item.isUndated) return @[];
    NSMutableArray<PODateSuggestion *> *suggestions = [NSMutableArray array];
    void (^add)(PODateSuggestion *) = ^(PODateSuggestion *suggestion) {
        if (!suggestion) return;
        for (PODateSuggestion *existing in suggestions) if ([existing isSameAs:suggestion]) return;
        [suggestions addObject:suggestion];
    };
    // A folder named after a year is the user's own sorting: neighbours that disagree with it (a camera
    // counter shared across years, files from elsewhere dropped in) are not suggested.
    NSInteger folderYear = 0;
    for (NSString *folder in item.currentFolder.pathComponents.reverseObjectEnumerator) {
        NSDateComponents *inFolder = POYearInName(folder);
        if (inFolder) { folderYear = inFolder.year; break; }
    }
    PODateSuggestion *neighbours = [self neighbourSuggestionForItem:item];
    if (neighbours && (!folderYear || [POGregorian() component:NSCalendarUnitYear fromDate:neighbours.date] == folderYear)) add(neighbours);
    NSString *name = item.url.lastPathComponent.stringByDeletingPathExtension;
    NSDateComponents *inName = POYearInName(name);
    if (inName) add(POSuggestionFromComponents(inName, PODateSuggestionFileName, [NSString stringWithFormat:POL(@"из имени файла «%@»"), item.url.lastPathComponent]));
    for (NSString *folder in item.currentFolder.pathComponents.reverseObjectEnumerator) {
        NSDateComponents *inFolder = POYearInName(folder);
        if (!inFolder) continue;
        add(POSuggestionFromComponents(inFolder, PODateSuggestionFolderName, [NSString stringWithFormat:POL(@"из названия папки «%@»"), folder]));
        break;
    }
    if (item.fileDate) {
        add([[PODateSuggestion alloc] initWithKind:PODateSuggestionFileDate date:item.fileDate precision:PODatePrecisionDay
                                            reason:POL(@"дата файла — часто это день, когда файл скопировали")]);
    }
    return suggestions;
}

- (PODateSuggestion *)bestSuggestionForItem:(POPhotoItem *)item {
    for (PODateSuggestion *suggestion in [self suggestionsForItem:item]) {
        if (suggestion.kind != PODateSuggestionFileDate) return suggestion;
    }
    return nil;
}

@end
