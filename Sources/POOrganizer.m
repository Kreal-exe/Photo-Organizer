#import "POOrganizer.h"
#import "POStrings.h"
#import <unistd.h>
#import <stdio.h>
#import <errno.h>

@interface POMoveRecord ()
- (instancetype)initWithFrom:(NSURL *)from to:(NSURL *)to fileSize:(unsigned long long)fileSize;
@end

@implementation POMoveRecord

- (instancetype)initWithFrom:(NSURL *)from to:(NSURL *)to fileSize:(unsigned long long)fileSize {
    if ((self = [super init])) {
        _from = from;
        _to = to;
        _fileSize = fileSize;
    }
    return self;
}

@end

@interface POOrganizeResult ()
- (instancetype)initWithRecords:(NSArray<POMoveRecord *> *)records
             createdDirectories:(NSArray<NSURL *> *)createdDirectories
                         errors:(NSArray<NSString *> *)errors;
@end

@implementation POOrganizeResult

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
    for (NSURL *current = directory; current.path.length > 1 && ![fm fileExistsAtPath:current.path];
         current = current.URLByDeletingLastPathComponent) {
        [missing insertObject:current atIndex:0];
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

static BOOL POIsSameDirectory(NSURL *a, NSURL *b) {
    id identifierA = nil, identifierB = nil;
    // Fresh URLs: resource values are cached per NSURL instance.
    [[NSURL fileURLWithPath:a.path] getResourceValue:&identifierA forKey:NSURLFileResourceIdentifierKey error:NULL];
    [[NSURL fileURLWithPath:b.path] getResourceValue:&identifierB forKey:NSURLFileResourceIdentifierKey error:NULL];
    return identifierA && [identifierA isEqual:identifierB];
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

@implementation POOrganizer

+ (POOrganizeResult *)applyPlan:(POPlan *)plan progress:(void (^)(NSUInteger, NSUInteger))progress {
    return [self moveItems:plan.pendingItems rootURL:plan.rootURL progress:progress folder:^NSString *(POPhotoItem *item) {
        return item.destinationFolder;
    }];
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
    NSMutableString *text = [NSMutableString stringWithFormat:@"# %@\n# куда\t← откуда\n", rootURL.path];
    for (POMoveRecord *record in result.records) {
        [text appendFormat:@"%@\t← %@\n", record.to.path, record.from.path];
    }
    NSURL *file = [directory URLByAppendingPathComponent:[[formatter stringFromDate:NSDate.date] stringByAppendingPathExtension:@"txt"]];
    return [text writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:NULL] ? file : nil;
}

@end
