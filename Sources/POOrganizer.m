#import "POOrganizer.h"
#import "POStrings.h"
#import "POScanner.h"
#import "POSimilarCopies.h"
#import <unistd.h>
#import <stdio.h>
#import <errno.h>
#import <copyfile.h>

@interface POMoveRecord ()
- (instancetype)initWithFrom:(NSURL *)from to:(NSURL *)to fileSize:(unsigned long long)fileSize;
- (instancetype)initWithFrom:(NSURL *)from to:(NSURL *)to fileSize:(unsigned long long)fileSize sidecar:(BOOL)sidecar;
@end

@implementation POMoveRecord

- (instancetype)initWithFrom:(NSURL *)from to:(NSURL *)to fileSize:(unsigned long long)fileSize {
    return [self initWithFrom:from to:to fileSize:fileSize sidecar:[from.pathExtension caseInsensitiveCompare:@"json"] == NSOrderedSame];
}

- (instancetype)initWithFrom:(NSURL *)from to:(NSURL *)to fileSize:(unsigned long long)fileSize sidecar:(BOOL)sidecar {
    if ((self = [super init])) {
        _from = from;
        _to = to;
        _fileSize = fileSize;
        _sidecar = sidecar;
    }
    return self;
}

@end

@interface POOrganizeResult ()
- (instancetype)initWithRecords:(NSArray<POMoveRecord *> *)records
             createdDirectories:(NSArray<NSURL *> *)createdDirectories
                         errors:(NSArray<NSString *> *)errors;
@property (nonatomic) BOOL copied;
@property (nonatomic) NSUInteger alreadyCopied;
@property (nonatomic) BOOL stopped;
@end

@implementation POOrganizeResult

- (NSUInteger)fileCount {
    NSUInteger count = 0;
    for (POMoveRecord *record in self.records) count += !record.isSidecar;
    return count;
}

+ (instancetype)resultWithMoves:(NSArray<POMoveRecord *> *)moves {
    return [[POOrganizeResult alloc] initWithRecords:moves createdDirectories:@[] errors:@[]];
}

- (instancetype)initWithRecords:(NSArray<POMoveRecord *> *)records
             createdDirectories:(NSArray<NSURL *> *)createdDirectories
                         errors:(NSArray<NSString *> *)errors {
    if ((self = [super init])) {
        _records = [records copy];
        _createdDirectories = [createdDirectories copy];
        _errors = [errors copy];
    }
    return self;
}

@end

/// Returns a URL in `directory` that nothing exists at yet: "name.jpg", "name (2).jpg", …
static NSURL *POUniqueURL(NSURL *directory, NSString *name, NSFileManager *fm) {
    NSURL *candidate = [directory URLByAppendingPathComponent:name isDirectory:NO];
    NSString *base = name.stringByDeletingPathExtension, *extension = name.pathExtension;
    for (NSUInteger index = 2; [fm fileExistsAtPath:candidate.path]; index++) {
        NSString *numbered = [NSString stringWithFormat:@"%@ (%lu)", base, (unsigned long)index];
        if (extension.length) numbered = [numbered stringByAppendingPathExtension:extension];
        candidate = [directory URLByAppendingPathComponent:numbered isDirectory:NO];
    }
    return candidate;
}

