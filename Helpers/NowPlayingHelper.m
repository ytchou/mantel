// TopNotch now-playing helper.
//
// macOS 15.4 and later answer MediaRemote now-playing requests only for
// Apple-signed processes, so a normal app gets nothing back. This library is
// loaded into /usr/bin/perl (Apple-signed) by SystemNowPlayingWatcher in
// EventSources, which reads its output. MediaRemote is a private framework:
// this can stop working after a macOS update. The Spotify and Music watchers
// do not depend on it.
//
// Output: one JSON line per change, on stdout:
//   {"pid": 123, "playing": true, "title": "...", "artist": "...",
//    "album": "...", "artwork": "<base64>"}
// A line is written only when it differs from the previous one.
// The process exits when stdin closes, so it never outlives the app.
//
// Built and signed by the "Build now-playing helper" phase of the app target.

#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*RegisterFn)(dispatch_queue_t);
typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(BOOL));
typedef void (*GetPIDFn)(dispatch_queue_t, void (^)(int));

static GetInfoFn getInfo;
static GetPlayingFn getPlaying;
static GetPIDFn getPID;
static NSString *lastLine;
static BOOL pending;

/// Artwork larger than this is left out of the line.
static const NSUInteger maxArtworkBytes = 1024 * 1024;

static NSString *string(NSDictionary *info, NSString *key) {
    id value = info[key];
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static void emitNow(void) {
    dispatch_queue_t main = dispatch_get_main_queue();
    getPID(main, ^(int pid) {
        getPlaying(main, ^(BOOL playing) {
            getInfo(main, ^(NSDictionary *info) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"pid"] = @(pid);
                out[@"playing"] = @(playing);
                out[@"title"] = string(info, @"kMRMediaRemoteNowPlayingInfoTitle");
                out[@"artist"] = string(info, @"kMRMediaRemoteNowPlayingInfoArtist");
                out[@"album"] = string(info, @"kMRMediaRemoteNowPlayingInfoAlbum");
                id artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if ([artwork isKindOfClass:[NSData class]] && [artwork length] <= maxArtworkBytes) {
                    out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
                }
                NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
                NSString *line = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
                if (!line || [line isEqualToString:lastLine]) return;
                lastLine = line;
                printf("%s\n", line.UTF8String);
                fflush(stdout);
            });
        });
    });
}

/// MediaRemote posts several notifications for one change. Coalesce them.
static void emitSoon(void) {
    if (pending) return;
    pending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        pending = NO;
        emitNow();
    });
}

/// Called from perl as an XSUB; the two arguments are perl's and unused.
/// Runs until stdin closes.
void topnotch_nowplaying_stream(void *perl, void *cv) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) exit(2);
    RegisterFn registerForNotifications = (RegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    getInfo = (GetInfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getPlaying = (GetPlayingFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getPID = (GetPIDFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
    if (!registerForNotifications || !getInfo || !getPlaying || !getPID) exit(3);

    registerForNotifications(dispatch_get_main_queue());
    const char *names[] = {
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        CFStringRef *name = (CFStringRef *)dlsym(mr, names[i]);
        if (!name) continue;
        [[NSNotificationCenter defaultCenter] addObserverForName:(__bridge NSString *)*name
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) { emitSoon(); }];
    }

    // The app holds stdin open; end of input means the app is gone.
    dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(input, ^{
        char buffer[256];
        if (read(STDIN_FILENO, buffer, sizeof(buffer)) <= 0) exit(0);
    });
    dispatch_resume(input);

    emitNow();
    CFRunLoopRun();
}
