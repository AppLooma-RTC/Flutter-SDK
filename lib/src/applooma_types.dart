/// Roles supported by AppLooma RTC channels.
enum AppRole { host, cohost, audience }

/// Connection lifecycle states.
enum AppConnectionState { connecting, connected, reconnecting, disconnected }

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