/// Creates `directory` and remembers every level that did not exist before, outermost first.
static BOOL POEnsureDirectory(NSURL *directory, NSMutableArray<NSURL *> *created, NSFileManager *fm, NSError **error) {
    NSMutableArray<NSURL *> *missing = [NSMutableArray array];
    // By path: URLByDeletingLastPathComponent of a URL ending in an empty component climbs nowhere ("…/../").
    for (NSString *current = directory.path.stringByStandardizingPath; current.length > 1 && ![fm fileExistsAtPath:current];
         current = current.stringByDeletingLastPathComponent) {
        [missing insertObject:[NSURL fileURLWithPath:current isDirectory:YES] atIndex:0];
    }
    if (![fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    [created addObjectsFromArray:missing];
    return YES;
}

/// Removes a directory that holds nothing but (possibly) Finder's .DS_Store.
static BOOL PORemoveIfEmpty(NSURL *directory, NSFileManager *fm) {
    NSArray<NSString *> *contents = [fm contentsOfDirectoryAtPath:directory.path error:NULL];
    if (!contents) return NO;
    for (NSString *name in contents) {
        if (![name isEqualToString:@".DS_Store"]) return NO;
    }
    if (contents.count) [fm removeItemAtURL:[directory URLByAppendingPathComponent:@".DS_Store"] error:NULL];
    return rmdir(directory.fileSystemRepresentation) == 0;
}

static NSError *POError(NSString *message) {
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// YES when `url` is still a regular file of exactly `size` bytes.
static BOOL POIsUnchangedFile(NSURL *url, unsigned long long size, NSFileManager *fm) {
    NSDictionary<NSFileAttributeKey, id> *attributes = [fm attributesOfItemAtPath:url.path error:NULL];
    return [attributes[NSFileType] isEqual:NSFileTypeRegular] && [attributes[NSFileSize] unsignedLongLongValue] == size;
}

/// YES when `copy` is already a copy of `original`: a regular file of the same size and modification time (copies
/// keep it; two seconds of slack for FAT and exFAT drives, which store times that coarsely).
static BOOL POIsCopyOf(NSURL *copy, NSURL *original, unsigned long long size, NSFileManager *fm) {
    NSDictionary<NSFileAttributeKey, id> *a = [fm attributesOfItemAtPath:copy.path error:NULL];
    NSDictionary<NSFileAttributeKey, id> *b = [fm attributesOfItemAtPath:original.path error:NULL];
    if (![a[NSFileType] isEqual:NSFileTypeRegular] || [a[NSFileSize] unsignedLongLongValue] != size) return NO;
    NSDate *dateA = a[NSFileModificationDate], *dateB = b[NSFileModificationDate];
    return dateA && dateB && fabs(dateA.timeIntervalSinceReferenceDate - dateB.timeIntervalSinceReferenceDate) <= 2;
}

/// YES when `directory` already holds a copy of `original` under its name or a numbered one ("name (2).jpg", …):
/// another picture that happens to have the same name pushes the copy to the next free number.
static BOOL POHasCopyIn(NSURL *directory, NSURL *original, unsigned long long size, NSFileManager *fm) {
    NSString *name = original.lastPathComponent, *base = name.stringByDeletingPathExtension, *extension = name.pathExtension;
    NSURL *candidate = [directory URLByAppendingPathComponent:name isDirectory:NO];
    for (NSUInteger index = 2; [fm fileExistsAtPath:candidate.path]; index++) {
        if (POIsCopyOf(candidate, original, size, fm)) return YES;
        NSString *numbered = [NSString stringWithFormat:@"%@ (%lu)", base, (unsigned long)index];
        if (extension.length) numbered = [numbered stringByAppendingPathExtension:extension];
        candidate = [directory URLByAppendingPathComponent:numbered isDirectory:NO];
    }
    return NO;
}

static BOOL POIsSameDirectory(NSURL *a, NSURL *b) {
    id identifierA = nil, identifierB = nil;
    // Fresh URLs: resource values are cached per NSURL instance.
    [[NSURL fileURLWithPath:a.path] getResourceValue:&identifierA forKey:NSURLFileResourceIdentifierKey error:NULL];
    [[NSURL fileURLWithPath:b.path] getResourceValue:&identifierB forKey:NSURLFileResourceIdentifierKey error:NULL];
    return identifierA && [identifierA isEqual:identifierB];
}

/// Copies `source` into `directory` as `name` (or "name (2)", …) without ever replacing an existing file. On APFS the
/// copy is a clone: instant, and it takes no space until one of the two changes. Dates and metadata are kept.
static NSURL *POCopyExclusively(NSURL *source, NSURL *directory, NSString *name, NSFileManager *fm, NSError **error) {
    for (int attempt = 0; attempt < 100; attempt++) {
        NSURL *destination = POUniqueURL(directory, name, fm);
        if (copyfile(source.fileSystemRepresentation, destination.fileSystemRepresentation, NULL,
                     COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_CLONE) == 0) return destination;
        int code = errno;
        if (code == EEXIST) continue;   // the name was taken since we looked; try the next one
        unlink(destination.fileSystemRepresentation);   // a half-written copy (disk full, unplugged drive)
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
        return nil;
    }
    if (error) *error = POError(POL(@"не удалось подобрать свободное имя"));
    return nil;
}

/// Moves `source` into `directory` as `name` (or "name (2)", …) without ever replacing an existing file.
static NSURL *POMoveExclusively(NSURL *source, NSURL *directory, NSString *name, NSFileManager *fm, NSError **error) {
    for (int attempt = 0; attempt < 100; attempt++) {
        NSURL *destination = POUniqueURL(directory, name, fm);
        if (renamex_np(source.fileSystemRepresentation, destination.fileSystemRepresentation, RENAME_EXCL) == 0) return destination;
        int code = errno;
        if (code == EEXIST) continue;   // the name was taken since we looked; try the next one
        if (code == ENOTSUP || code == EXDEV || code == EINVAL) {
            // No exclusive rename on this volume (exFAT, some network shares) or a different volume.
            // NSFileManager also refuses to overwrite, and copies then deletes when it has to cross volumes.
            return [fm moveItemAtURL:source toURL:destination error:error] ? destination : nil;
        }
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
        return nil;
    }
    if (error) *error = POError(POL(@"не удалось подобрать свободное имя"));
    return nil;
}

/// Takes the Google Takeout .json of `item` along to where the file went (see POPhotoItem.sidecarURL), under its own
/// name, never over another file — only when the file kept its name, for the .json names the file it describes.
static void POCarrySidecar(POPhotoItem *item, NSURL *destination, BOOL copies, NSMutableArray<POMoveRecord *> *records, NSFileManager *fm) {
    NSURL *sidecar = item.sidecarURL;
    if (!sidecar || ![destination.lastPathComponent isEqualToString:item.url.lastPathComponent]) return;
    NSDictionary<NSFileAttributeKey, id> *attributes = [fm attributesOfItemAtPath:sidecar.path error:NULL];
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) return;
    NSURL *target = [destination.URLByDeletingLastPathComponent URLByAppendingPathComponent:sidecar.lastPathComponent];
    if ([fm fileExistsAtPath:target.path]) return;
    BOOL done = copies ? [fm copyItemAtURL:sidecar toURL:target error:NULL]
                       : renamex_np(sidecar.fileSystemRepresentation, target.fileSystemRepresentation, RENAME_EXCL) == 0 ||
                         (errno != EEXIST && [fm moveItemAtURL:sidecar toURL:target error:NULL]);
    if (done) [records addObject:[[POMoveRecord alloc] initWithFrom:sidecar to:target fileSize:[attributes[NSFileSize] unsignedLongLongValue] sidecar:YES]];
}

@implementation POOrganizer

+ (POOrganizeResult *)applyPlan:(POPlan *)plan progress:(void (^)(NSUInteger, NSUInteger))progress {
    NSString *(^folder)(POPhotoItem *) = ^NSString *(POPhotoItem *item) { return item.destinationFolder; };
    if (plan.copiesFiles) return [self copyItems:plan.pendingItems rootURL:plan.rootURL progress:progress folder:folder];
    return [self moveItems:plan.pendingItems rootURL:plan.rootURL progress:progress folder:folder];
}

/// The picture a file shows, as the library knows it: its original when it is an exact copy, the best version when a lesser one.
static POPhotoItem *POPictureOf(POPhotoItem *item) {
    POPhotoItem *picture = item.duplicateOf ?: item;
    picture = picture.betterCopy ?: picture;
    return picture.duplicateOf ?: picture;
}

/// "name.jpg", "name (2).jpg"… already in `directory` showing the same picture, pixel by pixel, though saved differently
/// (the same shot with other metadata or compression is not copied again next to itself).
static BOOL POSamePictureIn(NSURL *directory, POPhotoItem *item, NSFileManager *fm) {
    if (item.isVideo || item.pixelWidth <= 0 || item.pixelHeight <= 0) return NO;
    NSString *name = item.url.lastPathComponent, *stem = name.stringByDeletingPathExtension, *extension = name.pathExtension;
    for (NSString *other in [fm contentsOfDirectoryAtPath:directory.path error:NULL]) {
        if ([other.pathExtension caseInsensitiveCompare:extension] != NSOrderedSame) continue;
        NSString *otherStem = other.stringByDeletingPathExtension;
        BOOL numbered = NO;
        if (otherStem.length > stem.length + 3 && [[otherStem substringToIndex:stem.length] caseInsensitiveCompare:stem] == NSOrderedSame) {
            NSString *tail = [otherStem substringFromIndex:stem.length];
            NSScanner *scanner = [NSScanner scannerWithString:tail];
            numbered = [scanner scanString:@" (" intoString:NULL] && [scanner scanInteger:NULL] && [scanner scanString:@")" intoString:NULL] && scanner.isAtEnd;
        }
        if ([otherStem caseInsensitiveCompare:stem] != NSOrderedSame && !numbered) continue;
        if ([POSimilarCopies isSamePictureAtURL:[directory URLByAppendingPathComponent:other] asItem:item]) return YES;
    }
    return NO;
}

/// Every regular file in `root` and the folders inside it, by size; empty when it does not exist.
static NSMutableDictionary<NSNumber *, NSMutableArray<NSURL *> *> *POFilesBySize(NSURL *root, NSFileManager *fm) {
    NSMutableDictionary<NSNumber *, NSMutableArray<NSURL *> *> *bySize = [NSMutableDictionary dictionary];
    NSDirectoryEnumerator<NSURL *> *enumerator = [fm enumeratorAtURL:root includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey]
                                                             options:NSDirectoryEnumerationSkipsPackageDescendants
                                                        errorHandler:^BOOL(NSURL *url, NSError *error) { return YES; }];
    for (NSURL *url in enumerator) {
        NSDictionary *values = [url resourceValuesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey] error:NULL];
        if (![values[NSURLIsRegularFileKey] boolValue]) continue;
        NSNumber *size = values[NSURLFileSizeKey];
        NSMutableArray *list = bySize[size];
        if (!list) bySize[size] = list = [NSMutableArray array];
        [list addObject:url];
    }
    return bySize;
}

