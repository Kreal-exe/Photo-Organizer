#import "POPlan.h"
#import "POStrings.h"

static NSString *const PODefaultsScheme = @"scheme";
static NSString *const PODefaultsYearStyle = @"yearStyle";
static NSString *const PODefaultsMonthStyle = @"monthStyle";
static NSString *const PODefaultsDayStyle = @"dayStyle";
static NSString *const PODefaultsNested = @"nested";
static NSString *const PODefaultsSeparateDuplicates = @"separateDuplicates";
static NSString *const PODefaultsSeparateTiny = @"separateTiny";
static NSString *const PODefaultsDuplicatesFolder = @"duplicatesFolderName";
static NSString *const PODefaultsTinyFolder = @"tinyFolderName";

@interface POGroup ()
- (instancetype)initWithKind:(POGroupKind)kind folder:(NSString *)folder;
@property (nonatomic, readonly) NSMutableArray<NSString *> *mutableGeneratedFolders;
@property (nonatomic, readonly) NSMutableArray<POPhotoItem *> *mutableItems;
@end

@implementation POGroup

- (instancetype)initWithKind:(POGroupKind)kind folder:(NSString *)folder {
    if ((self = [super init])) {
        _kind = kind;
        _folder = [folder copy];
        _mutableGeneratedFolders = [NSMutableArray array];
        _mutableItems = [NSMutableArray array];
    }
    return self;
}

- (NSArray<NSString *> *)generatedFolders { return _mutableGeneratedFolders; }
- (NSArray<POPhotoItem *> *)items { return _mutableItems; }

@end

@implementation POPlan {
    NSCalendar *_calendar;
    NSMutableDictionary<NSString *, NSString *> *_customNames;   // generated folder → custom folder
}

+ (void)initialize {
    if (self != POPlan.class) return;
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        PODefaultsScheme: @(POSchemeYear),
        PODefaultsNested: @YES,
        PODefaultsSeparateDuplicates: @YES,
        PODefaultsSeparateTiny: @YES,
    }];
}

+ (NSString *)defaultDuplicatesFolderName { return POL(@"Дубликаты"); }
+ (NSString *)defaultTinyFolderName { return POL(@"Миниатюры"); }
+ (NSString *)undatedFolderName { return POL(@"Без даты"); }

+ (NSString *)savedDuplicatesFolderName {
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:PODefaultsDuplicatesFolder];
    if ([@[@"Дубликаты", @"Duplicates"] containsObject:saved ?: @""]) saved = nil;
    return [self sanitizedFolderPath:saved ?: @""].pathComponents.firstObject ?: self.defaultDuplicatesFolderName;
}

+ (NSString *)sanitizedFolderPath:(NSString *)path {
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    for (NSString *raw in [path componentsSeparatedByString:@"/"]) {
        // A colon is the path separator in Finder, and a leading dot would hide the folder from the next scan.
        NSString *component = [raw stringByReplacingOccurrencesOfString:@":" withString:@"-"];
        component = [component stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        while ([component hasPrefix:@"."]) component = [component substringFromIndex:1];
        if (component.length) [components addObject:component];
    }
    return components.count ? [components componentsJoinedByString:@"/"] : nil;
}

- (instancetype)initWithRootURL:(NSURL *)rootURL items:(NSArray<POPhotoItem *> *)items {
    if ((self = [super init])) {
        _rootURL = rootURL;
        _items = [items copy];
        _duplicateItems = [items filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"duplicate == YES"]];
        _nested = YES;
        _separateDuplicates = YES;
        _separateTiny = YES;
        _duplicatesFolderName = POPlan.defaultDuplicatesFolderName;
        _tinyFolderName = POPlan.defaultTinyFolderName;
        _customNames = [NSMutableDictionary dictionary];
        _groups = @[];
        _pendingItems = @[];
        // Folder names must not depend on the user's calendar (Buddhist, Japanese, …).
        _calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    }
    return self;
}

#pragma mark - Options

