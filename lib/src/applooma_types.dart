/// Roles supported by AppLooma RTC channels.
enum AppRole { host, cohost, audience }

/// Connection lifecycle states.
enum AppConnectionState { connecting, connected, reconnecting, disconnected }

/// Milestones on the way to seeing a remote picture, each with elapsed
/// milliseconds since [AppEngine.joinChannel].
enum AppConnectionStage { connected, firstRemoteVideoFrame }

/// How the engine treats audio for the whole session. Pick once, at create time.
///
/// [call] routes voice through the phone's communication path: echo
/// cancellation tuned for speech, the earpiece by default, volume keys control
/// the call. [media] keeps media attributes (loudspeaker, media volume keys,
/// music-grade bandwidth) while still running in the communication audio mode
/// so the phone's echo canceller stays engaged — voice rooms with music and
/// live streams sound better on [media]; a private call belongs on [call].
enum AppAudioScenario { call, media }

/// Which codec your camera is published with.
///
/// [auto] (default) publishes H.264 — which every Android and iOS phone
/// encodes in hardware — with a VP8 backup layer, so a viewer that cannot
/// decode the H.264 stream still gets a picture. Force one only for a known
/// fleet. (Flutter cannot probe the phone's encoder list the way the native
/// Android SDK does, so [auto] does not pick VP8 on VP8-hardware phones.)
///
/// [h265] and [av1] are opt-in. Dart cannot probe the phone's encoder list, so:
/// on iOS [h265] is published (hardware on every iPhone since the 7) with a
/// VP8 backup layer; on Android [h265] and [av1] fall back to [auto] with a
/// warning, and on iOS [av1] does too (no iPhone encodes AV1 in hardware).
enum AppVideoCodec { auto, vp8, h264, h265, av1 }

/// What the encoder gives up first when the network or the CPU cannot carry
/// the full picture.
///
/// [auto] (default) is the engine's choice for a camera — frame rate is kept
/// and resolution drops, which looks smoothest in a call. [keepResolution]
/// keeps the picture sharp and drops frames instead — for a 1080p broadcast
/// where crispness is the product. [keepFramerate] keeps motion smooth and
/// lets the picture soften. [balanced] gives up a little of each.
enum AppVideoDegradation { auto, keepResolution, keepFramerate, balanced }

/// Capture and encode settings for your own camera.
///
/// [maxBitrate] is in **bits per second** — `1900000` for 1.9 Mbps. A value
/// under 10 000 is almost certainly kbps by mistake and is logged as a warning.
/// [height] must be one of 360 / 540 / 720 / 1080 / 1440; anything else snaps
/// to the nearest preset (also logged).
///
/// When [maxBitrate] is 0 the cap is 5 Mbps at 1440p, 4 Mbps at 1080p,
/// 2.2 Mbps at 720p, and the preset default below that.
class AppVideoConfig {
  /// 360, 540, 720, 1080 or 1440 — the short edge of a 16:9 frame.
  final int height;
  final int fps;

  /// Cap on the encoder's bitrate in bits per second; 0 = our default for the height.
  final int maxBitrate;

  /// Floor on the encoder's bitrate in bits per second; 0 = engine default.
  ///
  /// Reserved: the engine exposes no per-sender minimum on this platform
  /// today, so the value is kept but does not change what is sent.
  final int minBitrate;

  /// Three layers so weak links still get a picture. Off = one layer only.
  final bool simulcast;

  /// VP8, H.264, H.265, AV1, or let the engine choose.
  final AppVideoCodec codec;

  /// What to give up first under pressure. See [AppVideoDegradation].
  final AppVideoDegradation degradation;

  const AppVideoConfig({
    this.height = 1080,
    this.fps = 30,
    this.maxBitrate = 0,
    this.minBitrate = 0,
    this.simulcast = true,
    this.codec = AppVideoCodec.auto,
    this.degradation = AppVideoDegradation.auto,
  });
}

/// Which of your simulcast layers the numbers in [AppVideoQualityInfo] describe.
enum AppVideoLayer { high, medium, low }

/// Why the encoder is not sending the full picture, when it is not.
enum AppVideoQualityReason { bandwidth, cpu, none }

/// What your own camera is actually sending right now — the top layer that
/// carries frames, its size, rate and bitrate, and why it is not the full
/// picture if it is not. Delivered on [AppEngine.onVideoQualityChanged]
/// whenever any of it changes while the camera is on.
class AppVideoQualityInfo {
  final int width;
  final int height;
  final int fps;
  final int bitrateKbps;
  final AppVideoLayer layer;
  final AppVideoQualityReason reason;

