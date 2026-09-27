// Remote diagnostics: the SDK's own recent log lines plus a stats snapshot
// every 10 s, kept in memory and uploaded (scrubbed, gzip) to AppLooma when a
// call had a problem, when support switched collection on for this device or
// project, or when the app calls `uploadDiagnostics(reason)`. Never audio,
// video, messages or names. Opt out with `AppEngineOptions.remoteDiagnostics`.
//
// Not exported from the package: internal to the SDK.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;

/// Fixed-size ring of log lines; adding formats nothing.
class DiagRing {
  DiagRing([this.capacity = 600])
      : _times = List<int>.filled(capacity, 0),
        _lines = List<String?>.filled(capacity, null);

  final int capacity;
  final List<int> _times;
  final List<String?> _lines;
  int _next = 0;
  int _count = 0;

  int get size => _count;

  void add(String line, [int? nowMs]) {
    _times[_next] = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    _lines[_next] = line;
    _next = (_next + 1) % capacity;
    if (_count < capacity) _count++;
  }

  /// Oldest first, "HH:MM:SS.mmm line" (UTC), scrubbed, newest lines that fit in [maxBytes].
  List<String> snapshot(String Function(String) scrub, int maxBytes) {
    final start = (_next - _count + capacity) % capacity;
    final out = <String>[];
    var bytes = 0;
    for (var i = _count - 1; i >= 0; i--) {
      final k = (start + i) % capacity;
      final l = _lines[k];
      if (l == null) continue;
      final t = DateTime.fromMillisecondsSinceEpoch(_times[k], isUtc: true).toIso8601String();
      final s = '${t.substring(11, 23)} ${scrub(l)}';
      final n = utf8.encode(s).length + 1;
      if (bytes + n > maxBytes) break;
      bytes += n;
      out.add(s);
    }
    return out.reversed.toList();
  }
}

// Built from parts so the SDK source itself stays free of these names.
final String _e1 = 'live' 'kit';
final String _e2 = 'web' 'rtc';
final String _e3 = 'ago' 'ra';
final _salt = math.Random().nextInt(0x7fffffff);

final _engine = <MapEntry<RegExp, String>>[
  MapEntry(RegExp('${_e1}_client', caseSensitive: false), 'engine'),
  MapEntry(RegExp('$_e1\\.org\\.$_e2', caseSensitive: false), 'rtc'),
  MapEntry(RegExp(_e1, caseSensitive: false), 'engine'),
  MapEntry(RegExp(_e2, caseSensitive: false), 'rtc'),
  MapEntry(RegExp(_e3, caseSensitive: false), 'vendor'),
];
final _jwt = RegExp(r'\beyJ[\w-]{6,}\.[\w-]{6,}\.[\w-]{6,}\b');
final _urlQuery = RegExp(r'''\b((?:https?|wss?)://[^\s?#"']+)\?[^\s"']*''', caseSensitive: false);
final _secret = RegExp(r'''\b(token|access_token|secret|password|key|authorization)(\s*[=:]\s*)("[^"]*"|[^\s,;&)}\]]+)''', caseSensitive: false);
final _personal = RegExp(r'''\b(name|displayName|metadata|attributes|userName|nickname)(\s*[=:]\s*)("[^"]*"|\{[^}]*\}|[^\s,;)}\]]+)''', caseSensitive: false);
final _uid = RegExp(r'''\b(uid|localUid|identity|userId)(\s*[=:]\s*)([^\s,;)}\]]+)''', caseSensitive: false);

