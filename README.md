# lio_rtc

Lio Live Flutter SDK — real-time voice, video, live streaming and audio rooms by AppLooma LLC.

## Install

```yaml
dependencies:
  lio_rtc: ^0.1.0
```

Add camera/microphone permissions (AndroidManifest.xml + Info.plist).

## Quickstart

```dart
import 'package:lio_rtc/lio_rtc.dart';

final engine = LioEngine.create(appId: 'YOUR_APP_ID');

engine.onUserJoined.listen((user) => print('${user.uid} joined'));

// Get { token, wsUrl } from YOUR server, which calls
// POST https://api.applooma.dev/v1/token with your API key/secret.
await engine.joinChannel(
  token: token,
  wsUrl: wsUrl,
  options: const LioJoinOptions(role: LioRole.host, camera: true),
);
```

Render video:

```dart
// Local preview
LioVideoView.local(engine)

// Remote users
ListView(
  children: engine.remoteUsers.map((u) => LioVideoView.remote(u)).toList(),
)
```

Controls:

```dart
await engine.enableCamera(false);
await engine.enableMicrophone(false);
await engine.enableScreenShare(true);
await engine.sendData(utf8.encode('hello'));
await engine.leaveChannel();
```

## Roles

`host` (admin + publish) · `cohost` (publish) · `audience` (view only — live streaming viewers)

Docs: https://applooma.dev/dashboard/docs
