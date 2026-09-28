// Native half of the Flutter SDK on iOS: Video Enhance and Clear Voice,
// attached to the media plugin's capture hooks (the local camera track's frame
// processing list and the microphone's capture post-processing stage).

#import "AppLoomaRtcPlugin.h"

#import <flutter_webrtc/AudioManager.h>
#import <flutter_webrtc/FlutterWebRTCPlugin.h>
#import <flutter_webrtc/LocalVideoTrack.h>

#import "AppLoomaClearVoice.h"
#import "AppLoomaEnhanceFilter.h"

@interface AppLoomaEnhanceProcessor : NSObject <ExternalVideoProcessingDelegate>
@property(nonatomic, strong, readonly) AppLoomaEnhanceFilter *filter;
@end

@implementation AppLoomaEnhanceProcessor
- (instancetype)init {
  if (self = [super init]) _filter = [AppLoomaEnhanceFilter new];
  return self;
}
- (RTCVideoFrame *)onFrame:(RTCVideoFrame *)frame {
  @try {
    return [_filter process:frame];
  } @catch (NSException *e) {
    return frame;
  }
}
@end

@interface AppLoomaClearVoiceProcessor : AppLoomaClearVoice <ExternalAudioProcessingDelegate>
@end
@implementation AppLoomaClearVoiceProcessor
@end

@implementation AppLoomaRtcPlugin {
  AppLoomaEnhanceProcessor *_enhancer;
  __weak LocalVideoTrack *_attached;
  AppLoomaClearVoiceProcessor *_clearVoice;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel = [FlutterMethodChannel methodChannelWithName:@"applooma_rtc/media"
                                                              binaryMessenger:[registrar messenger]];
  AppLoomaRtcPlugin *instance = [AppLoomaRtcPlugin new];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)init {
  if (self = [super init]) _enhancer = [AppLoomaEnhanceProcessor new];
  return self;
}

static float numberArg(NSDictionary *args, NSString *key) {
  id v = args[key];
  return [v isKindOfClass:[NSNumber class]] ? [v floatValue] : 0;
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSDictionary *args = [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : @{};
  if ([call.method isEqualToString:@"setVideoEnhance"]) {
    id lowLight = args[@"lowLight"];
    [_enhancer.filter setBeauty:numberArg(args, @"beauty")
                       lowLight:[lowLight isKindOfClass:[NSNumber class]] && [lowLight boolValue]
                        sharpen:numberArg(args, @"sharpen")
                         warmth:numberArg(args, @"warmth")];
    id trackId = args[@"trackId"];
    LocalVideoTrack *track = nil;
    if (!_enhancer.filter.isNeutral && [trackId isKindOfClass:[NSString class]]) {
      id<LocalTrack> t = [FlutterWebRTCPlugin sharedSingleton].localTracks[trackId];
      if ([(NSObject *)t isKindOfClass:[LocalVideoTrack class]]) track = (LocalVideoTrack *)t;
    }
    LocalVideoTrack *attached = _attached;
    if (track != attached) {
      if (attached) [attached removeProcessing:_enhancer];
      if (track) [track addProcessing:_enhancer];
      _attached = track;
    }
    // A track without a camera capture path has no processing adapter.
    result(@(track != nil && track.processing != nil));
  } else if ([call.method isEqualToString:@"setClearVoice"]) {
    id enabled = args[@"enabled"];
    if (!_clearVoice) {
      _clearVoice = [AppLoomaClearVoiceProcessor new];
      [[AudioManager sharedInstance].capturePostProcessingAdapter addProcessing:_clearVoice];
    }
    _clearVoice.enabled = [enabled isKindOfClass:[NSNumber class]] && [enabled boolValue];
    result(@YES);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

@end
