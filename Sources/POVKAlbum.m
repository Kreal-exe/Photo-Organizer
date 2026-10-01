#import "POVKAlbum.h"
#import "POStrings.h"
#import <stdatomic.h>
#import <stdio.h>

static NSString *const POVKAPIVersion = @"5.199";
static const NSUInteger POVKPageSize = 1000;   // the API's maximum per request

/// The token lives in a file only the user can read. Not in the Keychain: an ad-hoc signed build
/// changes its identity on every build, and the Keychain then asks for the login password.
static NSURL *POVKTokenURL(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [[support URLByAppendingPathComponent:@"Photo Organizer" isDirectory:YES] URLByAppendingPathComponent:@"vk-token"];
}

NSString *POVKSavedToken(void) {
    NSString *token = [NSString stringWithContentsOfURL:POVKTokenURL() encoding:NSUTF8StringEncoding error:NULL];
    token = [token stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return token.length ? token : nil;
}

void POVKSaveToken(NSString *token) {
    NSURL *url = POVKTokenURL();
    NSFileManager *manager = NSFileManager.defaultManager;
    [manager removeItemAtURL:url error:NULL];
    if (!token.length) return;
    [manager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    [manager createFileAtPath:url.path contents:[token dataUsingEncoding:NSUTF8StringEncoding]
                   attributes:@{NSFilePosixPermissions: @0600}];
}

static BOOL POWriteWithoutOverwriting(NSData *data, NSURL *file) {
    NSURL *partial = [file.URLByDeletingLastPathComponent URLByAppendingPathComponent:
                      [NSString stringWithFormat:@".%@.part", file.lastPathComponent]];
    if (![data writeToURL:partial options:0 error:NULL]) return NO;
    if (renamex_np(partial.fileSystemRepresentation, file.fileSystemRepresentation, RENAME_EXCL) == 0) return YES;
    unlink(partial.fileSystemRepresentation);
    return NO;
}

@implementation POVKAlbum {
    NSString *_link, *_token;
    NSURL *_folder;
    BOOL _newestFirst;
    NSURLSession *_session;
    atomic_bool _cancelled;
}

+ (BOOL)parseAlbumURL:(NSString *)link owner:(NSString **)owner album:(NSString **)album {
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:@"album(-?\\d+)_(\\d+)" options:0 error:NULL];
    NSTextCheckingResult *match = [expression firstMatchInString:link options:0 range:NSMakeRange(0, link.length)];
    if (!match) return NO;
    *owner = [link substringWithRange:[match rangeAtIndex:1]];
    NSString *number = [link substringWithRange:[match rangeAtIndex:2]];
    NSDictionary<NSString *, NSString *> *service = @{@"0": @"profile", @"00": @"wall", @"000": @"saved"};
    *album = service[number] ?: number;
    return YES;
}

+ (NSURL *)originalURLOfPhoto:(NSDictionary *)photo {
    NSDictionary *original = photo[@"orig_photo"];
    if ([original isKindOfClass:NSDictionary.class] && [original[@"url"] isKindOfClass:NSString.class]) {
        return [NSURL URLWithString:original[@"url"]];
    }
    // Otherwise the largest of the listed sizes. Old photos come without dimensions; for those the size type
    // tells the order (w is the largest, s the smallest).
    NSString *typeOrder = @"smxopqryzw";
    NSDictionary *best = nil;
    long long bestArea = -1;
    NSInteger bestRank = -1;
    for (NSDictionary *size in photo[@"sizes"]) {
        if (![size isKindOfClass:NSDictionary.class] || ![size[@"url"] isKindOfClass:NSString.class]) continue;
        long long area = [size[@"width"] longLongValue] * [size[@"height"] longLongValue];
        NSString *type = [size[@"type"] isKindOfClass:NSString.class] ? size[@"type"] : @"";
        NSInteger rank = type.length ? (NSInteger)[typeOrder rangeOfString:type].location : -1;
        if (rank == NSNotFound) rank = -1;
        if (area > bestArea || (area == bestArea && rank > bestRank)) {
            best = size;
            bestArea = area;
            bestRank = rank;
        }
    }
    return best ? [NSURL URLWithString:best[@"url"]] : nil;
}

+ (NSString *)fileNameForIndex:(NSUInteger)index ofCount:(NSUInteger)count url:(NSURL *)url {
    int digits = (int)[NSString stringWithFormat:@"%lu", (unsigned long)count].length;
    if (digits < 3) digits = 3;
    NSString *extension = url.path.pathExtension.lowercaseString;
    if (!extension.length || extension.length > 5) extension = @"jpg";
    return [NSString stringWithFormat:@"%0*lu.%@", digits, (unsigned long)index, extension];
}

- (instancetype)initWithLink:(NSString *)link token:(NSString *)token folder:(NSURL *)folder newestFirst:(BOOL)newestFirst {
    if ((self = [super init])) {
        _link = [link copy];
        _token = [[token stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] copy];
        _folder = folder;
        _newestFirst = newestFirst;
        _session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    }
    return self;
}

- (void)cancel {
    atomic_store(&_cancelled, true);
    [_session invalidateAndCancel];
}

/// Blocking GET; returns nil with `error` set on failure.
- (NSData *)dataFromURL:(NSURL *)url error:(NSError **)error {
    __block NSData *result = nil;
    __block NSError *failure = nil;
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    [[_session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (data && status == 200) {
            result = data;
        } else {
            failure = taskError ?: [NSError errorWithDomain:@"POVKAlbum" code:status userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)status]}];
        }
        dispatch_semaphore_signal(finished);
    }] resume];
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
    if (error) *error = failure;
    return result;
}

