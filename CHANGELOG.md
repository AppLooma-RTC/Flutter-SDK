# Changelog

## 0.5.2 — 2026-11-11

- Smart routing is tried twice with a 3 s wait each (was once, 2 s) and a final failure is logged as a warning instead of a silent fallback to the token's server. A slow route answer once put a host on one media server while the viewers were routed to another (Nur Live, 10 Nov). The API no longer waits on a media server that has stopped answering.
- `releaseMicrophoneOnMute` in the audio options (default false): with it, `enableMicrophone(false)` unpublishes and stops the microphone track instead of muting it, so the recorder closes, the phone's microphone indicator goes off and another app can record; unmuting republishes in a few hundred milliseconds. Equivalent to Agora's `enableLocalAudio(false)`.

## 0.5.1 — 2026-11-11

- `onUserLeftWithReason` now carries the server's real reason (`quit`, `kicked`, `duplicateIdentity`, `roomClosed`, `dropped`) via `applooma_rtc_core` 2.13.2. Only unexplained drops are held for the grace period.

## 0.5.0 — 2026-11-11

- `onUserLeftWithReason` (`AppUserLeave` with `AppLeaveReason`), also `user.leaveReason`. The transport does not yet pass the server's reason for a remote leave, so this release reports `unknown` for an unexplained leave and `dropped` when the grace period ran out. `onUserLeft` still fires.
- **Behaviour change:** when *your own* connection drops, the others are no longer reported through `onUserLeft`; you get `onConnectionStateChanged` `disconnected`.
- `AppEngineOptions.remoteLeaveGraceMs` (default 20000) and `onUserStateChanged` (`AppUserState.reconnecting` / `active`); back in time → no leave/join pair; not back → `dropped`. 0 restores the old behaviour.
- After a reconnect, people who stayed are not announced again; `onUsersResynced` carries the full roster.
- `onUserRoleChanged` (`AppUserRoleChange`) when your server promotes or demotes someone else.
- `onConnectionChanged` (`AppConnectionChange` with `AppConnectionReason`), `AppConnectionState.failed`, and `engine.connectionState`.

## 0.4.1 — 2026-11-11

- No API changes. Built on `applooma_rtc_core` 2.13.0, whose Android plugin, Dart types and generated protocol files no longer carry a third-party engine name. Your `GeneratedPluginRegistrant` now registers `com.applooma.rtc.plugin.AppLoomaRtcPlugin`.

## 0.4.0 — 2026-11-04

- **Breaking:** minimum Android is now 7.0 (API 24) and the Android plugin compiles with Java 17; minimum iOS is now 14.0 (was 13.0), matching the native iOS SDK.
- Your app should target Android API 36 (Google Play) and build iOS with Xcode 26 (App Store).
- No Dart API changes from 0.3.16.

## 0.3.16 — 2026-11-04

- `joinChannel` throws `AppLoomaException` with code `JOIN_ABANDONED` when `leaveChannel()` runs before it finishes; no cloud-proxy retry is started. A join that finishes after leave disconnects at once instead of pushing the same user's session out of the room.
- Stored chat: `loadHistory(limit:, before:)` returns `AppHistoryPage` (`AppStoredMessage` list, `nextBefore`), using the join token.

## 0.3.15 — 2026-10-28

- Android: audio routing during a call (start, stop, speaker and Bluetooth changes) can no longer crash the app. A phone that refuses a routing step now logs a warning and the call continues. Transport core 2.12.4.

## 0.3.14 — 2026-10-12

- Smart routing: `joinChannel` now asks AppLooma for the closest media server for this device before connecting (2 s limit; on any problem the `wsUrl` you passed is used). Only applies to `applooma.dev` URLs. Opt out with `AppJoinOptions(smartRouting: false)`.

## 0.3.13 — 2026-10-12

