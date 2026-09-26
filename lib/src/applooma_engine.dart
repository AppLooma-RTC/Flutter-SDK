import 'dart:async';
import 'dart:convert';

import 'package:applooma_rtc_core/applooma_rtc_core.dart' as lk;
import 'package:flutter/foundation.dart';

import 'applooma_types.dart';

/// Our own frames travel on the same channel as customer data, tagged so the
/// two never mix.
const _messageType = 'applooma.message';
const _giftType = 'applooma.gift';

int _idCounter = 0;
String _newId() =>
    'm_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}_${(_idCounter++).toRadixString(36)}';

/// A message sent to everyone in the channel.
///
/// Messages ride the same channel as the media, so they arrive with the same
/// latency and need no second connection. Nothing is stored: a message reaches
/// whoever is in the channel at the time.
class AppMessage {
  /// Unique to this message. Useful as a list key and for de-duplicating.
  final String id;

  /// What was sent, when [AppEngine.sendMessage] was given a string.
  final String? text;

  /// What was sent, when it was given a map.
  final Map<String, dynamic>? data;

  /// Who sent it. Null if it came from your own server.
  final AppRemoteUser? from;

  /// The sender's clock, not ours — do not order messages by it alone.
  final DateTime sentAt;

  const AppMessage({
    required this.id,
    required this.sentAt,
    this.text,
    this.data,
    this.from,
  });
}

/// A remote user in the channel.
class AppRemoteUser {
  final lk.RemoteParticipant _p;
  AppRemoteUser._(this._p);

  String get uid => _p.identity;
  String? get displayName => _p.name;

  /// What this user is allowed to do, decided by the token their server minted.
  /// An [AppRole.audience] member can watch and send messages but cannot publish.
  AppRole get role {
    switch (_parsed()['role']) {
      case 'host':
        return AppRole.host;
      case 'cohost':
        return AppRole.cohost;
      default:
        return AppRole.audience;
    }
  }

  /// Whether this user can publish. Convenient for laying out a stage.
  bool get isPublisher => role != AppRole.audience;

  /// The metadata your own server put in the token, with our fields stripped out.
  Map<String, dynamic> get attributes {
    final map = Map<String, dynamic>.from(_parsed());
    map.remove('appId');
    map.remove('role');
    return map;
  }

  /// The raw metadata string. Prefer [attributes].
  String? get metadata => _p.metadata;

  String? _cachedRaw;
  Map<String, dynamic>? _cachedValue;

  /// Parsing runs once per metadata string, not once per read.
  Map<String, dynamic> _parsed() {
    final raw = _p.metadata;
    if (_cachedValue != null && _cachedRaw == raw) return _cachedValue!;
    Map<String, dynamic> value = const {};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) value = decoded;
      } catch (_) {
        // Not ours — a customer may put anything here.
      }
    }
    _cachedRaw = raw;
    _cachedValue = value;
    return value;
  }

  bool get isSpeaking => _p.isSpeaking;
  bool get audioEnabled => _p.isMicrophoneEnabled();
  bool get videoEnabled => _p.isCameraEnabled();

  /// Whether this participant is currently publishing a camera.
  ///
  /// A participant is announced before their track arrives, so this is false
  /// for a moment after they join.
  bool get hasVideo => videoTrack != null;

  /// The underlying camera track. Used by [AppVideoView]; application code
  /// should render with `AppVideoView.remote(user)` instead.
  @internal
  lk.VideoTrack? get videoTrack {
    for (final pub in _p.videoTrackPublications) {
      final t = pub.track;
      if (t != null && !pub.muted) return t;
    }
    return null;
  }

  /// internal
  lk.RemoteParticipant get raw => _p;
}

/// Latest receiver stats for one remote user, folded into [AppRemoteStats].
class _RemoteHealth {
  int fps = 0, width = 0, height = 0, vLost = 0, aLost = 0, jitterMs = 0, freezes = 0;
  bool hadPicture = false;
  bool firstFrameReported = false;
  final listeners = <lk.EventsListener<lk.TrackEvent>>[];
}

