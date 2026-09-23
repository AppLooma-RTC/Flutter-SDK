# Changelog

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