- Errors from `joinChannel`, `enableCamera`, `enableMicrophone`, `switchCamera`, `enableScreenShare`, `sendData` and `sendMessage` are now thrown as `AppLoomaException` (`message`, `code`, `cause`), with transport-engine wording removed. `ArgumentError`/`StateError` for API misuse are unchanged.
- Transport core 2.12.3: neutral error and log text.

## 0.3.12 — 2026-10-12

- Android: joining no longer fails with "getAudioDeviceModule() on a null object reference" (transport core 2.12.2).
- Android: on some phones the local preview stays blank under Flutter's Impeller renderer. Until that is fixed upstream, turn Impeller off in `AndroidManifest.xml` (see README, "Android setup").

## 0.3.11 — 2026-10-03

- `AppVideoMode.stableHd` now degrades `balanced` by default (was keepResolution). Holding full size while the bandwidth estimate ramped up started live streams at a few frames per second for their first 10-20 s; now the picture is smooth from the start and grows to full size as bandwidth allows. `ultra-hd-4k` still keeps resolution, and an explicit degradation setting is honoured.

## 0.3.10 — 2026-09-29

- Cloud proxy auto-retry no longer reports a disconnect to the app while it switches to the relay.

## 0.3.9 — 2026-09-28

- Requires `applooma_rtc_core` ^2.12.1, the fixed core release: 2.12.0 did not compile on iOS, 2.12.1 does.

- Video Enhance now works on Android and iOS: `engine.setVideoEnhance(options)` applies skin smoothing, low-light boost, sharpening and warmth on the capture path (same filters as the native Android and iOS SDKs), follows the camera across off/on, switches and republishes, and returns true. New `engine.videoEnhance` getter. Web and desktop still return false.
- Clear Voice now works on Android and iOS: `AppNoiseSuppression.clear` runs the spectral suppressor of the native Android SDK on the microphone's post-processing stage (about 10 ms added latency).
- The package now contains native code (`android/`, `ios/`) and lists the media plugin it builds on as a direct dependency: do a full rebuild (and `pod install` on iOS) after upgrading.

## 0.3.8 — 2026-09-28

- `AppVideoEnhance` and `engine.setVideoEnhance(options)` added for API parity; not yet available on Flutter (returns false, camera unchanged).
- `AppAudioOptions.noiseSuppressionMode` (`AppNoiseSuppression.standard` default, `clear`, `off`) for API parity; on Flutter `clear` runs the standard suppressor (no microphone post-processing stage is reachable from Dart).
- Audience latency: `AppEngineOptions.audienceLatency` (`AppAudienceLatency.ultraLow` default, `low`, `standard`), applied only while audience. No receive-buffer control on Flutter: `low` behaves like `ultraLow`; `standard` turns on the `videoLowQuality` subscribe fallback unless the app set one.
- Codec detection: `AppEngine.getSupportedVideoCodecs()` returns `AppVideoCodecCapability` (mime, hardware, encoder, decoder) from the media engine's capability lists; `hardware` is true for H.264 and H.265.

## 0.3.7 — 2026-09-28

- Cloud proxy for restrictive networks: `AppEngineOptions.cloudProxy` (`AppCloudProxy.auto` default, `forceTls443`, `off`). `forceTls443` joins with relay-only transport through AppLooma's relay on TLS 443; `auto` retries a join once that way when the direct join fails with a connection or network timeout, and logs it. New `onProxyStateChanged` stream of `AppProxyStateChange { state, autoRetry }` (`AppProxyState.direct`, `connecting`, `connected`) and `proxyState`.
- Device tuning: the server's per-device video config (`forceCodec`, `preferCodec`, `maxHeight`, `maxFps`, `maxBitrateKbps`, `disableSimulcast`) is fetched at join (3 s timeout, kept in memory) and applied to the camera's capture and publish options when it is published; it only lowers caps. `denyHardware` is not applied (the encoder cannot be chosen from Dart).
- Still no echo test on Flutter: it needs a microphone recorder plugin the package does not depend on.

## 0.3.6 — 2026-09-27

