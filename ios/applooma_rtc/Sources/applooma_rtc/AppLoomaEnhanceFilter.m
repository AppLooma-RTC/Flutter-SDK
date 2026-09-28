#import "AppLoomaEnhanceFilter.h"

#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <math.h>

static float clampf(float v, float lo, float hi) {
  if (isnan(v)) return 0;
  return v < lo ? lo : (v > hi ? hi : v);
}

@implementation AppLoomaEnhanceFilter {
  NSLock *_lock;
  float _beauty, _sharpen, _warmth;
  BOOL _lowLight;
  CIContext *_context;
  CVPixelBufferPoolRef _pool;
  size_t _poolW, _poolH;
  OSType _poolFormat;
  float _exposure;  // smoothed EV for low light
  NSUInteger _frameCount;
}

- (instancetype)init {
  if (self = [super init]) {
    _lock = [NSLock new];
    _context = [CIContext contextWithOptions:@{
      kCIContextCacheIntermediates : @NO,
      kCIContextWorkingColorSpace : [NSNull null],
    }];
  }
  return self;
}

- (void)dealloc {
  if (_pool) CVPixelBufferPoolRelease(_pool);
}

- (void)setBeauty:(float)beauty lowLight:(BOOL)lowLight sharpen:(float)sharpen warmth:(float)warmth {
  [_lock lock];
  _beauty = clampf(beauty, 0, 1);
  _lowLight = lowLight;
  _sharpen = clampf(sharpen, 0, 1);
  _warmth = clampf(warmth, -1, 1);
  [_lock unlock];
}

- (BOOL)isNeutral {
  [_lock lock];
  BOOL n = _beauty <= 0 && !_lowLight && _sharpen <= 0 && _warmth == 0;
  [_lock unlock];
  return n;
}

- (RTCVideoFrame *)process:(RTCVideoFrame *)frame {
  [_lock lock];
  float beauty = _beauty, sharpen = _sharpen, warmth = _warmth;
  BOOL lowLight = _lowLight;
  [_lock unlock];
  if (beauty <= 0 && !lowLight && sharpen <= 0 && warmth == 0) return frame;
  if (![frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) return frame;
  CVPixelBufferRef input = ((RTCCVPixelBuffer *)frame.buffer).pixelBuffer;
  if (!input) return frame;

  CIImage *image = [CIImage imageWithCVPixelBuffer:input];

  if (lowLight) {
    // Measure the mean every 10th frame on a tiny average; aim EV at mid-grey.
    if (_frameCount % 10 == 0) {
      float mean = [self meanLuma:image];
      if (mean >= 0) {
        float target = mean < 0.43f ? fminf(1.6f, fmaxf(0, log2f(0.43f / fmaxf(mean, 0.02f)))) : 0;
        _exposure += (target - _exposure) * 0.4f;
      }
    }
    _frameCount++;
    if (_exposure > 0.02f) {
      image = [image imageByApplyingFilter:@"CIExposureAdjust" withInputParameters:@{kCIInputEVKey : @(_exposure)}];
    }
    image = [image imageByApplyingFilter:@"CIHighlightShadowAdjust"
                     withInputParameters:@{@"inputShadowAmount" : @0.6, @"inputHighlightAmount" : @1.0}];
  } else {
    _exposure = 0;
  }

  if (beauty > 0) {
    // Noise reduction smooths flat (skin) areas and keeps edges; blend it in
    // by strength (the mask's alpha is the foreground weight), plus a lift.
    CIImage *smooth = [image imageByApplyingFilter:@"CINoiseReduction"
                               withInputParameters:@{@"inputNoiseLevel" : @(0.02 + 0.06 * beauty), @"inputSharpness" : @0.2}];
    CIImage *mask = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:0.85 * beauty]] imageByCroppingToRect:image.extent];
    image = [smooth imageByApplyingFilter:@"CIBlendWithAlphaMask"
                      withInputParameters:@{kCIInputBackgroundImageKey : image, kCIInputMaskImageKey : mask}];
    image = [image imageByApplyingFilter:@"CIColorControls" withInputParameters:@{kCIInputBrightnessKey : @(0.03 * beauty)}];
  }

  if (sharpen > 0) {
    image = [image imageByApplyingFilter:@"CISharpenLuminance"
                     withInputParameters:@{kCIInputSharpnessKey : @(0.8 * sharpen), kCIInputRadiusKey : @1.5}];
  }

  if (warmth != 0) {
    // Neutral 6500 K; a lower target temperature renders warmer.
    image = [image imageByApplyingFilter:@"CITemperatureAndTint"
                     withInputParameters:@{
                       @"inputNeutral" : [CIVector vectorWithX:6500 Y:0],
                       @"inputTargetNeutral" : [CIVector vectorWithX:6500 - 1500 * warmth Y:0],
                     }];
  }

  size_t w = CVPixelBufferGetWidth(input), h = CVPixelBufferGetHeight(input);
  image = [image imageByCroppingToRect:CGRectMake(0, 0, w, h)];
  CVPixelBufferRef output = [self makeBufferLike:input];
  if (!output) return frame;
  [_context render:image toCVPixelBuffer:output];
  RTCCVPixelBuffer *outBuffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:output];
  CVPixelBufferRelease(output);
  return [[RTCVideoFrame alloc] initWithBuffer:outBuffer rotation:frame.rotation timeStampNs:frame.timeStampNs];
}

/// Mean luma 0..1 over the whole image, or -1 on failure.
- (float)meanLuma:(CIImage *)image {
  CIImage *avg = [image imageByApplyingFilter:@"CIAreaAverage"
                          withInputParameters:@{kCIInputExtentKey : [CIVector vectorWithCGRect:image.extent]}];
  uint8_t px[4] = {0, 0, 0, 0};
  [_context render:avg toBitmap:px rowBytes:4 bounds:CGRectMake(0, 0, 1, 1) format:kCIFormatRGBA8 colorSpace:nil];
  return (0.299f * px[0] + 0.587f * px[1] + 0.114f * px[2]) / 255.0f;
}

/// Output buffers come from a pool matching the camera's size and format. +1 retained.
- (CVPixelBufferRef)makeBufferLike:(CVPixelBufferRef)input {
  size_t w = CVPixelBufferGetWidth(input), h = CVPixelBufferGetHeight(input);
  OSType fmt = CVPixelBufferGetPixelFormatType(input);
  if (!_pool || _poolW != w || _poolH != h || _poolFormat != fmt) {
    if (_pool) {
      CVPixelBufferPoolRelease(_pool);
      _pool = NULL;
    }
    NSDictionary *attrs = @{
      (id)kCVPixelBufferPixelFormatTypeKey : @(fmt),
      (id)kCVPixelBufferWidthKey : @(w),
      (id)kCVPixelBufferHeightKey : @(h),
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };
    NSDictionary *poolAttrs = @{(id)kCVPixelBufferPoolMinimumBufferCountKey : @4};
    CVPixelBufferPoolCreate(NULL, (__bridge CFDictionaryRef)poolAttrs, (__bridge CFDictionaryRef)attrs, &_pool);
    _poolW = w;
    _poolH = h;
    _poolFormat = fmt;
  }
  if (!_pool) return NULL;
  CVPixelBufferRef out = NULL;
  CVPixelBufferPoolCreatePixelBuffer(NULL, _pool, &out);
  return out;
}

@end
