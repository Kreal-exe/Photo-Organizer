#import "POPlan.h"
#import "POMediaTypes.h"
#import "POScreenshots.h"
#import "POStrings.h"

static NSString *const PODefaultsScheme = @"scheme";
static NSString *const PODefaultsYearStyle = @"yearStyle";
static NSString *const PODefaultsMonthStyle = @"monthStyle";
static NSString *const PODefaultsDayStyle = @"dayStyle";
static NSString *const PODefaultsNested = @"nested";
static NSString *const PODefaultsSeparateDuplicates = @"separateDuplicates";
static NSString *const PODefaultsRemovesDuplicates = @"removesDuplicates";
static NSString *const PODefaultsSeparateTiny = @"separateTiny";
static NSString *const PODefaultsDuplicatesFolder = @"duplicatesFolderName";
static NSString *const PODefaultsTinyFolder = @"tinyFolderName";
static NSString *const PODefaultsCopiesFiles = @"organizeCopiesFiles";
static NSString *const PODefaultsArrangement = @"arrangement";
static NSString *const PODefaultsDatesInside = @"datesInside";
static NSString *const PODefaultsSeparateScreenshots = @"separateScreenshots";
static NSString *const PODefaultsScreenshotsInEachDate = @"screenshotsInEachDate";
static NSString *const PODefaultsScreenshotsFolder = @"screenshotsFolderName";
static NSString *const PODefaultsOrganizesPhotos = @"organizesPhotos";
static NSString *const PODefaultsOrganizesVideos = @"organizesVideos";
static NSString *const PODefaultsOrganizesPictures = @"organizesPictures";
static NSString *const PODefaultsOrganizesCollages = @"organizesCollages";
static NSString *const PODefaultsKeptFolders = @"keptFolders";   // library path (lower case) → [top-level folder]

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
    NSMutableSet<NSString *> *_keptFolders;                       // lower-cased
}

+ (void)initialize {
    if (self != POPlan.class) return;
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        PODefaultsScheme: @(POSchemeYear),
        PODefaultsNested: @YES,
        PODefaultsSeparateDuplicates: @YES,
        PODefaultsRemovesDuplicates: @YES,
        PODefaultsSeparateTiny: @YES,
        PODefaultsDatesInside: @YES,
        PODefaultsOrganizesPhotos: @YES,
        PODefaultsOrganizesVideos: @YES,
        PODefaultsOrganizesPictures: @YES,
        PODefaultsOrganizesCollages: @YES,
    }];
}

+ (NSString *)keyForKind:(NSInteger)kind {
    NSArray<NSString *> *keys = @[PODefaultsOrganizesPhotos, PODefaultsOrganizesVideos, PODefaultsOrganizesPictures, PODefaultsOrganizesCollages];
    return keys[MIN(MAX(kind, 0), 3)];
}

+ (BOOL)organizesKind:(NSInteger)kind {
    return [NSUserDefaults.standardUserDefaults boolForKey:[self keyForKind:kind]];
}

+ (void)setOrganizes:(BOOL)organizes kind:(NSInteger)kind {
    [NSUserDefaults.standardUserDefaults setBool:organizes forKey:[self keyForKind:kind]];
}

+ (NSString *)defaultDuplicatesFolderName { return POL(@"Дубликаты"); }
+ (NSString *)defaultTinyFolderName { return POL(@"Миниатюры"); }
+ (NSString *)defaultScreenshotsFolderName { return POL(@"Скриншоты"); }
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
        _sourceURLs = @[rootURL];
        _items = [items copy];
        _duplicateItems = [items filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"duplicate == YES"]];
        _nested = YES;
        _separateDuplicates = YES;
        _separateTiny = YES;
        _duplicatesFolderName = POPlan.defaultDuplicatesFolderName;
        _tinyFolderName = POPlan.defaultTinyFolderName;
        _screenshotsFolderName = POPlan.defaultScreenshotsFolderName;
        _datesInside = YES;
        _organizesPhotos = _organizesVideos = _organizesPictures = _organizesCollages = YES;
        _customNames = [NSMutableDictionary dictionary];
        NSArray *kept = [[NSUserDefaults.standardUserDefaults dictionaryForKey:PODefaultsKeptFolders] objectForKey:rootURL.path.lowercaseString];
        _keptFolders = [NSMutableSet setWithArray:[kept isKindOfClass:NSArray.class] ? kept : @[]];
        _groups = @[];
        _pendingItems = @[];
        _duplicatesToRemove = @[];
        // Folder names must not depend on the user's calendar (Buddhist, Japanese, …).
        _calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    }
    return self;
}

