// Dedicated ChatGPT app: do not register Reynard's browser media shortcuts.
//
// Reynard 0.19.0 SystemMediaSession.registerRemoteCommands() installs eleven
// MPRemoteCommandCenter handlers when its media manager initializes, even
// before playback begins. These are irrelevant in a single-purpose ChatGPT
// wrapper and can make iOS associate an empty Now Playing panel with the app.
//
// Unlike the failed 0.49/0.50/0.52 fixes, this stops handler registration at
// the actual entry point. There are no timers, polling, resets, audio-session
// changes, or metadata clearing; normal Gecko voice/audio output is untouched.
#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>

typedef id (*CGRegisterRemoteHandlerIMP)(id, SEL, id);
static CGRegisterRemoteHandlerIMP CGOriginalRegisterRemoteHandler = NULL;
static NSObject *CGUnusedRemoteTarget = nil;

static BOOL CGIsChatGPTApp(void) {
    return [[[NSBundle mainBundle] bundleIdentifier]
          isEqualToString:@"com.551uk.chatgptios16"];
}

static id CGRejectBrowserRemoteHandler(id command, SEL selector, id handler) {
    if (!CGIsChatGPTApp() && CGOriginalRegisterRemoteHandler)
        return CGOriginalRegisterRemoteHandler(command, selector, handler);

    // Swift's addTarget(handler:) returns Any (nonnull). A stable dummy token
    // preserves its subsequent removeTarget(_:) cleanup without registering
    // anything with MediaPlayer.
    (void)handler;
    return CGUnusedRemoteTarget;
}

__attribute__((constructor))
static void CGInstallRemoteRegistrationGuard(void) {
    @autoreleasepool {
        if (!CGIsChatGPTApp()) return;

        CGUnusedRemoteTarget = [NSObject new];
        Method method = class_getInstanceMethod(
            MPRemoteCommand.class, @selector(addTargetWithHandler:));
        if (!method) {
            NSLog(@"[ChatGPTGecko] MPRemoteCommand addTargetWithHandler: unavailable");
            return;
        }
        CGOriginalRegisterRemoteHandler = (CGRegisterRemoteHandlerIMP)
            method_setImplementation(method, (IMP)CGRejectBrowserRemoteHandler);
        NSLog(@"[ChatGPTGecko] Browser remote playback registrations disabled");
    }
}
