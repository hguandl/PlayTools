#import "MetalCaptureHook.h"

#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#import <string.h>

typedef void (*PTMetalCommitIMP)(id, SEL);
typedef id (*PTMetalNextDrawableIMP)(id, SEL);
typedef void (*PTMetalDrawablePresentIMP)(id, SEL);

static PTMetalCommitIMP PTOriginalCommit;
static PTMetalNextDrawableIMP PTOriginalNextDrawable;
static PTMetalDrawablePresentIMP PTOriginalDrawablePresent;

static PTMetalCommitCallback PTCommitCallback;
static PTMetalDrawableCallback PTPresentCallback;

static Class PTInstalledCommandBufferClass;
static BOOL PTDrawableHookInstalled;

#pragma mark - Swizzled Methods

static void PTMetalCommit(id commandBuffer, SEL selector) {
    @synchronized(CAMetalLayer.class) {
        PTMetalCommitCallback callback = PTCommitCallback;
        if (callback != nil) {
            callback(commandBuffer);
            PTCommitCallback = nil;

            if (class_getMethodImplementation(PTInstalledCommandBufferClass,
                                              selector) == (IMP)PTMetalCommit) {
                class_replaceMethod(PTInstalledCommandBufferClass, selector,
                                    (IMP)PTOriginalCommit, "v16@0:8");
            }
        }
    }

    PTMetalCommitIMP original = PTOriginalCommit;
    if (original != NULL) {
        original(commandBuffer, selector);
    }
}

static void PTInstallDrawablePresentHook(Class drawableClass);

static id PTMetalNextDrawable(id layer, SEL selector) {
    PTMetalNextDrawableIMP original = PTOriginalNextDrawable;
    id drawable = original != NULL ? original(layer, selector) : nil;
    if (drawable != nil) {
        PTInstallDrawablePresentHook(object_getClass(drawable));
    }
    return drawable;
}

static void PTMetalDrawablePresent(id drawable, SEL selector) {
    PTMetalDrawableCallback callback = PTPresentCallback;
    if (callback != nil) {
        callback(drawable);
    }

    PTMetalDrawablePresentIMP original = PTOriginalDrawablePresent;
    if (original != NULL) {
        original(drawable, selector);
    }
}

#pragma mark - Hook Installers

static IMP PTFindImplementation(Class targetClass, SEL selector,
                                const char *expectedTypes) {
    Method method = class_getInstanceMethod(targetClass, selector);
    if (method == NULL) {
        return NULL;
    }

    const char *types = method_getTypeEncoding(method);
    if (types == NULL || strcmp(types, expectedTypes) != 0) {
        return NULL;
    }
    return method_getImplementation(method);
}

static void PTInstallDrawablePresentHook(Class drawableClass) {
    @synchronized(CAMetalLayer.class) {
        if (PTDrawableHookInstalled) {
            return;
        }

        SEL presentSelector = sel_registerName("present");
        IMP original =
            PTFindImplementation(drawableClass, presentSelector, "v16@0:8");
        if (original == NULL) {
            return;
        }

        PTOriginalDrawablePresent = (PTMetalDrawablePresentIMP)original;
        class_replaceMethod(drawableClass, presentSelector,
                            (IMP)PTMetalDrawablePresent, "v16@0:8");
        PTDrawableHookInstalled = YES;

        // Discovery is complete, recover the original nextDrawable IMP.
        SEL nextDrawableSelector = sel_registerName("nextDrawable");
        if (class_getMethodImplementation(CAMetalLayer.class,
                                          nextDrawableSelector) ==
            (IMP)PTMetalNextDrawable) {
            class_replaceMethod(CAMetalLayer.class, nextDrawableSelector,
                                (IMP)PTOriginalNextDrawable, "@16@0:8");
        }
    }
}

BOOL PTInstallMetalCaptureHooks(Class commandBufferClass,
                                PTMetalCommitCallback commitCallback,
                                PTMetalDrawableCallback presentCallback) {
    if (commandBufferClass == Nil || commitCallback == nil ||
        presentCallback == nil) {
        return NO;
    }

    @synchronized(CAMetalLayer.class) {
        if (PTInstalledCommandBufferClass != Nil) {
            return PTInstalledCommandBufferClass == commandBufferClass;
        }

        SEL commitSelector = sel_registerName("commit");
        SEL nextDrawableSelector = sel_registerName("nextDrawable");
        IMP originalCommit =
            PTFindImplementation(commandBufferClass, commitSelector, "v16@0:8");
        IMP originalNextDrawable = PTFindImplementation(
            CAMetalLayer.class, nextDrawableSelector, "@16@0:8");
        if (originalCommit == NULL || originalNextDrawable == NULL) {
            return NO;
        }

        PTCommitCallback = [commitCallback copy];
        PTPresentCallback = [presentCallback copy];
        PTOriginalCommit = (PTMetalCommitIMP)originalCommit;
        PTOriginalNextDrawable = (PTMetalNextDrawableIMP)originalNextDrawable;
        PTInstalledCommandBufferClass = commandBufferClass;

        class_replaceMethod(commandBufferClass, commitSelector,
                            (IMP)PTMetalCommit, "v16@0:8");
        class_replaceMethod(CAMetalLayer.class, nextDrawableSelector,
                            (IMP)PTMetalNextDrawable, "@16@0:8");
        return YES;
    }
}