/// Main entry point of the AppLooma RTC SDK.
///
/// One engine is one connection to one channel. To be in two channels at once
/// (a PK battle, watching a second stream) create a second engine; instances
/// are independent and any number may coexist.
class AppEngine {
  final String appId;
  final AppEngineOptions options;
  final lk.Room _room;
  lk.EventsListener<lk.RoomEvent>? _listener;
  final _users = <String, AppRemoteUser>{};
  final _health = <String, _RemoteHealth>{};
  Timer? _statsTimer;
  DateTime? _joinStartedAt;
  bool _joined = false;

  // Event streams
  final _userJoined = StreamController<AppRemoteUser>.broadcast();
  final _userLeft = StreamController<AppRemoteUser>.broadcast();
  final _connectionState = StreamController<AppConnectionState>.broadcast();
  final _dataReceived = StreamController<(Uint8Array, AppRemoteUser?)>.broadcast();
  final _activeSpeakers = StreamController<List<String>>.broadcast();
  final _trackSubscribed = StreamController<AppRemoteUser>.broadcast();
  final _trackUnsubscribed = StreamController<AppRemoteUser>.broadcast();
  final _giftReceived = StreamController<AppGiftEvent>.broadcast();
  final _message = StreamController<AppMessage>.broadcast();
  final _audienceChanged = StreamController<List<AppRemoteUser>>.broadcast();
  final _localVideoChanged = StreamController<void>.broadcast();
  final _remoteStats = StreamController<List<AppRemoteStats>>.broadcast();
  final _firstRemoteVideoFrame = StreamController<(String, int)>.broadcast();
  final _connectionStage = StreamController<(AppConnectionStage, String?, int)>.broadcast();
  final _videoQuality = StreamController<AppVideoQualityInfo>.broadcast();
  lk.EventsListener<lk.TrackEvent>? _localVideoListener;
  lk.Track? _watchedLocalVideo;
  AppVideoQualityInfo? _lastQuality;

  Stream<AppRemoteUser> get onUserJoined => _userJoined.stream;
  Stream<AppRemoteUser> get onUserLeft => _userLeft.stream;
  Stream<AppConnectionState> get onConnectionStateChanged => _connectionState.stream;

  /// Someone sent a message with [sendMessage].
  Stream<AppMessage> get onMessage => _message.stream;

  /// The audience changed — someone started or stopped watching.
  /// Carries the whole list, so a viewer count can be rendered from it directly.
  Stream<List<AppRemoteUser>> get onAudienceChanged => _audienceChanged.stream;

  /// Raw bytes from [sendData]. Platform frames are not reported here.
  Stream<(Uint8Array, AppRemoteUser?)> get onDataReceived => _dataReceived.stream;
  Stream<List<String>> get onActiveSpeakersChanged => _activeSpeakers.stream;

  /// A remote user's camera or microphone became available to render. Rebuild
  /// your video tiles on this — a user is announced before their track arrives.
  Stream<AppRemoteUser> get onTrackSubscribed => _trackSubscribed.stream;
  Stream<AppRemoteUser> get onTrackUnsubscribed => _trackUnsubscribed.stream;

  /// A virtual gift was broadcast to the channel.
  Stream<AppGiftEvent> get onGiftReceived => _giftReceived.stream;

  /// Your own camera track was (re)created — camera off→on, a switch, a
  /// settings change. `AppVideoView.local` rebuilds by itself; listen here for
  /// anything else that holds your preview.
  Stream<void> get onLocalVideoChanged => _localVideoChanged.stream;

  /// Per-remote-user media health every two seconds while joined.
  Stream<List<AppRemoteStats>> get onRemoteStats => _remoteStats.stream;

  /// The first decoded frame of a remote user's camera reached your screen:
  /// `(uid, elapsedMs since joinChannel)`. Resolved from receiver statistics,
  /// so it is reported within about two seconds of the frame.
  Stream<(String, int)> get onFirstRemoteVideoFrame => _firstRemoteVideoFrame.stream;

  /// Milestones with elapsed ms since [joinChannel]: `(stage, uid, elapsedMs)`.
  Stream<(AppConnectionStage, String?, int)> get onConnectionStage => _connectionStage.stream;