  const AppVideoQualityInfo({
    required this.width,
    required this.height,
    required this.fps,
    required this.bitrateKbps,
    required this.layer,
    required this.reason,
  });

  @override
  String toString() =>
      'AppVideoQualityInfo(${width}x$height @$fps fps, $bitrateKbps kbps, ${layer.name}, ${reason.name})';
}

/// Microphone processing. Each stage can be switched independently; all are
/// on by default.
///
/// There is no post-processing gain on Flutter (the native Android SDK's
/// `micGain`): the platform does not expose a capture post-processor to Dart.
class AppAudioOptions {
  final bool echoCancellation;
  final bool noiseSuppression;
  final bool autoGainControl;

  const AppAudioOptions({
    this.echoCancellation = true,
    this.noiseSuppression = true,
    this.autoGainControl = true,
  });
}

/// Engine-wide settings. All optional; the defaults are what most apps want.
class AppEngineOptions {
  final AppAudioScenario audioScenario;
  final AppVideoConfig video;
  final AppAudioOptions audio;

  const AppEngineOptions({
    this.audioScenario = AppAudioScenario.call,
    this.video = const AppVideoConfig(),
    this.audio = const AppAudioOptions(),
  });
}

/// Options for joining a channel.
class AppJoinOptions {
  final AppRole role;

  /// Auto-enable camera on join (ignored for audience).
  final bool camera;

  /// Auto-enable microphone on join (ignored for audience).
  final bool microphone;

  const AppJoinOptions({
    this.role = AppRole.host,
    this.camera = false,
    this.microphone = true,
  });
}

/// Per-remote-user media health, delivered every two seconds while joined on
/// [AppEngine.onRemoteStats].
///
/// A camera you are subscribed to reporting [videoFps] 0 is a stuck picture;
/// [videoFreezeCount] climbs each time it stalls; a climbing [audioPacketsLost]
/// is why one voice is breaking up while the others are fine.
class AppRemoteStats {
  final String uid;
  final int videoFps;
  final int videoWidth;
  final int videoHeight;

  /// Times the picture stalled since you subscribed.
  final int videoFreezeCount;
  final int videoPacketsLost;
  final int audioPacketsLost;

  /// Audio jitter-buffer delay in milliseconds.
  final int audioJitterMs;

  const AppRemoteStats({
    required this.uid,
    required this.videoFps,
    required this.videoWidth,
    required this.videoHeight,
    required this.videoFreezeCount,
    required this.videoPacketsLost,
    required this.audioPacketsLost,
    required this.audioJitterMs,
  });

  @override
  String toString() =>
      'AppRemoteStats($uid fps=$videoFps ${videoWidth}x$videoHeight freezes=$videoFreezeCount '
      'vLost=$videoPacketsLost aLost=$audioPacketsLost jitter=${audioJitterMs}ms)';
}

/// A virtual gift broadcast to everyone in the channel.
///
/// Sent from your server with `POST /v1/gifts/send`; every client in the room
/// receives it on [AppEngine.onGiftReceived]. Shape matches the other SDKs.
class AppGiftEvent {
  final String txId;
  final String giftId;
  final String giftName;
  final String imageUrl;
  final int coinPrice;
  final String sender;
  final String receiver;
  final int quantity;

  const AppGiftEvent({
    required this.txId,
    required this.giftId,
    required this.giftName,
    required this.imageUrl,
    required this.coinPrice,
    required this.sender,
    required this.receiver,
    required this.quantity,
  });

  /// Returns null when the payload is not a gift event.
  static AppGiftEvent? fromJson(Map<String, dynamic> msg) {
    try {
      if (msg['type'] != 'applooma.gift') return null;
      final gift = Map<String, dynamic>.from(msg['gift'] as Map);
      return AppGiftEvent(
        txId: msg['txId'] as String,
        giftId: gift['id'] as String? ?? '',
        giftName: gift['name'] as String,
        imageUrl: gift['imageUrl'] as String,
        coinPrice: (gift['coinPrice'] as num?)?.toInt() ?? 0,
        sender: msg['sender'] as String,
        receiver: msg['receiver'] as String,
        quantity: (msg['quantity'] as num?)?.toInt() ?? 1,
      );
    } catch (_) {
      return null;
    }
  }
}
