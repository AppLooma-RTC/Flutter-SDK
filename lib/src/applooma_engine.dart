import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:applooma_rtc_core/applooma_rtc_core.dart' as lk;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;

import 'applooma_diag.dart';
import 'applooma_types.dart';
import 'applooma_video_enhance.dart' show appSetClearVoice;

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
/// One message read back from stored chat (see [AppEngine.loadHistory]).
class AppStoredMessage {
  AppStoredMessage._({required this.id, required this.sender, this.senderName, this.text, this.data,
      required this.kind, required this.deleted, required this.createdAt});

  factory AppStoredMessage._fromJson(Map<String, dynamic> m) => AppStoredMessage._(
        id: m['id'] as String? ?? '',
        sender: m['sender'] as String? ?? '',
        senderName: m['senderName'] as String?,
        text: m['text'] as String?,
        data: (m['data'] as Map?)?.cast<String, dynamic>(),
        kind: m['kind'] as String? ?? 'text',
        deleted: m['deleted'] == true,
        createdAt: DateTime.tryParse(m['createdAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      );

  final String id;
  /// Who sent it, in your own identity space.
  final String sender;
  /// Their display name when they sent it.
  final String? senderName;
  /// Null when the message was recalled.
  final String? text;
  final Map<String, dynamic>? data;
  final String kind;
  /// True for a recalled message. It keeps its place in the thread.
  final bool deleted;
  /// Server time, safe to order by.
  final DateTime createdAt;
}

/// One page of stored chat, newest first. [nextBefore] is null when there is no older page.
class AppHistoryPage {
  const AppHistoryPage({required this.messages, this.nextBefore});
  final List<AppStoredMessage> messages;
  final DateTime? nextBefore;
}

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
/// A remote user's state change ([AppEngine.onUserStateChanged]).
class AppUserStateChange {
  final AppRemoteUser user;
  final AppUserState state;
  const AppUserStateChange(this.user, this.state);
}

/// A remote user's role change ([AppEngine.onUserRoleChanged]).
class AppUserRoleChange {
  final AppRemoteUser user;
  final AppRole oldRole;
  final AppRole newRole;
  const AppUserRoleChange(this.user, this.oldRole, this.newRole);
}

/// A remote user's leave with its reason ([AppEngine.onUserLeftWithReason]).
class AppUserLeave {
  final AppRemoteUser user;
  final AppLeaveReason reason;
  const AppUserLeave(this.user, this.reason);
}

class AppRemoteUser {
  lk.RemoteParticipant _p;
  AppRemoteUser._(this._p);

  /// Rebound when the same identity comes back after a drop (new transport participant, same user).
  void _rebind(lk.RemoteParticipant p) => _p = p;

  /// The role last reported to the app, to tell a real change from a metadata rewrite.
  AppRole? _lastKnownRole;

  /// Why this user left, once they have. Null while they are in the channel.
  AppLeaveReason? leaveReason;

  /// [AppUserState.active], or [AppUserState.reconnecting] while their dropped
  /// connection is inside the grace period.
  AppUserState state = AppUserState.active;

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
  // Automatic codec recovery, viewer side.
  DateTime? noFrameSince;
  DateTime? lastReportAt;
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
  final _userLeftWithReason = StreamController<AppUserLeave>.broadcast();
  final _userStateChanged = StreamController<AppUserStateChange>.broadcast();
  final _userRoleChanged = StreamController<AppUserRoleChange>.broadcast();
  final _usersResynced = StreamController<List<AppRemoteUser>>.broadcast();
  final _connectionState = StreamController<AppConnectionState>.broadcast();
  final _connectionChanged = StreamController<AppConnectionChange>.broadcast();
  AppConnectionState _connectionStateNow = AppConnectionState.disconnected;
  /// Remote users whose connection dropped and who are still inside remoteLeaveGraceMs.
  final _pendingLeaves = <String, Timer>{};
  /// True between reconnecting and reconnected: remote "disconnects" in that window are the transport's, not the users'.
  bool _rosterFrozen = false;
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
  final _codecFallback = StreamController<AppVideoCodecFallback>.broadcast();
  // Automatic codec recovery, publisher side.
  final _viewerReports = <String, DateTime>{};
  bool _fallbackUsed = false;
  String? _codecOverride;
  bool? _simulcastOverride;
  // Anonymous device reports: at most one per outcome and codec per join.
  String? _joinToken;
  final _reported = <String>{};
  lk.EventsListener<lk.TrackEvent>? _localVideoListener;
  lk.Track? _watchedLocalVideo;
  AppVideoQualityInfo? _lastQuality;
  // Network fallback (downlink = remote video, uplink = own camera).
  final _fallbackState = StreamController<AppFallbackState>.broadcast();
  AppFallbackOption _remoteFallback = AppFallbackOption.none;
  AppFallbackOption _localFallback = AppFallbackOption.none;
  final _downlinkHysteresis = AppFallbackHysteresis();
  final _uplinkHysteresis = AppFallbackHysteresis();
  AppFallbackOption _remoteInEffect = AppFallbackOption.none;
  AppFallbackOption _localInEffect = AppFallbackOption.none;
  final _lowered = <lk.RemoteTrackPublication>{};
  final _disabledByFallback = <lk.RemoteTrackPublication>{};
  final _savedBitrates = <int?>[];
  bool _cameraMutedByFallback = false;
  // Token renewal.
  final _tokenWillExpire = StreamController<String>.broadcast();
  final _proxyStateCtl = StreamController<AppProxyStateChange>.broadcast();
  Timer? _tokenTimer;
  // Network test.
  lk.Room? _testRoom;
  Timer? _testTimer;
  void Function(AppNetworkTestResult)? _testCallback;

  Stream<AppRemoteUser> get onUserJoined => _userJoined.stream;
  /// A remote user left. Not fired when *your own* connection drops. See also [onUserLeftWithReason].
  Stream<AppRemoteUser> get onUserLeft => _userLeft.stream;
  /// A remote user left, with why: [AppLeaveReason.quit] means on purpose,
  /// [AppLeaveReason.dropped] that their network failed for longer than the grace period.
  Stream<AppUserLeave> get onUserLeftWithReason => _userLeftWithReason.stream;
  /// A remote user's connection dropped ([AppUserState.reconnecting]) or came
  /// back ([AppUserState.active]) within [AppEngineOptions.remoteLeaveGraceMs].
  /// Show "weak network" on their tile; if they do not come back, [onUserLeft] follows.
  Stream<AppUserStateChange> get onUserStateChanged => _userStateChanged.stream;
  /// Another user's role changed without them leaving (promoted or demoted by your server).
  Stream<AppUserRoleChange> get onUserRoleChanged => _userRoleChanged.stream;
  /// After a reconnect: who is in the channel now. People who stayed are not announced again.
  Stream<List<AppRemoteUser>> get onUsersResynced => _usersResynced.stream;
  Stream<AppConnectionState> get onConnectionStateChanged => _connectionState.stream;
  /// Your own connection as one state machine, with why it changed:
  /// [AppConnectionReason.tokenExpired] means mint a new token,
  /// [AppConnectionReason.kicked] means your server removed you,
  /// [AppConnectionReason.networkLost] means show "Reconnecting…".
  Stream<AppConnectionChange> get onConnectionChanged => _connectionChanged.stream;
  /// The current connection state.
  AppConnectionState get connectionState => _connectionStateNow;

  void _setConnectionState(AppConnectionState state, AppConnectionReason reason) {
    if (_connectionStateNow == state && state != AppConnectionState.connected) return;
    _connectionStateNow = state;
    _diag.log('connection $state reason=$reason');
    _connectionState.add(state);
    _connectionChanged.add(AppConnectionChange(state, reason));
  }

  static AppConnectionReason _connectionReasonOf(lk.DisconnectReason? r) {
    switch (r) {
      case lk.DisconnectReason.clientInitiated: return AppConnectionReason.leaveChannel;
      case lk.DisconnectReason.duplicateIdentity: return AppConnectionReason.duplicateIdentity;
      case lk.DisconnectReason.participantRemoved: return AppConnectionReason.kicked;
      case lk.DisconnectReason.roomDeleted:
      case lk.DisconnectReason.serverShutdown: return AppConnectionReason.roomClosed;
      case lk.DisconnectReason.stateMismatch:
      case lk.DisconnectReason.signalClose: return AppConnectionReason.networkLost;
      case lk.DisconnectReason.joinFailure: return AppConnectionReason.joinFailed;
      default: return AppConnectionReason.unknown;
    }
  }

  static AppLeaveReason _leaveReasonOf(String? name) {
    switch (name) {
      case 'CLIENT_INITIATED': return AppLeaveReason.quit;
      case 'SIGNAL_CLOSE':
      case 'STATE_MISMATCH':
      case 'CONNECTION_TIMEOUT':
      case 'MIGRATION':
      case 'JOIN_FAILURE': return AppLeaveReason.dropped;
      case 'PARTICIPANT_REMOVED': return AppLeaveReason.kicked;
      case 'DUPLICATE_IDENTITY': return AppLeaveReason.duplicateIdentity;
      case 'ROOM_DELETED':
      case 'ROOM_CLOSED':
      case 'SERVER_SHUTDOWN': return AppLeaveReason.roomClosed;
      default: return AppLeaveReason.unknown;
    }
  }

  /// Whether a leave with this reason may be a drop the user comes back from.
  static bool _holdsForReturn(AppLeaveReason r) =>
      r == AppLeaveReason.dropped || r == AppLeaveReason.unknown || r == AppLeaveReason.duplicateIdentity;

  void _deliverUserLeft(AppRemoteUser u, AppLeaveReason reason) {
    u.leaveReason = reason;
    _userLeft.add(u);
    _userLeftWithReason.add(AppUserLeave(u, reason));
  }

  /// The grace period ran out: the dropped user is gone for real.
  void _expireLeave(String uid) {
    _pendingLeaves.remove(uid);
    final u = _users.remove(uid);
    if (u == null) return;
    _unwatch(uid);
    _diag.log('user left after grace uid=$uid');
    _deliverUserLeft(u, AppLeaveReason.dropped);
    _audienceChanged.add(audience);
  }

  /// A dropped user came back on a new transport participant: same person, no leave, no join.
  void _resumeUser(AppRemoteUser u, lk.RemoteParticipant p) {
    _pendingLeaves.remove(u.uid)?.cancel();
    u._rebind(p);
    u.state = AppUserState.active;
    u.leaveReason = null;
    _diag.log('user back within grace uid=${u.uid}');
    _userStateChanged.add(AppUserStateChange(u, AppUserState.active));
    for (final pub in p.trackPublications.values) {
      final t = pub.track;
      if (t != null) {
        _trackSubscribed.add(u);
        _watchTrack(u, t);
      }
    }
  }

  void _cancelPendingLeaves() {
    for (final t in _pendingLeaves.values) {
      t.cancel();
    }
    _pendingLeaves.clear();
  }

  /// After a reconnect: report who left while we were away (dropped) and who
  /// is new, without announcing again the people who stayed.
  void _resyncAfterReconnect() {
    final present = <String, lk.RemoteParticipant>{
      for (final p in _room.remoteParticipants.values) p.identity: p,
    };
    for (final u in _users.values) {
      final p = present[u.uid];
      if (p != null && !identical(u._p, p)) u._rebind(p);
    }
    for (final uid in _pendingLeaves.keys.toList()) {
      final u = _users[uid];
      final p = present[uid];
      if (u != null && p != null) {
        _resumeUser(u, p);
      } else {
        _pendingLeaves.remove(uid)?.cancel();
      }
    }
    final gone = _users.keys.where((uid) => !present.containsKey(uid)).toList();
    final added = present.keys.where((uid) => !_users.containsKey(uid)).toList();
    for (final uid in gone) {
      final u = _users.remove(uid);
      _unwatch(uid);
      if (u != null) _deliverUserLeft(u, AppLeaveReason.dropped);
    }
    for (final uid in added) {
      final p = present[uid]!;
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
    if (gone.isNotEmpty || added.isNotEmpty) {
      _diag.log('resync after reconnect: gone=${gone.length} added=${added.length}');
      _audienceChanged.add(audience);
    }
  }

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

  /// Automatic codec recovery republished your camera on a safer path
  /// because viewers were receiving it but could not show a picture. See
  /// [AppVideoCodecFallback]. At most once per join; nothing to do in the app.
  Stream<AppVideoCodecFallback> get onVideoCodecFallback => _codecFallback.stream;

  /// A network fallback set with [setRemoteSubscribeFallback] or
  /// [setLocalPublishFallback] took effect or was lifted.
  Stream<AppFallbackState> get onFallbackStateChanged => _fallbackState.stream;

  /// The join token expires in about 30 s (or already had less than that
  /// left at join). Fetch a new one from your server and pass it to
  /// [renewToken]. Carries the token that is about to expire.
  Stream<String> get onTokenWillExpire => _tokenWillExpire.stream;

  /// The cloud proxy state changed; see [AppEngineOptions.cloudProxy].
  Stream<AppProxyStateChange> get onProxyStateChanged => _proxyStateCtl.stream;

  AppEngine._(this.appId, this.options) : _room = lk.Room(roomOptions: _roomOptions(options));

  static const _heights = [360, 540, 720, 1080, 1440, 2160];

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
      case 2160:
        return lk.VideoParametersPresets.h2160_169;
      default:
        return lk.VideoParametersPresets.h1080_169;
    }
  }

  /// Our own caps. [AppVideoMode.adaptive] keeps the earlier sharp-end caps
  /// (the preset defaults were tuned for calls and leave 1080p visibly soft);
  /// 540p and below keep the preset's.
  static int _defaultMaxBitrate(int height, lk.VideoParameters preset, AppVideoMode mode, String codec) {
    switch (height) {
      case 2160:
        return codec == 'h265' ? 16000000 : 25000000;
      case 1440:
        return 5000000;
      case 1080:
        return mode == AppVideoMode.adaptive ? 4000000 : 3500000;
      case 720:
        return mode == AppVideoMode.adaptive ? 2200000 : 1800000;
      default:
        return preset.encoding?.maxBitrate ?? 1700000;
    }
  }

  static bool get _isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Whether this device can publish [AppVideoMode.ultraHd4k]. iOS: yes (every
  /// supported iPhone encodes 2160p in hardware). Android and web: no for now —
  /// Dart cannot check the encoders for a hardware 3840x2160 path, and a CPU
  /// encoder cannot hold it.
  static bool isUltraHdSupported() => _isIOS;

  /// The mode in force for [c], after an unsupported ultraHd4k falls back.
  static AppVideoMode _modeOf(AppVideoConfig c) =>
      c.mode == AppVideoMode.ultraHd4k && !isUltraHdSupported() ? AppVideoMode.stableHd : c.mode;

  /// The height [c] captures at on this device once the mode fills in the blanks.
  static int _heightOf(AppVideoConfig c) {
    if (c.height > 0) return _snapHeight(c.height);
    switch (_modeOf(c)) {
      case AppVideoMode.ultraHd4k:
        return 2160;
      case AppVideoMode.stableHd:
        // iOS encodes in hardware everywhere; Android may be on a CPU encoder.
        return _isIOS ? 1080 : 720;
      case AppVideoMode.adaptive:
        return 1080;
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
    if (o.video.mode == AppVideoMode.ultraHd4k && !isUltraHdSupported()) {
      debugPrint('[AppLoomaRTC] AppVideoMode.ultraHd4k is not supported on this device; using stableHd');
    }
    final mode = _modeOf(o.video);
    final height = _heightOf(o.video);
    if (o.video.height > 0 && height != o.video.height) {
      debugPrint('[AppLoomaRTC] AppVideoConfig.height=${o.video.height} is not a preset; using ${height}p');
    }
    if (o.video.maxBitrate > 0 && o.video.maxBitrate < 10000) {
      debugPrint('[AppLoomaRTC] AppVideoConfig.maxBitrate=${o.video.maxBitrate} is in bits per second — did you mean ${o.video.maxBitrate}000 (kbps)?');
    }
    final preset = _preset(height);
    // In ultraHd4k, auto prefers H.265 where the phone encodes it (iOS).
    final codec = o.video.codec == AppVideoCodec.auto && mode == AppVideoMode.ultraHd4k && _isIOS
        ? 'h265'
        : resolveCodec(o.video.codec);
    // minBitrate: the engine's encoding carries no floor on this platform, so
    // AppVideoConfig.minBitrate is not applied here. No start-bitrate hook is
    // exposed either; the encoder ramps up to the cap on its own.
    final encoding = lk.VideoEncoding(
      maxBitrate: o.video.maxBitrate > 0 ? o.video.maxBitrate : _defaultMaxBitrate(height, preset, mode, codec),
      maxFramerate: o.video.fps,
    );
    final simulcast = o.video.simulcast ?? mode == AppVideoMode.adaptive;
    // stableHd gives up a little resolution and frame rate while bandwidth
    // ramps up; holding full size from the first second started live streams
    // at a few frames per second. ultraHd4k still keeps resolution.
    final degradation = o.video.degradation != AppVideoDegradation.auto
        ? o.video.degradation
        : mode == AppVideoMode.adaptive
            ? AppVideoDegradation.auto
            : mode == AppVideoMode.ultraHd4k
                ? AppVideoDegradation.keepResolution
                : AppVideoDegradation.balanced;
    return lk.RoomOptions(
      // adaptive: adaptive stream down-shifts a remote layer for a small or
      // hidden view (good on weak links). stableHd / ultraHd4k turn it off so
      // a receiver keeps the full picture. Dynacast is OFF: with it on, a
      // publisher withholds a video layer until a subscriber's "viewing"
      // signal arrives, which on flaky links left co-hosts staring at a black
      // frame.
      adaptiveStream: mode == AppVideoMode.adaptive,
      dynacast: false,
      defaultCameraCaptureOptions: lk.CameraCaptureOptions(params: preset),
      defaultVideoPublishOptions: lk.VideoPublishOptions(
        videoCodec: codec,
        videoEncoding: encoding,
        simulcast: simulcast,
        degradationPreference: _degradation(degradation),
        // Anything but VP8 rides with a VP8 backup layer, so a viewer whose
        // phone cannot decode the main stream is served VP8 by the server
        // instead of a black frame.
        backupVideoCodec: codec != 'vp8'
            ? lk.BackupVideoCodec(enabled: true, codec: 'vp8', simulcast: simulcast)
            : const lk.BackupVideoCodec(enabled: false),
      ),
      defaultAudioCaptureOptions: lk.AudioCaptureOptions(
        noiseSuppression: o.audio.effectiveNoiseSuppression != AppNoiseSuppression.off,
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
        ? lk.AppLoomaClient.initialize(initialAudioSessionOptions: _sessionOptions(s))
        : Future.value();
  }

  /// Create an engine instance with your AppLooma RTC App ID.
  /// The video codecs this device can send and receive, from the media
  /// engine's own capability list. `hardware` is true for H.264 and H.265
  /// (offered only on a hardware encoder) and false for the rest, which the
  /// SDK cannot tell apart from Flutter. Empty on an unsupported platform.
  static Future<List<AppVideoCodecCapability>> getSupportedVideoCodecs() async {
    Future<Set<String>> mimes(String method) async {
      try {
        final r = await _mediaChannel.invokeMethod<dynamic>(method, <String, dynamic>{'kind': 'video'});
        final codecs = (r is Map ? r['codecs'] : null) as List? ?? const [];
        return codecs
            .whereType<Map>()
            .map((c) => (c['mimeType'] ?? '').toString())
            .where((m) => m.startsWith('video/') && !const {'video/rtx', 'video/red', 'video/ulpfec', 'video/flexfec-03'}.contains(m.toLowerCase()))
            .map((m) => m.toUpperCase().replaceFirst('VIDEO/', 'video/'))
            .toSet();
      } catch (_) {
        return <String>{};
      }
    }

    final enc = await mimes('getRtpSenderCapabilities');
    final dec = await mimes('getRtpReceiverCapabilities');
    const order = ['video/VP8', 'video/VP9', 'video/H264', 'video/H265', 'video/AV1'];
    final all = {...enc, ...dec}.toList()..sort((a, b) => (order.indexOf(a) & 0xff).compareTo(order.indexOf(b) & 0xff));
    return [
      for (final m in all)
        AppVideoCodecCapability(
          mime: m,
          hardware: enc.contains(m) && (m == 'video/H264' || m == 'video/H265'),
          encoder: enc.contains(m),
          decoder: dec.contains(m),
        ),
    ];
  }

  /// The media engine's own method channel (a contract with the engine plugin).
  static const _mediaChannel = MethodChannel('FlutterWebRTC.Method');

  static AppEngine create({required String appId, AppEngineOptions options = const AppEngineOptions()}) {
    if (appId.isEmpty) {
      throw ArgumentError('AppEngine.create: appId is required');
    }
    return AppEngine._(appId, options);
  }

  /// The codec this phone publishes with, after [AppVideoCodec.auto] is resolved.
  String get publishedCodec => _codecOverride ?? _DeviceVideoConfig.codec(options.video.codec, _configuredCodec, _deviceVideo);

  String get _configuredCodec => options.video.codec == AppVideoCodec.auto && _modeOf(options.video) == AppVideoMode.ultraHd4k && _isIOS
      ? 'h265'
      : resolveCodec(options.video.codec);

  int _elapsed() => _joinStartedAt == null ? 0 : DateTime.now().difference(_joinStartedAt!).inMilliseconds;

  /// Join a channel with a token from your server
  /// (POST https://api.applooma.dev/v1/token → { token, wsUrl }).
  static bool _isAppLoomaHost(String url) {
    final h = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    return h == 'applooma.dev' || h.endsWith('.applooma.dev');
  }

  /// Per attempt. The API answers in well under a second; a dead region no longer holds it.
  static const routeTimeout = Duration(seconds: 3);
  static const routeAttempts = 2;

  /// Asks the API for the best media server for this device. Never throws;
  /// falls back to [wsUrl]. Everyone in a channel must land on the same media
  /// server and the API pins the room on the first routed join, so a device
  /// that gives up on the route and connects to the token's URL can end up
  /// alone on another server. The route is therefore tried twice and a final
  /// failure is logged as a warning.
  Future<String> _resolveWsUrl(String token, String wsUrl) async {
    if (!_isAppLoomaHost(wsUrl)) return wsUrl;
    for (var attempt = 0; attempt < routeAttempts; attempt++) {
      final r = await _routeOnce(token);
      if (r == _routeRefused) return wsUrl;
      if (r != null) return r;
    }
    debugPrint('[AppLoomaRTC] smart routing failed after $routeAttempts attempts; '
        'connecting to the token\'s server. If others in this channel were routed elsewhere they will not see each other.');
    _diagLog('warning: route failed; using the token\'s server');
    return wsUrl;
  }

  static const _routeRefused = '\u0000refused';

  /// One attempt: the routed URL, [_routeRefused] on a 4xx (retrying cannot help), or null on failure.
  Future<String?> _routeOnce(String token) async {
    final client = io.HttpClient()..connectionTimeout = routeTimeout;
    try {
      return await () async {
        final req = await client.postUrl(Uri.parse('${_DeviceReports._apiBase}/rtc/route'));
        req.headers.contentType = io.ContentType.json;
        req.headers.set('Accept', 'application/json');
        req.write(jsonEncode({'token': token}));
        final res = await req.close();
        final text = await res.transform(utf8.decoder).join();
        if (res.statusCode >= 400 && res.statusCode < 500) return _routeRefused;
        if (res.statusCode != 200) return null;
        final body = jsonDecode(text);
        final next = body is Map ? body['wsUrl'] : null;
        if (next is! String) return null;
        final scheme = Uri.tryParse(next)?.scheme.toLowerCase();
        if ((scheme != 'wss' && scheme != 'ws') || !_isAppLoomaHost(next)) return null;
        return next;
      }().timeout(routeTimeout);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> joinChannel({
    required String token,
    required String wsUrl,
    AppJoinOptions options = const AppJoinOptions(),
  }) async {
    if (_joined) {
      throw StateError('Already in a channel — call leaveChannel() first');
    }
    _joinStartedAt = DateTime.now();
    _fallbackUsed = false;
    _viewerReports.clear();
    _joinToken = token;
    _reported.clear();
    _armTokenTimer();
    _diag.enabled = this.options.remoteDiagnostics;
    _diag.begin(token);
    // Device tuning: fetched in the background (3 s timeout) and read when
    // the camera is published, so a join never waits for it.
    _deviceFetch = _fetchDeviceConfig(token);
    _diagLog('join: region=${this.options.region.value} codec=$publishedCodec role=${options.role.name} camera=${options.camera} mic=${options.microphone}');
    await _ensurePlatformInit(this.options.audioScenario);
    if (_isMobile) {
      // Runtime session policy for this engine's scenario.
      try {
        await lk.AudioManager.instance.setAudioSessionOptions(_sessionOptions(this.options.audioScenario));
      } catch (e) {
        debugPrint('[AppLoomaRTC] audio session: ${AppLoomaException.cleanMessage(e)}');
      }
    }
    _wireEvents();
    // Auto-subscribe so an audience member (and every co-host) receives all
    // published tracks the moment they join.
    if (options.smartRouting) {
      final routed = await _resolveWsUrl(token, wsUrl);
      if (routed != wsUrl) _diag.log('server ${Uri.parse(routed).host}');
      wsUrl = routed;
    }
    final epoch = _joinEpoch;
    _setConnectionState(AppConnectionState.connecting, AppConnectionReason.joinSuccess);
    try {
      await _connectWithProxy(wsUrl, token, epoch);
    } catch (e) {
      if (epoch != _joinEpoch) {
        // leaveChannel() was called before the join finished: the user left.
        _diag.log('join abandoned: left before connected');
        throw AppLoomaException('Left the channel before the join finished', code: 'JOIN_ABANDONED', cause: e);
      }
      _diag.log('join failed: ${e.runtimeType}: $e');
      _diag.problem('join_failed');
      _diag.end('join failed');
      _setConnectionState(AppConnectionState.failed, AppConnectionReason.joinFailed);
      throw AppLoomaException.wrap(e);
    }
    if (epoch != _joinEpoch) {
      // Left while the connect was finishing: do not stay in the room as a
      // second copy of this user (it would push the real session out).
      _diag.log('join abandoned: left while connecting; disconnecting');
      try {
        await _room.disconnect();
      } catch (_) {}
      throw AppLoomaException('Left the channel before the join finished', code: 'JOIN_ABANDONED');
    }
    _joined = true;
    _diag.log('connected in ${_elapsed()} ms');
    _setConnectionState(AppConnectionState.connected, AppConnectionReason.joinSuccess);
    await _holdClearVoice(this.options.audio.effectiveNoiseSuppression == AppNoiseSuppression.clear);
    _connectionStage.add((AppConnectionStage.connected, null, _elapsed()));

    // Participants already in the room when we join never produce a
    // "participant connected" event; without this an audience member joining a
    // live stream sees nobody and never receives the host's video.
    _seedExistingParticipants();
    _startStats();

    // Audience latency: no receive-side jitter-buffer control here, so only
    // STANDARD acts, by preferring lower video layers under congestion.
    if (options.role == AppRole.audience &&
        this.options.audienceLatency == AppAudienceLatency.standard &&
        _remoteFallback == AppFallbackOption.none) {
      _remoteFallback = AppFallbackOption.videoLowQuality;
    }

    if (options.role != AppRole.audience) {
      if (options.microphone) {
        await _room.localParticipant?.setMicrophoneEnabled(true);
      }
      if (options.camera) {
        try {
          await _deviceFetch?.timeout(const Duration(seconds: 1));
        } catch (_) {}
        await _publishCamera();
      }
    }
  }

  /// Bumped by leaveChannel(); a join that sees it change was abandoned, not failed.
  int _joinEpoch = 0;

  Future<void> leaveChannel() async {
    _joinEpoch++;
    _cancelPendingLeaves();
    _setConnectionState(AppConnectionState.disconnected, AppConnectionReason.leaveChannel);
    _diag.end('leave');
    _tokenTimer?.cancel();
    _tokenTimer = null;
    _resetFallbackState();
    _stopStats();
    await _room.disconnect();
    _joined = false;
    _users.clear();
    _setProxyState(AppProxyState.direct, false);
    await _holdClearVoice(false);
  }

  // ---- Clear Voice ----

  /// Engines in a channel with [AppNoiseSuppression.clear]. The capture
  /// post-processing stage is shared by every engine in the process, so it
  /// stays on while any of them wants it.
  static int _clearVoiceUsers = 0;
  bool _clearVoiceHeld = false;

  Future<void> _holdClearVoice(bool hold) async {
    if (hold == _clearVoiceHeld) return;
    _clearVoiceHeld = hold;
    _clearVoiceUsers += hold ? 1 : -1;
    final on = _clearVoiceUsers > 0;
    final ok = await appSetClearVoice(on);
    if (hold) _diagLog('clear voice ${ok ? 'on' : 'unavailable'}');
  }

  // ---- Cloud proxy ----

  AppProxyState _proxy = AppProxyState.direct;

  /// True only while the failed direct attempt is torn down before a proxy retry.
  bool _proxyRetrying = false;

  /// Current cloud proxy state; see [AppEngineOptions.cloudProxy].
  AppProxyState get proxyState => _proxy;

  void _setProxyState(AppProxyState state, bool autoRetry) {
    if (state == _proxy) return;
    _proxy = state;
    _diagLog('cloud proxy ${state.name}${autoRetry ? ' (auto retry)' : ''}');
    if (!_proxyStateCtl.isClosed) _proxyStateCtl.add(AppProxyStateChange(state: state, autoRetry: autoRetry));
  }

  /// Whether a failed direct join is worth one retry through the relay: a
  /// connection or network timeout, not a refused token.
  @visibleForTesting
  static bool isProxyRetryable(Object e) {
    final text = '${e.runtimeType} $e';
    if (RegExp(r'401|403|unauthori[sz]ed|forbidden|permission|invalid token|token is expired|not allowed|already', caseSensitive: false).hasMatch(text)) {
      return false;
    }
    return RegExp(r'time[d ]?out|network|transport|\bice\b|connection|connect|unreachable|socket|peer', caseSensitive: false).hasMatch(text);
  }

  Future<void> _connectWithProxy(String wsUrl, String token, [int? epoch]) async {
    final mode = options.cloudProxy;
    // Relay-only: media goes through the relay the server hands out (TLS on 443).
    const relay = lk.ConnectOptions(
      autoSubscribe: true,
      rtcConfiguration: lk.RTCConfiguration(iceTransportPolicy: lk.RTCIceTransportPolicy.relay),
    );
    if (mode == AppCloudProxy.forceTls443) {
      _setProxyState(AppProxyState.connecting, false);
      try {
        await _room.connect(wsUrl, token, connectOptions: relay);
      } catch (_) {
        _setProxyState(AppProxyState.direct, false);
        rethrow;
      }
      _setProxyState(AppProxyState.connected, false);
      return;
    }
    try {
      await _room.connect(wsUrl, token, connectOptions: const lk.ConnectOptions(autoSubscribe: true));
    } catch (e) {
      if (mode != AppCloudProxy.auto || (epoch != null && epoch != _joinEpoch) || !isProxyRetryable(e)) rethrow;
      _diagLog('direct join failed ($e); retrying once through the cloud proxy on TLS 443');
      debugPrint('[AppLoomaRTC] Direct connection failed; retrying through the AppLooma cloud proxy (TLS 443)');
      // Tear down the failed direct attempt without the app seeing a
      // disconnect; the event is delivered asynchronously, so let it drain
      // while the flag still hides it.
      _proxyRetrying = true;
      try {
        try {
          await _room.disconnect();
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 300));
      } finally {
        _proxyRetrying = false;
      }
      _setProxyState(AppProxyState.connecting, true);
      try {
        await _room.connect(wsUrl, token, connectOptions: relay);
      } catch (_) {
        _setProxyState(AppProxyState.direct, true);
        rethrow;
      }
      _setProxyState(AppProxyState.connected, true);
    }
  }

  // ---- Device tuning ----

  /// Last good answer of GET /v1/sdk/device-config, process-wide and kept in
  /// memory only (no storage plugin), so the first join after a cold start
  /// uses it only once the fetch has returned.
  static _DeviceVideoConfig? _deviceVideo;
  static DateTime? _deviceVideoAt;
  Future<void>? _deviceFetch;

  Future<void> _fetchDeviceConfig(String token) async {
    final at = _deviceVideoAt;
    final cached = _deviceVideo;
    if (at != null && cached != null && DateTime.now().difference(at).inSeconds < cached.ttlSeconds) return;
    final client = io.HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final q = 'platform=flutter&sdkVersion=${Uri.encodeQueryComponent(_DeviceReports._sdkVersion)}'
          '&osVersion=${Uri.encodeQueryComponent(_DeviceReports._clean(io.Platform.operatingSystemVersion, 32))}'
          '&region=${Uri.encodeQueryComponent(options.region.value)}';
      final req = await client.getUrl(Uri.parse('${_DeviceReports._apiBase}/sdk/device-config?$q')).timeout(const Duration(seconds: 3));
      req.headers.set('Authorization', 'Bearer $token');
      req.headers.set('Accept', 'application/json');
      final res = await req.close().timeout(const Duration(seconds: 3));
      final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) return;
      final cfg = _DeviceVideoConfig.parse(jsonDecode(text));
      if (cfg == null) return;
      _deviceVideo = cfg;
      _deviceVideoAt = DateTime.now();
      _diagLog('device tuning: $cfg');
    } catch (_) {
      // keep the last good answer
    } finally {
      client.close(force: true);
    }
  }

  /// Publishes the camera with the device tuning applied. Room options are
  /// fixed when the engine is created, so the caps go into this publish's
  /// capture and publish options instead. An existing (muted) camera is
  /// simply turned back on.
  Future<void> _publishCamera() async {
    final lp = _room.localParticipant;
    if (lp == null) return;
    final cfg = _deviceVideo;
    if (cfg == null || cfg.isEmpty || lp.getTrackPublicationBySource(lk.TrackSource.camera) != null) {
      await lp.setCameraEnabled(true);
      _localVideoChanged.add(null);
      return;
    }
    final base = _room.roomOptions.defaultVideoPublishOptions;
    final baseEnc = base.videoEncoding;
    var height = _heightOf(options.video);
    if (cfg.maxHeight > 0 && height > cfg.maxHeight) {
      height = [2160, 1440, 1080, 720, 540, 360].firstWhere((h) => h <= cfg.maxHeight, orElse: () => 360);
    }
    final preset = _preset(height);
    final fps0 = baseEnc?.maxFramerate ?? options.video.fps;
    final fps = cfg.maxFps > 0 && fps0 > cfg.maxFps ? cfg.maxFps : fps0;
    final br0 = baseEnc?.maxBitrate ?? preset.encoding?.maxBitrate ?? 0;
    final capBps = cfg.maxBitrateKbps * 1000;
    final bitrate = capBps > 0 && (br0 == 0 || br0 > capBps) ? capBps : br0;
    final codec = publishedCodec;
    final simulcast = (_simulcastOverride ?? base.simulcast) && !cfg.disableSimulcast;
    final publish = base.copyWith(
      videoCodec: codec,
      videoEncoding: lk.VideoEncoding(maxBitrate: bitrate, maxFramerate: fps),
      simulcast: simulcast,
      backupVideoCodec: codec == 'vp8'
          ? const lk.BackupVideoCodec(enabled: false)
          : lk.BackupVideoCodec(enabled: true, codec: 'vp8', simulcast: simulcast),
    );
    final capture = lk.CameraCaptureOptions(
      cameraPosition: _backCamera ? lk.CameraPosition.back : lk.CameraPosition.front,
      params: preset,
      maxFrameRate: fps.toDouble(),
    );
    _diagLog('camera publish with device tuning: ${height}p ${fps}fps ${bitrate ~/ 1000}kbps codec=$codec simulcast=$simulcast');
    final track = await lk.LocalVideoTrack.createCameraTrack(capture);
    await lp.publishVideoTrack(track, publishOptions: publish);
    _localVideoChanged.add(null);
  }

  // ---- Local media controls ----
  Future<void> enableCamera([bool on = true]) => _guard(() async {
        if (on) {
          await _publishCamera();
        } else {
          await _room.localParticipant?.setCameraEnabled(false);
        }
        _localVideoChanged.add(null);
      });

  Future<void> enableMicrophone([bool on = true]) => _guard(() async {
        final lp = _room.localParticipant;
        if (lp == null) return;
        if (on || !options.audio.releaseMicrophoneOnMute) {
          await lp.setMicrophoneEnabled(on);
          return;
        }
        // Real mute: unpublish and stop the track so the device is released.
        lk.LocalTrackPublication? pub;
        for (final p in lp.audioTrackPublications) {
          if (p.source == lk.TrackSource.microphone) pub = p;
        }
        if (pub == null) {
          await lp.setMicrophoneEnabled(false);
          return;
        }
        await lp.removePublishedTrack(pub.sid);
        _diagLog('microphone released (releaseMicrophoneOnMute)');
      });

  /// Runs [body], rethrowing any transport error as an [AppLoomaException].
  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (e, st) {
      Error.throwWithStackTrace(AppLoomaException.wrap(e), st);
    }
  }

  bool _backCamera = false;

  /// Flip between the front and back cameras. Does nothing until the camera is
  /// on. Every [AppVideoView.local] follows the new track by itself.
  Future<void> switchCamera() async {
    final track = localVideoTrack;
    if (track is! lk.LocalVideoTrack) return;
    _backCamera = !_backCamera;
    await _guard(() => track.setCameraPosition(_backCamera ? lk.CameraPosition.back : lk.CameraPosition.front));
    _localVideoChanged.add(null);
  }

  Future<void> enableScreenShare([bool on = true]) =>
      _guard(() async => _room.localParticipant?.setScreenShareEnabled(on));

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
      debugPrint('[AppLoomaRTC] setSpeakerphone: ${AppLoomaException.cleanMessage(e)}');
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
  /// Reads stored chat for the channel you joined, newest first. Only
  /// messages your server stored through the chat API are returned;
  /// [sendMessage] is not stored. Uses the join token, so no server of yours
  /// is involved. Pass [AppHistoryPage.nextBefore] as [before] for the older
  /// page. Throws [AppLoomaException] (code `CHAT_NOT_IN_PLAN` when the plan
  /// has no stored chat).
  Future<AppHistoryPage> loadHistory({int? limit, DateTime? before}) async {
    final token = _joinToken;
    if (token == null) throw StateError('Join a channel before loading its history');
    final query = <String, String>{
      if (limit != null) 'limit': '$limit',
      if (before != null) 'before': before.toUtc().toIso8601String(),
    };
    final uri = Uri.parse('${_DeviceReports._apiBase}/chat/history').replace(queryParameters: query.isEmpty ? null : query);
    final client = io.HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(uri);
      req.headers.set('Authorization', 'Bearer $token');
      final res = await req.close().timeout(const Duration(seconds: 15));
      final text = await res.transform(utf8.decoder).join();
      Map<String, dynamic> body;
      try {
        body = (jsonDecode(text) as Map).cast<String, dynamic>();
      } catch (_) {
        body = <String, dynamic>{};
      }
      if (res.statusCode < 200 || res.statusCode > 299) {
        throw AppLoomaException(
          (body['error'] as String?) ?? 'Could not load history (${res.statusCode})',
          code: (body['code'] as String?) ?? 'HISTORY_FAILED',
        );
      }
      final list = (body['messages'] as List?) ?? const [];
      return AppHistoryPage(
        messages: list.map((m) => AppStoredMessage._fromJson((m as Map).cast<String, dynamic>())).toList(),
        nextBefore: body['nextBefore'] == null ? null : DateTime.parse(body['nextBefore'] as String),
      );
    } finally {
      client.close();
    }
  }

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
    await _guard(() async => _room.localParticipant?.publishData(
          data,
          reliable: reliable,
        ));
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
        layer: _layerOf(top.rid, height, _heightOf(options.video)),
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
      _tickFallback();
      final out = <AppRemoteStats>[];
      _health.forEach((uid, h) {
        final user = _users[uid];
        if (user == null) return;
        // A picture that had frames and now reports none has stalled.
        final hasVideo = user.hasVideo;
        if (hasVideo && h.fps == 0 && h.hadPicture) h.freezes++;
        if (hasVideo && h.fps > 0) h.hadPicture = true;
        _checkUndecodable(user, h);
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
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastDiagStatsAt >= 10000) {
        _lastDiagStatsAt = now;
        var minFps = -1;
        var freezes = 0;
        for (final s in out) {
          if (minFps < 0 || s.videoFps < minFps) minFps = s.videoFps.round();
          freezes += s.videoFreezeCount;
        }
        _diag.log('stats codec=$publishedCodec camera=${localVideoTrack != null} remotes=${out.length} minRemoteFps=$minFps freezes=$freezes');
      }
    });
  }

  /// Remote diagnostics ring and uploader (see [uploadDiagnostics]).
  late final DiagCollector _diag = DiagCollector(
    sdkVersion: _DeviceReports._sdkVersion,
    apiBase: _DeviceReports._apiBase,
    region: () => options.region.value,
  );
  int _lastDiagStatsAt = 0;

  /// SDK log line: kept in the diagnostics ring, and printed in debug builds.
  void _diagLog(String line) {
    _diag.log(line);
    debugPrint('[AppLoomaRTC] $line');
  }

  /// Upload this device's recent SDK log lines to AppLooma support now (or
  /// with the next join when not in a channel), for example from a "report a
  /// problem" button. [reason] is a short label you choose. Only SDK-produced
  /// lines are sent, scrubbed of names, metadata, tokens and URL parameters;
  /// never audio, video or messages. Does nothing when
  /// [AppEngineOptions.remoteDiagnostics] is false.
  void uploadDiagnostics(String reason) {
    try {
      _diag.request(reason);
    } catch (_) {}
  }

  /// Reserved data topics: anything starting with `_al.` is SDK-internal and
  /// never reaches [onMessage] or [onDataReceived].
  static const _internalTopicPrefix = '_al.';
  static const _videoReportTopic = '_al.vq';

  /// Viewer side of automatic codec recovery: a subscribed, enabled camera
  /// whose sender has it on, decoding nothing for more than 6 s. Tell that
  /// publisher only, at most once per 20 s.
  void _checkUndecodable(AppRemoteUser user, _RemoteHealth h) {
    final now = DateTime.now();
    lk.RemoteTrackPublication? pub;
    for (final p in user._p.videoTrackPublications) {
      pub = p;
      break;
    }
    final live = pub != null && pub.subscribed && pub.enabled && !pub.muted;
    if (!live || h.fps > 0) {
      h.noFrameSince = null;
      return;
    }
    final since = h.noFrameSince ??= now;
    if (now.difference(since).inMilliseconds <= 6000) return;
    final last = h.lastReportAt;
    if (last != null && now.difference(last).inMilliseconds < 20000) return;
    h.lastReportAt = now;
    final body = utf8.encode(jsonEncode({'v': 1, 't': 'no_frames', 'codec': pub.mimeType}));
    _room.localParticipant
        ?.publishData(body, reliable: true, topic: _videoReportTopic, destinationIdentities: [user.uid])
        .catchError((Object _) {});
  }

  void _reportDevice(String outcome, String codec, {String? fromCodec, String? toCodec}) {
    if (!_reported.add('$outcome:$codec')) return;
    _DeviceReports.send(_joinToken, outcome, codec,
        fromCodec: fromCodec, toCodec: toCodec, region: options.region.value);
  }

  /// Publisher side: a viewer reports no picture from our camera.
  void _onVideoReport(List<int> data, lk.RemoteParticipant? from) {
    if (from == null) return;
    dynamic msg;
    try {
      msg = jsonDecode(utf8.decode(data));
    } catch (_) {
      return;
    }
    if (msg is! Map || msg['t'] != 'no_frames') return;
    final track = localVideoTrack;
    if (track == null || track.muted) return;
    final now = DateTime.now();
    _viewerReports[from.identity] = now;
    _viewerReports.removeWhere((_, at) => now.difference(at).inMilliseconds > 20000);
    // Two distinct viewers within 20 s, or the only other person in a 1:1.
    _reportDevice('viewers_cannot_decode', publishedCodec);
    _diag.log('viewer uid=${from.identity} reports no picture codec=$publishedCodec');
    _diag.problem('no_frames');
    if (_viewerReports.length >= 2 || _room.remoteParticipants.length <= 1) {
      _fallBack(AppVideoCodecFallbackReason.viewersCannotDecode).catchError((Object e) {
        _diagLog('codec recovery failed: ${e.runtimeType}');
      });
    }
  }

  /// Republish the camera on a safer path: VP8 when it was on anything else,
  /// otherwise once more as a single layer. At most once per join.
  Future<void> _fallBack(AppVideoCodecFallbackReason reason) async {
    if (_fallbackUsed) return;
    final lp = _room.localParticipant;
    final old = localVideoTrack;
    if (lp == null || old is! lk.LocalVideoTrack) return;
    lk.LocalTrackPublication? pub;
    for (final p in lp.videoTrackPublications) {
      if (identical(p.track, old)) pub = p;
    }
    if (pub == null) return;
    _fallbackUsed = true;
    final from = publishedCodec;
    String to;
    if (from != 'vp8') {
      _codecOverride = 'vp8';
      to = 'vp8';
    } else {
      _simulcastOverride = false;
      to = 'vp8:single';
    }
    _diagLog('codec recovery: $from -> $to (${reason.value})');
    _diag.problem('fallback');
    _reportDevice('fallback', from, fromCodec: from, toCodec: 'vp8');
    final capture = old.currentOptions is lk.CameraCaptureOptions
        ? old.currentOptions as lk.CameraCaptureOptions
        : lk.CameraCaptureOptions(params: _preset(_heightOf(options.video)));
    final publish = _room.roomOptions.defaultVideoPublishOptions.copyWith(
      videoCodec: publishedCodec,
      simulcast: _simulcastOverride,
      backupVideoCodec: publishedCodec == 'vp8' ? const lk.BackupVideoCodec(enabled: false) : null,
    );
    await lp.removePublishedTrack(pub.sid);
    final fresh = await lk.LocalVideoTrack.createCameraTrack(capture);
    await lp.publishVideoTrack(fresh, publishOptions: publish);
    _localVideoChanged.add(null);
    _watchLocalVideo();
    _codecFallback.add(AppVideoCodecFallback(from: from, to: to, reason: reason));
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
        final uid = e.participant.identity;
        final pending = _pendingLeaves.containsKey(uid) ? _users[uid] : null;
        if (pending != null) {
          _resumeUser(pending, e.participant);
        } else {
          _diag.log('user joined uid=$uid');
          _userJoined.add(_userFor(e.participant));
        }
        _audienceChanged.add(audience);
      })
      ..on<lk.ParticipantDisconnectedEvent>((e) {
        final uid = e.participant.identity;
        if (_rosterFrozen) {
          // While *we* are reconnecting the transport drops every remote
          // participant and re-adds them on return. Nobody actually left;
          // _resyncAfterReconnect reports whoever really did.
          _diag.log('user disconnect during our reconnect held: uid=$uid');
          return;
        }
        final u = _users[uid];
        if (u != null && identical(u._p, e.participant)) {
          // The server's reason, kept on the participant by the transport core (2.13.2+).
          final reason = _leaveReasonOf(e.participant.lastDisconnectReason?.name);
          final grace = options.remoteLeaveGraceMs;
          if (grace > 0 && _holdsForReturn(reason) && !_pendingLeaves.containsKey(uid)) {
            _diag.log('user dropped uid=$uid; holding ${grace ~/ 1000} s');
            u.state = AppUserState.reconnecting;
            _pendingLeaves[uid] = Timer(Duration(milliseconds: grace), () => _expireLeave(uid));
            _userStateChanged.add(AppUserStateChange(u, AppUserState.reconnecting));
          } else {
            _pendingLeaves.remove(uid)?.cancel();
            _users.remove(uid);
            _unwatch(uid);
            _diag.log('user left uid=$uid reason=$reason');
            _deliverUserLeft(u, reason);
          }
        }
        _audienceChanged.add(audience);
      })
      // A promotion or demotion rewrites the token metadata; for a remote
      // user that is onUserRoleChanged.
      ..on<lk.ParticipantMetadataUpdatedEvent>((e) {
        final p = e.participant;
        if (p is lk.RemoteParticipant) {
          final u = _userFor(p);
          final old = u._lastKnownRole ?? u.role;
          final now = u.role;
          u._lastKnownRole = now;
          if (old != now) _userRoleChanged.add(AppUserRoleChange(u, old, now));
          _audienceChanged.add(audience);
        }
      })
      ..on<lk.RoomReconnectingEvent>((_) {
        _diag.log('reconnecting');
        _diag.reconnecting();
        _rosterFrozen = true;
        _setConnectionState(AppConnectionState.reconnecting, AppConnectionReason.networkLost);
      })
      ..on<lk.RoomReconnectedEvent>((_) {
        _diag.log('reconnected');
        _rosterFrozen = false;
        _resyncAfterReconnect();
        _setConnectionState(AppConnectionState.connected, AppConnectionReason.networkRestored);
        _usersResynced.add(List.unmodifiable(_users.values));
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
      ..on<lk.RoomDisconnectedEvent>((e) {
        if (_proxyRetrying) {
          _diag.log('disconnect of the failed direct attempt ignored (retrying through the cloud proxy)');
          return;
        }
        _diag.log('disconnected reason=${e.reason?.name}');
        _diag.end('disconnected');
        _joined = false;
        _tokenTimer?.cancel();
        _resetFallbackState();
        _stopStats();
        // Our own connection ended; the others are most likely still in the
        // channel, so nobody is reported as left. The roster is cleared so
        // remoteUsers is not stale.
        _rosterFrozen = false;
        _cancelPendingLeaves();
        _users.clear();
        var why = _connectionReasonOf(e.reason);
        // A reconnect that gave up ends with no transport reason: it was the network.
        if (why == AppConnectionReason.unknown && _connectionStateNow == AppConnectionState.reconnecting) {
          why = AppConnectionReason.networkLost;
        }
        _setConnectionState(AppConnectionState.disconnected, why);
      })
      ..on<lk.DataReceivedEvent>((e) {
        // SDK-internal traffic never reaches the app.
        final topic = e.topic;
        if (topic != null && topic.startsWith(_internalTopicPrefix)) {
          if (topic == _videoReportTopic) _onVideoReport(e.data, e.participant);
          return;
        }
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

  // ---- Token renewal ----

  /// The `exp` claim (seconds since epoch) of a join token, or null.
  static int? tokenExpiry(String token) {
    final parts = token.split('.');
    if (parts.length < 2) return null;
    try {
      final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      final exp = payload is Map ? payload['exp'] : null;
      return exp is num ? exp.toInt() : null;
    } catch (_) {
      return null;
    }
  }

  void _armTokenTimer() {
    _tokenTimer?.cancel();
    _tokenTimer = null;
    final token = _joinToken;
    if (token == null) return;
    final exp = tokenExpiry(token);
    if (exp == null) return;
    final fireAt = DateTime.fromMillisecondsSinceEpoch(exp * 1000).subtract(const Duration(seconds: 30));
    var wait = fireAt.difference(DateTime.now());
    if (wait.isNegative) wait = Duration.zero;
    _tokenTimer = Timer(wait, () {
      if (!_tokenWillExpire.isClosed) _tokenWillExpire.add(token);
    });
  }

  /// Replace the join token the SDK keeps and re-arm [onTokenWillExpire].
  ///
  /// While connected, the media server already refreshes the live
  /// connection's own credential; the renewed token is what the SDK uses for
  /// its own later calls (reports). When not joined it is stored only — the
  /// next [joinChannel] takes its own token.
  void renewToken(String token) {
    if (token.isEmpty) return;
    _joinToken = token;
    _diag.updateToken(token);
    _diag.log('join token renewed');
    if (_joined) _armTokenTimer();
  }

  // ---- Network fallback ----

  /// What to give up for remote video when YOUR downlink is weak: poor or
  /// lost connection quality for 4 s falls back, good or excellent for 10 s
  /// restores.
  ///
  /// [AppFallbackOption.videoLowQuality] asks for the low layer of every
  /// remote camera (best effort: only publishers sending several layers have
  /// one, and in [AppVideoMode.adaptive] a smaller view size still wins).
  /// [AppFallbackOption.audioOnly] stops receiving remote video until the
  /// network recovers; cameras you turned off yourself stay off.
  void setRemoteSubscribeFallback(AppFallbackOption option) {
    _remoteFallback = option;
    if (_remoteInEffect != AppFallbackOption.none && _remoteInEffect != option) {
      _restoreRemote();
      _downlinkHysteresis.reset();
    }
  }

  /// What to give up for your own camera when YOUR uplink is weak (same
  /// timing as [setRemoteSubscribeFallback]).
  ///
  /// [AppFallbackOption.videoLowQuality] lowers the camera's bitrate cap to
  /// 30 % (at least 300 kbps). [AppFallbackOption.audioOnly] pauses the
  /// camera (it stays published) and resumes it on recovery.
  void setLocalPublishFallback(AppFallbackOption option) {
    _localFallback = option;
    if (_localInEffect != AppFallbackOption.none && _localInEffect != option) {
      _restoreLocal();
      _uplinkHysteresis.reset();
    }
  }

  void _tickFallback() {
    final q = _room.localParticipant?.connectionQuality ?? lk.ConnectionQuality.unknown;
    final bad = q == lk.ConnectionQuality.poor || q == lk.ConnectionQuality.lost;
    final good = q == lk.ConnectionQuality.good || q == lk.ConnectionQuality.excellent;
    final now = DateTime.now();
    if (_remoteFallback != AppFallbackOption.none) {
      final fallen = _downlinkHysteresis.update(bad: bad, good: good, now: now);
      if (fallen && _remoteInEffect == AppFallbackOption.none) {
        _applyRemote(_remoteFallback);
      } else if (!fallen && _remoteInEffect != AppFallbackOption.none) {
        _restoreRemote();
      } else if (fallen) {
        _applyRemote(_remoteInEffect, announce: false); // cameras subscribed since
      }
    }
    if (_localFallback != AppFallbackOption.none) {
      final fallen = _uplinkHysteresis.update(bad: bad, good: good, now: now);
      if (fallen && _localInEffect == AppFallbackOption.none) {
        _applyLocal(_localFallback);
      } else if (!fallen && _localInEffect != AppFallbackOption.none) {
        _restoreLocal();
      }
    }
  }

  void _applyRemote(AppFallbackOption option, {bool announce = true}) {
    for (final p in _room.remoteParticipants.values) {
      for (final pub in p.videoTrackPublications) {
        if (!pub.subscribed) continue;
        if (option == AppFallbackOption.videoLowQuality) {
          if (_lowered.add(pub)) pub.setVideoQuality(lk.VideoQuality.LOW).catchError((Object _) {});
        } else if (option == AppFallbackOption.audioOnly) {
          // Only cameras that are on; one the app disabled stays the app's.
          if (pub.enabled && _disabledByFallback.add(pub)) pub.disable().catchError((Object _) {});
        }
      }
    }
    if (announce) {
      _remoteInEffect = option;
      _fallbackState.add(AppFallbackState(isLocal: false, state: option));
    }
  }

  void _restoreRemote() {
    for (final pub in _lowered) {
      pub.setVideoQuality(lk.VideoQuality.HIGH).catchError((Object _) {});
    }
    for (final pub in _disabledByFallback) {
      pub.enable().catchError((Object _) {});
    }
    _lowered.clear();
    _disabledByFallback.clear();
    if (_remoteInEffect != AppFallbackOption.none) {
      _remoteInEffect = AppFallbackOption.none;
      if (!_fallbackState.isClosed) {
        _fallbackState.add(const AppFallbackState(isLocal: false, state: AppFallbackOption.none));
      }
    }
  }

  void _applyLocal(AppFallbackOption option) {
    final track = localVideoTrack;
    if (track is! lk.LocalVideoTrack) return;
    if (option == AppFallbackOption.videoLowQuality) {
      final sender = track.sender;
      if (sender == null) return;
      final params = sender.parameters;
      final encodings = params.encodings ?? [];
      _savedBitrates
        ..clear()
        ..addAll(encodings.map((e) => e.maxBitrate));
      for (final e in encodings) {
        final cap = e.maxBitrate;
        if (cap != null && cap > 0) {
          final lowered = (cap * 0.3).round();
          e.maxBitrate = lowered >= 300000 ? lowered : (cap < 300000 ? cap : 300000);
        }
      }
      params.encodings = encodings;
      sender.setParameters(params).catchError((Object _) => false);
    } else if (option == AppFallbackOption.audioOnly) {
      if (track.muted) return;
      _cameraMutedByFallback = true;
      track.mute(stopOnMute: false).catchError((Object _) => false);
    }
    _localInEffect = option;
    _fallbackState.add(AppFallbackState(isLocal: true, state: option));
  }

  void _restoreLocal() {
    final track = localVideoTrack;
    if (_localInEffect == AppFallbackOption.videoLowQuality && track is lk.LocalVideoTrack) {
      final sender = track.sender;
      if (sender != null && _savedBitrates.isNotEmpty) {
        final params = sender.parameters;
        final encodings = params.encodings ?? [];
        for (var i = 0; i < encodings.length && i < _savedBitrates.length; i++) {
          encodings[i].maxBitrate = _savedBitrates[i];
        }
        params.encodings = encodings;
        sender.setParameters(params).catchError((Object _) => false);
      }
    }
    if (_cameraMutedByFallback && track is lk.LocalVideoTrack && track.muted) {
      track.unmute(stopOnMute: false).catchError((Object _) => false);
    }
    _cameraMutedByFallback = false;
    _savedBitrates.clear();
    if (_localInEffect != AppFallbackOption.none) {
      _localInEffect = AppFallbackOption.none;
      if (!_fallbackState.isClosed) {
        _fallbackState.add(const AppFallbackState(isLocal: true, state: AppFallbackOption.none));
      }
    }
  }

  void _resetFallbackState() {
    _downlinkHysteresis.reset();
    _uplinkHysteresis.reset();
    _lowered.clear();
    _disabledByFallback.clear();
    _savedBitrates.clear();
    _cameraMutedByFallback = false;
    _remoteInEffect = AppFallbackOption.none;
    _localInEffect = AppFallbackOption.none;
  }

  // ---- Network test ----

  static AppNetworkQuality _qualityOf(lk.ConnectionQuality q) {
    switch (q) {
      case lk.ConnectionQuality.excellent:
        return AppNetworkQuality.excellent;
      case lk.ConnectionQuality.good:
        return AppNetworkQuality.good;
      case lk.ConnectionQuality.poor:
        return AppNetworkQuality.poor;
      case lk.ConnectionQuality.lost:
        return AppNetworkQuality.lost;
      case lk.ConnectionQuality.unknown:
        return AppNetworkQuality.unknown;
    }
  }

  /// Measure the network on a short, separate test connection (about 5 s,
  /// 10 s at most) and call [callback] once with the result.
  ///
  /// Mint [token] for a throwaway channel (e.g. `nettest-<uid>`); the test
  /// never touches the channel this engine is in, but running it before
  /// [joinChannel] gives the cleanest numbers. Nothing is published, so loss
  /// and jitter cover only what the test connection itself carries; uplink
  /// and downlink quality both come from the server's grade of the test
  /// connection.
  Future<void> startNetworkTest(
    String serverUrl,
    String token,
    void Function(AppNetworkTestResult result) callback,
  ) async {
    await stopNetworkTest();
    final room = lk.Room();
    _testRoom = room;
    _testCallback = callback;
    var worst = AppNetworkQuality.unknown;
    var latest = AppNetworkQuality.unknown;
    final listener = room.createListener()
      ..on<lk.ParticipantConnectionQualityUpdatedEvent>((e) {
        if (e.participant is! lk.LocalParticipant) return;
        latest = _qualityOf(e.connectionQuality);
        if (latest != AppNetworkQuality.unknown &&
            (worst == AppNetworkQuality.unknown || latest.index > worst.index)) {
          worst = latest;
        }
      });

    Future<void> finish(AppNetworkTestResult r) async {
      if (!identical(_testRoom, room)) return;
      _testTimer?.cancel();
      _testTimer = null;
      final cb = _testCallback;
      _testRoom = null;
      _testCallback = null;
      await listener.dispose();
      try {
        await room.disconnect();
        await room.dispose();
      } catch (_) {}
      cb?.call(r);
    }

    _testTimer = Timer(const Duration(seconds: 10), () {
      finish(const AppNetworkTestResult(error: 'network test timed out'));
    });
    try {
      await room.connect(serverUrl, token).timeout(const Duration(seconds: 9));
    } catch (e) {
      await finish(AppNetworkTestResult(error: 'network test could not connect: ${AppLoomaException.cleanMessage(e)}'));
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 5));
    if (!identical(_testRoom, room)) return;
    final stats = await _transportStats(room);
    final now = latest != AppNetworkQuality.unknown
        ? latest
        : _qualityOf(room.localParticipant?.connectionQuality ?? lk.ConnectionQuality.unknown);
    final grade = worst != AppNetworkQuality.unknown && worst.index > now.index ? worst : now;
    await finish(AppNetworkTestResult(
      uplinkQuality: grade,
      downlinkQuality: grade,
      rttMs: stats.$1,
      jitterMs: stats.$2,
      uplinkLoss: stats.$3,
      downlinkLoss: stats.$4,
    ));
  }

  /// Cancel a running [startNetworkTest]; its callback is not called.
  Future<void> stopNetworkTest() async {
    _testTimer?.cancel();
    _testTimer = null;
    final room = _testRoom;
    _testRoom = null;
    _testCallback = null;
    if (room == null) return;
    try {
      await room.disconnect();
      await room.dispose();
    } catch (_) {}
  }

  /// (rttMs, jitterMs, uplinkLoss, downlinkLoss) from the test connection's
  /// transports. Best effort.
  static Future<(int, int, double, double)> _transportStats(lk.Room room) async {
    var rtt = -1;
    var jitter = 0.0;
    num sent = 0, sentLost = 0, received = 0, receivedLost = 0;
    num toNum(dynamic v) => v is num ? v : num.tryParse('$v') ?? 0;
    // The transports are not public API; reading their statistics is the only
    // way to measure a connection that publishes nothing.
    // ignore: invalid_use_of_internal_member
    for (final t in [room.engine.publisher, room.engine.subscriber]) {
      if (t == null) continue;
      try {
        final reports = await t.pc.getStats();
        for (final r in reports) {
          final v = r.values;
          switch (r.type) {
            case 'candidate-pair':
              final cur = v['currentRoundTripTime'];
              if ((v['nominated'] == true || v['state'] == 'succeeded') && cur != null) {
                final ms = (toNum(cur) * 1000).round();
                if (ms > 0 && (rtt < 0 || ms < rtt)) rtt = ms;
              }
            case 'outbound-rtp':
              sent += toNum(v['packetsSent']);
            case 'remote-inbound-rtp':
              sentLost += toNum(v['packetsLost']);
            case 'inbound-rtp':
              received += toNum(v['packetsReceived']);
              receivedLost += toNum(v['packetsLost']);
              final j = toNum(v['jitter']) * 1000;
              if (j > jitter) jitter = j.toDouble();
          }
        }
      } catch (_) {
        // Stats are best effort.
      }
    }
    double ratio(num lost, num ok) => lost + ok > 0 ? (lost / (lost + ok)).clamp(0, 1).toDouble() : 0;
    return (rtt, jitter.round(), ratio(sentLost, sent), ratio(receivedLost, received));
  }


  /// Release all resources.
  Future<void> dispose() async {
    await stopNetworkTest();
    await leaveChannel();
    await _listener?.dispose();
    await _userJoined.close();
    await _userLeft.close();
    await _userLeftWithReason.close();
    await _userStateChanged.close();
    await _userRoleChanged.close();
    await _usersResynced.close();
    await _connectionChanged.close();
    _cancelPendingLeaves();
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
    await _codecFallback.close();
    await _fallbackState.close();
    await _tokenWillExpire.close();
    await _proxyStateCtl.close();
    await _room.dispose();
  }

  /// internal — escape hatch for UIKits
  lk.Room get raw => _room;
}

/// Typed alias to keep the public API free of dart:typed_data imports for users.
typedef Uint8Array = Uint8List;


/// Anonymous reports of how the video encoder behaved on this phone
/// (POST /v1/sdk/device-report). Fire-and-forget; every error is swallowed.
class _DeviceReports {
  static const _sdkVersion = '0.5.1';
  static const _apiBase = 'https://api.applooma.dev/v1';

  static String _clean(String? s, int max) {
    final v = (s ?? '').replaceAll(RegExp(r'[^A-Za-z0-9 ._\-+/(),:#]'), ' ').trim();
    final t = v.length > max ? v.substring(0, max).trim() : v;
    return t.isEmpty ? 'unknown' : t;
  }

  static void send(String? token, String outcome, String codec,
      {String? fromCodec, String? toCodec, String? region}) {
    if (token == null || token.isEmpty) return;
    () async {
      final client = io.HttpClient()..connectionTimeout = const Duration(seconds: 3);
      try {
        final android = io.Platform.isAndroid;
        final report = <String, String>{
          'sdkPlatform': 'flutter',
          'sdkVersion': _sdkVersion,
          'osName': android ? 'Android' : (io.Platform.isIOS ? 'iOS' : _clean(io.Platform.operatingSystem, 32)),
          'osVersion': _clean(io.Platform.operatingSystemVersion, 32),
          // The phone's make and model are not readable from Dart alone.
          'manufacturer': android ? 'unknown' : 'Apple',
          'model': 'unknown',
          'codec': codec,
          'outcome': outcome,
          if (fromCodec != null) 'fromCodec': fromCodec,
          if (toCodec != null) 'toCodec': toCodec,
          if (region != null) 'region': region,
        };
        final req = await client.postUrl(Uri.parse('$_apiBase/sdk/device-report')).timeout(const Duration(seconds: 3));
        req.headers.set('Authorization', 'Bearer $token');
        req.headers.contentType = io.ContentType.json;
        req.write(jsonEncode({'reports': [report]}));
        final res = await req.close().timeout(const Duration(seconds: 3));
        await res.drain<void>();
      } catch (_) {
        // Telemetry never affects a call.
      } finally {
        client.close(force: true);
      }
    }();
  }
}


/// Per-device video overrides from GET /v1/sdk/device-config (the same
/// fields the other SDKs read). Every field is optional. `denyHardware` is
/// not applied: Dart cannot choose the phone's encoder.
class _DeviceVideoConfig {
  final String? forceCodec;
  final String? preferCodec;
  final int maxHeight;
  final int maxFps;
  final int maxBitrateKbps;
  final bool disableSimulcast;
  final int ttlSeconds;

  const _DeviceVideoConfig({
    this.forceCodec,
    this.preferCodec,
    this.maxHeight = 0,
    this.maxFps = 0,
    this.maxBitrateKbps = 0,
    this.disableSimulcast = false,
    this.ttlSeconds = 3600,
  });

  bool get isEmpty =>
      forceCodec == null && preferCodec == null && maxHeight == 0 && maxFps == 0 && maxBitrateKbps == 0 && !disableSimulcast;

  static const _codecs = {'vp8', 'h264', 'h265'};

  static _DeviceVideoConfig? parse(Object? root) {
    if (root is! Map) return null;
    final ttlRaw = root['ttlSeconds'];
    final ttl = ttlRaw is num && ttlRaw > 0 ? ttlRaw.toInt() : 3600;
    final v = root['video'];
    if (v is! Map) return _DeviceVideoConfig(ttlSeconds: ttl);
    String? codec(String key) {
      final c = v[key];
      if (c is! String) return null;
      final l = c.toLowerCase();
      if (!_codecs.contains(l)) return null;
      // H.265 is published on iOS only (see resolveCodec).
      if (l == 'h265' && !io.Platform.isIOS) return null;
      return l;
    }

    int positive(String key) {
      final n = v[key];
      return n is num && n > 0 ? n.toInt() : 0;
    }

    return _DeviceVideoConfig(
      forceCodec: codec('forceCodec'),
      preferCodec: codec('preferCodec'),
      maxHeight: positive('maxHeight'),
      maxFps: positive('maxFps'),
      maxBitrateKbps: positive('maxBitrateKbps'),
      disableSimulcast: v['disableSimulcast'] == true,
      ttlSeconds: ttl,
    );
  }

  /// forceCodec always wins; preferCodec only replaces the auto choice.
  static String codec(AppVideoCodec app, String resolved, _DeviceVideoConfig? cfg) {
    if (cfg == null) return resolved;
    if (cfg.forceCodec != null) return cfg.forceCodec!;
    if (app == AppVideoCodec.auto && cfg.preferCodec != null) return cfg.preferCodec!;
    return resolved;
  }

  @override
  String toString() =>
      'force=$forceCodec prefer=$preferCodec maxHeight=$maxHeight maxFps=$maxFps maxKbps=$maxBitrateKbps noSimulcast=$disableSimulcast';
}
