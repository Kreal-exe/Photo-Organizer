#import "POHuggingFace.h"
#import "POStrings.h"

static NSString *const POHubHost = @"https://huggingface.co";

@implementation POHuggingFace

+ (NSURL *)cacheURL {
    NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
    NSString *path = environment[@"HF_HUB_CACHE"] ?: environment[@"HUGGINGFACE_HUB_CACHE"];
    if (!path.length && environment[@"HF_HOME"].length) path = [environment[@"HF_HOME"] stringByAppendingPathComponent:@"hub"];
    if (!path.length) path = [NSHomeDirectory() stringByAppendingPathComponent:@".cache/huggingface/hub"];
    return [NSURL fileURLWithPath:path.stringByExpandingTildeInPath isDirectory:YES];
}

+ (NSURL *)repoURLForRepo:(NSString *)repo {
    NSString *name = [@"models--" stringByAppendingString:[repo stringByReplacingOccurrencesOfString:@"/" withString:@"--"]];
    return [self.cacheURL URLByAppendingPathComponent:name isDirectory:YES];
}

+ (NSURL *)snapshotURLForRepo:(NSString *)repo files:(NSArray<NSString *> *)files {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *snapshots = [[self repoURLForRepo:repo] URLByAppendingPathComponent:@"snapshots" isDirectory:YES];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *main = [NSString stringWithContentsOfURL:[[self repoURLForRepo:repo] URLByAppendingPathComponent:@"refs/main"]
                                              encoding:NSUTF8StringEncoding error:NULL];
    main = [main stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (main.length) [candidates addObject:main];
    [candidates addObjectsFromArray:[fm contentsOfDirectoryAtPath:snapshots.path error:NULL] ?: @[]];

    for (NSString *revision in candidates) {
        NSURL *snapshot = [snapshots URLByAppendingPathComponent:revision isDirectory:YES];
        BOOL complete = YES;
        for (NSString *file in files) {
            // fileExistsAtPath: follows the symlink into blobs/, so a dangling link counts as missing.
            if (![fm fileExistsAtPath:[snapshot URLByAppendingPathComponent:file].path]) { complete = NO; break; }
        }
        if (complete) return snapshot;
    }
    return nil;
}

@end

@interface POHuggingFaceDownload () <NSURLSessionDownloadDelegate>
@end

@implementation POHuggingFaceDownload {
    NSString *_repo;
    NSArray<NSString *> *_files;
    NSURLSession *_session;
    void (^_progress)(int64_t, int64_t);
    void (^_completion)(NSURL *, NSError *);

    // Touched on the session's serial delegate queue only.
    NSString *_revision;
    NSDictionary<NSString *, NSNumber *> *_sizes;
    NSUInteger _index;
    int64_t _finishedBytes, _totalBytes;
    NSString *_etag;         // of the file being downloaded
    NSError *_fileError;
    BOOL _finished;
}

- (instancetype)initWithRepo:(NSString *)repo files:(NSArray<NSString *> *)files {
    if ((self = [super init])) {
        _repo = [repo copy];
        _files = [files copy];
    }
    return self;
}

static NSError *POHubError(NSString *message) {
    return [NSError errorWithDomain:@"POHuggingFace" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (void)startWithProgress:(void (^)(int64_t, int64_t))progress completion:(void (^)(NSURL *, NSError *))completion {
    _progress = [progress copy];
    _completion = [completion copy];
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;
    _session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration delegate:self delegateQueue:queue];

    // The commit hash names the snapshot folder; the file sizes give the progress bar its total.
    NSString *api = [NSString stringWithFormat:@"%@/api/models/%@/revision/main?blobs=true", POHubHost, _repo];
    [[_session dataTaskWithURL:[NSURL URLWithString:api] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *info = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSString *revision = [info isKindOfClass:NSDictionary.class] ? info[@"sha"] : nil;
        if (![revision isKindOfClass:NSString.class] || revision.length < 7) {
            [self finishWithError:error ?: POHubError(POL(@"Hugging Face не вернул сведения о модели"))];
            return;
        }
        NSMutableDictionary<NSString *, NSNumber *> *sizes = [NSMutableDictionary dictionary];
        for (NSDictionary *sibling in info[@"siblings"]) {
            if ([sibling[@"size"] isKindOfClass:NSNumber.class]) sizes[sibling[@"rfilename"]] = sibling[@"size"];
        }
        self->_revision = revision;
        self->_sizes = sizes;
        for (NSString *file in self->_files) self->_totalBytes += sizes[file].longLongValue;
        [self downloadNextFile];
    }] resume];
}

- (void)cancel {
    [_session invalidateAndCancel];
}

- (void)finishWithError:(NSError *)error {
    if (_finished) return;
    _finished = YES;
    [_session finishTasksAndInvalidate];
    NSURL *snapshot = error ? nil : [POHuggingFace snapshotURLForRepo:_repo files:_files];
    if (!error && !snapshot) error = POHubError(POL(@"Файлы модели не найдены в кэше после загрузки"));
    void (^completion)(NSURL *, NSError *) = _completion;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(snapshot, error); });
}

