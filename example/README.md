# applooma_rtc example

A minimal video call: fetch a token from your server, join a channel, render
everyone in it.

Before running, set your App ID and the URL of your own token endpoint at the
top of `lib/main.dart`. The example deliberately does not contain an API secret
— tokens must be issued by your server, never by the app.

```bash
flutter run
```

Full documentation: https://docs.applooma.dev/sdk/flutter
