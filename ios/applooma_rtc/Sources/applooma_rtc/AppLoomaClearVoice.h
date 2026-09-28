// Clear Voice for iOS: the spectral noise suppressor of the native Android SDK
// (ClearVoice.kt), run on the microphone's capture post-processing stage.
// Shared verbatim with the React Native SDK (sdks/react-native/ios); keep the
// copies in sync.

#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppLoomaClearVoice : NSObject

+ (instancetype)shared;

/// Off by default: audio passes through untouched.
@property(atomic) BOOL enabled;

// The capture post-processing delegate selectors (the SDK-specific plugin
// declares the protocol conformance).
- (void)audioProcessingInitializeWithSampleRate:(size_t)sampleRateHz channels:(size_t)channels;
- (void)audioProcessingProcess:(RTCAudioBuffer *)audioBuffer;
- (void)audioProcessingRelease;

@end

NS_ASSUME_NONNULL_END