#pragma mark - Options

- (void)setDestinationURL:(NSURL *)url {
    char resolved[PATH_MAX];
    if (realpath(url.fileSystemRepresentation, resolved)) url = [NSURL fileURLWithFileSystemRepresentation:resolved isDirectory:YES relativeToURL:nil];
    _rootURL = url;
    NSArray *kept = [[NSUserDefaults.standardUserDefaults dictionaryForKey:PODefaultsKeptFolders] objectForKey:url.path.lowercaseString];
    _keptFolders = [NSMutableSet setWithArray:[kept isKindOfClass:NSArray.class] ? kept : @[]];
}

- (NSSet<NSString *> *)keptFolders {
    return [_keptFolders copy];
}

- (void)keepFolder:(NSString *)folder {
    NSString *top = [POPlan sanitizedFolderPath:folder ?: @""].pathComponents.firstObject.lowercaseString.precomposedStringWithCanonicalMapping;
    if (!top.length || [_keptFolders containsObject:top]) return;
    [_keptFolders addObject:top];
    NSMutableDictionary *all = [[NSUserDefaults.standardUserDefaults dictionaryForKey:PODefaultsKeptFolders] mutableCopy] ?: [NSMutableDictionary dictionary];
    all[self.rootURL.path.lowercaseString] = _keptFolders.allObjects;
    [NSUserDefaults.standardUserDefaults setObject:all forKey:PODefaultsKeptFolders];
}

- (BOOL)isInKeptFolder:(POPhotoItem *)item {
    if (!_keptFolders.count || !item.currentFolder.length) return NO;
    if (item.rootURL && ![item.rootURL.path isEqualToString:self.rootURL.path]) return NO;
    NSString *top = [item.currentFolder componentsSeparatedByString:@"/"].firstObject.lowercaseString.precomposedStringWithCanonicalMapping;
    return [_keptFolders containsObject:top];
}

/// Whether the kind of `item` is organized at all (photos, videos, pictures, collages).
- (BOOL)organizesItem:(POPhotoItem *)item {
    return POIsGooglePhotosCreation(item) ? self.organizesCollages
         : POIsPicture(item) ? self.organizesPictures
         : item.isVideo ? self.organizesVideos : self.organizesPhotos;
}

/// The first-level folder of a file when the library is not organized by date; nil for the date folders.
- (NSString *)sectionOfItem:(POPhotoItem *)item {
    if (self.separateScreenshots && POIsScreenshot(item)) return self.screenshotsFolderName;
    switch (self.arrangement) {
        case POArrangementType: return POTypeFolder(item);
        case POArrangementFormat: return POFormatFolder(item);
        case POArrangementPerson: {
            NSString *name = [self.personNames objectForKey:item];
            return name ? [[POPlan sanitizedFolderPath:name] stringByReplacingOccurrencesOfString:@"/" withString:@"-"] : nil;
        }
        case POArrangementDate: return nil;
    }
    return nil;
}

- (NSString *)folderForItem:(POPhotoItem *)item inFolder:(NSString *)folder layout:(POFolderLayout)layout {
    if (layout == POFolderLayoutFlat) return folder;
    if (item.isUndated) return [folder stringByAppendingPathComponent:POPlan.undatedFolderName];
    POScheme scheme = self.scheme;
    BOOL nested = self.nested;
    self.scheme = (POScheme)(layout - 1);
    self.nested = YES;
    NSString *dated = [folder stringByAppendingPathComponent:[self dateFolderForItem:item]];
    self.scheme = scheme;
    self.nested = nested;
    return dated;
}

