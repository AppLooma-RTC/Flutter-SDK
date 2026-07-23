/// Roles supported by Lio Live channels.
enum LioRole { host, cohost, audience }

/// Connection lifecycle states.
enum LioConnectionState { connecting, connected, reconnecting, disconnected }

/// Options for joining a channel.
class LioJoinOptions {
  final LioRole role;

  /// Auto-enable camera on join (ignored for audience).
  final bool camera;

  /// Auto-enable microphone on join (ignored for audience).
  final bool microphone;

  const LioJoinOptions({
    this.role = LioRole.host,
    this.camera = false,
    this.microphone = true,
  });
}
