import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'applooma_engine.dart';

/// Renders a user's video. Use [AppVideoView.local] for the local preview.
class AppVideoView extends StatelessWidget {
  final lk.VideoTrack? track;
  final BoxFit fit;
  final bool mirror;

  const AppVideoView({super.key, required this.track, this.fit = BoxFit.cover, this.mirror = false});

  /// Local camera preview.
  factory AppVideoView.local(AppEngine engine, {Key? key, BoxFit fit = BoxFit.cover}) =>
      AppVideoView(key: key, track: engine.localVideoTrack, fit: fit, mirror: true);

  /// A remote user's video.
  factory AppVideoView.remote(AppRemoteUser user, {Key? key, BoxFit fit = BoxFit.cover}) =>
      AppVideoView(key: key, track: user.videoTrack, fit: fit);

  @override
  Widget build(BuildContext context) {
    final t = track;
    if (t == null) return const SizedBox.shrink();
    return lk.VideoTrackRenderer(
      t,
      fit: fit == BoxFit.contain
          ? lk.VideoViewFit.contain
          : lk.VideoViewFit.cover,
      mirrorMode: mirror ? lk.VideoViewMirrorMode.mirror : lk.VideoViewMirrorMode.off,
    );
  }
}
