#import <Foundation/Foundation.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN

/// What the user said files are — "Это картинка" / "Это фото" — kept in Application Support/Photo Organizer/
/// picture-examples.plist under each file's analysis key, so that it survives moving the file and opening another
/// library. It wins over everything else (see POIsPicture).

/// What the user said each of `items` is: one entry per item, @YES, @NO or NSNull — for `pictureMark`, on the main
/// queue. Blocking.
FOUNDATION_EXPORT NSArray *POPictureMarks(NSArray<POPhotoItem *> *items);

/// Remembers that `items` are pictures (or photos) as the user said. Sets `pictureMark` at once; blocking, safe on any
/// queue.
FOUNDATION_EXPORT void POMarkPictures(NSArray<POPhotoItem *> *items, BOOL pictures);

NS_ASSUME_NONNULL_END