  /// The size, rate or layer your own camera is sending changed — the encoder
  /// stepped down for the network or the CPU, or came back up. Resolved from
  /// sender statistics while your camera is on.
  Stream<AppVideoQualityInfo> get onVideoQualityChanged => _videoQuality.stream;

  AppEngine._(this.appId, this.options) : _room = lk.Room(roomOptions: _roomOptions(options));

  static const _heights = [360, 540, 720, 1080, 1440];

  static int _snapHeight(int wanted) {
    var height = _heights.first;
    for (final h in _heights) {
      if ((h - wanted).abs() < (height - wanted).abs()) height = h;
    }
    return height;
  }

  static lk.VideoParameters _preset(int height) {
    switch (height) {
      case 360:
        return lk.VideoParametersPresets.h360_169;
      case 540:
        return lk.VideoParametersPresets.h540_169;
      case 720:
        return lk.VideoParametersPresets.h720_169;
      case 1440:
        return lk.VideoParametersPresets.h1440_169;
      default:
        return lk.VideoParametersPresets.h1080_169;
    }
  }

  /// Our own caps for the sharp end: the preset defaults were tuned for calls
  /// and leave 1080p visibly soft on a good link. 540p and below keep theirs.
  static int _defaultMaxBitrate(int height, lk.VideoParameters preset) {
    switch (height) {
      case 1440:
        return 5000000;
      case 1080:
        return 4000000;
      case 720:
        return 2200000;
      default:
        return preset.encoding?.maxBitrate ?? 1700000;
    }
  }

  static bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// The codec published for [config] once [AppVideoCodec.auto] is resolved.
  static String resolveCodec(AppVideoCodec c) {
    switch (c) {
      case AppVideoCodec.vp8:
        return 'vp8';
      case AppVideoCodec.h264:
        return 'h264';
      case AppVideoCodec.h265:
        // Every iPhone since the 7 encodes H.265 in hardware. On Android the
        // engine's encoder factory does not drive H.265 hardware, and Dart
        // cannot probe for it, so the auto choice is made instead.
        if (_isAndroid) {
          debugPrint('[AppLoomaRTC] AppVideoCodec.h265 is not available on Android; using auto');
          return resolveCodec(AppVideoCodec.auto);
        }
        return 'h265';
      case AppVideoCodec.av1:
        // No iPhone encodes AV1 in hardware, and Android phones that do are
        // rare and cannot be probed from Dart; software AV1 at camera sizes
        // would starve the CPU. The auto choice is made instead.
        debugPrint('[AppLoomaRTC] AppVideoCodec.av1 is not available on this platform; using auto');
        return resolveCodec(AppVideoCodec.auto);
      case AppVideoCodec.auto:
        // iOS encodes H.264 in hardware everywhere. On Android the engine only
        // drives Qualcomm/Exynos H.264 encoders; on MediaTek and other chips an
        // H.264 track is published but never carries a frame (viewers see
        // black — seen on realme/Infinix). Dart cannot inspect the codec list,
        // so Android publishes VP8, which works in hardware or software on
        // every phone. Pass AppVideoCodec.h264 explicitly on known-good devices.
        if (_isAndroid) return 'vp8';
        return 'h264';
    }
  }

  /// `auto` leaves the engine's per-source default (frame rate first for a camera).
  static lk.DegradationPreference? _degradation(AppVideoDegradation d) {
    switch (d) {
      case AppVideoDegradation.keepResolution:
        return lk.DegradationPreference.maintainResolution;
      case AppVideoDegradation.keepFramerate:
        return lk.DegradationPreference.maintainFramerate;
      case AppVideoDegradation.balanced:
        return lk.DegradationPreference.balanced;
      case AppVideoDegradation.auto:
        return null;
    }
  }