+ (POOrganizeResult *)copyItems:(NSArray<POPhotoItem *> *)pending rootURL:(NSURL *)rootURL
                       progress:(void (^)(NSUInteger, NSUInteger))progress folder:(NSString * (^)(POPhotoItem *))folderForItem {
    return [self copyItems:pending rootURL:rootURL skipSameContent:NO progress:progress cancelled:nil folder:folderForItem];
}

+ (POOrganizeResult *)copyItems:(NSArray<POPhotoItem *> *)items rootURL:(NSURL *)rootURL skipSameContent:(BOOL)skipSameContent
                       progress:(void (^)(NSUInteger, NSUInteger))progress cancelled:(BOOL (^)(void))cancelled
                         folder:(NSString * (^)(POPhotoItem *))folderForItem {
    NSFileManager *fm = [NSFileManager new];
    NSMutableArray<POMoveRecord *> *records = [NSMutableArray array];
    NSMutableArray<NSURL *> *created = [NSMutableArray array];
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    NSUInteger alreadyCopied = 0, done = 0;
    BOOL stopped = NO;
    NSMutableDictionary<NSNumber *, NSMutableArray<NSURL *> *> *bySize = skipSameContent ? POFilesBySize(rootURL, fm) : nil;
    NSMutableDictionary<NSString *, id> *hashes = [NSMutableDictionary dictionary];   // path → hash, or NSNull when unreadable
    NSString *(^hashOf)(NSURL *) = ^NSString *(NSURL *url) {
        id hash = hashes[url.path];
        if (!hash) hashes[url.path] = hash = POContentHashOfFile(url) ?: (id)NSNull.null;
        return hash == NSNull.null ? nil : hash;
    };
    NSArray<POPhotoItem *> *pending = items;
    if (skipSameContent) {
        // Versions of one picture the library knows about (exact copies, and resized or re-saved ones): one of them is
        // copied, the best — the picture itself, then the most pixels, then the larger file.
        NSMapTable<POPhotoItem *, POPhotoItem *> *best = [NSMapTable strongToStrongObjectsMapTable];
        NSMutableArray<POPhotoItem *> *order = [NSMutableArray array];
        for (POPhotoItem *item in items) {
            POPhotoItem *picture = POPictureOf(item), *chosen = [best objectForKey:picture];
            if (!chosen) [order addObject:picture];
            BOOL better = !chosen || (item == picture && chosen != picture) ||
                          (chosen != picture && ((long long)item.pixelWidth * item.pixelHeight > (long long)chosen.pixelWidth * chosen.pixelHeight ||
                                                 ((long long)item.pixelWidth * item.pixelHeight == (long long)chosen.pixelWidth * chosen.pixelHeight &&
                                                  item.fileSize > chosen.fileSize)));
            if (better) [best setObject:item forKey:picture];
        }
        NSMutableArray<POPhotoItem *> *chosen = [NSMutableArray array];
        for (POPhotoItem *picture in order) [chosen addObject:[best objectForKey:picture]];
        alreadyCopied = items.count - chosen.count;
        pending = chosen;
    }
    for (POPhotoItem *item in pending) {
        if (cancelled && cancelled()) {
            stopped = YES;
            break;
        }
        @autoreleasepool {
            NSError *error = nil;
            NSString *folder = folderForItem(item);
            // No folder: straight into the destination (its year folders, say).
            NSURL *directory = folder.length ? [rootURL URLByAppendingPathComponent:folder isDirectory:YES] : rootURL;
            NSString *hash = nil;
            NSNumber *size = @(item.fileSize);
            if (!POIsUnchangedFile(item.url, item.fileSize, fm)) {
                error = POError(POL(@"файл изменился или исчез после сканирования — пропущен"));
            } else if (POIsSameDirectory(directory, item.url.URLByDeletingLastPathComponent)) {
                // Already in its folder: a copy next to it would only be a duplicate.
            } else if (skipSameContent && POSamePictureIn(directory, item, fm)) {
                alreadyCopied++;   // the same picture under its own name, saved differently (other metadata, size)
            } else if (!skipSameContent && POHasCopyIn(directory, item.url, item.fileSize, fm)) {
                alreadyCopied++;   // copied by an earlier run, or already on the drive the files are added to
            } else if (skipSameContent && bySize[size] && (hash = item.contentHash ?: hashOf(item.url)) &&
                       [bySize[size] indexOfObjectPassingTest:^BOOL(NSURL *url, NSUInteger index, BOOL *stop) { return [hashOf(url) isEqualToString:hash]; }] != NSNotFound) {
                alreadyCopied++;   // the very contents are already somewhere in the destination
            } else if (POEnsureDirectory(directory, created, fm, &error)) {
                NSURL *destination = POCopyExclusively(item.url, directory, item.url.lastPathComponent, fm, &error);
                if (destination && !POIsUnchangedFile(destination, item.fileSize, fm)) {
                    error = POError(POL(@"после копирования размер файла не совпал — проверьте копию вручную"));
                }
                if (destination) {
                    [records addObject:[[POMoveRecord alloc] initWithFrom:item.url to:destination fileSize:item.fileSize]];
                    POCarrySidecar(item, destination, YES, records, fm);
                    if (skipSameContent) {
                        // Copied now: the same contents once more in the selection are not copied again.
                        NSMutableArray *list = bySize[size];
                        if (!list) bySize[size] = list = [NSMutableArray array];
                        [list addObject:destination];
                        NSString *copied = hash ?: item.contentHash ?: hashOf(item.url);
                        if (copied) hashes[destination.path] = copied;
                    }
                }
            }
            if (error) [errors addObject:[NSString stringWithFormat:@"%@: %@", item.relativePath, error.localizedDescription]];
        }
        done++;
        if (progress && (done % 10 == 0 || done == pending.count)) progress(done, pending.count);
    }
    POOrganizeResult *result = [[POOrganizeResult alloc] initWithRecords:records createdDirectories:created errors:errors];
    result.copied = YES;
    result.alreadyCopied = alreadyCopied;
    result.stopped = stopped;
    return result;
}

