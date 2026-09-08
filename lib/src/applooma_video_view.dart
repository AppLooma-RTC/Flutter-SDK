import 'package:flutter/widgets.dart';
import 'package:applooma_rtc_core/applooma_rtc_core.dart' as lk;

import 'applooma_engine.dart';

/// Renders a participant's camera.
///
/// Use [AppVideoView.local] for your own preview and [AppVideoView.remote] for
/// someone else in the channel:
///
/// ```dart
/// AppVideoView.local(engine)
/// for (final user in engine.remoteUsers) AppVideoView.remote(user)
/// ```
///
/// Nothing is drawn until that participant publishes a camera, so rebuild your
/// UI on [AppEngine.onTrackSubscribed] as well as [AppEngine.onUserJoined] —
/// a participant is announced before their track arrives.
class AppVideoView extends StatelessWidget {
  // Kept private: the underlying track type is an implementation detail and
  // should never appear in application code.
  final lk.VideoTrack? _track;

  /// How the video fills its box. Defaults to [BoxFit.cover].
  final BoxFit fit;

  /// Mirrors the image horizontally. On by default for the local preview,
  /// because people expect their own camera to behave like a mirror.
  final bool mirror;

  const AppVideoView._(this._track, {super.key, this.fit = BoxFit.cover, this.mirror = false});

  /// Your own camera preview.
  factory AppVideoView.local(
    AppEngine engine, {
    Key? key,
    BoxFit fit = BoxFit.cover,
    bool mirror = true,
  }) =>
      AppVideoView._(engine.localVideoTrack, key: key, fit: fit, mirror: mirror);

  /// A remote participant's camera.
  factory AppVideoView.remote(
    AppRemoteUser user, {
    Key? key,
    BoxFit fit = BoxFit.cover,
    bool mirror = false,
  }) =>
      AppVideoView._(user.videoTrack, key: key, fit: fit, mirror: mirror);

  @override
  Widget build(BuildContext context) {
    final track = _track;
    // No camera published yet. Draw your own placeholder around this widget.
    if (track == null) return const SizedBox.shrink();

    return lk.VideoTrackRenderer(
      track,
      fit: fit == BoxFit.contain ? lk.VideoViewFit.contain : lk.VideoViewFit.cover,
      mirrorMode: mirror ? lk.VideoViewMirrorMode.mirror : lk.VideoViewMirrorMode.off,
    );
  }
}
