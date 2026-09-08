import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:livekit_client/livekit_client.dart' as lk;

import 'applooma_types.dart';

/// A remote user in the channel.
class AppRemoteUser {
  final lk.RemoteParticipant _p;
  AppRemoteUser._(this._p);

  String get uid => _p.identity;
  String? get displayName => _p.name;
  String? get metadata => _p.metadata;
  bool get isSpeaking => _p.isSpeaking;
  bool get audioEnabled => _p.isMicrophoneEnabled();
  bool get videoEnabled => _p.isCameraEnabled();

  /// Video track for rendering (see AppVideoView).
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

  Stream<AppRemoteUser> get onUserJoined => _userJoined.stream;
  Stream<AppRemoteUser> get onUserLeft => _userLeft.stream;
  Stream<AppConnectionState> get onConnectionStateChanged => _connectionState.stream;
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
          roomOptions: const lk.RoomOptions(
            adaptiveStream: true,
            dynacast: true,
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
  lk.VideoTrack? get localVideoTrack {
    final lp = _room.localParticipant;
    if (lp == null) return null;
    for (final pub in lp.videoTrackPublications) {
      final t = pub.track;
      if (t != null) return t;
    }
    return null;
  }

  /// Broadcast data to the channel (chat, signals, gifts).
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
      })
      ..on<lk.ParticipantDisconnectedEvent>((e) {
        final u = _users.remove(e.participant.identity);
        if (u != null) _userLeft.add(u);
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
        _dataReceived.add((Uint8Array.fromList(e.data), from));
        // Platform events (gifts) arrive on the same channel as JSON.
        try {
          final msg = jsonDecode(utf8.decode(e.data));
          if (msg is Map && msg['type'] == 'applooma.gift') {
            final gift = AppGiftEvent.fromJson(Map<String, dynamic>.from(msg));
            if (gift != null) _giftReceived.add(gift);
          }
        } catch (_) {
          // Not JSON — ordinary user data.
        }
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
    await _room.dispose();
  }

  /// internal — escape hatch for UIKits
  lk.Room get raw => _room;
}

/// Typed alias to keep the public API free of dart:typed_data imports for users.
typedef Uint8Array = Uint8List;
