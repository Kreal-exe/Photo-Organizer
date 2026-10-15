#import "POPictures.h"
#import "POAnalyzer.h"

static NSURL *POMarksURL(void) {
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                                                 appropriateForURL:nil create:YES error:NULL];
    return [support URLByAppendingPathComponent:@"Photo Organizer/picture-examples.plist"];
}

static NSObject *POMarksLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

/// Key → what the user said (@YES a picture, @NO a photo), read and written under one lock.
static NSMutableDictionary<NSString *, NSNumber *> *POLoadMarks(void) {
    NSDictionary *marks = [NSDictionary dictionaryWithContentsOfURL:POMarksURL()][@"marks"];
    return [marks isKindOfClass:NSDictionary.class] ? [marks mutableCopy] : [NSMutableDictionary dictionary];
}

NSArray *POPictureMarks(NSArray<POPhotoItem *> *items) {
    NSDictionary<NSString *, NSNumber *> *marks;
    @synchronized (POMarksLock()) {
        marks = POLoadMarks();
    }
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:items.count];
    for (POPhotoItem *item in items) {
        NSString *key = marks.count ? [POAnalyzer cacheKeyForURL:item.url] : nil;
        [result addObject:(key ? marks[key] : nil) ?: NSNull.null];
    }
    return result;
}

void POMarkPictures(NSArray<POPhotoItem *> *items, BOOL pictures) {
    for (POPhotoItem *item in items) item.pictureMark = @(pictures);
    @synchronized (POMarksLock()) {
        NSMutableDictionary<NSString *, NSNumber *> *marks = POLoadMarks();
        for (POPhotoItem *item in items) {
            NSString *key = [POAnalyzer cacheKeyForURL:item.url];
            if (key) marks[key] = @(pictures);
        }
        [NSFileManager.defaultManager createDirectoryAtURL:POMarksURL().URLByDeletingLastPathComponent withIntermediateDirectories:YES
                                                attributes:nil error:NULL];
        // Only the marks: the examples an earlier version kept here are no longer used.
        [@{@"marks": marks} writeToURL:POMarksURL() atomically:YES];
    }
}
