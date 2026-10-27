// ChatGPT iOS16 v0.52: stop Reynard's browser media transport integration
// from advertising the dedicated ChatGPT app as a music/media player.
//
// v0.50 merely removed UIBackgroundModes.audio. Reynard 0.19.0 still creates
// SystemMediaSession, registers MPRemoteCommand targets, and publishes metadata.
// v0.49 only cleared state when backgrounded; it allowed new playback states
// while the app was foregrounded. This guard prevents both at their origin.
//
// This does NOT mute AVAudioSession, Gecko audio output, voice conversation,
// or modify playback on other apps. It only removes remote playback controls.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>

typedef void (*CGNowPlayingSetter)(id, SEL, NSDictionary *);
typedef void (*CGCommandEnabledSetter)(id, SEL, BOOL);
typedef void (*CGPlaybackStateSetter)(id, SEL, MPNowPlayingPlaybackState);
static CGNowPlayingSetter CGRealSetNowPlayingInfo = NULL;
static CGCommandEnabledSetter CGRealSetCommandEnabled = NULL;
static CGPlaybackStateSetter CGRealSetPlaybackState = NULL;

static BOOL CGIsDedicatedChatGPTApp(void) {
    return [[[NSBundle mainBundle] bundleIdentifier]
              isEqualToString:@"com.551uk.chatgptios16"];
}

static void CGRejectNowPlayingInfo(id self, SEL selector, NSDictionary *incoming) {
    (void)incoming;
    if (CGRealSetNowPlayingInfo) {
        CGRealSetNowPlayingInfo(self, selector, nil);
    }
}

static void CGRejectRemoteCommandEnabled(id self, SEL selector, BOOL enabled) {
    (void)enabled;
    if (CGRealSetCommandEnabled) {
        CGRealSetCommandEnabled(self, selector, NO);
    }
}

static void CGRejectPlaybackState(id self, SEL selector, MPNowPlayingPlaybackState state) {
    (void)state;
    if (CGRealSetPlaybackState) {
        CGRealSetPlaybackState(self, selector, MPNowPlayingPlaybackStateStopped);
    }
}

static void CGDisableMediaTransportNow(void) {
    if (!CGIsDedicatedChatGPTApp()) return;

    MPNowPlayingInfoCenter *nowPlaying = MPNowPlayingInfoCenter.defaultCenter;
    nowPlaying.nowPlayingInfo = nil;
    if (@available(iOS 13.0, *)) {
        nowPlaying.playbackState = MPNowPlayingPlaybackStateStopped;
    }

    MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
    NSArray<MPRemoteCommand *> *commands = @[
        center.playCommand, center.pauseCommand, center.stopCommand,
        center.togglePlayPauseCommand, center.nextTrackCommand,
        center.previousTrackCommand, center.skipForwardCommand,
        center.skipBackwardCommand, center.seekForwardCommand,
        center.seekBackwardCommand, center.changePlaybackPositionCommand
    ];
    for (MPRemoteCommand *command in commands) {
        command.enabled = NO;
    }
}

@interface CGMediaTransportLifecycle : NSObject
@end
@implementation CGMediaTransportLifecycle
- (void)resetMediaTransport:(NSNotification *)notification {
    (void)notification;
    CGDisableMediaTransportNow();
}
@end

__attribute__((constructor))
static void CGInstallMediaTransportGuard(void) {
    @autoreleasepool {
        if (!CGIsDedicatedChatGPTApp()) return;

        Class infoClass = NSClassFromString(@"MPNowPlayingInfoCenter");
        Method setInfo = class_getInstanceMethod(infoClass, @selector(setNowPlayingInfo:));
        if (setInfo) {
            CGRealSetNowPlayingInfo = (CGNowPlayingSetter)method_setImplementation(
                setInfo, (IMP)CGRejectNowPlayingInfo);
        }

        Method setState = class_getInstanceMethod(infoClass, @selector(setPlaybackState:));
        if (setState) {
            CGRealSetPlaybackState = (CGPlaybackStateSetter)method_setImplementation(
                setState, (IMP)CGRejectPlaybackState);
        }

        Class commandClass = NSClassFromString(@"MPRemoteCommand");
        Method setEnabled = class_getInstanceMethod(commandClass, @selector(setEnabled:));
        if (setEnabled) {
            CGRealSetCommandEnabled = (CGCommandEnabledSetter)method_setImplementation(
                setEnabled, (IMP)CGRejectRemoteCommandEnabled);
        }

        static CGMediaTransportLifecycle *observer = nil;
        observer = [CGMediaTransportLifecycle new];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:observer selector:@selector(resetMediaTransport:)
                   name:UIApplicationDidBecomeActiveNotification object:nil];
        [nc addObserver:observer selector:@selector(resetMediaTransport:)
                   name:UIApplicationWillResignActiveNotification object:nil];
        [nc addObserver:observer selector:@selector(resetMediaTransport:)
                   name:UIApplicationDidEnterBackgroundNotification object:nil];

        CGDisableMediaTransportNow();
        NSLog(@"[ChatGPTGecko] Native Now Playing metadata and remote transport disabled");
    }
}