+ (NSString *(^)(NSString *))existingYearFoldersIn:(NSURL *)rootURL {
    NSMutableDictionary<NSString *, NSString *> *known = [NSMutableDictionary dictionary];
    NSFileManager *fm = [NSFileManager new];
    // "2015", "2015 год", "2015г" — four digits not followed by a fifth.
    BOOL (^isYear)(NSString *, NSString *) = ^BOOL(NSString *name, NSString *year) {
        if (name.length < 4) return NO;
        NSString *head = [name substringToIndex:4];
        if (year ? ![head isEqualToString:year] : [head rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) return NO;
        for (NSUInteger i = 0; i < 4; i++) if (!isdigit([name characterAtIndex:i])) return NO;
        return name.length == 4 || !isdigit([name characterAtIndex:4]);
    };
    return ^NSString *(NSString *relative) {
        @synchronized (known) {
            NSString *found = known[relative];
            if (found) return found;
            NSMutableArray<NSString *> *parts = [[relative componentsSeparatedByString:@"/"] mutableCopy];
            NSURL *current = rootURL;
            for (NSUInteger i = 0; i < parts.count; i++) {
                NSString *part = parts[i];
                BOOL isDirectory = NO;
                if (part.length && isYear(part, nil) && [fm fileExistsAtPath:current.path isDirectory:&isDirectory] && isDirectory &&
                    ![fm fileExistsAtPath:[current URLByAppendingPathComponent:part].path]) {
                    NSString *year = [part substringToIndex:4];
                    NSMutableArray<NSString *> *existing = [NSMutableArray array];
                    for (NSString *name in [fm contentsOfDirectoryAtPath:current.path error:NULL]) {
                        BOOL folder = NO;
                        if (isYear(name, year) && [fm fileExistsAtPath:[current URLByAppendingPathComponent:name].path isDirectory:&folder] && folder) [existing addObject:name];
                    }
                    [existing sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
                    if (existing.count) parts[i] = existing.firstObject;
                }
                current = [current URLByAppendingPathComponent:parts[i] isDirectory:YES];
            }
            return known[relative] = [parts componentsJoinedByString:@"/"];
        }
    };
}

+ (POOrganizeResult *)moveItems:(NSArray<POPhotoItem *> *)items toFolder:(NSString *)folder rootURL:(NSURL *)rootURL
                       progress:(void (^)(NSUInteger, NSUInteger))progress {
    return [self moveItems:items rootURL:rootURL progress:progress folder:^NSString *(POPhotoItem *item) { return folder; }];
}

+ (POOrganizeResult *)moveItems:(NSArray<POPhotoItem *> *)pending rootURL:(NSURL *)rootURL
                       progress:(void (^)(NSUInteger, NSUInteger))progress folder:(NSString * (^)(POPhotoItem *))folderForItem {
    NSFileManager *fm = [NSFileManager new];
    NSMutableArray<POMoveRecord *> *records = [NSMutableArray array];
    NSMutableArray<NSURL *> *created = [NSMutableArray array];
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    NSMutableSet<NSURL *> *sourceDirectories = [NSMutableSet set];

    NSUInteger done = 0;
    for (POPhotoItem *item in pending) {
        @autoreleasepool {
            NSError *error = nil;
            NSURL *sourceDirectory = item.url.URLByDeletingLastPathComponent;
            NSURL *directory = [rootURL URLByAppendingPathComponent:folderForItem(item) isDirectory:YES];
            if (!POIsUnchangedFile(item.url, item.fileSize, fm)) {
                error = POError(POL(@"файл изменился или исчез после сканирования — пропущен"));
            } else if (POEnsureDirectory(directory, created, fm, &error) && !POIsSameDirectory(directory, sourceDirectory)) {
                NSURL *destination = POMoveExclusively(item.url, directory, item.url.lastPathComponent, fm, &error);
                if (destination && !POIsUnchangedFile(destination, item.fileSize, fm)) {
                    error = POError(POL(@"после перемещения размер файла не совпал — проверьте его вручную"));
                }
                if (destination) {
                    [records addObject:[[POMoveRecord alloc] initWithFrom:item.url to:destination fileSize:item.fileSize]];
                    [sourceDirectories addObject:sourceDirectory];
                    POCarrySidecar(item, destination, NO, records, fm);
                }
            }
            if (error) [errors addObject:[NSString stringWithFormat:@"%@: %@", item.relativePath, error.localizedDescription]];
        }
        done++;
        if (progress && (done % 10 == 0 || done == pending.count)) progress(done, pending.count);
    }

    // Tidy up folders that were emptied by the move, walking up but never touching the root itself.
    NSString *rootPrefix = [rootURL.path stringByAppendingString:@"/"];
    for (NSURL *directory in sourceDirectories) {
        NSURL *current = directory;
        while ([current.path hasPrefix:rootPrefix] && PORemoveIfEmpty(current, fm)) {
            current = current.URLByDeletingLastPathComponent;
        }
    }
    return [[POOrganizeResult alloc] initWithRecords:records createdDirectories:created errors:errors];
}

+ (NSArray<NSString *> *)revert:(POOrganizeResult *)result {
    return [self revert:result moves:NULL];
}

+ (NSArray<NSString *> *)revert:(POOrganizeResult *)result moves:(NSArray<POMoveRecord *> **)movesOut {
    NSFileManager *fm = [NSFileManager new];
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    NSMutableArray<POMoveRecord *> *moves = [NSMutableArray array];
    if (result.copied) {
        // The originals never moved; only the copies go, to the Trash, and only when nobody has changed them.
        for (POMoveRecord *record in result.records) {
            NSError *error = nil;
            if (!POIsUnchangedFile(record.to, record.fileSize, fm)) {
                error = POError(POL(@"копия изменилась или исчезла — оставлена как есть"));
            } else {
                [fm trashItemAtURL:record.to resultingItemURL:NULL error:&error];
            }
            if (error) [errors addObject:[NSString stringWithFormat:@"%@: %@", record.to.lastPathComponent, error.localizedDescription]];
        }
        for (NSURL *directory in result.createdDirectories.reverseObjectEnumerator) PORemoveIfEmpty(directory, fm);
        if (movesOut) *movesOut = @[];
        return errors;
    }
    for (POMoveRecord *record in result.records.reverseObjectEnumerator) {
        @autoreleasepool {
            NSError *error = nil;
            NSURL *directory = record.from.URLByDeletingLastPathComponent;
            if (!POIsUnchangedFile(record.to, record.fileSize, fm)) {
                error = POError(POL(@"файл изменился или исчез после раскладки — оставлен как есть"));
            } else if ([fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
                NSURL *back = POMoveExclusively(record.to, directory, record.from.lastPathComponent, fm, &error);
                if (back) [moves addObject:[[POMoveRecord alloc] initWithFrom:record.to to:back fileSize:record.fileSize]];
            }
            if (error) [errors addObject:[NSString stringWithFormat:@"%@: %@", record.to.lastPathComponent, error.localizedDescription]];
        }
    }
    for (NSURL *directory in result.createdDirectories.reverseObjectEnumerator) {
        PORemoveIfEmpty(directory, fm);
    }
    // Folders the files were taken out of (a redo has no list of created ones): up to three levels, as deep as the date
    // folders go, never past a folder that still holds something, and never one the files went back into.
    NSMutableSet<NSString *> *starts = [NSMutableSet set], *kept = [NSMutableSet set];
    for (POMoveRecord *move in moves) {
        [starts addObject:move.from.URLByDeletingLastPathComponent.path];
        for (NSURL *up = move.to.URLByDeletingLastPathComponent; up.path.length > 1; up = up.URLByDeletingLastPathComponent) [kept addObject:up.path];
    }
    for (NSString *start in starts) {
        NSURL *directory = [NSURL fileURLWithPath:start isDirectory:YES];
        for (int level = 0; level < 3 && ![kept containsObject:directory.path] && PORemoveIfEmpty(directory, fm); level++) {
            directory = directory.URLByDeletingLastPathComponent;
        }
    }
    if (movesOut) *movesOut = moves;
    return errors;
}

+ (NSURL *)writeJournalForResult:(POOrganizeResult *)result rootURL:(NSURL *)rootURL {
    if (!result.records.count) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *support = [fm URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:NULL];
    NSURL *directory = [support URLByAppendingPathComponent:@"Photo Organizer/Журнал" isDirectory:YES];
    if (![fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL]) return nil;

    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd HH-mm-ss";
    // The same header as on Windows: the folder, a line for copies, the columns.
    NSMutableString *text = [NSMutableString stringWithFormat:@"# %@\n", rootURL.path];
    if (result.copied) [text appendString:@"# копии: оригиналы остались на месте\n"];
    [text appendString:@"# куда\t← откуда\n"];
    for (POMoveRecord *record in result.records) {
        [text appendFormat:@"%@\t← %@\n", record.to.path, record.from.path];
    }
    NSURL *file = [directory URLByAppendingPathComponent:[[formatter stringFromDate:NSDate.date] stringByAppendingPathExtension:@"txt"]];
    return [text writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:NULL] ? file : nil;
}

@end
