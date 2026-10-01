#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN

/// Search for one particular object (this mug, this car) across a library, by looks rather than by words.
///
/// Every photo is described by a few "feature prints" — Vision's numeric description of how a picture looks —
/// one for the whole photo and one for each object Vision finds standing out in it (up to three). The object the
/// user marks in an example photo gets a print too, and photos are ranked by their closest print. The prints are
/// computed once, during the background analysis, and kept in Application Support/Photo Organizer/objects.bin.
@interface POObjectIndex : NSObject

@property (class, nonatomic, readonly) POObjectIndex *sharedIndex;

/// Prints of the whole picture and its salient objects, as stored. Slow-ish (tens of milliseconds).
+ (nullable NSData *)vectorsForImage:(CGImageRef)image;

/// The print of `rect` (in `image`'s pixels, origin top-left) — what the user marked.
+ (nullable NSData *)queryVectorForImage:(CGImageRef)image rect:(CGRect)rect;

/// The salient object Vision would pick in `image` (pixels, origin top-left), or CGRectNull.
+ (CGRect)mostSalientRectInImage:(CGImageRef)image;

- (BOOL)hasVectorsForKey:(NSString *)key;
- (void)setVectors:(NSData *)vectors forKey:(NSString *)key;
/// Writes what was added since the last save.
- (void)save;

/// `items` ordered by how close their nearest print is to `query`, closest first, with at most `limit` results.
/// `keys` gives each item's cache key (same order); items without prints are left out. `distances` receives the
/// distance (0 identical … 2 opposite) of each result.
- (NSArray<POPhotoItem *> *)itemsNearest:(NSData *)query
                                 inItems:(NSArray<POPhotoItem *> *)items
                                    keys:(NSArray<NSString *> *)keys
                                   limit:(NSUInteger)limit
                               distances:(NSArray<NSNumber *> *_Nullable *_Nullable)distances;

/// How many of `keys` have prints.
- (NSUInteger)countOfIndexedKeys:(NSArray<NSString *> *)keys;

@end

NS_ASSUME_NONNULL_END