  static lk.RoomOptions _roomOptions(AppEngineOptions o) {
    final height = _snapHeight(o.video.height);
    if (height != o.video.height) {
      debugPrint('[AppLoomaRTC] AppVideoConfig.height=${o.video.height} is not a preset; using ${height}p');
    }
    if (o.video.maxBitrate > 0 && o.video.maxBitrate < 10000) {
      debugPrint('[AppLoomaRTC] AppVideoConfig.maxBitrate=${o.video.maxBitrate} is in bits per second — did you mean ${o.video.maxBitrate}000 (kbps)?');
    }
    final preset = _preset(height);
    // minBitrate: the engine's encoding carries no floor on this platform, so
    // AppVideoConfig.minBitrate is not applied here.
    final encoding = lk.VideoEncoding(
      maxBitrate: o.video.maxBitrate > 0 ? o.video.maxBitrate : _defaultMaxBitrate(height, preset),
      maxFramerate: o.video.fps,
    );
    final codec = resolveCodec(o.video.codec);
    return lk.RoomOptions(
      // Adaptive stream still down-shifts a remote layer for a small or hidden
      // view (good on weak links). Dynacast is OFF: with it on, a publisher
      // withholds a video layer until a subscriber's "viewing" signal arrives,
      // which on flaky links left co-hosts staring at a black frame.
      adaptiveStream: true,
      dynacast: false,
      defaultCameraCaptureOptions: lk.CameraCaptureOptions(params: preset),
      defaultVideoPublishOptions: lk.VideoPublishOptions(
        videoCodec: codec,
        videoEncoding: encoding,
        simulcast: o.video.simulcast,
        degradationPreference: _degradation(o.video.degradation),
        // Anything but VP8 rides with a VP8 backup layer, so a viewer whose
        // phone cannot decode the main stream is served VP8 by the server
        // instead of a black frame.
        backupVideoCodec: codec != 'vp8'
            ? lk.BackupVideoCodec(enabled: true, codec: 'vp8', simulcast: o.video.simulcast)
            : const lk.BackupVideoCodec(enabled: false),
      ),
      defaultAudioCaptureOptions: lk.AudioCaptureOptions(
        noiseSuppression: o.audio.noiseSuppression,
        echoCancellation: o.audio.echoCancellation,
        autoGainControl: o.audio.autoGainControl,
      ),
      defaultAudioPublishOptions: const lk.AudioPublishOptions(dtx: false),
    );
  }

  /// Platform audio session for a scenario. MEDIA keeps media attributes
  /// (loudspeaker, media volume keys) but runs Android in the communication
  /// audio mode, and iOS in playAndRecord + videoChat, so the phone's echo
  /// canceller stays engaged — plain media mode leaves it off and a
  /// loudspeaker session then feeds itself back after a minute or two.
  static lk.AudioSessionOptions _sessionOptions(AppAudioScenario s) {
    if (s == AppAudioScenario.call) return const lk.AudioSessionOptions.communication();
    return const lk.AudioSessionOptions.mediaPlayback(
      android: lk.AndroidAudioSessionConfiguration(
        audioMode: lk.AndroidAudioMode.inCommunication,
        manageAudioFocus: true,
        focusMode: lk.AndroidAudioFocusMode.gain,
        streamType: lk.AndroidAudioStreamType.music,
        usageType: lk.AndroidAudioAttributesUsageType.media,
        contentType: lk.AndroidAudioAttributesContentType.music,
      ),
      apple: lk.AppleAudioSessionConfiguration(
        category: lk.AppleAudioCategory.playAndRecord,
        categoryOptions: {
          lk.AppleAudioCategoryOption.defaultToSpeaker,
          lk.AppleAudioCategoryOption.allowBluetooth,
          lk.AppleAudioCategoryOption.allowBluetoothA2DP,
          lk.AppleAudioCategoryOption.mixWithOthers,
        },
        mode: lk.AppleAudioMode.videoChat,
      ),
    );
  }

  static Future<void>? _platformInit;
  static bool get _isMobile =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  /// WebRTC reads Android playout attributes once, when it creates its audio
  /// device module — so the first engine's scenario seeds them, before connect.
  static Future<void> _ensurePlatformInit(AppAudioScenario s) {
    return _platformInit ??= _isMobile
        ? lk.LiveKitClient.initialize(initialAudioSessionOptions: _sessionOptions(s))
        : Future.value();
  }

  /// Create an engine instance with your AppLooma RTC App ID.
  static AppEngine create({required String appId, AppEngineOptions options = const AppEngineOptions()}) {
    if (appId.isEmpty) {
      throw ArgumentError('AppEngine.create: appId is required');
    }
    return AppEngine._(appId, options);
  }

