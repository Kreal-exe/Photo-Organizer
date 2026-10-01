#import "POMLXRuntime.h"
#import "POStrings.h"
#import <sys/sysctl.h>

static NSString *const POReadyMarker = @".photo-organizer-ready";

@implementation POMLXRuntime

+ (NSString *)processorName {
    char buffer[256] = {0};
    size_t size = sizeof buffer;
    if (sysctlbyname("machdep.cpu.brand_string", buffer, &size, NULL, 0) != 0 || !buffer[0]) return POL(@"неизвестный процессор");
    return @(buffer);
}

+ (BOOL)isSupported {
    // Reports the hardware, not the running slice: also true for the Intel build under Rosetta.
    int arm64 = 0;
    size_t size = sizeof arm64;
    return sysctlbyname("hw.optional.arm64", &arm64, &size, NULL, 0) == 0 && arm64 == 1;
}

+ (NSURL *)environmentURL {
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                                                 appropriateForURL:nil create:YES error:NULL];
    return [support URLByAppendingPathComponent:@"Photo Organizer/mlx-env" isDirectory:YES];
}

+ (NSURL *)pythonURL {
    return [self.environmentURL URLByAppendingPathComponent:@"bin/python3"];
}

+ (BOOL)isInstalled {
    NSFileManager *fm = NSFileManager.defaultManager;
    return [fm isExecutableFileAtPath:self.pythonURL.path] &&
           [fm fileExistsAtPath:[self.environmentURL URLByAppendingPathComponent:POReadyMarker].path];
}

#pragma mark - Installing

static NSError *PORuntimeError(NSString *message) {
    return [NSError errorWithDomain:@"POMLXRuntime" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// Runs a tool to completion, forwarding its output line by line. Returns its exit status (-1 if it didn't start).
static int PORun(NSString *tool, NSArray<NSString *> *arguments, void (^log)(NSString *)) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:tool];
    task.arguments = arguments;
    NSMutableDictionary<NSString *, NSString *> *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    // Apps launched from Finder get a bare PATH; uv and pip need to find git, compilers and each other.
    environment[@"PATH"] = [@"/opt/homebrew/bin:/usr/local/bin:" stringByAppendingString:environment[@"PATH"] ?: @"/usr/bin:/bin"];
    environment[@"PYTHONHOME"] = nil;
    environment[@"VIRTUAL_ENV"] = nil;
    task.environment = environment;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:NULL]) return -1;

    // Output arrives in arbitrary chunks; only complete lines are forwarded.
    NSMutableData *pending = [NSMutableData data];
    NSData *chunk;
    do {
        chunk = pipe.fileHandleForReading.availableData;
        [pending appendData:chunk];
        const char *bytes = pending.bytes;
        NSUInteger start = 0;
        for (NSUInteger i = 0; i < pending.length; i++) {
            if (bytes[i] != '\n' && bytes[i] != '\r' && !(chunk.length == 0 && i == pending.length - 1)) continue;
            NSUInteger end = (bytes[i] == '\n' || bytes[i] == '\r') ? i : i + 1;
            NSString *line = [[NSString alloc] initWithBytes:bytes + start length:end - start encoding:NSUTF8StringEncoding];
            line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (line.length && log) log(line);
            start = i + 1;
        }
        [pending replaceBytesInRange:NSMakeRange(0, MIN(start, pending.length)) withBytes:NULL length:0];
    } while (chunk.length);
    [task waitUntilExit];
    return task.terminationStatus;
}

static NSString *POFirstExecutable(NSArray<NSString *> *paths) {
    for (NSString *path in paths) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

/// A Python that MLX supports (3.10 or newer), if one is installed in the usual places.
static NSString *POFindPython(void) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (NSString *directory in @[@"/opt/homebrew/bin", @"/usr/local/bin", @"/Library/Frameworks/Python.framework/Versions/Current/bin", @"/usr/bin"]) {
        for (NSString *name in @[@"python3.13", @"python3.12", @"python3.11", @"python3.10", @"python3"]) {
            [candidates addObject:[directory stringByAppendingPathComponent:name]];
        }
    }
    for (NSString *path in candidates) {
        if (![NSFileManager.defaultManager isExecutableFileAtPath:path]) continue;
        if (PORun(path, @[@"-c", @"import sys; sys.exit(0 if (3, 10) <= sys.version_info[:2] <= (3, 13) else 1)"], nil) == 0) return path;
    }
    return nil;
}

+ (void)installWithLog:(void (^)(NSString *))log completion:(void (^)(NSError *))completion {
    void (^mainLog)(NSString *) = ^(NSString *line) {
        if (log) dispatch_async(dispatch_get_main_queue(), ^{ log(line); });
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = [self installSynchronouslyWithLog:mainLog];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

+ (NSError *)installSynchronouslyWithLog:(void (^)(NSString *))log {
    if (!self.isSupported) return PORuntimeError(POL(@"MLX работает только на Mac с Apple Silicon"));
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *environment = self.environmentURL.path, *python = self.pythonURL.path;
    [fm createDirectoryAtURL:self.environmentURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    // A half-built environment from an interrupted attempt would confuse both venv and uv.
    [fm removeItemAtURL:self.environmentURL error:NULL];

    NSString *basePython = POFindPython();
    NSString *uv = POFirstExecutable(@[@"/opt/homebrew/bin/uv", @"/usr/local/bin/uv",
                                       [NSHomeDirectory() stringByAppendingPathComponent:@".local/bin/uv"],
                                       [NSHomeDirectory() stringByAppendingPathComponent:@".cargo/bin/uv"]]);
    int status;
    if (basePython) {
        log([NSString stringWithFormat:POL(@"Создаём окружение на %@…"), basePython.lastPathComponent]);
        status = PORun(basePython, @[@"-m", @"venv", environment], log);
        if (status == 0) status = PORun(python, @[@"-m", @"pip", @"install", @"--disable-pip-version-check", @"mlx", @"numpy"], log);
    } else if (uv) {
        log(POL(@"Подходящего Python нет — uv загрузит Python 3.12…"));
        status = PORun(uv, @[@"venv", @"--python", @"3.12", environment], log);
        if (status == 0) status = PORun(uv, @[@"pip", @"install", @"--python", python, @"mlx", @"numpy"], log);
    } else {
        return PORuntimeError(POL(@"Для MLX нужен Python 3.10 или новее. Установите его (например, «brew install python» или с python.org) "
                              @"и нажмите кнопку ещё раз — либо выберите модель Core ML, ей Python не нужен."));
    }
    if (status != 0) return PORuntimeError(POL(@"Не удалось установить MLX. Проверьте подключение к интернету и попробуйте ещё раз."));

    log(POL(@"Проверяем MLX…"));
    if (PORun(python, @[@"-c", @"import mlx.core, numpy"], log) != 0) return PORuntimeError(POL(@"MLX установился, но не запускается на этом Mac."));
    [@"ok" writeToURL:[self.environmentURL URLByAppendingPathComponent:POReadyMarker] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return nil;
}

@end
