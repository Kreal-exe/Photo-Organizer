#import <Foundation/Foundation.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN

/// Tells screenshots from photos by what the file itself says, without looking at the picture: the name the system
/// gave it ("Screenshot 2024-…", "Снимок экрана…", "Screenshot_20240101-…"), a folder of screenshots, or a PNG — which
/// cameras never write — the size of a phone, tablet or computer screen (iPhones name screenshots IMG_1234.PNG).
/// The image labels count too: a screenshot sent through a messenger comes back as a JPEG under another name.
FOUNDATION_EXPORT BOOL POIsScreenshot(POPhotoItem *item);

/// Only the name and folder: what POIsScreenshot reads once a file (see PONameTraits).
FOUNDATION_EXPORT BOOL POHasScreenshotName(POPhotoItem *item);

NS_ASSUME_NONNULL_END
