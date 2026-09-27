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

/// How the SDK tunes your camera when you leave the details to it.
///
/// [stableHd] (default) holds one steady HD picture: a single layer,
/// resolution kept under pressure (frame rate gives way first) and receivers
/// pinned to the full picture. 1080p30 at 3.5 Mbps on iOS; 720p30 at 1.8 Mbps
/// on Android, where Dart cannot check the encoder for hardware.
///
/// [ultraHd4k] is the premium mode: 2160p30, one layer, resolution kept, H.265
/// at 16 Mbps on iOS. Android falls back to [stableHd] with a warning (see
/// [AppEngine.isUltraHdSupported]). Both ends need a strong network (20 Mbps
/// or more each way recommended) and the phone runs warmer.
///
/// [adaptive] is the earlier behaviour: three layers, receivers switch layers
/// by view size and network, resolution may drop to keep motion smooth.
///
/// Any field you set explicitly on [AppVideoConfig] wins over the mode.
enum AppVideoMode { stableHd, ultraHd4k, adaptive }

/// Capture and encode settings for your own camera.
///
/// [mode] picks sensible values for everything below; see [AppVideoMode].
/// Fields left at their default follow the mode, fields you set win.
///
/// [maxBitrate] is in **bits per second** — `1900000` for 1.9 Mbps. A value
/// under 10 000 is almost certainly kbps by mistake and is logged as a warning.
/// [height] must be one of 360 / 540 / 720 / 1080 / 1440 / 2160; anything else
/// snaps to the nearest preset (also logged). 0 = chosen by the mode.
///
/// When [maxBitrate] is 0 the cap comes from the mode: 3.5 Mbps at 1080p and
/// 1.8 Mbps at 720p for [AppVideoMode.stableHd], 16 or 25 Mbps for
/// [AppVideoMode.ultraHd4k]; in [AppVideoMode.adaptive] 5 Mbps at 1440p,
/// 4 Mbps at 1080p, 2.2 Mbps at 720p, and the preset default below that.
class AppVideoConfig {
  /// The overall tuning; see [AppVideoMode].
  final AppVideoMode mode;

  /// 360, 540, 720, 1080, 1440 or 2160 — the short edge of a 16:9 frame. 0 = chosen by [mode].
  final int height;
  final int fps;

  /// Cap on the encoder's bitrate in bits per second; 0 = our default for the height.
  final int maxBitrate;

  /// Floor on the encoder's bitrate in bits per second; 0 = engine default.
  ///
  /// Reserved: the engine exposes no per-sender minimum on this platform
  /// today, so the value is kept but does not change what is sent.
  final int minBitrate;

  /// Three layers so weak links still get a picture; false = one layer only.
  /// null = chosen by [mode] (on in adaptive, off in stableHd and ultraHd4k).
  final bool? simulcast;

  /// VP8, H.264, H.265, AV1, or let the engine choose.
  final AppVideoCodec codec;

  /// What to give up first under pressure. See [AppVideoDegradation].
  /// auto = chosen by [mode] (keepResolution in stableHd and ultraHd4k).
  final AppVideoDegradation degradation;