- (void)setDuplicatesFolderName:(NSString *)name {
    _duplicatesFolderName = [[POPlan sanitizedFolderPath:name ?: @""].pathComponents.firstObject ?: POPlan.defaultDuplicatesFolderName copy];
}

- (void)setTinyFolderName:(NSString *)name {
    _tinyFolderName = [[POPlan sanitizedFolderPath:name ?: @""].pathComponents.firstObject ?: POPlan.defaultTinyFolderName copy];
}

- (void)setCustomName:(NSString *)name forGroup:(POGroup *)group {
    NSString *sanitized = name ? [POPlan sanitizedFolderPath:name] : nil;
    switch (group.kind) {
        case POGroupKindDuplicates:
            self.duplicatesFolderName = sanitized ?: @"";
            break;
        case POGroupKindTiny:
            self.tinyFolderName = sanitized ?: @"";
            break;
        case POGroupKindUndated:
        case POGroupKindDate:
            for (NSString *generated in group.generatedFolders) {
                _customNames[generated] = [sanitized isEqualToString:generated] ? nil : sanitized;
            }
            break;
    }
}

- (BOOL)hasCustomNames {
    return _customNames.count > 0;
}

- (void)removeCustomNames {
    [_customNames removeAllObjects];
}

- (void)loadOptionsFromDefaults {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.scheme = MIN(MAX([defaults integerForKey:PODefaultsScheme], POSchemeYear), POSchemeYearMonthDay);
    self.yearStyle = MIN(MAX([defaults integerForKey:PODefaultsYearStyle], POYearStyleNumber), POYearStyleWord);
    self.monthStyle = MIN(MAX([defaults integerForKey:PODefaultsMonthStyle], POMonthStyleISO), POMonthStyleNameYear);
    self.dayStyle = MIN(MAX([defaults integerForKey:PODefaultsDayStyle], PODayStyleISO), PODayStyleDayMonth);
    self.nested = [defaults boolForKey:PODefaultsNested];
    self.separateDuplicates = [defaults boolForKey:PODefaultsSeparateDuplicates];
    self.separateTiny = [defaults boolForKey:PODefaultsSeparateTiny];
    // A saved name that is just the default of another interface language is not a choice the user made.
    NSString *duplicates = [defaults stringForKey:PODefaultsDuplicatesFolder], *tiny = [defaults stringForKey:PODefaultsTinyFolder];
    if ([@[@"Дубликаты", @"Duplicates"] containsObject:duplicates ?: @""]) duplicates = nil;
    if ([@[@"Миниатюры", @"Thumbnails"] containsObject:tiny ?: @""]) tiny = nil;
    self.duplicatesFolderName = duplicates ?: @"";
    self.tinyFolderName = tiny ?: @"";
}

- (void)saveOptionsToDefaults {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setInteger:self.scheme forKey:PODefaultsScheme];
    [defaults setInteger:self.yearStyle forKey:PODefaultsYearStyle];
    [defaults setInteger:self.monthStyle forKey:PODefaultsMonthStyle];
    [defaults setInteger:self.dayStyle forKey:PODefaultsDayStyle];
    [defaults setBool:self.nested forKey:PODefaultsNested];
    [defaults setBool:self.separateDuplicates forKey:PODefaultsSeparateDuplicates];
    [defaults setBool:self.separateTiny forKey:PODefaultsSeparateTiny];
    [defaults setObject:self.duplicatesFolderName forKey:PODefaultsDuplicatesFolder];
    [defaults setObject:self.tinyFolderName forKey:PODefaultsTinyFolder];
}

#pragma mark - Naming

