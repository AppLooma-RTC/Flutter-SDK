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

/// Built-in camera enhancement.
extension AppVideoEnhanceApi on AppEngine {
  /// Not yet available in the Flutter SDK: always returns false and leaves
  /// the camera unchanged. It is available today in the Android, iOS and Web
  /// SDKs; the Flutter version will forward to them in a later release.
  Future<bool> setVideoEnhance(AppVideoEnhance? options) async => false;
}
