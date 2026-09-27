# applooma_rtc

Real-time voice, video, live streaming and audio rooms for Flutter, by
[AppLooma LLC](https://applooma.dev).

Full documentation: **https://docs.applooma.dev/sdk/flutter**

## Install

```yaml
dependencies:
  applooma_rtc: ^0.3.5
```

### Permissions

**Android** — `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.INTERNET" />
```

On Android 12 and above add `android.permission.BLUETOOTH_CONNECT` too and request
it next to the microphone, or audio never reaches a Bluetooth headset (a refusal is
harmless).

Declaring them is not enough on Android 6 and later; request them at runtime
before joining.

**iOS** — `ios/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Used for video calls</string>
<key>NSMicrophoneUsageDescription</key>
<string>Used for voice and video calls</string>
```

Enable the **Audio, AirPlay, and Picture in Picture** background mode to keep a call
running while the app is in the background.

Without these the app terminates the first time it opens a device.

## Quickstart

Tokens come from **your** server. Your API secret must never ship inside an
app — anyone who extracts it can issue unlimited tokens on your account.

```dart
import 'package:applooma_rtc/applooma_rtc.dart';

final engine = AppEngine.create(appId: 'YOUR_APP_ID');

// A participant is announced before their camera arrives, so rebuild on this
// too — otherwise their tile stays black.
engine.onUserJoined.listen((_) => setState(() {}));
engine.onTrackSubscribed.listen((_) => setState(() {}));
engine.onUserLeft.listen((_) => setState(() {}));

// Your own endpoint, which calls POST https://api.applooma.dev/v1/token
// server-side with your API key and secret.
final session = await fetchToken(channel: 'lobby');

await engine.joinChannel(
  token: session.token,
  wsUrl: session.wsUrl,
  options: const AppJoinOptions(role: AppRole.host, camera: true),
);
```

Rendering:

```dart
AppVideoView.local(engine),
for (final user in engine.remoteUsers) AppVideoView.remote(user),
```

Controls:

```dart
await engine.enableCamera(false);
await engine.enableMicrophone(false);
await engine.enableScreenShare(true);
await engine.sendData(utf8.encode('hello'));
await engine.leaveChannel();
await engine.dispose();   // release the engine when the screen is gone
```

Video quality — 1080p at 4 Mbps by default (720p at 2.2 Mbps, 1440p preset at
5 Mbps). Choose what the encoder gives up first with `degradation`, cap it with
`maxBitrate`, and listen to `engine.onVideoQualityChanged`:

```dart
final engine = AppEngine.create(
  appId: 'YOUR_APP_ID',
  options: const AppEngineOptions(
    video: AppVideoConfig(height: 1080, fps: 30, maxBitrate: 4000000,
        degradation: AppVideoDegradation.keepResolution),
  ),
);
```

A complete app is in [`example/`](example).

## Roles

The role is fixed by the token your server issues, not by the client.

| Role | Publish | Subscribe | Administer the channel |
|---|---|---|---|
| `AppRole.host` | yes | yes | yes |
| `AppRole.cohost` | yes | yes | no |
| `AppRole.audience` | no | yes | no |

Use `audience` for viewers of a live stream. An audience token cannot publish,
which is what keeps a large broadcast cheap and stable.

## Support

- Documentation — https://docs.applooma.dev
- Issues — https://github.com/AppLooma-RTC/Flutter-SDK/issues
- Email — support@applooma.dev

## Licence

MIT. See [LICENSE](LICENSE).