/// One page of photos.get. Returns nil and a message for the user when VK refuses.
- (NSDictionary *)pageAtOffset:(NSUInteger)offset owner:(NSString *)owner album:(NSString *)album message:(NSString **)message {
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://api.vk.ru/method/photos.get"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"owner_id" value:owner],
        [NSURLQueryItem queryItemWithName:@"album_id" value:album],
        [NSURLQueryItem queryItemWithName:@"rev" value:_newestFirst ? @"1" : @"0"],
        [NSURLQueryItem queryItemWithName:@"photo_sizes" value:@"1"],
        [NSURLQueryItem queryItemWithName:@"count" value:@(POVKPageSize).stringValue],
        [NSURLQueryItem queryItemWithName:@"offset" value:@(offset).stringValue],
        [NSURLQueryItem queryItemWithName:@"access_token" value:_token],
        [NSURLQueryItem queryItemWithName:@"v" value:POVKAPIVersion],
    ];
    NSError *error = nil;
    NSData *data = [self dataFromURL:components.URL error:&error];
    NSDictionary *reply = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![reply isKindOfClass:NSDictionary.class]) {
        *message = [NSString stringWithFormat:POL(@"VK не ответил: %@"), error.localizedDescription ?: @"?"];
        return nil;
    }
    NSDictionary *failure = reply[@"error"];
    if ([failure isKindOfClass:NSDictionary.class]) {
        NSInteger code = [failure[@"error_code"] integerValue];
        NSString *text = failure[@"error_msg"] ?: @"";
        if (code == 5 || code == 15 || code == 1116) {
            *message = [NSString stringWithFormat:POL(@"VK не пустил к альбому (ошибка %ld: %@). Скорее всего, вход устарел — нажмите «Выйти», затем «Войти в VK…» и попробуйте снова."), (long)code, text];
        } else if (code == 14) {
            *message = POL(@"VK требует ввести капчу. Откройте vk.ru в браузере, пройдите проверку и попробуйте позже.");
        } else {
            *message = [NSString stringWithFormat:POL(@"VK вернул ошибку %ld: %@"), (long)code, text];
        }
        return nil;
    }
    return [reply[@"response"] isKindOfClass:NSDictionary.class] ? reply[@"response"] : @{};
}