  /// The codec this phone publishes with, after [AppVideoCodec.auto] is resolved.
  String get publishedCodec => resolveCodec(options.video.codec);

  int _elapsed() => _joinStartedAt == null ? 0 : DateTime.now().difference(_joinStartedAt!).inMilliseconds;

  /// Join a channel with a token from your server
  /// (POST https://api.applooma.dev/v1/token → { token, wsUrl }).
  Future<void> joinChannel({
    required String token,
    required String wsUrl,
    AppJoinOptions options = const AppJoinOptions(),
  }) async {
    if (_joined) {
      throw StateError('Already in a channel — call leaveChannel() first');
    }
    _joinStartedAt = DateTime.now();
    await _ensurePlatformInit(this.options.audioScenario);
    if (_isMobile) {
      // Runtime session policy for this engine's scenario.
      try {
        await lk.AudioManager.instance.setAudioSessionOptions(_sessionOptions(this.options.audioScenario));
      } catch (e) {
        debugPrint('[AppLoomaRTC] audio session: $e');
      }
    }
    _wireEvents();
    // Auto-subscribe so an audience member (and every co-host) receives all
    // published tracks the moment they join.
    await _room.connect(wsUrl, token, connectOptions: const lk.ConnectOptions(autoSubscribe: true));
    _joined = true;
    _connectionStage.add((AppConnectionStage.connected, null, _elapsed()));

    // Participants already in the room when we join never produce a
    // "participant connected" event; without this an audience member joining a
    // live stream sees nobody and never receives the host's video.
    _seedExistingParticipants();
    _startStats();

    if (options.role != AppRole.audience) {
      if (options.microphone) {
        await _room.localParticipant?.setMicrophoneEnabled(true);
      }
      if (options.camera) {
        await _room.localParticipant?.setCameraEnabled(true);
      }
    }
  }

  Future<void> leaveChannel() async {
    _stopStats();
    await _room.disconnect();
    _joined = false;
    _users.clear();
  }

  // ---- Local media controls ----
  Future<void> enableCamera([bool on = true]) async {
    await _room.localParticipant?.setCameraEnabled(on);
    _localVideoChanged.add(null);
  }

  Future<void> enableMicrophone([bool on = true]) async =>
      _room.localParticipant?.setMicrophoneEnabled(on);

  bool _backCamera = false;

  /// Flip between the front and back cameras. Does nothing until the camera is
  /// on. Every [AppVideoView.local] follows the new track by itself.
  Future<void> switchCamera() async {
    final track = localVideoTrack;
    if (track is! lk.LocalVideoTrack) return;
    _backCamera = !_backCamera;
    await track.setCameraPosition(_backCamera ? lk.CameraPosition.back : lk.CameraPosition.front);
    _localVideoChanged.add(null);
  }

  Future<void> enableScreenShare([bool on = true]) async =>
      _room.localParticipant?.setScreenShareEnabled(on);

  /// Route audio to the loudspeaker (true) or the earpiece (false). A
  /// connected Bluetooth or wired headset keeps priority either way — this only
  /// decides between the phone's own outputs when no headset is present.
  ///
  /// Android 12+ needs the `BLUETOOTH_CONNECT` runtime permission for a
  /// Bluetooth headset to be seen at all; request it next to the microphone.
  Future<void> setSpeakerphone(bool on) async {
    if (!_isMobile) return;
    try {
      await lk.AudioManager.instance.setSpeakerOutputPreferred(on);
    } catch (e) {
      debugPrint('[AppLoomaRTC] setSpeakerphone: $e');
    }
  }

  /// The local camera track. Used by [AppVideoView]; application code should
  /// render with `AppVideoView.local(engine)` instead.
  @internal
  lk.VideoTrack? get localVideoTrack {
    final lp = _room.localParticipant;
    if (lp == null) return null;
    for (final pub in lp.videoTrackPublications) {
      final t = pub.track;
      if (t != null) return t;
    }
    return null;
  }

