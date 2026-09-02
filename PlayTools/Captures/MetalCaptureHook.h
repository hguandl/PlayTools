#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^PTMetalCommitCallback)(id commandBuffer);
typedef void (^PTMetalDrawableCallback)(id drawable);

/// Installs the public Metal hooks used by the capture pipeline.
/// The drawable hook is installed lazily after the first `nextDrawable` call.
FOUNDATION_EXPORT BOOL PTInstallMetalCaptureHooks(
    Class commandBufferClass,
    PTMetalCommitCallback commitCallback,
    PTMetalDrawableCallback presentCallback
);

NS_ASSUME_NONNULL_END