- (void)downloadNextFile {
    if (_index >= _files.count) {
        // refs/main is what `huggingface_hub` resolves the default revision through.
        NSURL *refs = [[POHuggingFace repoURLForRepo:_repo] URLByAppendingPathComponent:@"refs" isDirectory:YES];
        NSError *error = nil;
        [NSFileManager.defaultManager createDirectoryAtURL:refs withIntermediateDirectories:YES attributes:nil error:&error];
        [_revision writeToURL:[refs URLByAppendingPathComponent:@"main"] atomically:YES encoding:NSUTF8StringEncoding error:&error];
        [self finishWithError:error];
        return;
    }
    _etag = nil;
    _fileError = nil;
    NSString *file = [_files[_index] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    NSString *url = [NSString stringWithFormat:@"%@/%@/resolve/%@/%@", POHubHost, _repo, _revision, file];
    [[_session downloadTaskWithURL:[NSURL URLWithString:url]] resume];
}

static NSString *POCleanETag(NSString *etag) {
    if ([etag hasPrefix:@"W/"]) etag = [etag substringFromIndex:2];
    etag = [etag stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\" "]];
    NSCharacterSet *unsafe = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"].invertedSet;
    return etag.length && [etag rangeOfCharacterFromSet:unsafe].location == NSNotFound ? etag : nil;
}

#pragma mark - NSURLSession delegate

/// Large files are redirected to a CDN; the hash that names the blob is only present on the redirect itself.
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    NSString *etag = POCleanETag([response valueForHTTPHeaderField:@"X-Linked-Etag"] ?: @"");
    if (!etag && !_etag) etag = POCleanETag([response valueForHTTPHeaderField:@"ETag"] ?: @"");
    if (etag) _etag = etag;
    completionHandler(request);
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)written
 totalBytesWritten:(int64_t)totalWritten totalBytesExpectedToWrite:(int64_t)expected {
    if (!_progress) return;
    int64_t received = _finishedBytes + totalWritten, total = MAX(_totalBytes, received);
    void (^progress)(int64_t, int64_t) = _progress;
    dispatch_async(dispatch_get_main_queue(), ^{ progress(received, total); });
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)task.response;
    NSString *file = _files[_index];
    if (![response isKindOfClass:NSHTTPURLResponse.class] || response.statusCode != 200) {
        _fileError = POHubError([NSString stringWithFormat:POL(@"%@: сервер ответил %ld"), file, (long)response.statusCode]);
        return;
    }
    NSString *etag = _etag ?: POCleanETag([response valueForHTTPHeaderField:@"ETag"] ?: @"");
    if (!etag) etag = [NSString stringWithFormat:@"%@-%lu", _revision, (unsigned long)_index];

    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *repo = [POHuggingFace repoURLForRepo:_repo];
    NSURL *blob = [[repo URLByAppendingPathComponent:@"blobs" isDirectory:YES] URLByAppendingPathComponent:etag];
    NSURL *link = [[[repo URLByAppendingPathComponent:@"snapshots" isDirectory:YES]
                    URLByAppendingPathComponent:_revision isDirectory:YES] URLByAppendingPathComponent:file];
    NSError *error = nil;
    if ([fm createDirectoryAtURL:blob.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error] &&
        [fm createDirectoryAtURL:link.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error]) {
        [fm removeItemAtURL:blob error:NULL];
        if ([fm moveItemAtURL:location toURL:blob error:&error]) {
            // Relative, like the Python library writes them, so the cache can be moved as a whole.
            NSMutableString *target = [NSMutableString stringWithString:@"../../"];
            for (NSUInteger depth = 1; depth < file.pathComponents.count; depth++) [target appendString:@"../"];
            [target appendFormat:@"blobs/%@", etag];
            [fm removeItemAtURL:link error:NULL];
            [fm createSymbolicLinkAtPath:link.path withDestinationPath:target error:&error];
        }
    }
    _fileError = error;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (![task isKindOfClass:NSURLSessionDownloadTask.class]) return;
    error = error ?: _fileError;
    if (error) {
        [self finishWithError:error];
        return;
    }
    _finishedBytes += task.countOfBytesReceived;
    _index++;
    [self downloadNextFile];
}

@end
