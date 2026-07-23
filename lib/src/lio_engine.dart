import 'dart:async';
import 'dart:typed_data';

import 'package:livekit_client/livekit_client.dart' as lk;

import 'lio_types.dart';

/// A remote user in the channel.
class LioRemoteUser {
  final lk.RemoteParticipant _p;
  LioRemoteUser._(this._p);

  String get uid => _p.identity;
  String? get displayName => _p.name;
  String? get metadata => _p.metadata;
  bool get isSpeaking => _p.isSpeaking;
  bool get audioEnabled => _p.isMicrophoneEnabled();
  bool get videoEnabled => _p.isCameraEnabled();

  /// Video track for rendering (see LioVideoView).
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

/// Main entry point of the Lio Live SDK.
class LioEngine {
  final String appId;
  final lk.Room _room;
  lk.EventsListener<lk.RoomEvent>? _listener;
  final _users = <String, LioRemoteUser>{};
  bool _joined = false;

  // Event streams
  final _userJoined = StreamController<LioRemoteUser>.broadcast();
  final _userLeft = StreamController<LioRemoteUser>.broadcast();
  final _connectionState = StreamController<LioConnectionState>.broadcast();
  final _dataReceived = StreamController<(Uint8Array, LioRemoteUser?)>.broadcast();
  final _activeSpeakers = StreamController<List<String>>.broadcast();

  Stream<LioRemoteUser> get onUserJoined => _userJoined.stream;
  Stream<LioRemoteUser> get onUserLeft => _userLeft.stream;
  Stream<LioConnectionState> get onConnectionStateChanged => _connectionState.stream;
  Stream<(Uint8Array, LioRemoteUser?)> get onDataReceived => _dataReceived.stream;
  Stream<List<String>> get onActiveSpeakersChanged => _activeSpeakers.stream;

  LioEngine._(this.appId)
      : _room = lk.Room(
          roomOptions: const lk.RoomOptions(
            adaptiveStream: true,
            dynacast: true,
          ),
        );

  /// Create an engine instance with your Lio Live App ID.
  static LioEngine create({required String appId}) {
    if (appId.isEmpty) {
      throw ArgumentError('LioEngine.create: appId is required');
    }
    return LioEngine._(appId);
  }

  /// Join a channel with a token from your server
  /// (POST https://api.liolive.com/v1/token → { token, wsUrl }).
  Future<void> joinChannel({
    required String token,
    required String wsUrl,
    LioJoinOptions options = const LioJoinOptions(),
  }) async {
    if (_joined) {
      throw StateError('Already in a channel — call leaveChannel() first');
    }
    _wireEvents();
    await _room.connect(wsUrl, token);
    _joined = true;

    if (options.role != LioRole.audience) {
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

  /// Local camera preview track (see LioVideoView.local).
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
  List<LioRemoteUser> get remoteUsers => List.unmodifiable(_users.values);

  LioRemoteUser _userFor(lk.RemoteParticipant p) =>
      _users.putIfAbsent(p.identity, () => LioRemoteUser._(p));

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
        _connectionState.add(LioConnectionState.connected);
      })
      ..on<lk.RoomReconnectingEvent>((_) {
        _connectionState.add(LioConnectionState.reconnecting);
      })
      ..on<lk.RoomDisconnectedEvent>((_) {
        _joined = false;
        _connectionState.add(LioConnectionState.disconnected);
      })
      ..on<lk.DataReceivedEvent>((e) {
        final from = e.participant is lk.RemoteParticipant
            ? _userFor(e.participant as lk.RemoteParticipant)
            : null;
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
    await _room.dispose();
  }

  /// internal — escape hatch for UIKits
  lk.Room get raw => _room;
}

/// Typed alias to keep the public API free of dart:typed_data imports for users.
typedef Uint8Array = Uint8List;