- (void)startWithProgress:(void (^)(NSUInteger, NSUInteger))progress completion:(void (^)(BOOL, NSString *))completion {
    void (^finish)(BOOL, NSString *) = ^(BOOL success, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(success, message); });
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *owner = nil, *album = nil;
        if (![POVKAlbum parseAlbumURL:self->_link owner:&owner album:&album]) {
            finish(NO, POL(@"Это не ссылка на альбом. Нужна ссылка вида https://vk.ru/album123_456."));
            return;
        }
        if (!self->_token.length) {
            finish(NO, POL(@"Сначала войдите в VK."));
            return;
        }
        NSFileManager *fm = [NSFileManager new];
        NSError *folderError = nil;
        if (![fm createDirectoryAtURL:self->_folder withIntermediateDirectories:YES attributes:nil error:&folderError]) {
            finish(NO, folderError.localizedDescription);
            return;
        }

        // The whole list first: the numbering has to be known before the first file is named.
        NSMutableArray<NSDictionary *> *photos = [NSMutableArray array];
        NSUInteger total = NSUIntegerMax;
        while (photos.count < total && !atomic_load(&self->_cancelled)) {
            NSString *message = nil;
            NSDictionary *page = [self pageAtOffset:photos.count owner:owner album:album message:&message];
            if (!page) {
                finish(NO, atomic_load(&self->_cancelled) ? POL(@"Загрузка отменена.") : message);
                return;
            }
            NSArray *items = [page[@"items"] isKindOfClass:NSArray.class] ? page[@"items"] : @[];
            total = [page[@"count"] unsignedIntegerValue];
            if (!items.count) break;
            [photos addObjectsFromArray:items];
            [NSThread sleepForTimeInterval:0.35];   // the API allows three requests a second
        }
        if (!photos.count) {
            finish(!atomic_load(&self->_cancelled), atomic_load(&self->_cancelled) ? POL(@"Загрузка отменена.") : POL(@"В альбоме нет фотографий."));
            return;
        }

        NSUInteger count = photos.count;
        __block atomic_uint_fast64_t done = 0, saved = 0, skipped = 0, failed = 0;
        dispatch_queue_t queue = dispatch_queue_create("photo-organizer.vk", DISPATCH_QUEUE_CONCURRENT);
        dispatch_semaphore_t slots = dispatch_semaphore_create(4);
        dispatch_group_t group = dispatch_group_create();
        for (NSUInteger index = 0; index < count && !atomic_load(&self->_cancelled); index++) {
            dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
            dispatch_group_async(group, queue, ^{
                @autoreleasepool {
                    NSURL *url = [POVKAlbum originalURLOfPhoto:photos[index]];
                    NSURL *file = url ? [self->_folder URLByAppendingPathComponent:[POVKAlbum fileNameForIndex:index + 1 ofCount:count url:url]] : nil;
                    if (!file) {
                        atomic_fetch_add(&failed, 1);
                    } else if ([fm fileExistsAtPath:file.path]) {
                        atomic_fetch_add(&skipped, 1);   // already there from an earlier run
                    } else if (!atomic_load(&self->_cancelled)) {
                        NSData *data = [self dataFromURL:url error:NULL];
                        // Written under a temporary name first, so a half-written file is never mistaken for a finished one,
                        // then renamed without replacing anything already there.
                        if (data.length && POWriteWithoutOverwriting(data, file)) {
                            atomic_fetch_add(&saved, 1);
                        } else {
                            atomic_fetch_add(&failed, 1);
                        }
                    }
                }
                NSUInteger finished = (NSUInteger)atomic_fetch_add(&done, 1) + 1;
                dispatch_async(dispatch_get_main_queue(), ^{ progress(finished, count); });
                dispatch_semaphore_signal(slots);
            });
        }
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        [parts addObject:[NSString stringWithFormat:POL(@"Скачано: %@"), PONumber((NSInteger)saved)]];
        if (skipped) [parts addObject:[NSString stringWithFormat:POL(@"уже были: %@"), PONumber((NSInteger)skipped)]];
        if (failed) [parts addObject:[NSString stringWithFormat:POL(@"не удалось: %@"), PONumber((NSInteger)failed)]];
        if (atomic_load(&self->_cancelled)) [parts addObject:POL(@"остановлено — нажмите «Скачать» ещё раз, чтобы продолжить")];
        finish(!failed && !atomic_load(&self->_cancelled), [[parts componentsJoinedByString:@", "] stringByAppendingString:@"."]);
    });
}

@end