  /// Send a message to everyone in the channel.
  ///
  /// An audience member can call this even though they cannot publish video —
  /// which is what makes live comments on a broadcast work.
  ///
  /// Pass [text] for a comment or [data] for anything structured. Nothing is
  /// stored, so a message reaches whoever is present when it is sent.
  Future<AppMessage> sendMessage({
    String? text,
    Map<String, dynamic>? data,
    bool reliable = true,
  }) async {
    assert(text != null || data != null, 'sendMessage needs text or data');
    final message = AppMessage(
      id: _newId(),
      text: text,
      data: data,
      sentAt: DateTime.now(),
    );
    await sendData(
      utf8.encode(jsonEncode({
        'type': _messageType,
        'id': message.id,
        if (text != null) 'text': text,
        if (data != null) 'data': data,
        'sentAt': message.sentAt.toUtc().toIso8601String(),
      })),
      reliable: reliable,
    );
    return message;
  }

  /// Broadcast raw bytes. Prefer [sendMessage] unless you need your own format.
  Future<void> sendData(List<int> data, {bool reliable = true}) async {
    await _room.localParticipant?.publishData(
      data,
      reliable: reliable,
    );
  }

  // ---- State ----
  String? get localUid => _room.localParticipant?.identity;
  String? get channelName => _room.name;
  List<AppRemoteUser> get remoteUsers => List.unmodifiable(_users.values);

  /// Everyone watching without publishing. The live audience of a broadcast.
  List<AppRemoteUser> get audience =>
      List.unmodifiable(_users.values.where((u) => !u.isPublisher));

  /// How many people are watching.
  int get audienceCount => _users.values.where((u) => !u.isPublisher).length;

  /// Everyone on stage: the host and any co-hosts, excluding you.
  List<AppRemoteUser> get hosts =>
      List.unmodifiable(_users.values.where((u) => u.isPublisher));

  AppRemoteUser _userFor(lk.RemoteParticipant p) =>
      _users.putIfAbsent(p.identity, () => AppRemoteUser._(p));

  /// Announces everyone already present, and their already-published tracks.
  void _seedExistingParticipants() {
    for (final p in _room.remoteParticipants.values) {
      final user = _userFor(p);
      _userJoined.add(user);
      for (final pub in p.trackPublications.values) {
        final t = pub.track;
        if (t != null) {
          _trackSubscribed.add(user);
          _watchTrack(user, t);
        }
      }
    }
  }

  // ---- Remote health ----

  /// Fold a remote track's receiver statistics into that user's health record.
  void _watchTrack(AppRemoteUser user, lk.Track track) {
    final h = _health.putIfAbsent(user.uid, () => _RemoteHealth());
    final l = track.createListener();
    h.listeners.add(l);
    l
      ..on<lk.VideoReceiverStatsEvent>((e) {
        final s = e.stats;
        h.fps = (s.framesPerSecond ?? 0).round();
        h.width = (s.frameWidth ?? 0).toInt();
        h.height = (s.frameHeight ?? 0).toInt();
        h.vLost = (s.packetsLost ?? 0).toInt();
        if (!h.firstFrameReported && (s.framesDecoded ?? 0) > 0) {
          h.firstFrameReported = true;
          final ms = _elapsed();
          _firstRemoteVideoFrame.add((user.uid, ms));
          _connectionStage.add((AppConnectionStage.firstRemoteVideoFrame, user.uid, ms));
        }
      })
      ..on<lk.AudioReceiverStatsEvent>((e) {
        final s = e.stats;
        h.aLost = (s.packetsLost ?? 0).toInt();
        // jitter is reported in seconds.
        h.jitterMs = ((s.jitter ?? 0) * 1000).round();
      });
  }

  // ---- Own camera quality ----