- (NSString *)dateFolderForItem:(POPhotoItem *)item {
    NSDate *date = item.date;
    static NSArray<NSString *> *monthNames, *monthNamesGenitive;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        monthNames = @[POL(@"Январь"), POL(@"Февраль"), POL(@"Март"), POL(@"Апрель"), POL(@"Май"), POL(@"Июнь"),
                       POL(@"Июль"), POL(@"Август"), POL(@"Сентябрь"), POL(@"Октябрь"), POL(@"Ноябрь"), POL(@"Декабрь")];
        monthNamesGenitive = @[POL(@"января"), POL(@"февраля"), POL(@"марта"), POL(@"апреля"), POL(@"мая"), POL(@"июня"),
                               POL(@"июля"), POL(@"августа"), POL(@"сентября"), POL(@"октября"), POL(@"ноября"), POL(@"декабря")];
    });
    NSDateComponents *c = [_calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:date];
    long year = (long)c.year, month = (long)c.month, day = (long)c.day;
    NSInteger monthIndex = MIN(MAX(c.month, 1), 12) - 1;

    NSMutableArray<NSString *> *levels = [NSMutableArray array];
    [levels addObject:[NSString stringWithFormat:self.yearStyle == POYearStyleWord ? POL(@"%04ld год") : @"%04ld", year]];
    // A date known only to the year (or month) goes to that level, not to the January (or the 1st) folder.
    POScheme scheme = self.scheme;
    if (POItemDatePrecision(item) == PODatePrecisionYear) scheme = POSchemeYear;
    if (POItemDatePrecision(item) == PODatePrecisionMonth) scheme = MIN(scheme, POSchemeYearMonth);
    if (scheme >= POSchemeYearMonth) {
        switch (self.monthStyle) {
            case POMonthStyleISO: [levels addObject:[NSString stringWithFormat:@"%04ld-%02ld", year, month]]; break;
            case POMonthStyleISOName: [levels addObject:[NSString stringWithFormat:@"%04ld-%02ld %@", year, month, monthNames[monthIndex]]]; break;
            case POMonthStyleNumberName: [levels addObject:[NSString stringWithFormat:@"%02ld %@", month, monthNames[monthIndex]]]; break;
            case POMonthStyleNameYear: [levels addObject:[NSString stringWithFormat:@"%@ %04ld", monthNames[monthIndex], year]]; break;
        }
    }
    if (scheme >= POSchemeYearMonthDay) {
        switch (self.dayStyle) {
            case PODayStyleISO: [levels addObject:[NSString stringWithFormat:@"%04ld-%02ld-%02ld", year, month, day]]; break;
            case PODayStyleNumber: [levels addObject:[NSString stringWithFormat:@"%02ld", day]]; break;
            case PODayStyleDayMonth: [levels addObject:[NSString stringWithFormat:@"%02ld %@", day, monthNamesGenitive[monthIndex]]]; break;
        }
    }
    return self.nested ? [levels componentsJoinedByString:@"/"] : levels.lastObject;
}

#pragma mark - Result

- (void)removeItems:(NSArray<POPhotoItem *> *)removed {
    if (!removed.count) return;
    NSSet<POPhotoItem *> *gone = [NSSet setWithArray:removed];
    _items = [_items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(POPhotoItem *item, NSDictionary *bindings) {
        return ![gone containsObject:item];
    }]];
    // Exact-duplicate sets, re-formed from their surviving members.
    NSMutableSet<POPhotoItem *> *originals = [NSMutableSet set];
    for (POPhotoItem *item in removed) {
        if (item.duplicates.count) [originals addObject:item];
        if (item.duplicateOf) [originals addObject:item.duplicateOf];
    }
    for (POPhotoItem *original in originals) {
        NSMutableArray<POPhotoItem *> *set = [NSMutableArray arrayWithObject:original];
        [set addObjectsFromArray:original.duplicates ?: @[]];
        [set filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(POPhotoItem *item, NSDictionary *bindings) {
            return ![gone containsObject:item];
        }]];
        for (POPhotoItem *item in set) {
            item.duplicateOf = nil;
            item.duplicates = nil;
        }
        if (set.count < 2) continue;
        POPhotoItem *keeper = set.firstObject;
        NSArray<POPhotoItem *> *copies = [set subarrayWithRange:NSMakeRange(1, set.count - 1)];
        keeper.duplicates = copies;
        for (POPhotoItem *copy in copies) copy.duplicateOf = keeper;
    }
    _duplicateItems = [_items filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"duplicate == YES"]];
}

