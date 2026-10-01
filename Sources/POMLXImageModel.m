#import "POMLXImageModel.h"
#import "POStrings.h"
#import "POMLXRuntime.h"
#import <CoreGraphics/CoreGraphics.h>
#import <stdio.h>
#import <unistd.h>

NSData *PORGBDataWithTransform(CGImageRef image, NSInteger size, CGAffineTransform transform) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, size, size, 8, size * 4, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(space);
    if (!context) return nil;
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextConcatCTM(context, transform);
    CGContextDrawImage(context, CGRectMake(0, 0, CGImageGetWidth(image), CGImageGetHeight(image)), image);

    const uint8_t *pixels = CGBitmapContextGetData(context);
    NSMutableData *data = [NSMutableData dataWithLength:size * size * 3];
    uint8_t *out = data.mutableBytes;
    for (NSInteger i = 0, count = size * size; i < count; i++) {
        out[i * 3] = pixels[i * 4];
        out[i * 3 + 1] = pixels[i * 4 + 1];
        out[i * 3 + 2] = pixels[i * 4 + 2];
    }
    CGContextRelease(context);
    return data;
}

@implementation POMLXImageModel {
    NSTask *_task;
    int _writeDescriptor;
    FILE *_replies;
    NSLock *_lock;
}

static NSError *POHelperError(NSString *message) {
    return [NSError errorWithDomain:@"POMLXImageModel" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (NSString *)readLine {
    char *line = NULL;
    size_t capacity = 0;
    ssize_t length = _replies ? getline(&line, &capacity, _replies) : -1;
    NSString *result = length > 0 ? [[NSString alloc] initWithBytes:line length:length encoding:NSUTF8StringEncoding] : nil;
    free(line);
    return [result stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (instancetype)initWithSnapshotURL:(NSURL *)snapshot embedding:(BOOL)embedding error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _lock = [NSLock new];
    NSURL *script = [NSBundle.mainBundle URLForResource:@"vit_mlx" withExtension:@"py"];
    if (!script || !POMLXRuntime.isInstalled) {
        if (error) *error = POHelperError(POL(@"Среда MLX не установлена — откройте «Настройки» и нажмите «Загрузить»."));
        return nil;
    }

    NSPipe *input = [NSPipe pipe], *output = [NSPipe pipe];
    _task = [NSTask new];
    _task.executableURL = POMLXRuntime.pythonURL;
    _task.arguments = embedding ? @[script.path, snapshot.path, @"embed"] : @[script.path, snapshot.path];
    _task.standardInput = input;
    _task.standardOutput = output;
    _task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![_task launchAndReturnError:error]) return nil;
    _writeDescriptor = dup(input.fileHandleForWriting.fileDescriptor);
    _replies = fdopen(dup(output.fileHandleForReading.fileDescriptor), "r");
    // Only the helper may hold the other ends, or neither side would ever see end-of-file.
    [input.fileHandleForReading closeFile];
    [input.fileHandleForWriting closeFile];
    [output.fileHandleForWriting closeFile];

    NSString *line = [self readLine];
    NSDictionary *hello = line ? [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : nil;
    if (![hello isKindOfClass:NSDictionary.class] || ![hello[@"ready"] boolValue]) {
        NSString *reason = [hello isKindOfClass:NSDictionary.class] ? hello[@"error"] : nil;
        if (error) *error = POHelperError([NSString stringWithFormat:POL(@"Модель MLX не запустилась: %@"), reason ?: POL(@"помощник завершился без ответа")]);
        [self invalidate];
        return nil;
    }
    _inputSize = [hello[@"size"] integerValue];
    return self;
}

- (NSString *)replyForRGBData:(NSData *)pixels {
    if (_inputSize <= 0 || (NSInteger)pixels.length != _inputSize * _inputSize * 3) return nil;
    [_lock lock];
    NSString *reply = nil;
    if (_replies) {
        const uint8_t *bytes = pixels.bytes;
        size_t remaining = pixels.length;
        while (remaining > 0) {
            ssize_t written = write(_writeDescriptor, bytes, remaining);
            if (written <= 0) break;   // the helper died; SIGPIPE is ignored in main()
            bytes += written;
            remaining -= written;
        }
        if (remaining == 0) reply = [self readLine];
    }
    [_lock unlock];
    return reply.length ? reply : nil;
}

- (void)invalidate {
    [_lock lock];
    if (_writeDescriptor > 0) close(_writeDescriptor);   // end-of-file makes the helper exit
    _writeDescriptor = 0;
    if (_replies) fclose(_replies);
    _replies = NULL;
    if (_task.isRunning) [_task terminate];
    _task = nil;
    [_lock unlock];
}

- (void)dealloc {
    [self invalidate];
}

@end
