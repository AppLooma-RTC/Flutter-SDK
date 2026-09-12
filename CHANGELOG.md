# Changelog

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
