import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:applooma_rtc_core/applooma_rtc_core.dart' as lk;
import 'package:meta/meta.dart';

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

  /// Video track for rendering (see AppVideoView).
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

/// Main entry point of the AppLooma RTC SDK.
class AppEngine {
  final String appId;
  final lk.Room _room;
  lk.EventsListener<lk.RoomEvent>? _listener;
  final _users = <String, AppRemoteUser>{};
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

  AppEngine._(this.appId)
      : _room = lk.Room(
          // 1080p with simulcast so each viewer gets the layer their screen
          // and link can take; 96 kbps voice with redundancy and no DTX.
          roomOptions: const lk.RoomOptions(
            adaptiveStream: true,
            dynacast: true,
            defaultCameraCaptureOptions: lk.CameraCaptureOptions(
              params: lk.VideoParametersPresets.h1080_169,
            ),
            defaultVideoPublishOptions: lk.VideoPublishOptions(
              videoEncoding: lk.VideoEncoding(maxBitrate: 3500000, maxFramerate: 30),
              simulcast: true,
            ),
            defaultAudioCaptureOptions: lk.AudioCaptureOptions(
              noiseSuppression: true,
              echoCancellation: true,
              autoGainControl: true,
            ),
            defaultAudioPublishOptions: lk.AudioPublishOptions(dtx: false),
          ),
        );

  /// Create an engine instance with your AppLooma RTC App ID.
  static AppEngine create({required String appId}) {
    if (appId.isEmpty) {
      throw ArgumentError('AppEngine.create: appId is required');
    }
    return AppEngine._(appId);
  }

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
    _wireEvents();
    await _room.connect(wsUrl, token);
    _joined = true;

    // Participants already in the room when we join never produce a
    // "participant connected" event; without this an audience member joining a
    // live stream sees nobody and never receives the host's video.
    _seedExistingParticipants();

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
    await _room.disconnect();
    _joined = false;
    _users.clear();
  }

  // ---- Local media controls ----
  Future<void> enableCamera([bool on = true]) async =>
      _room.localParticipant?.setCameraEnabled(on);

  Future<void> enableMicrophone([bool on = true]) async =>
      _room.localParticipant?.setMicrophoneEnabled(on);

  Future<void> enableScreenShare([bool on = true]) async =>
      _room.localParticipant?.setScreenShareEnabled(on);

  /// Local camera preview track (see AppVideoView.local).
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
        if (pub.track != null) _trackSubscribed.add(user);
      }
    }
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
        if (u != null) _userLeft.add(u);
        _audienceChanged.add(audience);
      })
      ..on<lk.RoomConnectedEvent>((_) {
        _connectionState.add(AppConnectionState.connected);
      })
      ..on<lk.RoomReconnectingEvent>((_) {
        _connectionState.add(AppConnectionState.reconnecting);
      })
      ..on<lk.TrackSubscribedEvent>((e) {
        _trackSubscribed.add(_userFor(e.participant));
      })
      ..on<lk.TrackUnsubscribedEvent>((e) {
        _trackUnsubscribed.add(_userFor(e.participant));
      })
      ..on<lk.RoomDisconnectedEvent>((_) {
        _joined = false;
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
    await _room.dispose();
  }

  /// internal — escape hatch for UIKits
  lk.Room get raw => _room;
}

/// Typed alias to keep the public API free of dart:typed_data imports for users.
typedef Uint8Array = Uint8List;
