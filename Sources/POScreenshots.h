#import <Foundation/Foundation.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN

/// Tells screenshots from photos by what the file itself says, without looking at the picture: the name the system
/// gave it ("Screenshot 2024-…", "Снимок экрана…", "Screenshot_20240101-…"), a folder of screenshots, or a PNG — which
/// cameras never write — the size of a phone, tablet or computer screen (iPhones name screenshots IMG_1234.PNG).
FOUNDATION_EXPORT BOOL POIsScreenshot(POPhotoItem *item);

NS_ASSUME_NONNULL_END