- (void)setDuplicatesFolderName:(NSString *)name {
    _duplicatesFolderName = [[POPlan sanitizedFolderPath:name ?: @""].pathComponents.firstObject ?: POPlan.defaultDuplicatesFolderName copy];
}

- (void)setScreenshotsFolderName:(NSString *)name {
    _screenshotsFolderName = [[POPlan sanitizedFolderPath:name ?: @""].pathComponents.firstObject ?: POPlan.defaultScreenshotsFolderName copy];
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
    self.removesDuplicates = [defaults boolForKey:PODefaultsRemovesDuplicates];
    self.separateTiny = [defaults boolForKey:PODefaultsSeparateTiny];
    self.copiesFiles = [defaults boolForKey:PODefaultsCopiesFiles];
    self.arrangement = MIN(MAX([defaults integerForKey:PODefaultsArrangement], POArrangementDate), POArrangementFormat);
    self.datesInside = [defaults boolForKey:PODefaultsDatesInside];
    self.organizesPhotos = [defaults boolForKey:PODefaultsOrganizesPhotos];
    self.organizesVideos = [defaults boolForKey:PODefaultsOrganizesVideos];
    self.organizesPictures = [defaults boolForKey:PODefaultsOrganizesPictures];
    self.organizesCollages = [defaults boolForKey:PODefaultsOrganizesCollages];
    self.separateScreenshots = [defaults boolForKey:PODefaultsSeparateScreenshots];
    self.screenshotsInEachDate = [defaults boolForKey:PODefaultsScreenshotsInEachDate];
    NSString *screenshots = [defaults stringForKey:PODefaultsScreenshotsFolder];
    if ([@[@"Скриншоты", @"Screenshots"] containsObject:screenshots ?: @""]) screenshots = nil;
    self.screenshotsFolderName = screenshots ?: @"";
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
    [defaults setBool:self.removesDuplicates forKey:PODefaultsRemovesDuplicates];
    [defaults setBool:self.separateTiny forKey:PODefaultsSeparateTiny];
    [defaults setBool:self.copiesFiles forKey:PODefaultsCopiesFiles];
    [defaults setInteger:self.arrangement forKey:PODefaultsArrangement];
    [defaults setBool:self.datesInside forKey:PODefaultsDatesInside];
    [defaults setBool:self.organizesPhotos forKey:PODefaultsOrganizesPhotos];
    [defaults setBool:self.organizesVideos forKey:PODefaultsOrganizesVideos];
    [defaults setBool:self.organizesPictures forKey:PODefaultsOrganizesPictures];
    [defaults setBool:self.organizesCollages forKey:PODefaultsOrganizesCollages];
    [defaults setBool:self.separateScreenshots forKey:PODefaultsSeparateScreenshots];
    [defaults setBool:self.screenshotsInEachDate forKey:PODefaultsScreenshotsInEachDate];
    [defaults setObject:self.screenshotsFolderName forKey:PODefaultsScreenshotsFolder];
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
    // Into the destination, or (undone) back into one of the library's folders: the deepest that holds it.
    NSMutableArray<NSURL *> *roots = [self.sourceURLs mutableCopy];
    [roots addObject:self.rootURL];
    [roots sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return a.path.length > b.path.length ? NSOrderedAscending : NSOrderedDescending; }];
    for (NSUInteger i = 0; i < MIN(from.count, to.count); i++) {
        POPhotoItem *item = byPath[from[i].path];
        NSString *path = to[i].path;
        if (!item) continue;
        for (NSURL *root in roots) {
            NSString *prefix = [root.path stringByAppendingString:@"/"];
            if (![path hasPrefix:prefix]) continue;
            [item movedToURL:to[i] rootURL:root relativePath:[path substringFromIndex:prefix.length]];
            break;
        }
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
    NSMutableArray<POGroup *> *sectionGroups = [NSMutableArray array];
    // A generated folder → its group (under its custom name), added to `list` the first time.
    POGroup *(^groupFor)(NSString *, NSMutableArray<POGroup *> *) = ^POGroup *(NSString *generated, NSMutableArray<POGroup *> *list) {
        NSString *folder = self->_customNames[generated] ?: generated;
        POGroup *group = byFolder[folder];
        if (!group) {
            group = [[POGroup alloc] initWithKind:POGroupKindDate folder:folder];
            byFolder[folder] = group;
            [list addObject:group];
        }
        if (![generatedFolders containsObject:generated]) {
            [generatedFolders addObject:generated];
            [group.mutableGeneratedFolders addObject:generated];
        }
        return group;
    };

    // Duplicates to remove: copies of the kinds organized whose original (or best version) stays — never the last
    // file of a picture. They are left where they are until they go to the Trash.
    NSMutableOrderedSet<POPhotoItem *> *removed = [NSMutableOrderedSet orderedSet];
    if (self.removesDuplicates) {
        NSMutableSet<POPhotoItem *> *doomed = [NSMutableSet set];
        for (POPhotoItem *item in self.items) {
            if ((item.isDuplicate || item.betterCopy) && !item.isTiny && [self organizesItem:item]) [doomed addObject:item];
        }
        for (POPhotoItem *item in self.items) {
            if (![doomed containsObject:item]) continue;
            POPhotoItem *keeper = item.duplicateOf ?: item.betterCopy;
            if (keeper && [doomed containsObject:keeper]) keeper = keeper.betterCopy && ![doomed containsObject:keeper.betterCopy] ? keeper.betterCopy : nil;
            if (keeper) [removed addObject:item];
        }
    }
    _duplicatesToRemove = self.copiesFiles ? @[] : removed.array;

    for (POPhotoItem *item in self.items) {
        item.destinationRootURL = self.rootURL;
        // Left where they are: sorted by hand into a folder of their own, of a kind not to organize, or a duplicate to
        // remove (or, when copying, not to copy).
        if (![self organizesItem:item] || [removed containsObject:item] || [self isInKeptFolder:item]) {
            item.destinationFolder = item.currentFolder;
            continue;
        }
        POGroup *group;
        // Thumbnails first: an exact copy of a thumbnail is still a thumbnail.
        if (self.separateTiny && item.isTiny) {
            group = tiny;
        } else if (self.separateDuplicates && (item.isDuplicate || item.betterCopy)) {
            group = duplicates;
        } else if (self.separateScreenshots && self.screenshotsInEachDate && POIsScreenshot(item)) {
            // A screenshots folder inside the folder of its date (or of the undated files).
            NSString *date = item.isUndated ? POPlan.undatedFolderName : [self dateFolderForItem:item];
            group = groupFor([date stringByAppendingPathComponent:self.screenshotsFolderName], dateGroups);
        } else if ([self sectionOfItem:item]) {
            // By type, person or format: that folder first, the date folders (or the undated one) inside. The
            // screenshots folder always has its dates.
            NSString *section = [self sectionOfItem:item];
            BOOL datesInside = self.datesInside || self.arrangement == POArrangementDate;
            NSString *generated = !datesInside ? section
                : [section stringByAppendingPathComponent:item.isUndated ? POPlan.undatedFolderName : [self dateFolderForItem:item]];
            group = groupFor(generated, sectionGroups);
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

    // The type, person or format folders by name (each in date order inside), before the date folders of the rest.
    NSArray<POGroup *> *sections = [sectionGroups sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(POGroup *a, POGroup *b) {
        return [a.folder.pathComponents.firstObject localizedStandardCompare:b.folder.pathComponents.firstObject];
    }];
    [dateGroups insertObjects:sections atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, sections.count)]];
    if (undated.items.count) [dateGroups addObject:undated];
    if (tiny.items.count) [dateGroups addObject:tiny];
    if (duplicates.items.count) [dateGroups addObject:duplicates];
    _groups = [dateGroups copy];
    _pendingItems = [pending copy];
}

@end