- (void)itemsMovedFrom:(NSArray<NSURL *> *)from to:(NSArray<NSURL *> *)to {
    NSMutableDictionary<NSString *, POPhotoItem *> *byPath = [NSMutableDictionary dictionaryWithCapacity:_items.count];
    for (POPhotoItem *item in _items) byPath[item.url.path] = item;
    NSString *rootPrefix = [self.rootURL.path stringByAppendingString:@"/"];
    for (NSUInteger i = 0; i < MIN(from.count, to.count); i++) {
        POPhotoItem *item = byPath[from[i].path];
        NSString *path = to[i].path;
        if (!item || ![path hasPrefix:rootPrefix]) continue;
        [item movedToURL:to[i] relativePath:[path substringFromIndex:rootPrefix.length]];
    }
}

- (void)sortItemsByDate {
    _items = [_items sortedArrayUsingComparator:^NSComparisonResult(POPhotoItem *a, POPhotoItem *b) {
        return [a.date compare:b.date] ?: [a.relativePath localizedStandardCompare:b.relativePath];
    }];
}

- (NSArray<POPhotoItem *> *)tinyItems {
    return [self.items filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"tiny == YES"]];
}

- (void)rebuild {
    // `items` is sorted by date, so date groups come out in chronological order whatever their names are.
    NSMutableArray<POGroup *> *dateGroups = [NSMutableArray array];
    NSMutableDictionary<NSString *, POGroup *> *byFolder = [NSMutableDictionary dictionary];
    POGroup *tiny = [[POGroup alloc] initWithKind:POGroupKindTiny folder:self.tinyFolderName];
    POGroup *duplicates = [[POGroup alloc] initWithKind:POGroupKindDuplicates folder:self.duplicatesFolderName];
    POGroup *undated = [[POGroup alloc] initWithKind:POGroupKindUndated folder:_customNames[POPlan.undatedFolderName] ?: POPlan.undatedFolderName];
    [undated.mutableGeneratedFolders addObject:POPlan.undatedFolderName];
    [tiny.mutableGeneratedFolders addObject:tiny.folder];
    [duplicates.mutableGeneratedFolders addObject:duplicates.folder];
    NSMutableSet<NSString *> *generatedFolders = [NSMutableSet set];
    NSMutableArray<POPhotoItem *> *pending = [NSMutableArray array];

    for (POPhotoItem *item in self.items) {
        POGroup *group;
        // Thumbnails first: an exact copy of a thumbnail is still a thumbnail.
        if (self.separateTiny && item.isTiny) {
            group = tiny;
        } else if (self.separateDuplicates && (item.isDuplicate || item.betterCopy)) {
            group = duplicates;
        } else if (item.isUndated) {
            group = undated;
        } else {
            NSString *generated = [self dateFolderForItem:item];
            NSString *folder = _customNames[generated] ?: generated;
            group = byFolder[folder];
            if (!group) {
                group = [[POGroup alloc] initWithKind:POGroupKindDate folder:folder];
                byFolder[folder] = group;
                [dateGroups addObject:group];
            }
            if (![generatedFolders containsObject:generated]) {
                [generatedFolders addObject:generated];
                [group.mutableGeneratedFolders addObject:generated];
            }
        }
        [group.mutableItems addObject:item];
        item.destinationFolder = group.folder;
        if (item.needsMove) [pending addObject:item];
    }

    // Custom names only make sense for the naming scheme they were typed for.
    for (NSString *generated in _customNames.allKeys) {
        if (![generatedFolders containsObject:generated] && ![generated isEqualToString:POPlan.undatedFolderName]) _customNames[generated] = nil;
    }

    if (undated.items.count) [dateGroups addObject:undated];
    if (tiny.items.count) [dateGroups addObject:tiny];
    if (duplicates.items.count) [dateGroups addObject:duplicates];
    _groups = [dateGroups copy];
    _pendingItems = [pending copy];
}

@end
