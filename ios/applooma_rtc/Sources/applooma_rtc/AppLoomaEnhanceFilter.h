// Video Enhance for iOS: the Core Image chain of the native iOS SDK
// (VideoEnhance.swift). Shared verbatim with the React Native SDK
// (sdks/react-native/ios); keep the copies in sync.

#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppLoomaEnhanceFilter : NSObject

/// Sets the options (clamped). All zero / NO means neutral: frames pass through.
- (void)setBeauty:(float)beauty lowLight:(BOOL)lowLight sharpen:(float)sharpen warmth:(float)warmth;

@property(nonatomic, readonly) BOOL isNeutral;

/// Returns the enhanced frame, or `frame` itself when neutral or on failure.
- (RTCVideoFrame *)process:(RTCVideoFrame *)frame;

@end

NS_ASSUME_NONNULL_END