  /// Follow the sender statistics of whatever local camera track is live, and
  /// report a change of size, layer or reason on [onVideoQualityChanged].
  void _watchLocalVideo() {
    final track = localVideoTrack;
    if (identical(track, _watchedLocalVideo)) return;
    _localVideoListener?.dispose();
    _localVideoListener = null;
    _watchedLocalVideo = track;
    _lastQuality = null;
    if (track == null) return;
    final l = track.createListener();
    _localVideoListener = l;
    l.on<lk.VideoSenderStatsEvent>((e) {
      final active = e.stats.values
          .where((s) => (s.framesPerSecond ?? 0) > 0 && (s.frameHeight ?? 0) > 0)
          .toList();
      if (active.isEmpty) return;
      var top = active.first;
      for (final s in active) {
        if ((s.frameHeight ?? 0) > (top.frameHeight ?? 0)) top = s;
      }
      final height = (top.frameHeight ?? 0).toInt();
      final q = AppVideoQualityInfo(
        width: (top.frameWidth ?? 0).toInt(),
        height: height,
        fps: (top.framesPerSecond ?? 0).round(),
        bitrateKbps: (e.currentBitrate / 1000).round(),
        layer: _layerOf(top.rid, height, _snapHeight(options.video.height)),
        reason: _reasonOf(top.qualityLimitationReason),
      );
      final prev = _lastQuality;
      _lastQuality = q;
      if (prev == null) return; // the first sample is the baseline, not a change
      final same = prev.width == q.width &&
          prev.height == q.height &&
          prev.layer == q.layer &&
          prev.reason == q.reason &&
          (prev.fps - q.fps).abs() < 5;
      if (!same) _videoQuality.add(q);
    });
  }

  /// Simulcast rid → layer; without a rid, by size relative to what was configured.
  static AppVideoLayer _layerOf(String? rid, int height, int configured) {
    switch (rid) {
      case 'f':
        return AppVideoLayer.high;
      case 'h':
        return AppVideoLayer.medium;
      case 'q':
        return AppVideoLayer.low;
    }
    if (height >= configured * 0.75) return AppVideoLayer.high;
    if (height >= configured * 0.4) return AppVideoLayer.medium;
    return AppVideoLayer.low;
  }

  static AppVideoQualityReason _reasonOf(String? r) {
    switch (r) {
      case 'bandwidth':
        return AppVideoQualityReason.bandwidth;
      case 'cpu':
        return AppVideoQualityReason.cpu;
      default:
        return AppVideoQualityReason.none;
    }
  }

  void _unwatch(String uid) {
    final h = _health.remove(uid);
    if (h == null) return;
    for (final l in h.listeners) {
      l.dispose();
    }
  }