- Remote diagnostics: the SDK keeps its recent log lines and a stats snapshot every 10 s in memory (no audio, video or messages) and uploads them (gzip), scrubbed of names, metadata, user ids, tokens and URL parameters, after a call with a problem (codec fallback, a viewer reporting no picture, join failure, 3 or more reconnects), when support turned collection on for the device or project, or on the new `AppEngine.uploadDiagnostics(reason)`. Opt out with `AppEngineOptions(remoteDiagnostics: false)`. Kept 14 days.
- `AppEngineOptions.region` (`AppRegion.auto` default, `bd`, `india` = wire `in`, `sa`, `sg`, `us`). Logged at join and sent with device reports; preparation for multi-region — every region still connects to the `wsUrl` your token endpoint returns.
- `startNetworkTest(serverUrl, token, callback)` / `stopNetworkTest()`: a ~5 s separate test connection (10 s timeout) reporting `AppNetworkTestResult { uplinkQuality, downlinkQuality, rttMs, jitterMs, uplinkLoss, downlinkLoss, error }` with `AppNetworkQuality`. Nothing is published, so both qualities come from the server's grade of the test connection. No echo test on Flutter yet.
- `setRemoteSubscribeFallback` / `setLocalPublishFallback` with `AppFallbackOption { none, videoLowQuality, audioOnly }` and the `onFallbackStateChanged` stream of `AppFallbackState { isLocal, state }`. Poor/lost for 4 s falls back, good for 10 s restores (`AppFallbackHysteresis`).
- `onTokenWillExpire` (about 30 s before the token's `exp`) and `renewToken(token)`.

## 0.3.5 — 2026-09-27

- Automatic codec recovery. Viewer side: a subscribed, enabled remote camera that decodes no picture for more than 6 s while its sender has it on is reported to that publisher only, on a reserved internal data topic. Internal topics (prefix `_al.`) are never delivered to the app's message or data callbacks.
- Publisher side: reports from 2 different viewers within 20 s (or from the only other person in a 1:1 call) republish the camera on a safer path: VP8 when it was on another codec, otherwise once more as a single layer. At most once per join.
- New `AppEngine.onVideoCodecFallback` stream of `AppVideoCodecFallback { from, to, reason }` with `AppVideoCodecFallbackReason` (`noFrames`, `encoderError`, `viewersCannotDecode`). `publishedCodec` reflects the switch.
- Anonymous device reports (OS and SDK version, codec and outcome; no user, identity or IP address) are sent on a codec fallback or a viewer report, so the platform can tune settings per device model. Fire-and-forget; failures are silent.

## 0.3.4

- `AppVideoMode` on `AppVideoConfig.mode`: `stableHd` (new default), `ultraHd4k` (premium, opt-in), `adaptive` (the previous behaviour). `stableHd` publishes one layer (no simulcast), keeps resolution under pressure and turns adaptive stream off: 1080p30 at 3.5 Mbps on iOS, 720p30 at 1.8 Mbps on Android (Dart cannot check the encoder for hardware).
- `ultraHd4k`: 2160p30, one layer, H.265 at 16 Mbps, resolution kept — iOS only for now; on Android it falls back to `stableHd` with a warning. `AppEngine.isUltraHdSupported()` returns the check.
- Fields set explicitly still win over the mode. `AppVideoConfig.height` now defaults to 0 (= by mode) and `simulcast` is `bool?` (null = by mode); `degradation: auto` means `keepResolution` outside `adaptive`. `height: 2160` is a new preset.

## 0.3.3

- `AppVideoConfig.degradation` — `AppVideoDegradation.keepResolution` / `keepFramerate` / `balanced` / `auto` (what the encoder gives up first under pressure); `AppVideoConfig.minBitrate` (reserved — the engine exposes no per-sender floor on this platform yet).
- Default bitrate caps raised when `maxBitrate` is 0: 4 Mbps at 1080p, 2.2 Mbps at 720p (was 3 / 1.7). New `height: 1440` preset (2560×1440, 5 Mbps, 30 fps).
- `AppVideoCodec.h265` — published on iOS (hardware on every iPhone since the 7), falls back to `auto` on Android; `AppVideoCodec.av1` falls back to `auto` with a warning. Every codec but VP8 keeps the VP8 backup layer.
- `onVideoQualityChanged` — `AppVideoQualityInfo { width, height, fps, bitrateKbps, layer, reason }` for your own camera, from sender statistics, whenever the layer, size or reason changes.
- Bluetooth headsets: `setSpeakerphone(bool)` chooses between the phone's speaker and earpiece while a connected Bluetooth or wired headset keeps priority. On Android 12+ the app must hold `BLUETOOTH_CONNECT` at runtime (`Permission.bluetoothConnect`) for a headset to be routed to at all — see the docs; the UIKit asks for it.

## 0.3.2

- Android: `AppVideoCodec.auto` now publishes VP8. The engine only drives Qualcomm/Exynos H.264 hardware encoders; on MediaTek and other chipsets an H.264 track was published without a single frame and viewers saw black. Pass `AppVideoCodec.h264` explicitly on devices you have verified.

## 0.3.1

- `switchCamera()` — flip between the front and back cameras; the local preview follows.

## 0.3.0

Parity with the Android SDK 0.4.2 – 0.4.4 fixes.

- `AppEngineOptions` (`AppEngine.create(appId:, options:)`): `audioScenario`
  (`call` / `media`), `video: AppVideoConfig` (height, fps, maxBitrate in bit/s,
  simulcast, `codec: AppVideoCodec.auto | vp8 | h264`), `audio: AppAudioOptions`
  (independent echo-cancellation / noise-suppression / AGC switches).
- Codec `auto` publishes H.264 (hardware on every phone) with a VP8 backup layer
  the server can fall back to — no more software VP8 on budget chipsets, no
  black frame for a viewer that cannot decode the H.264 stream.
  `engine.publishedCodec` says what was chosen.
- Dynacast off and explicit auto-subscribe: every publisher always sends, every
  joiner receives all tracks — fixes co-hosts seeing a black frame on flaky links.
- Echo: the `media` scenario keeps media attributes (loudspeaker, media volume
  keys) while running Android in the communication audio mode and iOS in
  playAndRecord + videoChat, so the phone's echo canceller stays engaged.
- Self-preview follows the local camera through off→on, a camera switch and
  settings changes — `AppVideoView.local` re-binds by itself;
  `onLocalVideoChanged` for anything else holding your preview.
- `onRemoteStats` — per-user fps, size, freeze count, packet loss, jitter every
  two seconds. `onFirstRemoteVideoFrame` and `onConnectionStage` for
  join-to-picture timing.
- Guardrails: `maxBitrate` under 10 000 logs a units warning; a non-preset
  `height` snaps to the nearest preset with a warning.
- Not on Flutter: post-processing `micGain` (no capture post-processor is
  exposed to Dart) and in-room music mixing.

## 0.2.0

- Signaling: `sendMessage`, `onMessage`, `audience`, `audienceCount`, `hosts` and
  `onAudienceChanged` — live comments, viewer counts and audience lists without a
  server round trip. Platform frames no longer surface on `onDataReceived`.
- HD by default: 1080p publish with simulcast, 96 kbps voice with redundancy and
  no DTX. Adaptive streaming hands each viewer the layer their screen and link
  can take.
- Repository moved to github.com/AppLooma-RTC.

## 0.1.0

First release.

- `AppEngine` with `joinChannel` / `leaveChannel`, camera, microphone and screen
  share controls, and data messaging.
- Streams for users joining and leaving, track subscription, connection state,
  active speakers, incoming data and virtual gifts.
- `AppVideoView.local` and `AppVideoView.remote` for rendering.
- Host, co-host and audience roles, matching the token issued by your server.
