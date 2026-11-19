// PRIVATE API. Option 3 of pd-b2 (remote layer). CAContext and CALayerHost
// are not public; Chromium uses the same pair for its out-of-process
// rendering on macOS. Everything is looked up at run time so a missing class
// returns nil instead of failing to link.
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

/// Block side: wrap `layer` in a new remote CAContext on this process's
/// WindowServer connection. Returns the context (keep it alive) and writes its
/// id to `outId`. Returns nil when the private class or selector is missing.
id _Nullable RLMakeRemoteContext(CALayer *layer, uint32_t *outId);

/// Host side: a layer that shows the remote context with `contextId`.
/// Returns nil when CALayerHost is missing.
CALayer *_Nullable RLMakeLayerHost(uint32_t contextId);

/// Id of the CAContext a layer is committed through (its window's context),
/// or 0 when unknown.
uint32_t RLContextIdOfLayer(CALayer *layer);

NS_ASSUME_NONNULL_END
