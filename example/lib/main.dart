import 'dart:async';
import 'dart:convert';

import 'package:applooma_rtc/applooma_rtc.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Your App ID from https://applooma.dev/dashboard.
const appId = 'YOUR_APP_ID';

/// Your own endpoint. It calls POST https://api.applooma.dev/v1/token with your
/// API key and secret, which must never be shipped inside an app.
const tokenEndpoint = 'https://your-server.example.com/api/rtc-token';

const channel = 'lobby';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AppLooma RTC example',
      theme: ThemeData.dark(useMaterial3: true),
      home: const CallScreen(),
    );
  }
}

class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late final AppEngine _engine;
  final List<StreamSubscription<dynamic>> _subs = [];

  String _status = 'Not connected';
  String? _error;
  bool _cameraOn = true;
  bool _micOn = true;

  @override
  void initState() {
    super.initState();
    _engine = AppEngine.create(appId: appId);

    void rebuild(dynamic _) {
      if (mounted) setState(() {});
    }

    _subs
      ..add(_engine.onUserJoined.listen(rebuild))
      ..add(_engine.onUserLeft.listen(rebuild))
      // A participant is announced before their camera arrives, so rebuild on
      // this too or their tile stays black.
      ..add(_engine.onTrackSubscribed.listen(rebuild))
      ..add(_engine.onTrackUnsubscribed.listen(rebuild))
      ..add(_engine.onConnectionStateChanged.listen((state) {
        if (mounted) setState(() => _status = state.name);
      }));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _engine.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    setState(() {
      _error = null;
      _status = 'requesting token';
    });

    try {
      final res = await http.post(
        Uri.parse(tokenEndpoint),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'channel': channel}),
      );
      if (res.statusCode != 200) {
        throw Exception('Token endpoint returned ${res.statusCode}');
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;

      await _engine.joinChannel(
        token: data['token'] as String,
        wsUrl: data['wsUrl'] as String,
        options: const AppJoinOptions(role: AppRole.host, camera: true),
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _leave() async {
    await _engine.leaveChannel();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final users = _engine.remoteUsers;

    return Scaffold(
      appBar: AppBar(title: Text('AppLooma RTC — $_status')),
      body: Column(
        children: [
          if (_error != null)
            Container(
              width: double.infinity,
              color: Colors.red.shade900,
              padding: const EdgeInsets.all(12),
              child: Text(_error!),
            ),
          Expanded(
            child: GridView.count(
              crossAxisCount: users.isEmpty ? 1 : 2,
              children: [
                _tile('You', AppVideoView.local(_engine)),
                for (final u in users) _tile(u.displayName ?? u.uid, AppVideoView.remote(u)),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: BottomAppBar(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              icon: Icon(_micOn ? Icons.mic : Icons.mic_off),
              onPressed: () async {
                await _engine.enableMicrophone(!_micOn);
                setState(() => _micOn = !_micOn);
              },
            ),
            IconButton(
              icon: Icon(_cameraOn ? Icons.videocam : Icons.videocam_off),
              onPressed: () async {
                await _engine.enableCamera(!_cameraOn);
                setState(() => _cameraOn = !_cameraOn);
              },
            ),
            FilledButton(onPressed: _join, child: const Text('Join')),
            OutlinedButton(onPressed: _leave, child: const Text('Leave')),
          ],
        ),
      ),
    );
  }

  Widget _tile(String label, Widget video) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: Colors.black, child: video),
          Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Text(label, style: const TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }
}
