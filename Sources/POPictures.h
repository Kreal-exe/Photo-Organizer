#import <Foundation/Foundation.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN

/// Tells pictures — postcards, memes, drawings, tickets, art saved from messengers and the web — from photographs,
/// with what the analysis already stored, so nothing is looked at again. A logistic regression on the feature print
/// of the whole picture (Vision's numeric description of how it looks, see POObjectIndex.h) is trained on the library
/// itself: files with a capture date that the labels don't call graphic are photos, files without one that the labels
/// call drawn, printed or written are pictures. It then catches what the labels miss (a colourful postcard of roses is
/// "flowers" to them), and keeps family photos sent through a messenger, which lost their dates, among the photos.
/// The sure examples of every library opened are remembered, so a folder of saved pictures learns from the camera roll
/// opened before it. The same approach as on Windows, where the vector is MobileCLIP's.
///
/// Blocking (a second or two for a large library), safe on any queue. Returns one entry per item — @YES, @NO, or
/// NSNull when it could not be judged (no print yet) — to be applied to `pictureVerdict` on the main queue (see
/// POApplyPictureVerdicts). Nil when the library has too few sure examples of either kind to learn from: the labels
/// alone decide then.
FOUNDATION_EXPORT NSArray *_Nullable POClassifyPictures(NSArray<POPhotoItem *> *items);

/// Sets `pictureVerdict` of `items` from what POClassifyPictures returned for them (nil clears every verdict).
FOUNDATION_EXPORT void POApplyPictureVerdicts(NSArray<POPhotoItem *> *items, NSArray *_Nullable verdicts);

/// What the user said each of `items` is, remembered between launches: one entry per item, @YES, @NO or NSNull —
/// for `pictureMark`, on the main queue. Blocking.
FOUNDATION_EXPORT NSArray *POPictureMarks(NSArray<POPhotoItem *> *items);

/// Remembers that `items` are pictures (or photos) as the user said: they count as such from now on whatever else
/// says otherwise, and teach the model more than any other example (it learns renders and photo art that way, which
/// the labels never call graphic). Sets `pictureMark` at once; blocking, safe on any queue.
FOUNDATION_EXPORT void POMarkPictures(NSArray<POPhotoItem *> *items, BOOL pictures);

NS_ASSUME_NONNULL_END
