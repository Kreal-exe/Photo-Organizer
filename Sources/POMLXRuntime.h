#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The private Python environment with Apple's MLX that runs MLX models. It lives in Application Support and
/// is only created when the user asks for it.
@interface POMLXRuntime : NSObject

/// "Apple M1 Pro", "Intel(R) Core(TM) i7-…".
@property (class, nonatomic, readonly) NSString *processorName;
/// MLX needs Apple Silicon.
@property (class, nonatomic, readonly) BOOL isSupported;

@property (class, nonatomic, readonly) NSURL *environmentURL;
@property (class, nonatomic, readonly) NSURL *pythonURL;
@property (class, nonatomic, readonly) BOOL isInstalled;

/// Creates the environment and installs `mlx` and `numpy` from PyPI. Uses a Python 3.10+ already on the Mac, or
/// `uv` (which fetches its own Python) when there is none. Both blocks are called on the main queue.
+ (void)installWithLog:(nullable void (^)(NSString *line))log completion:(void (^)(NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
