#import <Foundation/Foundation.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN

/// The folder a file goes to when the library is organized by type — told by what the file itself says (its name,
/// folder, format and proportions), the way Photos lists its media types: Screenshots, Screen Recordings, WhatsApp,
/// Telegram, Viber, Instagram, Videos, Animations, RAW, Panoramas, Photos — and Collages (what Google Photos made) and
/// Pictures (postcards, memes, drawings).
FOUNDATION_EXPORT NSString *POTypeFolder(POPhotoItem *item);

/// What Google Photos made out of photos rather than a camera took: collages, photo frames, animations, movies,
/// video snippets and effects ("…-COLLAGE.jpg", "…-PHOTO_FRAME.jpg", "MOVIE.mp4") — told by the names Google Photos
/// and Google Takeout give them. An edited copy ("…-отредактировано.jpg") is still a photo.
FOUNDATION_EXPORT BOOL POIsGooglePhotosCreation(POPhotoItem *item);

/// A picture rather than a photograph: what Google Photos made (above), or a postcard, drawing, document or the like —
/// a file the image labels call drawn, printed or written ("illustrations", "document", "printed_page"…). What a
/// camera took — a capture date of its own, a place, a camera's name — is a photo whatever is in it.
FOUNDATION_EXPORT BOOL POIsPicture(POPhotoItem *item);

typedef NS_ENUM(NSInteger, POMediaFileKind) {
    POMediaFileKindNone,
    POMediaFileKindImage,
    POMediaFileKindVideo,
};

/// Whether a file with this extension is a photo or a video the library takes in. One explicit list, the same on
/// macOS and Windows, so that both find the same files in a folder: JPEG, PNG, GIF, BMP, TIFF, WebP, HEIC/HEIF, AVIF,
/// JPEG XL, JPEG 2000, PSD, ICO, camera RAW; MP4, MOV, AVI, MKV, 3GP, MTS/M2TS, WMV, WebM, MPEG, FLV.
FOUNDATION_EXPORT POMediaFileKind POMediaKindOfExtension(NSString *extension);

/// The folder a file goes to when the library is organized by format: JPEG, HEIC, PNG, MOV…
FOUNDATION_EXPORT NSString *POFormatFolder(POPhotoItem *item);

NS_ASSUME_NONNULL_END