  void _startStats() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_joined) return;
      // The local camera may have been swapped by a path that raised no
      // event; the tick keeps the quality watcher on the live track.
      _watchLocalVideo();
      final out = <AppRemoteStats>[];
      _health.forEach((uid, h) {
        final user = _users[uid];
        if (user == null) return;
        // A picture that had frames and now reports none has stalled.
        final hasVideo = user.hasVideo;
        if (hasVideo && h.fps == 0 && h.hadPicture) h.freezes++;
        if (hasVideo && h.fps > 0) h.hadPicture = true;
        out.add(AppRemoteStats(
          uid: uid,
          videoFps: h.fps,
          videoWidth: h.width,
          videoHeight: h.height,
          videoFreezeCount: h.freezes,
          videoPacketsLost: h.vLost,
          audioPacketsLost: h.aLost,
          audioJitterMs: h.jitterMs,
        ));
      });
      if (out.isNotEmpty) _remoteStats.add(out);
    });
  }

  void _stopStats() {
    _statsTimer?.cancel();
    _statsTimer = null;
    for (final uid in _health.keys.toList()) {
      _unwatch(uid);
    }
    _localVideoListener?.dispose();
    _localVideoListener = null;
    _watchedLocalVideo = null;
    _lastQuality = null;
  }

  void _wireEvents() {
    _listener?.dispose();
    final listener = _room.createListener();
    _listener = listener;

    listener
      ..on<lk.ParticipantConnectedEvent>((e) {
        _userJoined.add(_userFor(e.participant));
        _audienceChanged.add(audience);
      })
      ..on<lk.ParticipantDisconnectedEvent>((e) {
        final u = _users.remove(e.participant.identity);
        _unwatch(e.participant.identity);
        if (u != null) _userLeft.add(u);
        _audienceChanged.add(audience);
      })
      ..on<lk.RoomConnectedEvent>((_) {
        _connectionState.add(AppConnectionState.connected);
      })
      ..on<lk.RoomReconnectingEvent>((_) {
        _connectionState.add(AppConnectionState.reconnecting);
      })
      ..on<lk.RoomReconnectedEvent>((_) {
        // Track state can change while disconnected, so rebuild the roster.
        for (final uid in _health.keys.toList()) {
          _unwatch(uid);
        }
        _users.clear();
        _seedExistingParticipants();
        _connectionState.add(AppConnectionState.connected);
      })
      ..on<lk.TrackSubscribedEvent>((e) {
        final user = _userFor(e.participant);
        _trackSubscribed.add(user);
        _watchTrack(user, e.track);
      })
      ..on<lk.TrackUnsubscribedEvent>((e) {
        _trackUnsubscribed.add(_userFor(e.participant));
      })
      // Camera off→on keeps the publication and swaps the track underneath;
      // publish/unpublish/unmute of our own camera are the moments a
      // self-view must re-bind.
      ..on<lk.LocalTrackPublishedEvent>((_) {
        _localVideoChanged.add(null);
        _watchLocalVideo();
      })
      ..on<lk.LocalTrackUnpublishedEvent>((_) {
        _localVideoChanged.add(null);
        _watchLocalVideo();
      })
      ..on<lk.TrackMutedEvent>((e) {
        if (e.participant is lk.LocalParticipant) _localVideoChanged.add(null);
      })
      ..on<lk.TrackUnmutedEvent>((e) {
        if (e.participant is lk.LocalParticipant) _localVideoChanged.add(null);
      })
      ..on<lk.RoomDisconnectedEvent>((_) {
        _joined = false;
        _stopStats();
        // Report everyone as gone; a stale roster after a disconnect made
        // remoteUsers wrong until the next join.
        for (final u in _users.values) {
          _userLeft.add(u);
        }
        _users.clear();
        _connectionState.add(AppConnectionState.disconnected);
      })
      ..on<lk.DataReceivedEvent>((e) {
        final from = e.participant is lk.RemoteParticipant
            ? _userFor(e.participant as lk.RemoteParticipant)
            : null;

        // Each frame is either ours or the customer's, never both. Reporting
        // our own envelopes as raw data as well would deliver every comment
        // twice to anyone listening on both streams.
        dynamic frame;
        try {
          frame = jsonDecode(utf8.decode(e.data));
        } catch (_) {
          frame = null;
        }

        if (frame is Map && frame['type'] == _messageType) {
          _message.add(AppMessage(
            id: frame['id'] as String? ?? _newId(),
            text: frame['text'] as String?,
            data: frame['data'] is Map
                ? Map<String, dynamic>.from(frame['data'] as Map)
                : null,
            from: from,
            sentAt: DateTime.tryParse(frame['sentAt'] as String? ?? '') ??
                DateTime.now(),
          ));
          return;
        }
        if (frame is Map && frame['type'] == _giftType) {
          final gift = AppGiftEvent.fromJson(Map<String, dynamic>.from(frame));
          if (gift != null) _giftReceived.add(gift);
          return;
        }
        _dataReceived.add((Uint8Array.fromList(e.data), from));
      })
      ..on<lk.ActiveSpeakersChangedEvent>((e) {
        _activeSpeakers.add(e.speakers.map((s) => s.identity).toList());
      });
  }

  /// Release all resources.
  Future<void> dispose() async {
    await leaveChannel();
    await _listener?.dispose();
    await _userJoined.close();
    await _userLeft.close();
    await _connectionState.close();
    await _dataReceived.close();
    await _activeSpeakers.close();
    await _trackSubscribed.close();
    await _trackUnsubscribed.close();
    await _giftReceived.close();
    await _message.close();
    await _audienceChanged.close();
    await _localVideoChanged.close();
    await _remoteStats.close();
    await _firstRemoteVideoFrame.close();
    await _connectionStage.close();
    await _videoQuality.close();
    await _room.dispose();
  }

  /// internal — escape hatch for UIKits
  lk.Room get raw => _room;
}

/// Typed alias to keep the public API free of dart:typed_data imports for users.
typedef Uint8Array = Uint8List;