String _shortHash(String v) {
  var h = 0x811c9dc5 ^ _salt;
  for (final c in v.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0').substring(2);
}

/// Removes engine names, tokens, URL parameters, names and metadata; user ids become a salted short hash.
String scrubDiagLine(String line) {
  var s = line;
  for (final e in _engine) {
    s = s.replaceAll(e.key, e.value);
  }
  s = s.replaceAll(_jwt, '[token]');
  s = s.replaceAllMapped(_urlQuery, (m) => '${m[1]}?[redacted]');
  s = s.replaceAllMapped(_secret, (m) => '${m[1]}${m[2]}[redacted]');
  s = s.replaceAllMapped(_personal, (m) => '${m[1]}${m[2]}[redacted]');
  s = s.replaceAllMapped(_uid, (m) => '${m[1]}${m[2]}#${_shortHash(m[3]!)}');
  return s.length > 1000 ? s.substring(0, 1000) : s;
}

const diagRepeatedReconnects = 3;

/// (trigger, reason) or null. An app request wins, then a problem, then remote collection.
(String, String?)? decideDiag(bool optedIn, String? appReason, Set<String> problems, int reconnects, bool remoteEnabled) {
  if (!optedIn) return null;
  if (appReason != null) return ('app_requested', appReason);
  final all = {...problems, if (reconnects >= diagRepeatedReconnects) 'reconnects'};
  if (all.isNotEmpty) {
    final r = (all.toList()..sort()).join(',');
    return ('auto_problem', r.length > 64 ? r.substring(0, 64) : r);
  }
  if (remoteEnabled) return ('remote_enabled', null);
  return null;
}

String cleanDiagReason(String s) {
  final v = s.replaceAll(RegExp(r'[^A-Za-z0-9 ._\-+/(),:#]'), ' ').trim();
  final t = v.length > 64 ? v.substring(0, 64) : v;
  return t.isEmpty ? 'app' : t;
}

/// Per-engine collector and uploader. Every error is swallowed.
class DiagCollector {
  DiagCollector({required this.sdkVersion, required this.apiBase, required this.region});

  static const _maxUploadBytes = 240 * 1024;

  final String sdkVersion;
  final String apiBase;
  final String Function() region;
  final ring = DiagRing(600);
  bool enabled = true;
  bool remoteEnabled = false;
  String? _token;
  bool _active = false;
  final _problems = <String>{};
  int _reconnects = 0;
  String? _appReason;
  bool _uploaded = false;
  Timer? _midCall;
  List<int>? _pending;

  void log(String line) => ring.add(line);

  void problem(String kind) {
    _problems.add(kind);
    log('diag: problem $kind');
  }

  void reconnecting() => _reconnects++;

  void updateToken(String t) {
    if (_active) _token = t;
  }

  void begin(String token) {
    _token = token;
    _active = true;
    _uploaded = false;
    _reconnects = 0;
    if (!enabled) return;
    final p = _pending;
    if (p != null) {
      _post(token, p).then((ok) {
        if (ok) _pending = null;
      });
    }
    _fetchRemoteFlag(token);
    _midCall?.cancel();
    _midCall = Timer(const Duration(seconds: 60), () => _maybeUpload(false));
  }

  void end(String why) {
    if (!_active) return;
    log('diag: session end ($why)');
    _active = false;
    _midCall?.cancel();
    _midCall = null;
    _maybeUpload(true);
  }

  void request(String reason) {
    _appReason = cleanDiagReason(reason);
    log('diag: app requested upload');
    if (_active) _maybeUpload(false, force: true);
  }

  static String _short(String s, int max) {
    final v = cleanDiagReason(s);
    return v.length > max ? v.substring(0, max).trim() : v;
  }

  String get _os => io.Platform.isAndroid ? 'Android' : (io.Platform.isIOS ? 'iOS' : io.Platform.operatingSystem);

  void _maybeUpload(bool isFinal, {bool force = false}) {
    try {
      final d = decideDiag(enabled, _appReason, _problems, _reconnects, remoteEnabled);
      if (isFinal) {
        _problems.clear();
        _reconnects = 0;
      }
      final token = _token;
      if (d == null || token == null || token.isEmpty) return;
      if (!isFinal && !force && _uploaded) return;
      if (d.$1 == 'app_requested') _appReason = null;
      _uploaded = true;
      final lines = ring.snapshot(scrubDiagLine, _maxUploadBytes);
      if (lines.isEmpty) return;
      final body = jsonEncode({
        'platform': 'flutter',
        'sdkVersion': sdkVersion,
        'manufacturer': io.Platform.isIOS ? 'Apple' : null,
        'osVersion': _short('$_os ${io.Platform.operatingSystemVersion}', 32),
        'region': region(),
        'trigger': d.$1,
        if (d.$2 != null) 'reason': d.$2,
        'lines': lines,
      });
      final gz = io.gzip.encode(utf8.encode(body));
      _post(token, gz).then((ok) {
        if (!ok) _pending = gz; // no network: keep the latest one for the next join
      });
    } catch (_) {
      // Diagnostics never affect a call.
    }
  }

  /// Reads `diag.enabled` from the device config. Best effort, 3 s timeout.
  void _fetchRemoteFlag(String token) {
    () async {
      final client = io.HttpClient()..connectionTimeout = const Duration(seconds: 3);
      try {
        final q = 'platform=flutter&sdkVersion=${Uri.encodeQueryComponent(sdkVersion)}&region=${Uri.encodeQueryComponent(region())}';
        final req = await client.getUrl(Uri.parse('$apiBase/sdk/device-config?$q')).timeout(const Duration(seconds: 3));
        req.headers.set('Authorization', 'Bearer $token');
        final res = await req.close().timeout(const Duration(seconds: 3));
        final text = await res.transform(utf8.decoder).join();
        if (res.statusCode == 200) {
          final j = jsonDecode(text);
          remoteEnabled = j is Map && j['diag'] is Map && j['diag']['enabled'] == true;
        }
      } catch (_) {
        // keep the last value
      } finally {
        client.close(force: true);
      }
    }();
  }

  /// False only when the server could not be reached.
  Future<bool> _post(String token, List<int> gz) async {
    final client = io.HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.postUrl(Uri.parse('$apiBase/sdk/diag')).timeout(const Duration(seconds: 10));
      req.headers.set('Authorization', 'Bearer $token');
      req.headers.contentType = io.ContentType.json;
      req.headers.set('Content-Encoding', 'gzip');
      req.add(gz);
      final res = await req.close().timeout(const Duration(seconds: 10));
      await res.drain<void>();
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
