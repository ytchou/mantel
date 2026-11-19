#import "RemoteLayer.h"
#import <dlfcn.h>
#import <objc/message.h>

typedef uint32_t (*CGSMainConnectionIDFn)(void);

id RLMakeRemoteContext(CALayer *layer, uint32_t *outId) {
    Class cls = NSClassFromString(@"CAContext");
    if (!cls) return nil;
    CGSMainConnectionIDFn mainConn = (CGSMainConnectionIDFn)dlsym(RTLD_DEFAULT, "CGSMainConnectionID");
    if (!mainConn) mainConn = (CGSMainConnectionIDFn)dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
    NSString *const *filterKey = (NSString *const *)dlsym(RTLD_DEFAULT, "kCAContextCIFilterBehavior");
    NSDictionary *opts = filterKey ? @{ *filterKey: @"ignore" } : @{};
    id ctx = nil;
    SEL withConn = NSSelectorFromString(@"contextWithCGSConnection:options:");
    if (mainConn && [cls respondsToSelector:withConn]) {
        ctx = ((id (*)(id, SEL, uint32_t, NSDictionary *))objc_msgSend)(cls, withConn, mainConn(), opts);
    }
    if (!ctx) {
        SEL remote = NSSelectorFromString(@"remoteContextWithOptions:");
        if ([cls respondsToSelector:remote]) {
            ctx = ((id (*)(id, SEL, NSDictionary *))objc_msgSend)(cls, remote, opts);
        }
    }
    if (!ctx) return nil;
    ((void (*)(id, SEL, CALayer *))objc_msgSend)(ctx, NSSelectorFromString(@"setLayer:"), layer);
    *outId = ((uint32_t (*)(id, SEL))objc_msgSend)(ctx, NSSelectorFromString(@"contextId"));
    return ctx;
}

CALayer *RLMakeLayerHost(uint32_t contextId) {
    Class cls = NSClassFromString(@"CALayerHost");
    if (!cls) return nil;
    CALayer *host = [cls layer];
    ((void (*)(id, SEL, uint32_t))objc_msgSend)(host, NSSelectorFromString(@"setContextId:"), contextId);
    return host;
}

uint32_t RLContextIdOfLayer(CALayer *layer) {
    SEL ctxSel = NSSelectorFromString(@"context");
    if (![layer respondsToSelector:ctxSel]) return 0;
    id ctx = ((id (*)(id, SEL))objc_msgSend)(layer, ctxSel);
    if (!ctx) return 0;
    return ((uint32_t (*)(id, SEL))objc_msgSend)(ctx, NSSelectorFromString(@"contextId"));
}
