import 'dart:async';
import 'dart:io' as io;

import 'package:applooma_rtc_core/applooma_rtc_core.dart' as lk;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'applooma_engine.dart';

/// Options for [AppVideoEnhanceApi.setVideoEnhance]: skin smoothing
/// ([beauty] 0..1), [lowLight] boost, [sharpen] 0..1 and [warmth] -1..1.
class AppVideoEnhance {
  final double beauty;
  final bool lowLight;
  final double sharpen;
  final double warmth;

  const AppVideoEnhance({this.beauty = 0, this.lowLight = false, this.sharpen = 0, this.warmth = 0});

  /// A good default for a front camera: gentle smoothing plus low-light help.
  static const portrait = AppVideoEnhance(beauty: 0.5, lowLight: true);

  bool get isNeutral => beauty <= 0 && !lowLight && sharpen <= 0 && warmth == 0;
}

/// The SDK's own native half (android/, ios/ in this package).
const _media = MethodChannel('applooma_rtc/media');

bool get _nativeMedia => !kIsWeb && (io.Platform.isAndroid || io.Platform.isIOS);

final _enhance = Expando<AppVideoEnhance>('applooma.videoEnhance');
final _enhanceSub = Expando<StreamSubscription<void>>('applooma.videoEnhanceSub');

/// Turns Clear Voice on or off on the microphone's capture post-processing
/// stage. Process-wide; false where the native half is unavailable.
@internal
Future<bool> appSetClearVoice(bool enabled) async {
  if (!_nativeMedia) return false;
  try {
    return await _media.invokeMethod<bool>('setClearVoice', {'enabled': enabled}) ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException catch (e) {
    debugPrint('[AppLoomaRTC] clear voice: ${e.message}');
    return false;
  }
}

/// Built-in camera enhancement.
extension AppVideoEnhanceApi on AppEngine {
  /// Built-in camera enhancement: skin smoothing, low-light boost, sharpening
  /// and warmth, applied on the capture path so both your own preview and
  /// what viewers receive are enhanced. Pass null (or neutral options) to
  /// turn it off.
  ///
  /// Survives camera off/on, camera switches and republishes. Set it before
  /// the camera is on and it applies as soon as the camera starts.
  ///
  /// Resolves true when the enhancement is running on the camera now, or
  /// (camera off) has been stored for when it starts; false on platforms
  /// without it (web and desktop).
  Future<bool> setVideoEnhance(AppVideoEnhance? options) async {
    if (!_nativeMedia) return false;
    final on = options != null && !options.isNeutral;
    _enhance[this] = on ? options : null;
    if (on) {
      _enhanceSub[this] ??= onLocalVideoChanged.listen((_) => _syncVideoEnhance());
    } else {
      await _enhanceSub[this]?.cancel();
      _enhanceSub[this] = null;
    }
    final attached = await _syncVideoEnhance();
    return on ? (attached || localVideoTrack == null) : true;
  }

  /// The enhancement in force, or null when off.
  AppVideoEnhance? get videoEnhance => _enhance[this];

  /// Puts the current options on the current camera track (or detaches).
  Future<bool> _syncVideoEnhance() async {
    final o = _enhance[this];
    final track = localVideoTrack;
    final trackId = track is lk.LocalVideoTrack ? track.mediaStreamTrack.id : null;
    try {
      return await _media.invokeMethod<bool>('setVideoEnhance', {
            'trackId': o == null ? null : trackId,
            'beauty': o?.beauty ?? 0.0,
            'lowLight': o?.lowLight ?? false,
            'sharpen': o?.sharpen ?? 0.0,
            'warmth': o?.warmth ?? 0.0,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      debugPrint('[AppLoomaRTC] video enhance: ${e.message}');
      return false;
    }
  }
}
