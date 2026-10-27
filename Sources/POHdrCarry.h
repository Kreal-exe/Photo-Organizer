#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Carries dynamic HDR metadata from an original video into its compressed version, which no encoder writes again:
/// HDR Vivid (Honor, Huawei) and HDR10+ (Samsung) as a message in every frame, Dolby Vision (iPhone) as a layer in
/// every frame — how bright each scene is to be shown — and the boxes that announce them in the track's description
/// (cuvv, dvcC). Without them a phone shows the video brighter. The compressed file is written again around the same
/// pictures, nothing encoded: each frame gets what the original's frame shown at the same moment had (an iPhone's
/// frames are stored in another order than they are shown). The same as HdrCarry on Windows.

/// "dolby vision", "vivid" or "hdr10+" when the video's first frame carries dynamic HDR metadata of that kind; nil otherwise.
FOUNDATION_EXPORT NSString *_Nullable PODynamicHdrOf(NSURL *video);

/// Whether a video's frames, though stored out of order (B-frames), are all marked shown at the moment they are decoded
/// (no ctts): players show them out of order, in jerks. The same as VideoInfo.FlatTimestamps on Windows.
FOUNDATION_EXPORT BOOL POHasFlatTimestamps(NSURL *video);

/// Writes `output`: `encoded` with `original`'s dynamic HDR metadata in every frame. Returns how many frames got it; on
/// an error 0, with `error` saying what went wrong. `output` is only valid when there is no error.
FOUNDATION_EXPORT NSInteger POCarryHdr(NSURL *original, NSURL *encoded, NSURL *output, NSString *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