  const AppVideoConfig({
    this.mode = AppVideoMode.stableHd,
    this.height = 0,
    this.fps = 30,
    this.maxBitrate = 0,
    this.minBitrate = 0,
    this.simulcast,
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

  /// Preferred server region; see [AppRegion].
  final AppRegion region;

  const AppEngineOptions({
    this.audioScenario = AppAudioScenario.call,
    this.video = const AppVideoConfig(),
    this.audio = const AppAudioOptions(),
    this.region = AppRegion.auto,
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

/// Why automatic codec recovery switched how your camera is encoded.
enum AppVideoCodecFallbackReason {
  /// The encoder produced no frames or no key frame.
  noFrames('no_frames'),

  /// The encoder failed to start or to encode.
  encoderError('encoder_error'),

  /// Viewers reported they receive your camera but get no picture.
  viewersCannotDecode('viewers_cannot_decode');

  const AppVideoCodecFallbackReason(this.value);

  /// The wire value, the same on every platform.
  final String value;
}

/// Delivered on `AppEngine.onVideoCodecFallback`: your camera was republished
/// on a safer path by itself (viewers see about half a second of
/// interruption). For logs and support; the app has nothing to do.
class AppVideoCodecFallback {
  /// The codec before, e.g. `h264`.
  final String from;

  /// The codec after, e.g. `vp8`; `vp8:single` when a VP8 camera was
  /// republished as one layer.
  final String to;
  final AppVideoCodecFallbackReason reason;

  const AppVideoCodecFallback({required this.from, required this.to, required this.reason});

  @override
  String toString() => 'AppVideoCodecFallback($from -> $to, ${reason.value})';
}

/// Preferred server region for this engine.
///
/// Preparation for multi-region: the value is stored, logged at join and sent
/// with the SDK's own reports. Today every region connects to the same server
/// URL your token endpoint returns (`wsUrl`).
enum AppRegion {
  auto('auto'),
  bd('bd'),
  india('in'),
  sa('sa'),
  sg('sg'),
  us('us');

  const AppRegion(this.value);

  /// The wire value, the same on every platform.
  final String value;
}

/// Network quality grades, best to worst.
enum AppNetworkQuality { excellent, good, poor, lost, unknown }

/// What [AppEngine.startNetworkTest] measured. Delivered once.
class AppNetworkTestResult {
  final AppNetworkQuality uplinkQuality;
  final AppNetworkQuality downlinkQuality;

  /// Round-trip time to the server in ms; -1 when unknown.
  final int rttMs;

  /// Receive jitter in ms; 0 when nothing was received.
  final int jitterMs;

  /// Fraction of sent packets lost, 0..1.
  final double uplinkLoss;

  /// Fraction of received packets lost, 0..1.
  final double downlinkLoss;

  /// Null on success, otherwise why the test failed.
  final String? error;

  const AppNetworkTestResult({
    this.uplinkQuality = AppNetworkQuality.unknown,
    this.downlinkQuality = AppNetworkQuality.unknown,
    this.rttMs = -1,
    this.jitterMs = 0,
    this.uplinkLoss = 0,
    this.downlinkLoss = 0,
    this.error,
  });

  @override
  String toString() =>
      'AppNetworkTestResult(up=${uplinkQuality.name} down=${downlinkQuality.name} rtt=${rttMs}ms '
      'jitter=${jitterMs}ms upLoss=$uplinkLoss downLoss=$downlinkLoss error=$error)';
}

/// What to give up when the network is too weak. See
/// [AppEngine.setRemoteSubscribeFallback] and [AppEngine.setLocalPublishFallback].
enum AppFallbackOption { none, videoLowQuality, audioOnly }

/// Delivered on `AppEngine.onFallbackStateChanged`: which fallback is now in
/// effect ([AppFallbackOption.none] = restored).
class AppFallbackState {
  /// True for your own camera (uplink), false for remote video (downlink).
  final bool isLocal;
  final AppFallbackOption state;

  const AppFallbackState({required this.isLocal, required this.state});

  @override
  String toString() => 'AppFallbackState(${isLocal ? 'local' : 'remote'}, ${state.name})';
}

/// Hysteresis for fallback: bad for >= 4 s falls back, good for >= 10 s
/// restores. Pure; feed it one sample at a time.
class AppFallbackHysteresis {
  static const fallAfter = Duration(seconds: 4);
  static const restoreAfter = Duration(seconds: 10);

  bool _fallen = false;
  DateTime? _badSince;
  DateTime? _goodSince;

  bool get isFallenBack => _fallen;

  /// [bad]: poor/lost quality or loss above 10 %. [good]: good/excellent.
  /// Neither (unknown) resets both clocks. Returns the new fallen-back state.
  bool update({required bool bad, required bool good, required DateTime now}) {
    if (bad) {
      _goodSince = null;
      final since = _badSince ??= now;
      if (!_fallen && now.difference(since) >= fallAfter) _fallen = true;
    } else if (good) {
      _badSince = null;
      final since = _goodSince ??= now;
      if (_fallen && now.difference(since) >= restoreAfter) _fallen = false;
    } else {
      _badSince = null;
      _goodSince = null;
    }
    return _fallen;
  }

  void reset() {
    _fallen = false;
    _badSince = null;
    _goodSince = null;
  }
}
