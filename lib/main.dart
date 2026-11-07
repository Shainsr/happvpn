import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_v2ray_client/flutter_v2ray.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef JsonMap = Map<String, dynamic>;
typedef StringMap = Map<String, String>;
typedef IntMap = Map<String, int>;

const MethodChannel kQuickControlsChannel =
    MethodChannel('com.example.happ_vpn/quick_controls');

// ---------------------------------------------------------------------------
//  تنظیمات ارتباط با سازنده (برای دریافت درخواست سرور از سمت کاربر)
// ---------------------------------------------------------------------------
// وب‌هوک HTTPS باید روی سرور سازنده تنظیم شود؛ کلید محرمانه را داخل APK قرار ندهید.
const String kCreatorWebhookUrl = '';
const String kCreatorDefaultSubUrl = '';

enum PingMode { real }

extension PingModeLabel on PingMode {
  String get label => 'پینگ واقعی';
}

const String kDefaultPingUrl = 'https://www.gstatic.com/generate_204';

class ServerEndpoint {
  final String host;
  final int port;
  const ServerEndpoint(this.host, this.port);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ShinVPNApp());
}

// نقطه ورود پس‌زمینه برای ویجت و Quick Settings بدون باز شدن صفحه برنامه
@pragma('vm:entry-point')

bool isNewerVersion(String remote, String local) {
  List<int> parts(String v) => v
      .replaceAll(RegExp(r'[^0-9.]'), '')
      .split('.')
      .map((e) => int.tryParse(e) ?? 0)
      .toList();
  final a = parts(remote);
  final b = parts(local);
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

Future<Map<String, String>?> fetchLatestReleaseInfo() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    final req = await client.getUrl(
      Uri.parse('https://api.github.com/repos/$kUpdateRepo/releases/latest'),
    );
    req.headers.set('User-Agent', 'SHIN-Updater');
    req.headers.set('Accept', 'application/vnd.github+json');
    final resp = await req.close().timeout(const Duration(seconds: 15));
    final body = await utf8.decoder.bind(resp).join();
    final data = jsonDecode(body);
    if (data is! Map) return null;

    final tag = (data['tag_name'] ?? '').toString().replaceFirst(RegExp(r'^v'), '');
    var apk = '';
    var fallback = '';
    final assets = data['assets'];
    if (assets is List) {
      for (final a in assets) {
        if (a is! Map) continue;
        final name = (a['name'] ?? '').toString();
        if (!name.endsWith('.apk')) continue;
        final url = (a['browser_download_url'] ?? '').toString();
        if (name.contains('arm64')) {
          apk = url;
          break;
        }
        if (fallback.isEmpty) fallback = url;
      }
    }
    return {
      'tag': tag,
      'notes': (data['body'] ?? '').toString(),
      'apk': apk.isEmpty ? fallback : apk,
    };
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

class UpdateNotifier {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
  }

  static Future<void> requestPermission() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  static Future<void> showNewVersion(String version) async {
    await _plugin.show(
      7001,
      'نسخهٔ جدید SHIN ($version)',
      'برای دانلود و نصب، برنامه را باز کنید.',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'shin_updates',
          'بروزرسانی برنامه',
          channelDescription: 'اطلاع از نسخهٔ جدید SHIN',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  }
}

Future<void> runBackgroundUpdateCheck() async {
  final info = await fetchLatestReleaseInfo();
  if (info == null) return;
  final tag = info['tag'] ?? '';
  if (tag.isEmpty || !isNewerVersion(tag, kAppVersion)) return;

  final prefs = await SharedPreferences.getInstance();
  // برای هر نسخه فقط یک بار اعلان بده
  if (prefs.getString('notified_update_tag') == tag) return;

  await UpdateNotifier.init();
  await UpdateNotifier.showNewVersion(tag);
  await prefs.setString('notified_update_tag', tag);
}

@pragma('vm:entry-point')
void shinUpdateDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      await runBackgroundUpdateCheck();
    } catch (_) {}
    return true;
  });
}

Future<void> vpnBackgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final isConnected = prefs.getBool('bg_vpn_connected') ?? false;
  final config = prefs.getString('native_ready_config') ?? '';
  final remark = prefs.getString('native_ready_remark') ?? 'SHIN Server';
  const isProxyOnly = false;

  final v2ray = V2ray(
    onStatusChanged: (status) async {
      final connected = status.state == 'CONNECTED';
      await prefs.setBool('bg_vpn_connected', connected);
      try {
        await kQuickControlsChannel.invokeMethod('setConnectionState', {
          'connected': connected,
          'status': status.state,
        });
      } catch (_) {}
    },
  );

  try {
    await v2ray.initialize(
      notificationIconResourceType: 'mipmap',
      notificationIconResourceName: 'ic_launcher',
    );
    if (isConnected) {
      await prefs.setBool('bg_vpn_connected', false);
      try {
        await kQuickControlsChannel.invokeMethod('setConnectionState', {
          'connected': false,
          'status': 'DISCONNECTED',
        });
      } catch (_) {}
      await v2ray.stopV2Ray();
    } else if (config.isNotEmpty) {
      await v2ray.startV2Ray(
        remark: remark,
        config: config,
        proxyOnly: isProxyOnly,
        blockedApps: null,
        bypassSubnets: null,
      );
    }
  } catch (_) {}
}

// ---------------------------------------------------------------------------
//  ثابت‌ها و تنظیمات پایه
// ---------------------------------------------------------------------------

const String kAppVersion = '1.00.0';

// مخزن گیت‌هاب برای بررسی بروزرسانی (owner/repo)
const String kUpdateRepo = 'Shainsr/happvpn';

const List<String> kUserAgents = [
  'SHIN/1.00.0 (Android; Xray/26.10.31)',
  'v2rayNG/1.9.12',
  'SHIN/1.00.0 (Android)',
];

const List<String> kDnsOptions = [
  '1.1.1.1',
  '8.8.8.8',
  '9.9.9.9',
  '94.140.14.14',
];

const List<String> kSupportedSchemes = [
  'vless',
  'vmess',
  'trojan',
  'ss',
  'socks',
  'socks5',
];

enum AppThemeModeSetting { system, dark, light }

// ---------------------------------------------------------------------------
//  پارسر پیشرفته لینک‌ها
// ---------------------------------------------------------------------------

class ParsedLink {
  final String scheme;
  final String userInfo;
  final String host;
  final int port;
  final StringMap params;
  final String fragment;

  ParsedLink(
    this.scheme,
    this.userInfo,
    this.host,
    this.port,
    this.params,
    this.fragment,
  );
}

class ConvertedConfig {
  final String remark;
  final String protocol;
  final JsonMap config;

  ConvertedConfig(this.remark, this.protocol, this.config);
}

class LinkParser {
  static String safeDecode(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }

  static String? decodeBase64Loose(String input) {
    var s = input.trim().replaceAll(RegExp(r'\s+'), '');
    if (s.isEmpty) return null;
    s = s.replaceAll('-', '+').replaceAll('_', '/').replaceAll('=', '');
    final mod = s.length % 4;
    if (mod == 1) return null;
    if (mod == 2) s += '==';
    if (mod == 3) s += '=';
    try {
      return utf8.decode(base64.decode(s), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  static ServerEndpoint? parseHostPort(String input) {
    final s = input.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('[')) {
      final close = s.indexOf(']');
      if (close <= 0) return null;
      final host = s.substring(1, close);
      final after = s.substring(close + 1);
      if (!after.startsWith(':')) return null;
      final port = int.tryParse(after.substring(1));
      if (port == null || port <= 0 || port > 65535) return null;
      return ServerEndpoint(host, port);
    }
    final colon = s.lastIndexOf(':');
    if (colon <= 0) return null;
    final port = int.tryParse(s.substring(colon + 1));
    if (port == null || port <= 0 || port > 65535) return null;
    return ServerEndpoint(s.substring(0, colon), port);
  }

  static ParsedLink? splitLink(String link) {
    final schemeEnd = link.indexOf('://');
    if (schemeEnd <= 0) return null;
    final scheme = link.substring(0, schemeEnd).toLowerCase();
    var rest = link.substring(schemeEnd + 3);

    var fragment = '';
    final hashIdx = rest.indexOf('#');
    if (hashIdx >= 0) {
      fragment = safeDecode(rest.substring(hashIdx + 1)).trim();
      rest = rest.substring(0, hashIdx);
    }

    var query = '';
    final qIdx = rest.indexOf('?');
    if (qIdx >= 0) {
      query = rest.substring(qIdx + 1);
      rest = rest.substring(0, qIdx);
    }

    final slashIdx = rest.indexOf('/');
    if (slashIdx >= 0) rest = rest.substring(0, slashIdx);

    var userInfo = '';
    final atIdx = rest.lastIndexOf('@');
    if (atIdx >= 0) {
      userInfo = safeDecode(rest.substring(0, atIdx));
      rest = rest.substring(atIdx + 1);
    }

    final hp = parseHostPort(rest);
    if (hp == null) return null;

    final StringMap params = {};
    if (query.isNotEmpty) {
      for (final pair in query.split('&')) {
        if (pair.isEmpty) continue;
        final eq = pair.indexOf('=');
        final key = (eq <= 0 ? pair : pair.substring(0, eq)).toLowerCase();
        final value = eq <= 0 ? '' : safeDecode(pair.substring(eq + 1));
        params[key] = value;
      }
    }
    return ParsedLink(scheme, userInfo, hp.host, hp.port, params, fragment);
  }

  static String _p(StringMap p, String key, [String fallback = '']) {
    final v = p[key];
    return (v == null || v.isEmpty) ? fallback : v;
  }

  static bool _truthy(String? v) {
    if (v == null) return false;
    final l = v.toLowerCase();
    return l == '1' || l == 'true' || l == 'yes';
  }

  static JsonMap _wrap(JsonMap outbound) => {
        'log': {'loglevel': 'none'},
        'inbounds': standardInbounds(),
        'outbounds': [
          outbound,
          {'tag': 'direct', 'protocol': 'freedom', 'settings': {}},
          {'tag': 'blackhole', 'protocol': 'blackhole', 'settings': {}},
        ],
      };

  static List<JsonMap> standardInbounds() => [
        {
          'tag': 'in_proxy',
          'port': 10808,
          'protocol': 'socks',
          'listen': '127.0.0.1',
          'settings': {'auth': 'noauth', 'udp': true, 'userLevel': 8},
          'sniffing': {
            'enabled': true,
            'destOverride': ['http', 'tls', 'quic'],
            'routeOnly': false,
          },
        }
      ];

  static JsonMap _stream(
    StringMap p, {
    required String host,
    String defaultSecurity = 'none',
  }) {
    var net = _p(p, 'type', _p(p, 'net', 'tcp')).toLowerCase();
    if (net == 'raw') net = 'tcp';
    if (net == 'splithttp') net = 'xhttp';
    if (net == 'mkcp') net = 'kcp';
    if (net == 'http') net = 'h2';

    final path = _p(p, 'path');
    final hostHeader = _p(p, 'host');
    final JsonMap stream = {'network': net};

    switch (net) {
      case 'ws':
        final JsonMap ws = {'path': path.isEmpty ? '/' : path};
        if (hostHeader.isNotEmpty) ws['headers'] = {'Host': hostHeader};
        stream['wsSettings'] = ws;
        break;
      case 'grpc':
        stream['grpcSettings'] = {
          'serviceName': _p(p, 'servicename', path),
          'multiMode': _p(p, 'mode') == 'multi',
        };
        break;
      case 'httpupgrade':
        stream['httpupgradeSettings'] = {
          'path': path.isEmpty ? '/' : path,
          'host': hostHeader,
        };
        break;
      case 'xhttp':
        final JsonMap x = {
          'path': path.isEmpty ? '/' : path,
          'host': hostHeader,
          'mode': _p(p, 'mode', 'auto'),
        };
        final extra = _p(p, 'extra');
        if (extra.isNotEmpty) {
          try {
            final decoded = jsonDecode(extra);
            if (decoded is Map) x['extra'] = decoded;
          } catch (_) {}
        }
        stream['xhttpSettings'] = x;
        break;
      case 'kcp':
        final JsonMap kcp = {
          'header': {'type': _p(p, 'headertype', 'none')},
        };
        final seed = _p(p, 'seed');
        if (seed.isNotEmpty) kcp['seed'] = seed;
        stream['kcpSettings'] = kcp;
        break;
      case 'h2':
        stream['httpSettings'] = {
          'path': path.isEmpty ? '/' : path,
          'host': hostHeader.isEmpty ? <String>[] : hostHeader.split(','),
        };
        break;
      case 'tcp':
      default:
        if (_p(p, 'headertype') == 'http') {
          stream['tcpSettings'] = {
            'header': {
              'type': 'http',
              'request': {
                'version': '1.1',
                'method': 'GET',
                'path': [path.isEmpty ? '/' : path],
                'headers': {
                  'Host':
                      hostHeader.isEmpty ? <String>[] : hostHeader.split(','),
                  'Connection': ['keep-alive'],
                },
              },
            },
          };
        }
        break;
    }

    final sec = _p(p, 'security', defaultSecurity).toLowerCase();
    if (sec == 'tls') {
      stream['security'] = 'tls';
      final JsonMap tls = {
        'serverName': _p(
            p, 'sni', _p(p, 'peer', hostHeader.isNotEmpty ? hostHeader : host)),
        'allowInsecure':
            _truthy(p['allowinsecure']) || _truthy(p['insecure']),
      };
      final fp = _p(p, 'fp');
      if (fp.isNotEmpty) tls['fingerprint'] = fp;
      final alpn = _p(p, 'alpn');
      if (alpn.isNotEmpty) tls['alpn'] = alpn.split(',');
      stream['tlsSettings'] = tls;
    } else if (sec == 'reality') {
      stream['security'] = 'reality';
      stream['realitySettings'] = {
        'serverName': _p(p, 'sni', host),
        'fingerprint': _p(p, 'fp', 'chrome'),
        'publicKey': _p(p, 'pbk'),
        'shortId': _p(p, 'sid'),
        'spiderX': _p(p, 'spx'),
      };
    }
    return stream;
  }

  static ConvertedConfig? convert(String link) {
    final l = link.trim();
    final lower = l.toLowerCase();
    try {
      if (lower.startsWith('vless://')) return _vless(l);
      if (lower.startsWith('vmess://')) return _vmess(l);
      if (lower.startsWith('trojan://')) return _trojan(l);
      if (lower.startsWith('ss://')) return _shadowsocks(l);
      if (lower.startsWith('socks://') || lower.startsWith('socks5://')) {
        return _socks(l);
      }
    } catch (_) {}
    return null;
  }

  static String _remarkOrDefault(ParsedLink p) =>
      p.fragment.isNotEmpty ? p.fragment : '${p.host}:${p.port}';

  static ConvertedConfig? _vless(String link) {
    final p = splitLink(link);
    if (p == null || p.userInfo.isEmpty) return null;
    final JsonMap user = {
      'id': p.userInfo,
      'encryption': _p(p.params, 'encryption', 'none'),
      'level': 8,
    };
    final flow = _p(p.params, 'flow');
    if (flow.isNotEmpty) user['flow'] = flow;

    final JsonMap outbound = {
      'tag': 'proxy',
      'protocol': 'vless',
      'settings': {
        'vnext': [
          {
            'address': p.host,
            'port': p.port,
            'users': [user],
          }
        ],
      },
      'streamSettings': _stream(p.params, host: p.host),
    };
    return ConvertedConfig(_remarkOrDefault(p), 'VLESS', _wrap(outbound));
  }

  static ConvertedConfig? _trojan(String link) {
    final p = splitLink(link);
    if (p == null || p.userInfo.isEmpty) return null;
    final JsonMap outbound = {
      'tag': 'proxy',
      'protocol': 'trojan',
      'settings': {
        'servers': [
          {
            'address': p.host,
            'port': p.port,
            'password': p.userInfo,
            'level': 8
          }
        ],
      },
      'streamSettings':
          _stream(p.params, host: p.host, defaultSecurity: 'tls'),
    };
    return ConvertedConfig(_remarkOrDefault(p), 'TROJAN', _wrap(outbound));
  }

  static ConvertedConfig? _vmess(String link) {
    var payload = link.substring('vmess://'.length).trim();
    var fragment = '';
    final hashIdx = payload.indexOf('#');
    if (hashIdx >= 0) {
      fragment = safeDecode(payload.substring(hashIdx + 1)).trim();
      payload = payload.substring(0, hashIdx);
    }

    final decoded = decodeBase64Loose(payload);
    if (decoded != null && decoded.trim().startsWith('{')) {
      final j = jsonDecode(decoded);
      if (j is! Map) return null;
      String s(String k) => (j[k] ?? '').toString();

      final host = s('add');
      final port = int.tryParse(s('port'));
      final id = s('id');
      if (host.isEmpty || port == null || id.isEmpty) return null;

      final net = s('net').isEmpty ? 'tcp' : s('net');
      final StringMap params = {
        'type': net,
        'headertype':
            s('type') == 'multi' || s('type') == 'gun' ? '' : s('type'),
        'host': s('host'),
        'path': s('path'),
        'security': s('tls') == 'tls'
            ? 'tls'
            : (s('tls') == 'reality' ? 'reality' : 'none'),
        'sni': s('sni'),
        'fp': s('fp'),
        'alpn': s('alpn'),
        'allowinsecure': s('allowInsecure'),
      };
      if (net == 'grpc') {
        params['servicename'] = s('path');
        params['mode'] = s('type') == 'multi' ? 'multi' : '';
      }

      final JsonMap outbound = {
        'tag': 'proxy',
        'protocol': 'vmess',
        'settings': {
          'vnext': [
            {
              'address': host,
              'port': port,
              'users': [
                {
                  'id': id,
                  'alterId': int.tryParse(s('aid')) ?? 0,
                  'security': s('scy').isEmpty ? 'auto' : s('scy'),
                  'level': 8,
                }
              ],
            }
          ],
        },
        'streamSettings': _stream(params, host: host),
      };
      final remark = s('ps').isNotEmpty
          ? s('ps')
          : (fragment.isNotEmpty ? fragment : '$host:$port');
      return ConvertedConfig(remark, 'VMESS', _wrap(outbound));
    }

    final p = splitLink(link);
    if (p == null || p.userInfo.isEmpty) return null;
    final JsonMap outbound = {
      'tag': 'proxy',
      'protocol': 'vmess',
      'settings': {
        'vnext': [
          {
            'address': p.host,
            'port': p.port,
            'users': [
              {
                'id': p.userInfo,
                'alterId': 0,
                'security': _p(p.params, 'encryption', 'auto'),
                'level': 8
              }
            ],
          }
        ],
      },
      'streamSettings': _stream(p.params, host: p.host),
    };
    return ConvertedConfig(_remarkOrDefault(p), 'VMESS', _wrap(outbound));
  }

  static ConvertedConfig? _shadowsocks(String link) {
    var rest = link.substring('ss://'.length).trim();
    var fragment = '';
    final hashIdx = rest.indexOf('#');
    if (hashIdx >= 0) {
      fragment = safeDecode(rest.substring(hashIdx + 1)).trim();
      rest = rest.substring(0, hashIdx);
    }
    final qIdx = rest.indexOf('?');
    if (qIdx >= 0) rest = rest.substring(0, qIdx);
    while (rest.endsWith('/')) {
      rest = rest.substring(0, rest.length - 1);
    }

    String? creds;
    String? hostPart;

    if (rest.contains('@')) {
      final at = rest.lastIndexOf('@');
      final userPart = rest.substring(0, at);
      hostPart = rest.substring(at + 1);
      creds = userPart.contains(':')
          ? safeDecode(userPart)
          : decodeBase64Loose(userPart);
    } else {
      final decoded = decodeBase64Loose(rest);
      if (decoded == null) return null;
      final at = decoded.lastIndexOf('@');
      if (at <= 0) return null;
      creds = decoded.substring(0, at);
      hostPart = decoded.substring(at + 1);
    }

    if (creds == null) return null;
    final colon = creds.indexOf(':');
    if (colon <= 0) return null;
    final method = creds.substring(0, colon);
    final password = creds.substring(colon + 1);

    final hp = parseHostPort(hostPart);
    if (hp == null) return null;

    final JsonMap outbound = {
      'tag': 'proxy',
      'protocol': 'shadowsocks',
      'settings': {
        'servers': [
          {
            'address': hp.host,
            'port': hp.port,
            'method': method,
            'password': password,
            'level': 8,
          }
        ],
      },
    };
    final remark =
        fragment.isNotEmpty ? fragment : '${hp.host}:${hp.port}';
    return ConvertedConfig(remark, 'SHADOWSOCKS', _wrap(outbound));
  }

  static ConvertedConfig? _socks(String link) {
    final p = splitLink(link);
    if (p == null) return null;

    String? user;
    String? pass;
    if (p.userInfo.isNotEmpty) {
      var cred = p.userInfo;
      if (!cred.contains(':')) {
        cred = decodeBase64Loose(cred) ?? cred;
      }
      final idx = cred.indexOf(':');
      if (idx > 0) {
        user = cred.substring(0, idx);
        pass = cred.substring(idx + 1);
      }
    }

    final JsonMap serverObj = {
      'address': p.host,
      'port': p.port,
    };
    if (user != null && user.isNotEmpty) {
      serverObj['users'] = [
        {'user': user, 'pass': pass ?? '', 'level': 8}
      ];
    }

    final JsonMap outbound = {
      'tag': 'proxy',
      'protocol': 'socks',
      'settings': {
        'servers': [serverObj],
      },
    };
    return ConvertedConfig(_remarkOrDefault(p), 'SOCKS', _wrap(outbound));
  }
}

// ---------------------------------------------------------------------------
//  استخراج سرورها از متن سابسکریپشن یا ورودی JSON
// ---------------------------------------------------------------------------

class ExtractedEntries {
  final List<String> links = [];
  final List<JsonMap> jsonConfigs = [];
  bool looksLikeHtml = false;
  bool looksLikeClash = false;
}

ExtractedEntries extractEntries(String body, {int depth = 0}) {
  final out = ExtractedEntries();
  final text = body.replaceAll('\uFEFF', '').trim();
  if (text.isEmpty) return out;

  if (text.startsWith('{') || text.startsWith('[')) {
    try {
      final j = jsonDecode(text);
      final list = j is List ? j : [j];
      for (final e in list) {
        if (e is Map && e['outbounds'] is List) {
          out.jsonConfigs.add(JsonMap.from(e));
        }
      }
      if (out.jsonConfigs.isNotEmpty) return out;
    } catch (_) {}
  }

  final head = text.substring(0, min(300, text.length)).toLowerCase();
  if (head.contains('html') || head.contains('doctype')) {
    out.looksLikeHtml = true;
    return out;
  }

  if (RegExp(r'^\s*proxies\s*:', multiLine: true).hasMatch(text)) {
    out.looksLikeClash = true;
    return out;
  }

  if (text.contains('://')) {
    final schemeChars = RegExp(r'[A-Za-z0-9+.\-]');
    for (final raw in text.split(RegExp(r'[\r\n]+'))) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final count = '://'.allMatches(line).length;
      if (count == 0) continue;

      if (count == 1) {
        final idx = line.indexOf('://');
        var start = idx;
        while (start > 0 && schemeChars.hasMatch(line[start - 1])) {
          start--;
        }
        if (start != idx) out.links.add(line.substring(start));
      } else {
        for (final m in RegExp(r'[A-Za-z][A-Za-z0-9+.\-]*://\S+')
            .allMatches(line)) {
          out.links.add(m.group(0)!);
        }
      }
    }
    if (out.links.isNotEmpty) return out;
  }

  if (depth <= 1) {
    final decoded = LinkParser.decodeBase64Loose(text);
    if (decoded != null && decoded.trim().isNotEmpty) {
      return extractEntries(decoded, depth: depth + 1);
    }
  }
  return out;
}

class ImportReport {
  final List<ServerItem> servers = [];
  int failed = 0;
  final IntMap unsupported = {};
  bool looksLikeHtml = false;
  bool looksLikeClash = false;
  String rawPreview = '';
  int httpStatus = 0;
  String? error;

  int get added => servers.length;
  bool get hasProblems =>
      error != null ||
      failed > 0 ||
      unsupported.isNotEmpty ||
      looksLikeHtml ||
      looksLikeClash ||
      added == 0;
}

String _schemeOf(String link) {
  final i = link.indexOf('://');
  return i <= 0 ? '' : link.substring(0, i).toLowerCase();
}

ImportReport buildImport(
  String body, {
  required String subId,
  required String subName,
}) {
  final report = ImportReport();
  final trimmed = body.trim();
  report.rawPreview =
      trimmed.length > 600 ? trimmed.substring(0, 600) : trimmed;

  final extracted = extractEntries(body);
  report.looksLikeHtml = extracted.looksLikeHtml;
  report.looksLikeClash = extracted.looksLikeClash;

  final stamp = DateTime.now().microsecondsSinceEpoch;
  var index = 0;

  for (final cfg in extracted.jsonConfigs) {
    try {
      final outbounds = cfg['outbounds'] as List;
      Map? main;
      for (final o in outbounds) {
        if (o is Map && o['tag'] == 'proxy') main = o;
      }
      main ??= outbounds.firstWhere(
        (o) =>
            o is Map &&
            !['freedom', 'blackhole', 'dns'].contains(o['protocol']),
        orElse: () => null,
      ) as Map?;

      cfg['inbounds'] = LinkParser.standardInbounds();
      final remark =
          (cfg['remarks'] ?? cfg['remark'] ?? cfg['ps'] ?? '').toString().trim();
      final protocol = (main?['protocol'] ?? 'JSON').toString().toUpperCase();
      index++;
      report.servers.add(ServerItem(
        id: '${subId}_${stamp}_$index',
        rawUrl: '',
        remark: remark.isEmpty ? 'Custom JSON $index' : remark,
        protocol: protocol,
        subId: subId,
        subName: subName,
        fullJsonConfig: jsonEncode(cfg),
      ));
    } catch (_) {
      report.failed++;
    }
  }

  final seen = <String>{};
  for (final link in extracted.links) {
    if (!seen.add(link)) continue;
    final scheme = _schemeOf(link);
    if (scheme == 'http' || scheme == 'https') continue;

    if (!kSupportedSchemes.contains(scheme)) {
      report.unsupported[scheme] = (report.unsupported[scheme] ?? 0) + 1;
      continue;
    }

    String? fullConfig;
    String remark = '';
    String protocol = scheme.toUpperCase();

    final preferOwn = RegExp(
      r'(type|net)=(xhttp|splithttp|httpupgrade|raw)|^socks',
      caseSensitive: false,
    ).hasMatch(link);

    void tryPlugin() {
      if (fullConfig != null) return;
      try {
        final parser = V2ray.parseFromURL(link);
        fullConfig = parser.getFullConfiguration();
        remark = parser.remark.trim();
      } catch (_) {}
    }

    void tryOwn() {
      if (fullConfig != null) return;
      final c = LinkParser.convert(link);
      if (c != null) {
        fullConfig = jsonEncode(c.config);
        remark = c.remark;
        protocol = c.protocol;
      }
    }

    if (preferOwn) {
      tryOwn();
      tryPlugin();
    } else {
      tryPlugin();
      tryOwn();
    }

    if (fullConfig == null) {
      report.failed++;
      continue;
    }

    index++;
    report.servers.add(ServerItem(
      id: '${subId}_${stamp}_$index',
      rawUrl: link,
      remark: remark.isEmpty ? '$protocol $index' : remark,
      protocol: protocol == 'SS'
          ? 'SHADOWSOCKS'
          : (protocol == 'SOCKS5' ? 'SOCKS' : protocol),
      subId: subId,
      subName: subName,
      fullJsonConfig: fullConfig!,
    ));
  }
  return report;
}

// ---------------------------------------------------------------------------
//  دریافت سابسکریپشن
// ---------------------------------------------------------------------------

class FetchResult {
  int status = 0;
  String body = '';
  StringMap headers = {};
  String? error;
  String? resolvedUrl;
}

List<String> resolveSubscriptionCandidateUrls(
  String primaryUrl,
  String? fallbackUrl,
) {
  final candidates = <String>[];
  try {
    final uri = Uri.parse(primaryUrl.trim());
    final newUrlParam =
        uri.queryParameters['new-url'] ?? uri.queryParameters['new_url'];
    if (newUrlParam != null && newUrlParam.startsWith('http')) {
      candidates.add(newUrlParam);
    }
    candidates.add(primaryUrl.trim());
    final queryFallback = uri.queryParameters['fallback-url'] ??
        uri.queryParameters['fallback_url'];
    if (queryFallback != null && queryFallback.startsWith('http')) {
      candidates.add(queryFallback);
    }
  } catch (_) {
    candidates.add(primaryUrl.trim());
  }
  if (fallbackUrl != null && fallbackUrl.trim().startsWith('http')) {
    if (!candidates.contains(fallbackUrl.trim())) {
      candidates.add(fallbackUrl.trim());
    }
  }
  return candidates;
}

Future<FetchResult> fetchSubscription(
  String url,
  String userAgent,
  String hwid,
) async {
  final r = FetchResult();
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 15);
  client.badCertificateCallback = (cert, host, port) => true;
  try {
    final req = await client.getUrl(Uri.parse(url.trim()));
    req.headers.set('User-Agent', userAgent);
    req.headers.set('Accept', '*/*');
    req.headers.set('x-hwid', hwid);
    req.headers.set('x-device-os', 'Android');
    final resp = await req.close().timeout(const Duration(seconds: 25));
    r.status = resp.statusCode;
    r.resolvedUrl = url.trim();
    resp.headers.forEach((name, values) {
      r.headers[name.toLowerCase()] = values.join(',');
    });
    final bb = BytesBuilder();
    await for (final chunk in resp) {
      bb.add(chunk);
      if (bb.length > 8 * 1024 * 1024) break;
    }
    r.body = utf8.decode(bb.toBytes(), allowMalformed: true);
  } catch (e) {
    r.error = e.toString();
  } finally {
    client.close(force: true);
  }
  return r;
}

ServerEndpoint? extractServerEndpoint(String rawConfig) {
  try {
    final decoded = jsonDecode(rawConfig);
    if (decoded is! Map) return null;
    final outbounds = decoded['outbounds'];
    if (outbounds is! List) return null;

    for (final outbound in outbounds) {
      if (outbound is! Map) continue;
      final protocol = (outbound['protocol'] ?? '').toString().toLowerCase();
      if (protocol.isEmpty ||
          protocol == 'freedom' ||
          protocol == 'blackhole' ||
          protocol == 'dns') {
        continue;
      }
      final settings = outbound['settings'];
      if (settings is! Map) continue;

      for (final key in ['vnext', 'servers']) {
        final endpoints = settings[key];
        if (endpoints is! List) continue;
        for (final item in endpoints) {
          if (item is! Map) continue;
          final host = (item['address'] ?? '').toString().trim();
          final portValue = item['port'];
          final port =
              portValue is int ? portValue : int.tryParse('$portValue');
          if (host.isNotEmpty && port != null && port > 0 && port <= 65535) {
            return ServerEndpoint(host, port);
          }
        }
      }
    }
  } catch (_) {
    return null;
  }
  return null;
}

// ---------------------------------------------------------------------------
//  مدل‌های داده
// ---------------------------------------------------------------------------

class ServerItem {
  String id;
  String rawUrl;
  String remark;
  String protocol;
  String subId;
  String subName;
  String fullJsonConfig;
  // کلید = نام حالت پینگ (PingMode.name)، مقدار = میلی‌ثانیه یا -1 در صورت خطا
  Map<String, int> pings;
  Set<String> busyPings;
  String countryCode = '';

  bool get isPinging => busyPings.isNotEmpty;

  int? pingFor(PingMode mode) => pings[mode.name];

  ServerItem({
    required this.id,
    required this.rawUrl,
    required this.remark,
    required this.protocol,
    required this.subId,
    required this.subName,
    required this.fullJsonConfig,
    Map<String, int>? pings,
  })  : pings = pings ?? <String, int>{},
        busyPings = <String>{};

  JsonMap toJson() => {
        'id': id,
        'rawUrl': rawUrl,
        'remark': remark,
        'protocol': protocol,
        'subId': subId,
        'subName': subName,
        'fullJsonConfig': fullJsonConfig,
        'pings': pings,
        'countryCode': countryCode,
      };

  factory ServerItem.fromJson(JsonMap json) {
    final pings = <String, int>{};
    final raw = json['pings'];
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is int) pings[k.toString()] = v;
      });
    }
    // سازگاری با نسخه‌های قبلی: realPing همان میانهٔ TCP بود
    if (json['realPing'] is int && !pings.containsKey('tcp')) {
      pings['tcp'] = json['realPing'] as int;
    }
    final item = ServerItem(
      id: json['id'] ?? DateTime.now().microsecondsSinceEpoch.toString(),
      rawUrl: json['rawUrl'] ?? '',
      remark: json['remark'] ?? 'سرور',
      protocol: json['protocol'] ?? 'V2RAY',
      subId: json['subId'] ?? 'manual',
      subName: json['subName'] ?? 'دستی',
      fullJsonConfig: json['fullJsonConfig'] ?? '',
      pings: pings,
    );
    item.countryCode = (json['countryCode'] ?? '').toString();
    return item;
  }
}

class SubscriptionItem {
  String id;
  String name;
  String url;
  String fallbackUrl;
  int updatedAt;
  int serverCount;
  bool isUpdating;
  bool autoName;
  int usedBytes;
  int totalBytes;
  int expireSec;
  String? lastError;

  SubscriptionItem({
    required this.id,
    required this.name,
    required this.url,
    this.fallbackUrl = '',
    this.updatedAt = 0,
    this.serverCount = 0,
    this.isUpdating = false,
    this.autoName = false,
    this.usedBytes = 0,
    this.totalBytes = 0,
    this.expireSec = 0,
    this.lastError,
  });

  JsonMap toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'fallbackUrl': fallbackUrl,
        'updatedAt': updatedAt,
        'serverCount': serverCount,
        'autoName': autoName,
        'usedBytes': usedBytes,
        'totalBytes': totalBytes,
        'expireSec': expireSec,
      };

  factory SubscriptionItem.fromJson(JsonMap json) => SubscriptionItem(
        id: json['id'] ?? '',
        name: json['name'] ?? 'اشتراک',
        url: json['url'] ?? '',
        fallbackUrl: json['fallbackUrl'] ?? '',
        updatedAt: json['updatedAt'] is int ? json['updatedAt'] : 0,
        serverCount: json['serverCount'] ?? 0,
        autoName: json['autoName'] ?? false,
        usedBytes: json['usedBytes'] ?? 0,
        totalBytes: json['totalBytes'] ?? 0,
        expireSec: json['expireSec'] ?? 0,
      );
}

// ---------------------------------------------------------------------------
//  توابع فرمت‌بندی و رنگ‌ها
// ---------------------------------------------------------------------------

String fmtBytes(num bytes, {bool isSpeed = false}) {
  final suffix = isSpeed ? '/s' : '';
  if (bytes <= 1023) return '${bytes.toInt()} B$suffix';
  if (bytes <= 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB$suffix';
  }
  if (bytes <= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB$suffix';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB$suffix';
}

String fmtAgo(int ms) {
  if (ms <= 0) return 'هرگز';
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inMinutes <= 0) return 'همین الان';
  if (d.inMinutes <= 59) return '${d.inMinutes} دقیقه پیش';
  if (d.inHours <= 23) return '${d.inHours} ساعت پیش';
  return '${d.inDays} روز پیش';
}

Color pingColor(int ping) {
  if (ping <= 0) return const Color(0xFFFF5252);
  if (ping <= 250) return const Color(0xFF00E676);
  if (ping <= 600) return const Color(0xFFFFAB40);
  return const Color(0xFFFF5252);
}

Color protocolBadgeColor(String protocol) {
  switch (protocol.toUpperCase()) {
    case 'VLESS':
      return const Color(0xFF3E82F7);
    case 'VMESS':
      return const Color(0xFFAB47BC);
    case 'TROJAN':
      return const Color(0xFFFF7043);
    case 'SHADOWSOCKS':
      return const Color(0xFF26A69A);
    case 'SOCKS':
      return const Color(0xFFEC407A);
    default:
      return const Color(0xFF78909C);
  }
}

// ---------------------------------------------------------------------------
//  دکمه گرافیکی ویژه SHIN با امواج نئونی، چرخش هاله و افکت سایبری (مورد ۲)
// ---------------------------------------------------------------------------

class ShinCyberConnectButton extends StatefulWidget {
  final bool isConnected;
  final bool isConnecting;
  final Color activeColor;
  final VoidCallback onTap;

  const ShinCyberConnectButton({
    super.key,
    required this.isConnected,
    required this.isConnecting,
    required this.activeColor,
    required this.onTap,
  });

  @override
  State<ShinCyberConnectButton> createState() => _ShinCyberConnectButtonState();
}

class _ShinCyberConnectButtonState extends State<ShinCyberConnectButton>
    with TickerProviderStateMixin {
  late final AnimationController _waveCtrl;
  late final AnimationController _rotateCtrl;
  late final AnimationController _pressCtrl;

  @override
  void initState() {
    super.initState();
    _waveCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();

    _rotateCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )..repeat();

    _pressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
      lowerBound: 0.0,
      upperBound: 0.08,
    );
  }

  @override
  void dispose() {
    _waveCtrl.dispose();
    _rotateCtrl.dispose();
    _pressCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.activeColor;

    return GestureDetector(
      onTapDown: (_) => _pressCtrl.forward(),
      onTapUp: (_) {
        _pressCtrl.reverse();
        HapticFeedback.mediumImpact();
        widget.onTap();
      },
      onTapCancel: () => _pressCtrl.reverse(),
      child: AnimatedBuilder(
        animation: Listenable.merge([_waveCtrl, _rotateCtrl, _pressCtrl]),
        builder: (context, _) {
          final pressScale = 1.0 - _pressCtrl.value;
          return Transform.scale(
            scale: pressScale,
            child: SizedBox(
              width: 220,
              height: 220,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // امواج راداری با محوشدن نرم هنگام قطع اتصال
                  AnimatedOpacity(
                    opacity: widget.isConnected || widget.isConnecting ? 1 : 0,
                    duration: const Duration(milliseconds: 520),
                    curve: Curves.easeOutCubic,
                    child: Stack(
                      alignment: Alignment.center,
                      children: List.generate(3, (index) {
                        final progress =
                            (_waveCtrl.value + (index * 0.333)) % 1.0;
                        final size = 128.0 + (progress * 88.0);
                        final opacity = (1.0 - progress).clamp(0.0, 1.0);
                        return Container(
                          width: size,
                          height: size,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: color.withOpacity(opacity * 0.65),
                              width: 2.5 * opacity + 0.5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: color.withOpacity(opacity * 0.2),
                                blurRadius: 14,
                              ),
                            ],
                          ),
                        );
                      }),
                    ),
                  ),

                  // ۲. حلقه سایبری چرخان با گرادیان نوری
                  Transform.rotate(
                    angle: _rotateCtrl.value * 2 * pi,
                    child: Container(
                      width: 162,
                      height: 162,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: SweepGradient(
                          colors: [
                            color.withOpacity(0.05),
                            color.withOpacity(
                                widget.isConnected || widget.isConnecting
                                    ? 0.95
                                    : 0.45),
                            color.withOpacity(0.05),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // ۳. لایه محافظ میانی
                  Container(
                    width: 152,
                    height: 152,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context).cardColor,
                    ),
                  ),

                  // ۴. هسته مرکزی درخشان دکمه
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 450),
                    curve: Curves.easeOutBack,
                    width: widget.isConnected ? 138 : 132,
                    height: widget.isConnected ? 138 : 132,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        center: const Alignment(-0.25, -0.25),
                        radius: 0.95,
                        colors: [
                          color,
                          Color.lerp(color, Colors.black, 0.45)!,
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: color.withOpacity(
                              widget.isConnected ? 0.65 : 0.35),
                          blurRadius: widget.isConnected ? 34 : 18,
                          spreadRadius: widget.isConnected ? 6 : 1,
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (widget.isConnecting)
                          const SizedBox(
                            width: 42,
                            height: 42,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 3.2,
                            ),
                          )
                        else
                          Icon(
                            widget.isConnected
                                ? Icons.shield_rounded
                                : Icons.power_settings_new_rounded,
                            size: 52,
                            color: Colors.white,
                          ),
                        const SizedBox(height: 6),
                        Text(
                          widget.isConnected
                              ? 'متصل'
                              : widget.isConnecting
                                  ? 'در حال اتصال'
                                  : 'شروع اتصال',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  ریشه اپلیکیشن و مدیریت تم
// ---------------------------------------------------------------------------

class ShinVPNApp extends StatefulWidget {
  const ShinVPNApp({super.key});

  @override
  State<ShinVPNApp> createState() => _ShinVPNAppState();
}

class _ShinVPNAppState extends State<ShinVPNApp> {
  AppThemeModeSetting currentTheme = AppThemeModeSetting.system;

  @override
  void initState() {
    super.initState();
    loadSavedTheme();
  }

  Future<void> loadSavedTheme() async {
    final prefs = await SharedPreferences.getInstance();
    // کلید جدید: ۰ سیستم، ۱ دارک، ۲ روشن
    final idx = prefs.getInt('saved_theme_mode_v2') ?? 0;
    if (!mounted) return;
    setState(() {
      currentTheme = AppThemeModeSetting.values[
          idx.clamp(0, AppThemeModeSetting.values.length - 1)];
    });
  }

  Future<void> setTheme(AppThemeModeSetting mode) async {
    setState(() => currentTheme = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('saved_theme_mode_v2', mode.index);
  }

  ThemeMode get _themeMode {
    switch (currentTheme) {
      case AppThemeModeSetting.system:
        return ThemeMode.system;
      case AppThemeModeSetting.dark:
        return ThemeMode.dark;
      case AppThemeModeSetting.light:
        return ThemeMode.light;
    }
  }

  ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF0E1015) : const Color(0xFFF4F5F7);
    final card = isDark ? const Color(0xFF181B22) : const Color(0xFFFFFFFF);
    final text = isDark ? const Color(0xFFF2F4F8) : const Color(0xFF14171F);
    const accent = Color(0xFF4F7CFF);
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: 'Vazirmatn',
      scaffoldBackgroundColor: bg,
      cardColor: card,
      dividerColor: isDark ? const Color(0xFF232732) : const Color(0xFFE6E8EE),
      colorScheme: isDark
          ? ColorScheme.dark(primary: accent, secondary: accent, surface: card)
          : ColorScheme.light(primary: accent, secondary: accent, surface: card),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: 'Vazirmatn',
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: text,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: card,
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(visualDensity: VisualDensity.compact),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'Vazirmatn', bodyColor: text, displayColor: text),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'Vazirmatn'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SHIN',
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: _themeMode,
      home: MainShell(onThemeChanged: setTheme, currentTheme: currentTheme),
    );
  }
}

// ---------------------------------------------------------------------------
//  پوسته اصلی برنامه (MainShell)
// ---------------------------------------------------------------------------

class MainShell extends StatefulWidget {
  final Function(AppThemeModeSetting) onThemeChanged;
  final AppThemeModeSetting currentTheme;

  const MainShell({
    super.key,
    required this.onThemeChanged,
    required this.currentTheme,
  });

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  late final V2ray flutterV2ray;
  V2RayStatus v2rayStatus = V2RayStatus();
  String coreVersion = '...';

  int currentTab = 0;
  List<ServerItem> servers = [];
  List<SubscriptionItem> subscriptions = [];
  String selectedServerId = '';
  String selectedGroupFilter = 'ALL';
  String searchQuery = '';
  bool sortByPing = false;
  PingMode selectedPingMode = PingMode.real;
  int pingProxyTimeoutSec = 5;
  bool pingBestOfTwo = false;
  bool pingBypassRouting = false;
  String pingTestUrl = kDefaultPingUrl;
  String ipAddress = '';
  String ipCountryCode = '';
  String serverIp = '';
  String serverCountryCode = '';
  bool isCheckingIp = false;
  bool isTestingAll = false;
  int pingTestsCompleted = 0;
  int pingTestsTotal = 0;

  bool _subUpdateMutex = false;
  bool isCheckingUpdate = false;
  bool isRequestingFromCreator = false;

  bool isProxyOnly = false;
  bool lowPowerMode = false;
  final Set<String> _sortedGroups = <String>{};
  final Set<String> _testingGroups = <String>{};
  final Set<String> _collapsedGroups = <String>{};
  bool bypassLan = true;
  bool bypassIran = true;
  bool enableMux = false;
  bool allowInsecureDefault = false;
  bool autoUpdateSubs = true;
  String selectedDns = '1.1.1.1';
  String hwid = '';
  String updateRepoUrl = 'https://api.github.com/repos/$kUpdateRepo/releases/latest';
  String availableVersion = '';
  String availableApkUrl = '';
  String availableChangelog = '';
  double? downloadProgress;

  bool get isConnected => v2rayStatus.state == 'CONNECTED';
  bool get isConnecting => v2rayStatus.state == 'CONNECTING';

  @override
  void initState() {
    super.initState();

    kQuickControlsChannel.setMethodCallHandler((call) async {
      if (call.method == 'quickToggleVpn' && mounted) {
        await toggleVpn();
      }
    });
    flutterV2ray = V2ray(
      onStatusChanged: (status) {
        if (mounted) setState(() => v2rayStatus = status);
        if (_pendingTarget == true && status.state == 'CONNECTED') {
          if (mounted) setState(() => _pendingTarget = null);
        }
        unawaited(
          _syncNativeConnectionState(status.state == 'CONNECTED', status.state),
        );
        if (status.state == 'DISCONNECTED' && mounted) {
          setState(() {
            ipAddress = '';
            ipCountryCode = '';
            serverIp = '';
            serverCountryCode = '';
          });
        }
      },
    );
    initEngineAndLoadData();
  }

  Future<void> initEngineAndLoadData() async {
    try {
      await flutterV2ray.initialize(
        notificationIconResourceType: 'mipmap',
        notificationIconResourceName: 'ic_launcher',
      );
    } catch (e) {
      if (mounted) showSnack('راه‌اندازی هسته Xray ناموفق بود: $e');
    }
    String ver = '';
    try {
    } catch (_) {}
    await loadPersistentData();
    if (!mounted) return;
    setState(() => coreVersion = ver.isEmpty ? 'هستهٔ Xray v26.9.9' : ver);
    await _syncNativeConnectionState(isConnected, v2rayStatus.state);
    await _consumePendingQuickAction();
    _autoUpdateOldSubscriptions();
    await _maybeShowOnboarding();
    unawaited(checkForAppUpdate(silent: true));
    unawaited(_setupBackgroundUpdates());
  }

  Future<void> _setupBackgroundUpdates() async {
    try {
      await UpdateNotifier.init();
      await UpdateNotifier.requestPermission();
      await Workmanager().initialize(shinUpdateDispatcher);
      await Workmanager().registerPeriodicTask(
        'shin-update-check',
        'shinUpdateCheck',
        frequency: const Duration(hours: 12),
        constraints: Constraints(networkType: NetworkType.connected),
      );
    } catch (_) {}
  }

  Future<void> _maybeShowOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('onboarding_done') ?? false) return;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const OnboardingScreen(),
      fullscreenDialog: true,
    ));
  }

  Future<void> _syncNativeConnectionState(bool connected, String status) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('bg_vpn_connected', connected);
      await kQuickControlsChannel.invokeMethod('setConnectionState', {
        'connected': connected,
        'status': status,
      });
    } catch (_) {}
  }

  Future<void> _consumePendingQuickAction() async {
    try {
      final action =
          await kQuickControlsChannel.invokeMethod('consumePendingAction');
      if (action == 'toggleVpn' && mounted) await toggleVpn();
    } catch (_) {}
  }

  // ------------------------------------------------------------------ دریافت سرور از سازنده (مورد ۳)

  void _showRequestServerFromCreatorDialog() {
    final userNoteCtrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            4,
            20,
            MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetHeader(Icons.cloud_download_rounded, const Color(0xFF10B981),
                  'دریافت سرور از سازنده',
                  'درخواست به وب‌سرویس سازنده ارسال می‌شود'),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'HWID: $hwid',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 11),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      tooltip: 'کپی شناسه',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: hwid));
                        showSnack('شناسه دستگاه کپی شد');
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: userNoteCtrl,
                decoration: const InputDecoration(
                  labelText: 'نام یا آیدی تلگرام (اختیاری)',
                  hintText: 'مثلاً @username',
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: const Icon(Icons.send_rounded),
                label: const Text(
                  'ارسال درخواست',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                onPressed: () {
                  final note = userNoteCtrl.text.trim();
                  Navigator.pop(ctx);
                  _sendServerRequestToCreator(note);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _sendServerRequestToCreator(String userNote) async {
    if (isRequestingFromCreator) return;
    setState(() => isRequestingFromCreator = true);
    showSnack('در حال ارسال درخواست سرور به سازنده...');

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 12);
    bool requestSent = false;
    bool subscriptionLoaded = false;

    final messageText = '🚀 درخواست سرور جدید در برنامه SHIN\n'
        '🔑 شناسه دستگاه (HWID): $hwid\n'
        '📝 پیام کاربر: ${userNote.isEmpty ? "بدون توضیح" : userNote}\n'
        '📱 نسخه برنامه: $kAppVersion\n'
        '🆔 شناسه درخواست: ${DateTime.now().microsecondsSinceEpoch}\n'
        '⏰ زمان: ${DateTime.now().toIso8601String()}';

    try {
      // درخواست فقط از طریق وب‌هوک HTTPS معتبرِ متعلق به سازنده ارسال می‌شود.
      // توکن ربات تلگرام نباید داخل APK قرار بگیرد؛ قابل استخراج است.
      if (Uri.tryParse(kCreatorWebhookUrl.trim())?.scheme == 'https') {
        final req = await client.postUrl(Uri.parse(kCreatorWebhookUrl.trim()));
        req.headers.set('Content-Type', 'application/json; charset=utf-8');
        req.add(utf8.encode(jsonEncode({
          'app': 'SHIN',
          'version': kAppVersion,
          'hwid': hwid,
          'note': userNote,
          'timestamp': DateTime.now().toIso8601String(),
        })));
        final resp = await req.close().timeout(const Duration(seconds: 12));
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          requestSent = true;
        }
      }

      // در صورت تعریف لینک اشتراک پیش‌فرض، پس از ثبت درخواست دریافت شود.
      if (kCreatorDefaultSubUrl.trim().startsWith('http')) {
        await processInput(
          kCreatorDefaultSubUrl.trim(),
          name: 'سرورهای اختصاصی SHIN',
        );
        subscriptionLoaded = true;
      }

      if (requestSent) {
        showSnack('درخواست شما با موفقیت برای سازنده ارسال شد! ✅');
      } else if (subscriptionLoaded) {
        showSnack('سرورهای پیش‌فرض SHIN دریافت شدند؛ وب‌هوک درخواست سازنده تنظیم نشده است.');
      } else {
        // کپی درخواست در صورت تنظیم‌نبودن وب‌هوک یا قطع بودن اینترنت
        await Clipboard.setData(ClipboardData(text: messageText));
        showSnack(
          'متن درخواست و شناسه HWID شما کپی شد؛ برای سازنده ارسال کنید 📩',
        );
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: messageText));
      showSnack(
        'خطا در ارتباط مستقیم؛ متن درخواست در کلیپ‌بورد کپی شد 📋',
      );
    } finally {
      client.close(force: true);
      if (mounted) setState(() => isRequestingFromCreator = false);
    }
  }

  // ------------------------------------------------------------------ ذخیره‌سازی

  Future<void> savePersistentData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('selectedServerId', selectedServerId);
      await prefs.setBool('isProxyOnly', isProxyOnly);
      await prefs.setBool('bypassLan', bypassLan);
      await prefs.setBool('bypassIran', bypassIran);
      await prefs.setBool('enableMux', enableMux);
      await prefs.setBool('allowInsecureDefault', allowInsecureDefault);
      await prefs.setBool('autoUpdateSubs', autoUpdateSubs);
      await prefs.setString('selectedDns', selectedDns);
      await prefs.setString('pingMode', selectedPingMode.name);
      await prefs.setBool('sortByPing', sortByPing);
      await prefs.setString('hwid', hwid);
      await prefs.setString('updateRepoUrl', updateRepoUrl);
      await prefs.setInt('pingProxyTimeoutSec', pingProxyTimeoutSec);
      await prefs.setBool('pingBestOfTwo', pingBestOfTwo);
      await prefs.setBool('pingBypassRouting', pingBypassRouting);
      await prefs.setString('pingTestUrl', pingTestUrl);
      await prefs.setBool('lowPowerMode', lowPowerMode);

      final active = selectedServer;
      if (active != null) {
        await prefs.setString(
          'native_ready_config',
          buildCustomizedConfig(active.fullJsonConfig),
        );
        await prefs.setString('native_ready_remark', active.remark);
      } else {
        await prefs.remove('native_ready_config');
        await prefs.remove('native_ready_remark');
      }

      final serversJson = servers.map((e) => jsonEncode(e.toJson())).toList();
      await prefs.setStringList('saved_servers_list', serversJson);

      final subsJson =
          subscriptions.map((e) => jsonEncode(e.toJson())).toList();
      await prefs.setStringList('saved_subs_list', subsJson);
    } catch (_) {}
  }

  Future<void> loadPersistentData() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      var savedHwid = prefs.getString('hwid') ?? '';
      if (savedHwid.isEmpty) {
        final rnd = Random.secure();
        savedHwid = List.generate(
          16,
          (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
      }

      final loadedServers = <ServerItem>[];
      for (final e
          in prefs.getStringList('saved_servers_list') ?? <String>[]) {
        try {
          loadedServers.add(ServerItem.fromJson(JsonMap.from(jsonDecode(e))));
        } catch (_) {}
      }
      final loadedSubs = <SubscriptionItem>[];
      for (final e in prefs.getStringList('saved_subs_list') ?? <String>[]) {
        try {
          loadedSubs
              .add(SubscriptionItem.fromJson(JsonMap.from(jsonDecode(e))));
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        hwid = savedHwid;
        selectedServerId = prefs.getString('selectedServerId') ?? '';
        isProxyOnly = false;
        bypassLan = prefs.getBool('bypassLan') ?? true;
        bypassIran = prefs.getBool('bypassIran') ?? true;
        enableMux = prefs.getBool('enableMux') ?? false;
        allowInsecureDefault = prefs.getBool('allowInsecureDefault') ?? false;
        autoUpdateSubs = prefs.getBool('autoUpdateSubs') ?? true;
        selectedDns = prefs.getString('selectedDns') ?? '1.1.1.1';
        updateRepoUrl = 'https://api.github.com/repos/$kUpdateRepo/releases/latest';
        selectedPingMode = PingMode.values.firstWhere(
          (mode) => mode.name == prefs.getString('pingMode'),
          orElse: () => PingMode.real,
        );
        sortByPing = prefs.getBool('sortByPing') ?? false;
        pingProxyTimeoutSec = prefs.getInt('pingProxyTimeoutSec') ?? 5;
        pingBestOfTwo = prefs.getBool('pingBestOfTwo') ?? false;
        pingBypassRouting = prefs.getBool('pingBypassRouting') ?? false;
        pingTestUrl = prefs.getString('pingTestUrl') ?? kDefaultPingUrl;
        lowPowerMode = prefs.getBool('lowPowerMode') ?? false;
        servers = loadedServers;
        subscriptions = loadedSubs;
        if (selectedServerId.isEmpty && servers.isNotEmpty) {
          selectedServerId = servers.first.id;
        }
      });
    } catch (_) {}
  }

  static String flagOf(String code) {
    if (code.length != 2) return '🏳️';
    final c = code.toUpperCase();
    return String.fromCharCodes([
      0x1F1E6 + c.codeUnitAt(0) - 0x41,
      0x1F1E6 + c.codeUnitAt(1) - 0x41,
    ]);
  }

  Future<JsonMap?> _fetchJson(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join();
      final data = jsonDecode(body);
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> checkIpCountry() async {
    if (isCheckingIp) return;
    setState(() => isCheckingIp = true);
    try {
      // در حالت VPN این درخواست از تونل عبور می‌کند و IP خروجی را برمی‌گرداند
      final exit = await _fetchJson('https://api.country.is/');

      var sIp = '';
      var sCode = '';
      final target = selectedServer;
      if (target != null) {
        final ep = extractServerEndpoint(target.fullJsonConfig);
        if (ep != null) {
          try {
            final addr = await InternetAddress.lookup(ep.host)
                .timeout(const Duration(seconds: 4));
            if (addr.isNotEmpty) {
              sIp = addr.first.address;
              final info = await _fetchJson('https://api.country.is/$sIp');
              sCode = (info?['country'] ?? '').toString();
            }
          } catch (_) {}
        }
      }

      if (!mounted) return;
      setState(() {
        ipAddress = (exit?['ip'] ?? '').toString();
        ipCountryCode = (exit?['country'] ?? '').toString();
        serverIp = sIp;
        serverCountryCode = sCode;
      });
    } finally {
      if (mounted) setState(() => isCheckingIp = false);
    }
  }

  // ------------------------------------------------------------------ ساخت کانفیگ

  String buildCustomizedConfig(String rawJson) {
    try {
      final JsonMap config = JsonMap.from(jsonDecode(rawJson));
      config['dns'] = {
        'servers': [selectedDns, '8.8.8.8', '1.1.1.1']
      };

      if (config['outbounds'] is List &&
          (config['outbounds'] as List).isNotEmpty) {
        final List outbounds = config['outbounds'];
        if (outbounds[0] is Map) {
          outbounds[0]['mux'] = {
            'enabled': enableMux,
            'concurrency': enableMux ? 8 : -1,
          };
          if (allowInsecureDefault &&
              outbounds[0]['streamSettings'] is Map &&
              outbounds[0]['streamSettings']['tlsSettings'] is Map) {
            outbounds[0]['streamSettings']['tlsSettings']['allowInsecure'] =
                true;
          }
        }
        final hasDirect =
            outbounds.any((o) => o is Map && o['tag'] == 'direct');
        if (!hasDirect) {
          outbounds
              .add({'tag': 'direct', 'protocol': 'freedom', 'settings': {}});
        }
      }

      final List<dynamic> rules = [];
      if (bypassLan) {
        rules.add({
          'type': 'field',
          'ip': [
            '10.0.0.0/8',
            '172.16.0.0/12',
            '192.168.0.0/16',
            '127.0.0.0/8'
          ],
          'outboundTag': 'direct'
        });
      }
      if (bypassIran) {
        rules.add({
          'type': 'field',
          'domain': ['regexp:.*\\.ir\$'],
          'outboundTag': 'direct'
        });
        rules.add({
          'type': 'field',
          'ip': [
            '2.144.0.0/14',
            '5.52.0.0/16',
            '31.2.128.0/17',
            '37.98.0.0/16',
            '78.38.0.0/15',
            '79.127.0.0/16'
          ],
          'outboundTag': 'direct'
        });
      }

      if (rules.isNotEmpty) {
        config['routing'] = {
          'domainStrategy': 'IPIfNonMatch',
          'rules': rules,
        };
        if (config['inbounds'] is List) {
          for (final inb in config['inbounds']) {
            if (inb is Map) {
              inb['sniffing'] = {
                'enabled': true,
                'destOverride': ['http', 'tls', 'quic'],
                'routeOnly': false,
              };
            }
          }
        }
      }

      return jsonEncode(config);
    } catch (_) {
      return rawJson;
    }
  }

  String buildLightweightPingConfig(String rawJson) {
    try {
      final JsonMap config = JsonMap.from(jsonDecode(rawJson));
      config['log'] = {'loglevel': 'none'};
      config.remove('routing');
      config.remove('dns');
      if (config['inbounds'] is List) {
        for (final inb in config['inbounds']) {
          if (inb is Map) {
            inb.remove('sniffing');
          }
        }
      }
      if (allowInsecureDefault &&
          config['outbounds'] is List &&
          (config['outbounds'] as List).isNotEmpty) {
        final first = config['outbounds'][0];
        if (first is Map &&
            first['streamSettings'] is Map &&
            first['streamSettings']['tlsSettings'] is Map) {
          first['streamSettings']['tlsSettings']['allowInsecure'] = true;
        }
      }
      return jsonEncode(config);
    } catch (_) {
      return rawJson;
    }
  }

  ServerItem? get selectedServer {
    if (servers.isEmpty) return null;
    try {
      return servers.firstWhere((s) => s.id == selectedServerId);
    } catch (_) {
      return servers.first;
    }
  }

  // ------------------------------------------------------------------ اتصال

  bool _vpnBusy = false;
  // نیت کاربر تا وقتی هسته تأیید کند: true = در حال وصل شدن، false = در حال قطع
  bool? _pendingTarget;
  int _pendingToken = 0;

  void _setPending(bool? value) {
    if (mounted) setState(() => _pendingTarget = value);
  }

  Future<void> _waitForState(String target, {int ms = 2500}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(end) && v2rayStatus.state != target) {
      await Future.delayed(const Duration(milliseconds: 150));
    }
  }

  Future<void> _stopVpn() async {
    if (mounted) {
      setState(() => v2rayStatus = V2RayStatus(state: 'DISCONNECTING'));
    }
    // کاشی Quick Settings همان لحظه خاموش شود، نه بعد از انتظار برای هسته
    unawaited(_syncNativeConnectionState(false, 'DISCONNECTING'));
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await flutterV2ray.stopV2Ray();
      } catch (_) {}
      await _waitForState('DISCONNECTED');
      if (v2rayStatus.state == 'DISCONNECTED') break;
    }
    if (mounted && v2rayStatus.state != 'DISCONNECTED') {
      setState(() => v2rayStatus = V2RayStatus(state: 'DISCONNECTED'));
    }
    await _syncNativeConnectionState(false, 'DISCONNECTED');
    _setPending(null);
  }

  Future<void> toggleVpn() async {
    if (_vpnBusy || _pendingTarget != null) return;
    _vpnBusy = true;
    HapticFeedback.mediumImpact();
    final wantConnect = !(isConnected || isConnecting);
    var started = false;
    try {
      if (!wantConnect) {
        _setPending(false);
        await _stopVpn();
        return;
      }

      final target = selectedServer;
      if (target == null) {
        showSnack('لطفاً ابتدا یک سرور اضافه کنید');
        return;
      }

      if (!isProxyOnly && !await flutterV2ray.requestPermission()) {
        showSnack('مجوز ساخت تونل VPN توسط سیستم صادر نشد');
        return;
      }

      _setPending(true);
      final token = ++_pendingToken;
      // اگر هسته هیچ‌وقت تأیید نکرد، نیت کاربر پس از ۱۵ ثانیه پاک می‌شود
      Future.delayed(const Duration(seconds: 15), () {
        if (mounted && _pendingToken == token && _pendingTarget == true) {
          setState(() => _pendingTarget = null);
        }
      });

      await savePersistentData();
      final finalConfig = buildCustomizedConfig(target.fullJsonConfig);
      await flutterV2ray.startV2Ray(
        remark: target.remark,
        config: finalConfig,
        proxyOnly: isProxyOnly,
        blockedApps: null,
        bypassSubnets: null,
      );
      started = true;
    } catch (e) {
      showSnack('خطا در برقراری اتصال: $e');
    } finally {
      _vpnBusy = false;
      if (wantConnect && !started && _pendingTarget == true) _setPending(null);
    }
  }

  Future<void> reconnectIfNeeded() async {
    if (!isConnected && !isConnecting) return;
    await flutterV2ray.stopV2Ray();
    for (var i = 0; i <= 24 && v2rayStatus.state != 'DISCONNECTED'; i++) {
      await Future.delayed(const Duration(milliseconds: 120));
    }
    await toggleVpn();
  }

  // ------------------------------------------------------------------ سیستم پینگ

  // Via Proxy: درخواست HTTP به آدرس تست، از داخل تونل/پروکسی سرور انجام می‌شود.
  // اگر «دو درخواست» فعال باشد، بهترین نتیجه از دو اجرا انتخاب می‌شود.
  Future<int> _measureThroughTunnel() async {
    final client = HttpClient()
      ..connectionTimeout = Duration(seconds: pingProxyTimeoutSec);
    try {
      final timeout = Duration(seconds: pingProxyTimeoutSec);
      final sw = Stopwatch()..start();
      final req = await client.getUrl(Uri.parse(pingTestUrl)).timeout(timeout);
      final resp = await req.close().timeout(timeout);
      sw.stop();
      await resp.drain<void>();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return -1;
    } finally {
      client.close(force: true);
    }
  }

  Future<int> _measureViaProxy(ServerItem server) async {
    if (isConnected) {
      // وقتی وصلیم، فقط سرور فعال تست می‌شود؛ درخواست از داخل تونل می‌رود
      if (server.id != selectedServerId) return -1;
      final viaTunnel = await _measureThroughTunnel();
      if (viaTunnel > 0) return viaTunnel;
      try {
        final ms = await flutterV2ray
            .getConnectedServerDelay(url: pingTestUrl)
            .timeout(Duration(seconds: pingProxyTimeoutSec));
        return ms > 0 ? ms : -1;
      } catch (_) {
        return -1;
      }
    }
    final raw = server.fullJsonConfig;
    final cfg = pingBypassRouting
        ? buildCustomizedConfig(raw)
        : buildLightweightPingConfig(raw);
    final timeout = Duration(seconds: pingProxyTimeoutSec);
    final attempts = pingBestOfTwo ? 2 : 1;

    final samples = <int>[];
    for (var i = 0; i < attempts; i++) {
      try {
        final ms = await flutterV2ray
            .getServerDelay(config: cfg)
            .timeout(timeout);
        if (ms > 0) samples.add(ms);
      } catch (_) {
        // این تلاش ناموفق بود؛ تلاش بعدی یا نتیجهٔ خطا
      }
    }
    if (samples.isEmpty) return -1;
    samples.sort();
    return samples.first;
  }

  Future<void> pingSingleServer(
    ServerItem server, {
    PingMode? mode,
    bool save = true,
  }) async {
    final testMode = mode ?? selectedPingMode;
    final key = testMode.name;
    if (!mounted || server.busyPings.contains(key)) return;

    setState(() => server.busyPings.add(key));

    var result = -1;
    try {
      result = await _measureViaProxy(server);
      if (result > 0) await _resolveServerCountry(server);
    } catch (_) {
      result = -1;
    } finally {
      server.busyPings.remove(key);
      server.pings[key] = result;
      if (mounted) setState(() {});
      if (save) await savePersistentData();
    }
  }

  // تعداد تست‌های همزمان Real Ping. اگر هسته در اجرای همزمان خطا داد، این عدد را ۱ کن.
  static const int kPingConcurrency = 8;

  Future<void> testAllPings() async {
    if (isTestingAll || servers.isEmpty) return;
    final mode = selectedPingMode;
    final queue = isConnected
        ? <ServerItem>[if (selectedServer != null) selectedServer!]
        : List<ServerItem>.from(servers);
    if (isConnected) {
      showSnack('هنگام اتصال فقط سرور فعال تست می‌شود');
    }
    if (queue.isEmpty) return;

    setState(() {
      isTestingAll = true;
      pingTestsCompleted = 0;
      pingTestsTotal = queue.length;
    });

    // استخر کارگرها: هر کارگر به محض پایان یک سرور، سرور بعدی را برمی‌دارد
    // و سرورهای کند باعث معطلی بقیه نمی‌شوند.
    var next = 0;
    Future<void> worker() async {
      while (mounted && next < queue.length) {
        final server = queue[next++];
        await pingSingleServer(server, mode: mode, save: false);
        if (mounted) setState(() => pingTestsCompleted++);
      }
    }

    try {
      final workers = min(kPingConcurrency, queue.length);
      await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    } finally {
      if (mounted) setState(() => isTestingAll = false);
      await savePersistentData();
    }
  }

  // ------------------------------------------------------------------ بررسی بروزرسانی

  Future<void> checkForXrayCoreUpdate() async {
    if (isCheckingUpdate) return;
    setState(() => isCheckingUpdate = true);
    showSnack('در حال بررسی آخرین نسخه هسته Xray از گیت‌هاب...');

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 12);
    try {
      final req = await client.getUrl(
        Uri.parse(
            'https://api.github.com/repos/XTLS/Xray-core/releases/latest'),
      );
      req.headers.set('User-Agent', 'SHIN-Updater');
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await utf8.decoder.bind(resp).join();
      final data = jsonDecode(body);
      final latestTag = (data['tag_name'] ?? 'نامشخص').toString();
      final publishedAt =
          (data['published_at'] ?? '').toString().split('T').first;

      if (!mounted) return;
      _infoSheet(
        icon: Icons.memory_rounded,
        color: const Color(0xFF22C55E),
        title: 'وضعیت هسته Xray',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _kv('نسخهٔ فعلی', coreVersion),
            _kv('آخرین نسخهٔ رسمی', '$latestTag ($publishedAt)'),
            const SizedBox(height: 6),
            const Text(
              'هسته Xray داخل کتابخانهٔ پلاگین است و با بروزرسانی پلاگین ارتقا می‌یابد.',
              style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.6),
            ),
          ],
        ),
        actions: (ctx) => [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('متوجه شدم'),
          ),
        ],
      );
    } catch (e) {
      showSnack('خطا در استعلام نسخه هسته: $e');
    } finally {
      client.close(force: true);
      if (mounted) setState(() => isCheckingUpdate = false);
    }
  }

  List<int> _verParts(String v) {
    return v
        .replaceAll(RegExp(r'[^0-9.]'), '')
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
  }

  bool _isNewer(String remote, String local) {
    final a = _verParts(remote);
    final b = _verParts(local);
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  Future<void> checkForAppUpdate({bool silent = false}) async {
    if (isCheckingUpdate) return;
    setState(() => isCheckingUpdate = true);

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final req = await client.getUrl(Uri.parse(updateRepoUrl.trim()));
      req.headers.set('User-Agent', 'SHIN-Updater');
      req.headers.set('Accept', 'application/vnd.github+json');
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await utf8.decoder.bind(resp).join();
      final data = jsonDecode(body);
      if (data is! Map) throw 'پاسخ نامعتبر از سرور';

      final tag = (data['tag_name'] ?? '').toString().replaceFirst(RegExp(r'^v'), '');
      final notes = (data['body'] ?? '').toString();

      // اگر چند APK وجود داشت، نسخهٔ arm64 ترجیح داده می‌شود
      var apk = '';
      final assets = data['assets'];
      if (assets is List) {
        var fallback = '';
        for (final a in assets) {
          if (a is! Map) continue;
          final name = (a['name'] ?? '').toString();
          if (!name.endsWith('.apk')) continue;
          final url = (a['browser_download_url'] ?? '').toString();
          if (name.contains('arm64')) {
            apk = url;
            break;
          }
          if (fallback.isEmpty) fallback = url;
        }
        if (apk.isEmpty) apk = fallback;
      }

      if (!mounted) return;
      final newer = tag.isNotEmpty && _isNewer(tag, kAppVersion);
      setState(() {
        availableVersion = newer ? tag : '';
        availableApkUrl = apk;
        availableChangelog = notes;
      });

      if (!silent) {
        if (newer) {
          _showUpdateSheet();
        } else {
          showSnack('برنامه به‌روز است ($kAppVersion)');
        }
      }
    } catch (_) {
      if (!silent) showSnack('بررسی بروزرسانی ناموفق بود');
    } finally {
      client.close(force: true);
      if (mounted) setState(() => isCheckingUpdate = false);
    }
  }

  void _showUpdateSheet() {
    _infoSheet(
      icon: Icons.system_update_rounded,
      color: const Color(0xFF4F7CFF),
      title: 'نسخهٔ جدید $availableVersion',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _kv('نسخهٔ فعلی', kAppVersion),
          if (availableChangelog.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: Text(
                  availableChangelog,
                  style: const TextStyle(fontSize: 12, height: 1.6),
                ),
              ),
            ),
          ],
        ],
      ),
      actions: (ctx) => [
        OutlinedButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('بعداً'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.download_rounded),
          label: const Text('دانلود و نصب'),
          onPressed: () {
            Navigator.pop(ctx);
            _downloadAndInstall();
          },
        ),
      ],
    );
  }

  Future<void> _downloadAndInstall() async {
    if (availableApkUrl.isEmpty) {
      showSnack('فایل نصبی این نسخه پیدا نشد');
      return;
    }
    setState(() => downloadProgress = 0);
    final client = HttpClient();
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
      await dir.create(recursive: true);
      final file = File('${dir.path}/shin-update.apk');

      final req = await client.getUrl(Uri.parse(availableApkUrl));
      req.followRedirects = true;
      req.maxRedirects = 5;
      final resp = await req.close();
      final total = resp.contentLength;
      var received = 0;
      final sink = file.openWrite();
      await for (final chunk in resp) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && mounted) {
          setState(() => downloadProgress = received / total);
        }
      }
      await sink.close();

      final result = await kQuickControlsChannel
          .invokeMethod<String>('installApk', {'path': file.path});
      if (result == 'permission') {
        showSnack('اجازهٔ نصب از این منبع را بدهید و دوباره تلاش کنید');
      }
    } catch (e) {
      showSnack('دانلود ناموفق بود: $e');
    } finally {
      client.close(force: true);
      if (mounted) setState(() => downloadProgress = null);
    }
  }

  Widget _updateBanner() {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.10),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'نسخهٔ جدید $availableVersion موجود است',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          if (downloadProgress != null)
            LinearProgressIndicator(
              value: downloadProgress == 0 ? null : downloadProgress,
            )
          else
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _downloadAndInstall,
                    child: const Text('دانلود و نصب'),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => setState(() => availableVersion = ''),
                  child: const Text('بعداً'),
                ),
              ],
            ),
        ],
      ),
    );
  }


  // ------------------------------------------------------------------ آپدیت سابسکریپشن

  Future<void> updateSubscription(
    SubscriptionItem sub, {
    bool silent = false,
  }) async {
    if (sub.isUpdating) return;
    while (_subUpdateMutex) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _subUpdateMutex = true;

    try {
      if (!mounted) return;
      setState(() {
        sub.isUpdating = true;
        sub.lastError = null;
      });

      ImportReport? best;
      FetchResult? bestFetch;
      String? networkError;

      final candidateUrls =
          resolveSubscriptionCandidateUrls(sub.url, sub.fallbackUrl);

      outerLoop:
      for (final targetUrl in candidateUrls) {
        for (final ua in kUserAgents) {
          final res = await fetchSubscription(targetUrl, ua, hwid);
          if (res.error != null) {
            networkError = res.error;
            break;
          }
          if (res.status != 200) {
            best ??= ImportReport()..httpStatus = res.status;
            best.httpStatus = res.status;
            continue;
          }
          final report =
              buildImport(res.body, subId: sub.id, subName: sub.name);
          report.httpStatus = res.status;
          if (best == null ||
              report.added > best.added ||
              best.httpStatus != 200) {
            best = report;
            bestFetch = res;
          }
          if (report.added > 0 &&
              report.failed == 0 &&
              report.unsupported.isEmpty) {
            break outerLoop;
          }
        }
      }

      if (!mounted) return;

      if (networkError != null && (best == null || best.added == 0)) {
        setState(() {
          sub.isUpdating = false;
          sub.lastError = 'خطای شبکه یا عدم دسترسی به لینک';
        });
        if (!silent) showSnack('خطا در دریافت سابسکریپشن «${sub.name}» ❌');
        return;
      }

      final report = best ?? ImportReport();

      if (report.added > 0) {
        final prev = selectedServer;
        final prevWasInThisSub = prev != null && prev.subId == sub.id;
        final prevRawUrl = prev?.rawUrl;
        final prevRemark = prev?.remark;

        servers.removeWhere((s) => s.subId == sub.id);
        servers.addAll(report.servers);

        if (prevWasInThisSub) {
          ServerItem? matched;
          if (prevRawUrl != null && prevRawUrl.isNotEmpty) {
            for (final s in report.servers) {
              if (s.rawUrl == prevRawUrl) {
                matched = s;
                break;
              }
            }
          }
          if (matched == null && prevRemark != null) {
            for (final s in report.servers) {
              if (s.remark == prevRemark) {
                matched = s;
                break;
              }
            }
          }
          if (matched != null) {
            selectedServerId = matched.id;
          }
        }
        if (!servers.any((s) => s.id == selectedServerId) &&
            servers.isNotEmpty) {
          selectedServerId = servers.first.id;
        }
      } else {
        sub.lastError = report.httpStatus != 200 && report.httpStatus != 0
            ? 'کد وضعیت سرور: ${report.httpStatus}'
            : 'هیچ سروری در پاسخ یافت نشد';
      }

      if (bestFetch != null) {
        final fallbackHeader = bestFetch.headers['fallback-url'] ??
            bestFetch.headers['x-fallback-url'];
        if (fallbackHeader != null && fallbackHeader.startsWith('http')) {
          sub.fallbackUrl = fallbackHeader.trim();
        }

        final info = bestFetch.headers['subscription-userinfo'];
        if (info != null) {
          sub.usedBytes = 0;
          for (final part in info.split(';')) {
            final kv = part.trim().split('=');
            if (kv.length != 2) continue;
            final value = double.tryParse(kv[1].trim())?.toInt() ?? 0;
            switch (kv[0].trim().toLowerCase()) {
              case 'upload':
              case 'download':
                sub.usedBytes += value;
                break;
              case 'total':
                sub.totalBytes = value;
                break;
              case 'expire':
                sub.expireSec = value;
                break;
            }
          }
        }
        final title = bestFetch.headers['profile-title'];
        if (title != null && title.isNotEmpty && sub.autoName) {
          var t = title.trim();
          if (t.toLowerCase().startsWith('base64:')) {
            t = LinkParser.decodeBase64Loose(t.substring(7)) ?? t;
          }
          if (t.isNotEmpty) {
            sub.name = t;
            for (final s in servers.where((s) => s.subId == sub.id)) {
              s.subName = t;
            }
          }
        }
      }

      setState(() {
        sub.isUpdating = false;
        if (report.added > 0) {
          sub.serverCount = report.added;
          sub.updatedAt = DateTime.now().millisecondsSinceEpoch;
        }
      });
      await savePersistentData();

      if (silent) return;
      if (report.hasProblems) {
        _showReportSheet(sub.name, report);
      } else {
        showSnack(
            'اشتراک «${sub.name}» بروزرسانی شد (${report.added} سرور) ✅');
      }
    } finally {
      _subUpdateMutex = false;
    }
  }

  Future<void> updateAllSubscriptions() async {
    if (subscriptions.isEmpty) {
      showSnack('هیچ سابسکریپشنی ثبت نشده است!');
      return;
    }
    for (final sub in List<SubscriptionItem>.from(subscriptions)) {
      await updateSubscription(sub);
    }
  }

  Future<void> _autoUpdateOldSubscriptions() async {
    if (!autoUpdateSubs) return;
    final cutoff =
        DateTime.now().subtract(const Duration(hours: 6)).millisecondsSinceEpoch;
    for (final sub in List<SubscriptionItem>.from(subscriptions)) {
      if (sub.updatedAt <= cutoff) {
        await updateSubscription(sub, silent: true);
      }
    }
  }

  // ------------------------------------------------------------------ ایمپورت

  Future<void> importFromClipboard() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      showSnack('کلیپ‌بورد خالی است! 📋');
      return;
    }
    await processInput(text);
  }

  Future<void> processInput(
    String input, {
    String? name,
    String? fallbackUrl,
  }) async {
    final text = input.trim();
    if (text.isEmpty) return;

    final isUrl =
        RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(text);
    if (isUrl) {
      final existing = subscriptions.where((s) => s.url == text);
      if (existing.isNotEmpty) {
        showSnack('این اشتراک قبلاً ثبت شده؛ در حال بروزرسانی...');
        await updateSubscription(existing.first);
        return;
      }

      var subName = (name ?? '').trim();
      var auto = false;
      if (subName.isEmpty) {
        final frag = Uri.tryParse(text)?.fragment ?? '';
        subName = frag.isNotEmpty
            ? LinkParser.safeDecode(frag)
            : 'اشتراک ${subscriptions.length + 1}';
        auto = frag.isEmpty;
      }

      final sub = SubscriptionItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: subName,
        url: text,
        fallbackUrl: (fallbackUrl ?? '').trim(),
        autoName: auto,
      );
      setState(() => subscriptions.add(sub));
      await savePersistentData();
      await updateSubscription(sub);
      return;
    }

    final report = buildImport(text, subId: 'manual', subName: 'دستی');
    final existingUrls = servers
        .where((s) => s.subId == 'manual')
        .map((s) => s.rawUrl)
        .toSet();
    final fresh = report.servers
        .where((s) => s.rawUrl.isEmpty || !existingUrls.contains(s.rawUrl))
        .toList();

    if (fresh.isNotEmpty) {
      setState(() {
        servers.addAll(fresh);
        if (selectedServerId.isEmpty) selectedServerId = fresh.first.id;
      });
      await savePersistentData();
    }

    if (report.failed > 0 ||
        report.unsupported.isNotEmpty ||
        report.added == 0) {
      _showReportSheet('افزودن دستی', report);
    } else if (fresh.isEmpty) {
      showSnack('این سرورها قبلاً در لیست وجود داشتند.');
    } else {
      showSnack('${fresh.length} سرور جدید با موفقیت اضافه شد! 🎉');
    }
  }

  void _showAddSheet() {
    final textCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final fallbackCtrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            4,
            20,
            MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFF3B82F6).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(Icons.add_link_rounded,
                          color: Color(0xFF3B82F6)),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'افزودن سرور یا اشتراک',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'لینک vless، vmess، trojan، ss، socks یا لینک اشتراک یا JSON را بچسبانید.',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: textCtrl,
                  minLines: 3,
                  maxLines: 6,
                  textDirection: TextDirection.ltr,
                  decoration: InputDecoration(
                    hintText: 'vless://... یا https://...',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.content_paste_rounded),
                      tooltip: 'چسباندن از کلیپ‌بورد',
                      onPressed: () async {
                        final d = await Clipboard.getData(Clipboard.kTextPlain);
                        if (d?.text != null) textCtrl.text = d!.text!.trim();
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  title: const Text('تنظیمات بیشتر',
                      style: TextStyle(fontSize: 13, color: Colors.grey)),
                  children: [
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'نام دلخواه (اختیاری)',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: fallbackCtrl,
                      textDirection: TextDirection.ltr,
                      decoration: const InputDecoration(
                        labelText: 'لینک جایگزین (اختیاری)',
                        hintText: 'https://backup-domain.com/sub/...',
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('افزودن'),
                  onPressed: () {
                    final t = textCtrl.text;
                    final n = nameCtrl.text;
                    final fb = fallbackCtrl.text;
                    if (t.trim().isEmpty) return;
                    Navigator.pop(ctx);
                    processInput(t, name: n, fallbackUrl: fb);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ ویرایشگر JSON سرور

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(k, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              v,
              textAlign: TextAlign.end,
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _infoSheet({
    required IconData icon,
    required Color color,
    required String title,
    required Widget body,
    required List<Widget> Function(BuildContext ctx) actions,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetHeader(icon, color, title),
              const SizedBox(height: 16),
              body,
              const SizedBox(height: 18),
              Row(
                children: [
                  for (var i = 0; i < actions(ctx).length; i++) ...[
                    if (i > 0) const SizedBox(width: 10),
                    Expanded(child: actions(ctx)[i]),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetHeader(IconData icon, Color color, String title, [String? subtitle]) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color.withOpacity(0.15),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              if (subtitle != null)
                Text(subtitle,
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      ],
    );
  }

  void _showJsonEditorModal(ServerItem server) {
    String prettyJson = server.fullJsonConfig;
    try {
      final decoded = jsonDecode(server.fullJsonConfig);
      prettyJson = const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {}

    final jsonCtrl = TextEditingController(text: prettyJson);
    final remarkCtrl = TextEditingController(text: server.remark);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            4,
            20,
            MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetHeader(Icons.data_object_rounded, const Color(0xFF8B5CF6),
                  'کانفیگ سرور', 'ویرایش JSON هستهٔ Xray'),
              const SizedBox(height: 14),
              TextField(
                controller: remarkCtrl,
                decoration: const InputDecoration(labelText: 'نام سرور'),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 260,
                child: TextField(
                  controller: jsonCtrl,
                  maxLines: null,
                  expands: true,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.copy_rounded),
                      label: const Text('کپی'),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: jsonCtrl.text));
                        showSnack('کانفیگ JSON کپی شد');
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.save_rounded),
                      label: const Text('ذخیره'),
                      onPressed: () {
                        try {
                          final parsed = jsonDecode(jsonCtrl.text);
                          if (parsed is! Map) {
                            throw const FormatException(
                                'JSON باید یک شیء باشد');
                          }
                          setState(() {
                            server.remark = remarkCtrl.text.trim().isEmpty
                                ? server.remark
                                : remarkCtrl.text.trim();
                            server.fullJsonConfig = jsonEncode(parsed);
                          });
                          savePersistentData();
                          Navigator.pop(ctx);
                          showSnack('تغییرات کانفیگ ذخیره شد');
                        } catch (e) {
                          showSnack('خطای سینتکس JSON: $e');
                        }
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ دیالوگ گزارش

  Future<bool> _confirmSheet({
    required IconData icon,
    required Color color,
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetHeader(icon, color, title),
              const SizedBox(height: 14),
              Text(message, style: const TextStyle(fontSize: 13, height: 1.6)),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('انصراف'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: color),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(confirmLabel),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return ok == true;
  }

  void _showReportSheet(String title, ImportReport r) {
    if (!mounted) return;
    final lines = <String>[];
    if (r.added > 0) lines.add('✅ ${r.added} سرور با موفقیت خوانده شد');
    if (r.failed > 0) {
      lines.add('⚠️ ${r.failed} لینک ناقص بود یا قابل پردازش نبود');
    }
    if (r.unsupported.isNotEmpty) {
      final parts = r.unsupported.entries
          .map((e) => '${e.key} (${e.value})')
          .join('، ');
      lines.add('🚫 پروتکل خارج از هسته Xray: $parts');
    }
    if (r.looksLikeHtml) {
      lines.add(
          '🌐 سرور یک صفحهٔ وب (HTML) برگرداند. لینک اشتباه است یا نیاز به ثبت HWID دارد.');
    }
    if (r.looksLikeClash) {
      lines.add(
          '📄 خروجی به فرمت Clash است. لطفاً لینک استاندارد V2Ray/Xray یا Base64 وارد کنید.');
    }
    if (r.httpStatus != 0 && r.httpStatus != 200 && r.added == 0) {
      lines.add('❌ کد پاسخ سرور: ${r.httpStatus}');
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetHeader(Icons.fact_check_rounded, const Color(0xFF3B82F6),
                  'گزارش پردازش', title),
              const SizedBox(height: 14),
              for (final l in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(l, style: const TextStyle(fontSize: 13, height: 1.6)),
                ),
              if (r.rawPreview.isNotEmpty && r.added == 0) ...[
                const SizedBox(height: 6),
                const Text('پیش‌نمایش پاسخ دریافتی:',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectableText(
                    r.rawPreview,
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('متوجه شدم'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void deleteServer(ServerItem s) {
    setState(() {
      servers.removeWhere((x) => x.id == s.id);
      if (selectedServerId == s.id) {
        selectedServerId = servers.isNotEmpty ? servers.first.id : '';
      }
    });
    savePersistentData();
  }

  Future<void> editSubscriptionDialog(SubscriptionItem sub) async {
    final nameCtrl = TextEditingController(text: sub.name);
    final urlCtrl = TextEditingController(text: sub.url);
    final fbCtrl = TextEditingController(text: sub.fallbackUrl);

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            4,
            20,
            MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetHeader(Icons.rss_feed_rounded, const Color(0xFF3B82F6),
                  'تنظیمات اشتراک'),
              const SizedBox(height: 14),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'نام اشتراک'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: urlCtrl,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(labelText: 'لینک اصلی'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: fbCtrl,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                  labelText: 'لینک جایگزین (اختیاری)',
                ),
              ),
              const SizedBox(height: 14),
              FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('ذخیره'),
              ),
            ],
          ),
        ),
      ),
    );

    if (saved == true) {
      setState(() {
        sub.name =
            nameCtrl.text.trim().isEmpty ? sub.name : nameCtrl.text.trim();
        sub.url = urlCtrl.text.trim().isEmpty ? sub.url : urlCtrl.text.trim();
        sub.fallbackUrl = fbCtrl.text.trim();
        sub.autoName = false;
        for (final s in servers.where((s) => s.subId == sub.id)) {
          s.subName = sub.name;
        }
      });
      await savePersistentData();
      showSnack('اشتراک بروزرسانی شد');
    }
  }

  Future<void> deleteSubscription(SubscriptionItem sub) async {
    final ok = await _confirmSheet(
      icon: Icons.delete_outline_rounded,
      color: Colors.redAccent,
      title: 'حذف اشتراک',
      message: 'اشتراک «${sub.name}» و تمام سرورهای آن حذف شوند؟',
      confirmLabel: 'حذف',
    );
    if (ok != true) return;
    setState(() {
      servers.removeWhere((s) => s.subId == sub.id);
      subscriptions.removeWhere((s) => s.id == sub.id);
      if (selectedGroupFilter == sub.id) selectedGroupFilter = 'ALL';
      if (!servers.any((s) => s.id == selectedServerId)) {
        selectedServerId = servers.isNotEmpty ? servers.first.id : '';
      }
    });
    await savePersistentData();
  }

  void showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, textDirection: TextDirection.rtl),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(body: _buildHomeTab()),
    );
  }

  List<ServerItem> get filteredServers {
    final list = servers.where((s) {
      final matchGroup =
          selectedGroupFilter == 'ALL' || s.subId == selectedGroupFilter;
      final matchSearch = searchQuery.isEmpty ||
          s.remark.toLowerCase().contains(searchQuery.toLowerCase()) ||
          s.protocol.toLowerCase().contains(searchQuery.toLowerCase());
      return matchGroup && matchSearch;
    }).toList();

    if (sortByPing) {
      int? value(ServerItem server) => server.pingFor(selectedPingMode);

      int rank(ServerItem server) {
        final ping = value(server);
        if (ping == null) return 1;
        if (ping <= 0) return 2;
        return 0;
      }

      list.sort((a, b) {
        final rankCompare = rank(a).compareTo(rank(b));
        if (rankCompare != 0) return rankCompare;
        return (value(a) ?? 0).compareTo(value(b) ?? 0);
      });
    }
    return list;
  }

  Future<void> _autoSelectBestServer() async {
    List<ServerItem> rankable() => servers
        .where((s) => (s.pingFor(PingMode.real) ?? 0) > 0)
        .toList()
      ..sort((a, b) =>
          a.pingFor(PingMode.real)!.compareTo(b.pingFor(PingMode.real)!));

    var candidates = rankable();
    if (candidates.isEmpty) {
      await testAllPings();
      candidates = rankable();
    }
    if (candidates.isEmpty) {
      showSnack('هیچ سرور سالمی پیدا نشد');
      return;
    }
    HapticFeedback.lightImpact();
    setState(() => selectedServerId = candidates.first.id);
    await savePersistentData();
    showSnack('بهترین سرور: ${candidates.first.remark}');
  }

  String _fmtSpeed(int bps) {
    if (bps < 1024) return '$bps B/s';
    if (bps < 1024 * 1024) return '${(bps / 1024).toStringAsFixed(1)} KB/s';
    return '${(bps / (1024 * 1024)).toStringAsFixed(2)} MB/s';
  }

  String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  final Map<String, String> _countryByIp = {};

  Future<void> _resolveServerCountry(ServerItem server) async {
    if (server.countryCode.isNotEmpty) return;
    final ep = extractServerEndpoint(server.fullJsonConfig);
    if (ep == null) return;
    try {
      final addr = await InternetAddress.lookup(ep.host)
          .timeout(const Duration(seconds: 4));
      if (addr.isEmpty) return;
      final ip = addr.first.address;
      var code = _countryByIp[ip] ?? '';
      if (code.isEmpty) {
        final info = await _fetchJson('https://api.country.is/$ip');
        code = (info?['country'] ?? '').toString();
        if (code.isNotEmpty) _countryByIp[ip] = code;
      }
      if (code.isNotEmpty) server.countryCode = code;
    } catch (_) {}
  }

  Widget _speedItem(IconData icon, Color color, String text) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(
          text,
          textDirection: TextDirection.ltr,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }

  Widget _speedRow() {
    final st = v2rayStatus;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Expanded(
            child: _speedItem(Icons.arrow_downward_rounded,
                const Color(0xFF22C55E), _fmtSpeed(st.downloadSpeed)),
          ),
          Expanded(
            child: _speedItem(Icons.arrow_upward_rounded,
                const Color(0xFFA855F7), _fmtSpeed(st.uploadSpeed)),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Colors.grey,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _settingsCard(List<Widget> children) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1)
              const Divider(height: 1, indent: 16, endIndent: 16),
          ],
        ],
      ),
    );
  }

  Widget _settingsSwitch({
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      value: value,
      onChanged: (v) {
        onChanged(v);
        savePersistentData();
      },
    );
  }

  Widget _settingsTile({
    required IconData icon,
    Color? color,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title, style: TextStyle(fontSize: 14, color: color)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
      trailing: trailing ?? const Icon(Icons.chevron_right_rounded, size: 20),
      onTap: onTap,
    );
  }

  Widget _statTile(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: const Color(0xFF3B82F6)),
          const SizedBox(height: 10),
          Text(
            value,
            textDirection: TextDirection.ltr,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildStatsTab() {
    final st = v2rayStatus;
    final pings = servers
        .map((s) => s.pingFor(PingMode.real))
        .whereType<int>()
        .where((p) => p > 0)
        .toList();
    final best = pings.isEmpty ? null : pings.reduce((a, b) => min(a, b));
    final avg =
        pings.isEmpty ? null : pings.reduce((a, b) => a + b) ~/ pings.length;
    final countries = servers
        .map((s) => s.countryCode)
        .where((c) => c.isNotEmpty)
        .toSet()
        .length;

    return Scaffold(
      appBar: AppBar(title: const Text('آمار')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _statTile('مدت اتصال', st.duration, Icons.timer_outlined),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _statTile('دریافتی', _fmtBytes(st.download),
                    Icons.arrow_downward_rounded),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _statTile(
                    'ارسالی', _fmtBytes(st.upload), Icons.arrow_upward_rounded),
              ),
            ],
          ),
          _sectionTitle('سرورها'),
          _settingsCard([
            _settingsTile(
              icon: Icons.dns_outlined,
              title: 'کل سرورها',
              trailing: Text('${servers.length}'),
            ),
            _settingsTile(
              icon: Icons.public_rounded,
              title: 'کشورها',
              trailing: Text('$countries'),
            ),
            _settingsTile(
              icon: Icons.speed_rounded,
              title: 'سرورهای تست‌شده',
              trailing: Text('${pings.length}'),
            ),
            _settingsTile(
              icon: Icons.bolt_rounded,
              title: 'بهترین پینگ',
              trailing: Text(best == null ? '—' : '$best ms',
                  textDirection: TextDirection.ltr),
            ),
            _settingsTile(
              icon: Icons.show_chart_rounded,
              title: 'میانگین پینگ',
              trailing: Text(avg == null ? '—' : '$avg ms',
                  textDirection: TextDirection.ltr),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _homeCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: iconColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (subtitle != null)
                      Text(subtitle,
                          style:
                              const TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }

  Widget _serverRow(ServerItem s) {
    final selected = s.id == selectedServerId;
    final ping = s.pingFor(PingMode.real);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: selected
            ? Border.all(color: const Color(0xFF3B82F6), width: 1.2)
            : null,
      ),
      child: ListTile(
        onTap: () {
          setState(() => selectedServerId = s.id);
          savePersistentData();
        },
        title: Text(
          s.remark,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14),
        ),
        subtitle: Text(s.protocol,
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
        trailing: ping == null
            ? const Text('—', style: TextStyle(color: Colors.grey))
            : Text(
                ping <= 0 ? 'خطا' : '$ping ms',
                textDirection: TextDirection.ltr,
                style: TextStyle(
                  color: pingColor(ping),
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
      ),
    );
  }

  void Function()? _settingsRebuild;

  void _applySetting(VoidCallback change) {
    setState(change);
    _settingsRebuild?.call();
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StatefulBuilder(
        builder: (ctx, setLocal) {
          _settingsRebuild = () => setLocal(() {});
          return Directionality(
            textDirection: TextDirection.rtl,
            child: _buildSettingsTab(),
          );
        },
      ),
    )).then((_) => _settingsRebuild = null);
  }

  Widget _homeHeader() {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.add_rounded),
          tooltip: 'افزودن سرور یا اشتراک',
          onPressed: _showAddSheet,
        ),
        const Expanded(
          child: Center(
            child: Text(
              'SHIN',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                letterSpacing: 2,
              ),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.settings_rounded),
          tooltip: 'تنظیمات',
          onPressed: _openSettings,
        ),
      ],
    );
  }

  List<ServerItem> _orderServers(List<ServerItem> list, {bool sort = true}) {
    if (!sort) return list;
    int rank(ServerItem s) {
      final p = s.pingFor(PingMode.real);
      if (p == null) return 2;
      if (p <= 0) return 3;
      return 1;
    }
    final copy = List<ServerItem>.from(list);
    copy.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      return (a.pingFor(PingMode.real) ?? 0).compareTo(b.pingFor(PingMode.real) ?? 0);
    });
    return copy;
  }

  Widget _serverBox(List<ServerItem> list) {
    final divider = Theme.of(context).dividerColor;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: divider),
      ),
      child: Column(
        children: [
          for (var i = 0; i < list.length; i++) ...[
            _serverTile(list[i]),
            if (i < list.length - 1) Divider(height: 1, color: divider),
          ],
        ],
      ),
    );
  }

  String _groupMeta(SubscriptionItem? sub, int count) {
    if (sub == null) return '$count سرور';
    final parts = <String>[
      '$count سرور',
      'بروزرسانی ${fmtAgo(sub.updatedAt)}',
    ];
    if (sub.expireSec > 0) {
      final days = DateTime.fromMillisecondsSinceEpoch(sub.expireSec * 1000)
          .difference(DateTime.now())
          .inDays;
      parts.add(days >= 0 ? '$days روز مانده' : 'منقضی شده');
    }
    return parts.join('  •  ');
  }

  Widget _groupSection({
    required String id,
    required String title,
    SubscriptionItem? sub,
    required List<ServerItem> servers,
  }) {
    final collapsed = _collapsedGroups.contains(id);
    final sorted = _sortedGroups.contains(id);
    final testing = _testingGroups.contains(id);
    final scheme = Theme.of(context).colorScheme;
    final divider = Theme.of(context).dividerColor;
    final used = sub?.usedBytes ?? 0;
    final total = sub?.totalBytes ?? 0;
    final unlimited = total <= 0;
    final ratio = unlimited ? 1.0 : (used / total).clamp(0.0, 1.0).toDouble();
    String expiry = 'بدون انقضا';
    if (sub != null && sub.expireSec > 0) {
      final days = DateTime.fromMillisecondsSinceEpoch(sub.expireSec * 1000)
          .difference(DateTime.now())
          .inDays;
      expiry = days >= 0 ? '$days روز مانده' : 'منقضی شده';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: divider),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () {
                        setState(() {
                          if (collapsed) {
                            _collapsedGroups.remove(id);
                          } else {
                            _collapsedGroups.add(id);
                          }
                        });
                      },
                      child: Row(
                        children: [
                          Icon(
                            collapsed
                                ? Icons.chevron_left_rounded
                                : Icons.expand_more_rounded,
                            size: 20,
                            color: Colors.grey,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  testing
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          tooltip: 'تست پینگ این اشتراک',
                          icon: const Icon(Icons.speed_rounded, size: 20),
                          onPressed: () => testGroupPings(id, servers),
                        ),
                  IconButton(
                    tooltip: sorted ? 'حذف مرتب‌سازی' : 'مرتب‌سازی بر اساس پینگ',
                    icon: Icon(
                      sorted ? Icons.sort_rounded : Icons.swap_vert_rounded,
                      size: 20,
                      color: sorted ? scheme.primary : null,
                    ),
                    onPressed: () {
                      setState(() {
                        if (sorted) {
                          _sortedGroups.remove(id);
                        } else {
                          _sortedGroups.add(id);
                        }
                      });
                    },
                  ),
                  if (sub != null) ...[
                    sub.isUpdating
                        ? const Padding(
                            padding: EdgeInsets.all(10),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            tooltip: 'بروزرسانی اشتراک',
                            icon: const Icon(Icons.refresh_rounded, size: 20),
                            onPressed: () => updateSubscription(sub),
                          ),
                    PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'edit') editSubscriptionDialog(sub);
                        if (v == 'copy') {
                          Clipboard.setData(ClipboardData(text: sub.url));
                          showSnack('لینک اشتراک کپی شد');
                        }
                        if (v == 'delete') deleteSubscription(sub);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('تنظیمات اشتراک')),
                        PopupMenuItem(value: 'copy', child: Text('کپی لینک')),
                        PopupMenuItem(value: 'delete', child: Text('حذف')),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            // اطلاعات از چپ به راست: حجم ← نوار ← انقضا، سپس تعداد و زمان بروزرسانی
            Directionality(
              textDirection: TextDirection.ltr,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Text(
                          unlimited
                              ? 'نامحدود'
                              : '${_fmtBytes(used)} / ${_fmtBytes(total)}',
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                              value: ratio,
                              minHeight: 6,
                              color: ratio > 0.9 ? Colors.redAccent : scheme.primary,
                              backgroundColor: scheme.primary.withOpacity(0.12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(expiry, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          '${servers.length} سرور',
                          style: const TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                        const Spacer(),
                        if (sub != null)
                          Text(
                            'بروزرسانی ${fmtAgo(sub.updatedAt)}',
                            style: const TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (!collapsed) ...[
              Divider(height: 1, color: divider),
              for (var i = 0; i < _orderServers(servers, sort: sorted).length; i++) ...[
                _serverTile(_orderServers(servers, sort: sorted)[i]),
                if (i < servers.length - 1) Divider(height: 1, color: divider),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Future<void> testGroupPings(String id, List<ServerItem> list) async {
    if (_testingGroups.contains(id)) return;
    final queue = isConnected
        ? list.where((s) => s.id == selectedServerId).toList()
        : List<ServerItem>.from(list);
    if (queue.isEmpty) {
      showSnack('سروری برای تست در این بخش نیست');
      return;
    }
    setState(() => _testingGroups.add(id));
    var next = 0;
    Future<void> worker() async {
      while (mounted && next < queue.length) {
        final server = queue[next++];
        await pingSingleServer(server, save: false);
      }
    }
    try {
      final workers = min(kPingConcurrency, queue.length);
      await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    } finally {
      if (mounted) setState(() => _testingGroups.remove(id));
      await savePersistentData();
    }
  }

  Widget _buildHomeTab() {
    final pending = _pendingTarget;
    final connected = pending == null ? isConnected : false;
    final connecting = pending != null ||
        isConnecting ||
        v2rayStatus.state == 'DISCONNECTING';
    final accent = connected ? const Color(0xFF22C55E) : const Color(0xFF4F7CFF);
    final statusTitle = pending == false
        ? 'در حال قطع...'
        : connected
            ? 'متصل'
            : connecting
                ? 'در حال اتصال...'
                : 'برای اتصال بزنید';
    final active = selectedServer;

    final grouped = <String, List<ServerItem>>{};
    for (final server in servers) {
      grouped.putIfAbsent(server.subId, () => <ServerItem>[]).add(server);
    }

    final sections = <Widget>[
      for (final sub in subscriptions)
        _groupSection(
          id: sub.id,
          title: sub.name,
          sub: sub,
          servers: grouped[sub.id] ?? const <ServerItem>[],
        ),
      if ((grouped['manual'] ?? const <ServerItem>[]).isNotEmpty)
        _groupSection(
          id: 'manual',
          title: 'سرورهای دستی',
          servers: grouped['manual']!,
        ),
    ];

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
            child: _homeHeader(),
          ),
          if (isTestingAll)
            LinearProgressIndicator(
              value: pingTestsTotal == 0 ? null : pingTestsCompleted / pingTestsTotal,
              minHeight: 2,
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                Center(
                  child: _PowerButton(
                    lowPower: lowPowerMode,
                    connected: connected,
                    connecting: connecting,
                    accent: accent,
                    onTap: toggleVpn,
                  ),
                ),
                const SizedBox(height: 14),
                Center(
                  child: Text(
                    statusTitle,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ),
                if (connecting)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        'لطفاً کمی صبر کنید',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                  ),
                if (connected)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${v2rayStatus.duration}${active != null ? '  •  ${active.remark}' : ''}',
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                  ),
                if (connected) ...[
                  const SizedBox(height: 14),
                  _speedRow(),
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton.icon(
                      onPressed: active == null || active.isPinging
                          ? null
                          : () => pingSingleServer(active, mode: PingMode.real),
                      icon: const Icon(Icons.speed_rounded, size: 18),
                      label: Text(
                        active == null
                            ? 'پینگ سرور فعال'
                            : active.isPinging
                                ? 'در حال تست...'
                                : active.pingFor(PingMode.real) == null
                                    ? 'تست پینگ سرور فعال'
                                    : active.pingFor(PingMode.real)! <= 0
                                        ? 'پینگ: خطا'
                                        : 'پینگ: ${active.pingFor(PingMode.real)} ms',
                        textDirection: TextDirection.ltr,
                      ),
                    ),
                  ),
                ],
                if (availableVersion.isNotEmpty) _updateBanner(),
                const SizedBox(height: 24),
                if (servers.isEmpty)
                  _emptyState(
                    icon: Icons.dns_outlined,
                    title: 'هنوز سروری اضافه نشده است',
                    subtitle: 'لینک سرور یا اشتراک را اضافه کنید.',
                    actionLabel: 'افزودن سرور',
                    onAction: _showAddSheet,
                  )
                else
                  ...sections,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState({
    required IconData icon,
    required String title,
    String? subtitle,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final color = Theme.of(context).colorScheme.primary;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 40, color: color),
            ),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.grey, height: 1.6)),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.add_rounded),
                label: Text(actionLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildServersTab() {
    final list = filteredServers;
    final hasManual = servers.any((s) => s.subId == 'manual');

    return Scaffold(
      appBar: AppBar(
        title: Text('سرورها · ${list.length}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.support_agent_rounded),
            tooltip: 'دریافت سرور از سازنده',
            onPressed: _showRequestServerFromCreatorDialog,
          ),
          isTestingAll
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.speed_rounded),
                  tooltip: 'تست پینگ همه سرورها',
                  onPressed: testAllPings,
                ),
          IconButton(
            icon: Icon(
              sortByPing ? Icons.sort_rounded : Icons.sort_by_alpha_rounded,
            ),
            tooltip: 'مرتب‌سازی بر اساس پینگ',
            onPressed: () {
              setState(() => sortByPing = !sortByPing);
              savePersistentData();
            },
          ),
          IconButton(
            icon: const Icon(Icons.add_rounded),
            tooltip: 'افزودن سرور',
            onPressed: _showAddSheet,
          ),
        ],
      ),
      body: Column(
        children: [
          if (isTestingAll)
            LinearProgressIndicator(
              value: pingTestsTotal == 0 ? null : pingTestsCompleted / pingTestsTotal,
              minHeight: 2,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: TextField(
              onChanged: (v) => setState(() => searchQuery = v),
              decoration: InputDecoration(
                hintText: 'جستجوی سرور یا پروتکل',
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: Theme.of(context).cardColor,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (subscriptions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Card(
                margin: EdgeInsets.zero,
                child: ExpansionTile(
                  leading: const Icon(Icons.rss_feed_rounded, size: 20),
                  title: Text(
                    'اشتراک‌ها (${subscriptions.length})',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.sync_rounded),
                    tooltip: 'بروزرسانی همه',
                    onPressed: updateAllSubscriptions,
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  children: [
                    for (final sub in subscriptions) _subscriptionTile(sub),
                  ],
                ),
              ),
            ),
          if (subscriptions.isNotEmpty || hasManual)
            SizedBox(
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                children: [
                  _groupChip('ALL', 'همه (${servers.length})'),
                  for (final sub in subscriptions) _groupChip(sub.id, sub.name),
                  if (hasManual) _groupChip('manual', 'دستی'),
                ],
              ),
            ),
          Expanded(
            child: list.isEmpty
                ? _emptyState(
                    icon: Icons.dns_outlined,
                    title: servers.isEmpty
                        ? 'هنوز سروری اضافه نشده است'
                        : 'سروری با این عبارت پیدا نشد',
                    subtitle: servers.isEmpty
                        ? 'لینک سرور یا اشتراک را اضافه کنید، یا از سازنده درخواست بدهید.'
                        : null,
                    actionLabel: servers.isEmpty ? 'افزودن سرور' : null,
                    onAction: servers.isEmpty ? _showAddSheet : null,
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) => _serverTile(list[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _groupChip(String id, String label) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: ChoiceChip(
        label: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11),
        ),
        selected: selectedGroupFilter == id,
        onSelected: (_) => setState(() => selectedGroupFilter = id),
      ),
    );
  }

  // آیتم سرور با فونت ۲ سایز کوچک‌تر (مورد ۴)
  Color _pingTone(int? ping) {
    if (ping == null) return Colors.grey;
    if (ping <= 0) return const Color(0xFFFF5252);
    if (ping <= 200) return const Color(0xFF22C55E);
    if (ping <= 400) return const Color(0xFFFFA726);
    return const Color(0xFFFF5252);
  }

  Widget _serverTile(ServerItem server) {
    final isSelected = server.id == selectedServerId;
    final ping = server.pingFor(PingMode.real);
    final tone = _pingTone(ping);
    final accent = Theme.of(context).colorScheme.primary;
    final busy = server.busyPings.contains(PingMode.real.name);

    return Material(
      color: isSelected ? accent.withOpacity(0.08) : Colors.transparent,
      child: InkWell(
        onLongPress: () => _showServerSheet(server),
        onTap: () async {
          setState(() => selectedServerId = server.id);
          await savePersistentData();
          await reconnectIfNeeded();
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      server.remark,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      server.protocol,
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  border: Border.all(color: tone, width: 1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  ping == null ? '—' : (ping <= 0 ? 'خطا' : '$ping ms'),
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: tone,
                  ),
                ),
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 36, height: 36),
                tooltip: 'تست پینگ این سرور',
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.speed_rounded, size: 18),
                onPressed: server.isPinging ? null : () => pingSingleServer(server),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showServerSheet(ServerItem server) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  server.remark,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12, // ۲ سایز کوچک‌تر (از 14 به 12)
                  ),
                ),
                subtitle: Text(
                  '${server.protocol} • ${server.subName}',
                  style: const TextStyle(fontSize: 10),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.edit_note_rounded),
                title: const Text('مشاهده و ویرایش کانفیگ JSON'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showJsonEditorModal(server);
                },
              ),
              if (server.rawUrl.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.link_rounded),
                  title: const Text('کپی لینک اشتراک‌گذاری سرور'),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: server.rawUrl));
                    Navigator.pop(ctx);
                    showSnack('لینک سرور کپی شد');
                  },
                ),
              ListTile(
                leading: const Icon(Icons.speed_rounded),
                title: const Text('تست پینگ این سرور'),
                onTap: () {
                  Navigator.pop(ctx);
                  pingSingleServer(server);
                },
              ),
              ListTile(
                leading:
                    const Icon(Icons.delete_outline_rounded, color: Colors.red),
                title: const Text(
                  'حذف سرور',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  deleteServer(server);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _subscriptionTile(SubscriptionItem sub) {
    final hasUsage = sub.totalBytes > 0;
    final usage =
        hasUsage ? (sub.usedBytes / sub.totalBytes).clamp(0.0, 1.0) : 0.0;
    String? expiry;
    if (sub.expireSec > 0) {
      final days = DateTime.fromMillisecondsSinceEpoch(sub.expireSec * 1000)
          .difference(DateTime.now())
          .inDays;
      expiry = days >= 0 ? '$days روز مانده' : 'منقضی شده';
    }
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  sub.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
              if (sub.isUpdating)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                  tooltip: 'بروزرسانی',
                  onPressed: () => updateSubscription(sub),
                ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'edit') editSubscriptionDialog(sub);
                  if (v == 'copy') {
                    Clipboard.setData(ClipboardData(text: sub.url));
                    showSnack('لینک اشتراک کپی شد');
                  }
                  if (v == 'delete') deleteSubscription(sub);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('تنظیمات اشتراک')),
                  PopupMenuItem(value: 'copy', child: Text('کپی لینک')),
                  PopupMenuItem(value: 'delete', child: Text('حذف')),
                ],
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 0, top: 2),
            child: Text(
              [
                '${sub.serverCount} سرور',
                'بروزرسانی ${fmtAgo(sub.updatedAt)}',
                if (expiry != null) expiry,
              ].join('  •  '),
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
          if (hasUsage) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: usage.toDouble(),
                minHeight: 6,
                color: usage > 0.9 ? Colors.redAccent : scheme.primary,
                backgroundColor: scheme.primary.withOpacity(0.12),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${_fmtBytes(sub.usedBytes)} / ${_fmtBytes(sub.totalBytes)}',
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildIpCard() {
    final exitFlag = flagOf(ipCountryCode);
    final serverFlag = flagOf(serverCountryCode);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.public_rounded, size: 18),
              const SizedBox(width: 6),
              const Text('IP و کشور', style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              if (isCheckingIp)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (ipAddress.isEmpty)
            const Text(
              'در حال تشخیص IP و کشور...',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            )
          else ...[
            Text(
              'IP خروجی: $ipAddress  $exitFlag ${ipCountryCode.toUpperCase()}',
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              serverIp.isEmpty
                  ? 'کشور سرور: نامشخص'
                  : 'IP سرور: $serverIp  $serverFlag ${serverCountryCode.toUpperCase()}',
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ],
      ),
    );
  }

  void _editPingUrl() {
    final controller = TextEditingController(text: pingTestUrl);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            4,
            20,
            MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetHeader(Icons.link_rounded, const Color(0xFF3B82F6),
                  'آدرس تست پینگ'),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(hintText: 'https://...'),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('انصراف'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        final v = controller.text.trim();
                        if (v.startsWith('https://') || v.startsWith('http://')) {
                          _applySetting(() => pingTestUrl = v);
                          savePersistentData();
                        }
                        Navigator.pop(ctx);
                      },
                      child: const Text('ذخیره'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsTab() {
    return Scaffold(
      appBar: AppBar(title: const Text('تنظیمات')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          _sectionTitle('ظاهر'),
          SegmentedButton<AppThemeModeSetting>(
            segments: const [
              ButtonSegment(
                value: AppThemeModeSetting.system,
                label: Text('سیستم'),
                icon: Icon(Icons.brightness_auto_rounded),
              ),
              ButtonSegment(
                value: AppThemeModeSetting.dark,
                label: Text('تیره'),
                icon: Icon(Icons.dark_mode_rounded),
              ),
              ButtonSegment(
                value: AppThemeModeSetting.light,
                label: Text('روشن'),
                icon: Icon(Icons.light_mode_rounded),
              ),
            ],
            selected: {widget.currentTheme},
            onSelectionChanged: (val) {
              widget.onThemeChanged(val.first);
              _settingsRebuild?.call();
            },
          ),
          _sectionTitle('مسیریابی'),
          _settingsCard([
            _settingsSwitch(
              title: 'بای‌پس ایران',
              subtitle: 'دامنه‌های .ir و آی‌پی‌های ایران مستقیم باز می‌شوند',
              value: bypassIran,
              onChanged: (v) => _applySetting(() => bypassIran = v),
            ),
            _settingsSwitch(
              title: 'بای‌پس شبکهٔ محلی',
              subtitle: 'ترافیک شبکهٔ محلی مستقیم وصل می‌شود',
              value: bypassLan,
              onChanged: (v) => _applySetting(() => bypassLan = v),
            ),
          ]),
          _sectionTitle('پیشرفته'),
          _settingsCard([
            _settingsSwitch(
              title: 'تجمیع اتصال (Mux)',
              subtitle: 'برای Reality و XHTTP خاموش بماند',
              value: enableMux,
              onChanged: (v) => _applySetting(() => enableMux = v),
            ),
            _settingsSwitch(
              title: 'پذیرش TLS نامعتبر',
              subtitle: 'گواهی‌های نامعتبر را قبول کن',
              value: allowInsecureDefault,
              onChanged: (v) => _applySetting(() => allowInsecureDefault = v),
            ),
            _settingsSwitch(
              title: 'اعمال مسیریابی روی پینگ',
              subtitle: 'قوانین بای‌پس را در پینگ اعمال کن',
              value: pingBypassRouting,
              onChanged: (v) => _applySetting(() => pingBypassRouting = v),
            ),
            _settingsSwitch(
              title: 'بهترین از دو پینگ',
              subtitle: 'دو درخواست بفرست و سریع‌تر را نگه دار',
              value: pingBestOfTwo,
              onChanged: (v) => _applySetting(() => pingBestOfTwo = v),
            ),
            _settingsSwitch(
              title: 'حالت کم‌مصرف',
              subtitle: 'انیمیشن و هالهٔ دکمهٔ اتصال خاموش می‌شوند',
              value: lowPowerMode,
              onChanged: (v) => _applySetting(() => lowPowerMode = v),
            ),
            ListTile(
              title: const Text('مهلت پینگ', style: TextStyle(fontSize: 14)),
              trailing: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 5, label: Text('5s')),
                  ButtonSegment(value: 15, label: Text('15s')),
                ],
                selected: {pingProxyTimeoutSec},
                onSelectionChanged: (v) {
                  _applySetting(() => pingProxyTimeoutSec = v.first);
                  savePersistentData();
                },
              ),
            ),
            _settingsTile(
              icon: Icons.link_rounded,
              title: 'آدرس تست پینگ',
              subtitle: pingTestUrl,
              trailing: const Icon(Icons.edit_rounded, size: 18),
              onTap: _editPingUrl,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('DNS ترجیحی',
                      style: TextStyle(fontSize: 14)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final d in kDnsOptions)
                        ChoiceChip(
                          label: Text(d),
                          selected: selectedDns == d,
                          onSelected: (_) {
                            _applySetting(() => selectedDns = d);
                            savePersistentData();
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ]),
          _sectionTitle('پشتیبانی'),
          _settingsCard([
            _settingsTile(
              icon: Icons.system_update_rounded,
              color: Colors.blueAccent,
              title: 'بررسی بروزرسانی برنامه',
              subtitle: 'نسخهٔ فعلی $kAppVersion',
              trailing: isCheckingUpdate
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
              onTap: () => checkForAppUpdate(),
            ),
            _settingsTile(
              icon: Icons.memory_rounded,
              color: Colors.greenAccent,
              title: 'هستهٔ Xray',
              subtitle: coreVersion,
              trailing: const Icon(Icons.sync_rounded, size: 20),
              onTap: checkForXrayCoreUpdate,
            ),
            _settingsTile(
              icon: Icons.fingerprint_rounded,
              title: 'شناسهٔ دستگاه',
              subtitle: hwid,
              trailing: const Icon(Icons.copy_rounded, size: 18),
              onTap: () {
                Clipboard.setData(ClipboardData(text: hwid));
                showSnack('شناسه HWID کپی شد');
              },
            ),
          ]),
          _sectionTitle('منطقهٔ خطر'),
          _settingsCard([
            _settingsTile(
              icon: Icons.delete_sweep_rounded,
              color: Colors.redAccent,
              title: 'حذف همهٔ سرورها و اشتراک‌ها',
              onTap: _confirmClearAll,
            ),
          ]),
        ],
      ),
    );
  }

  Future<void> _confirmClearAll() async {
    final ok = await _confirmSheet(
      icon: Icons.delete_sweep_rounded,
      color: Colors.redAccent,
      title: 'پاک کردن کل اطلاعات؟',
      message: 'تمام سرورها و اشتراک‌ها حذف خواهند شد.',
      confirmLabel: 'حذف همه',
    );
    if (ok != true) return;
    if (isConnected || isConnecting) await flutterV2ray.stopV2Ray();
    setState(() {
      servers.clear();
      subscriptions.clear();
      selectedServerId = '';
      selectedGroupFilter = 'ALL';
    });
    await savePersistentData();
  }
}

// ---------------------------------------------------------------------------
//  دکمهٔ اتصال مینیمال با هاله‌ی رنگی (سبک و بدون انیمیشن مداوم)
// ---------------------------------------------------------------------------

class _PowerButton extends StatelessWidget {
  final bool connected;
  final bool connecting;
  final Color accent;
  final bool lowPower;
  final VoidCallback onTap;

  const _PowerButton({
    this.lowPower = false,
    required this.connected,
    required this.connecting,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final card = Theme.of(context).cardColor;
    final ringColor = connected ? accent : accent.withOpacity(0.35);
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 220,
        height: 220,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (connecting)
              const SizedBox(
                width: 220,
                height: 220,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            AnimatedContainer(
              duration: lowPower ? Duration.zero : const Duration(milliseconds: 300),
              width: 190,
              height: 190,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: card,
                border: Border.all(color: ringColor, width: 2),
              ),
              child: Center(
                child: Text(
                  'S',
                  style: TextStyle(
                    fontSize: 84,
                    fontWeight: FontWeight.w900,
                    height: 1,
                    color: connected ? accent : Colors.grey,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  راهنمای اولین اجرا (فقط یک بار نمایش داده می‌شود)
// ---------------------------------------------------------------------------

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _controller = PageController();
  int _index = 0;

  static const List<(IconData, String, String)> _pages = [
    (
      Icons.shield_rounded,
      'به SHIN خوش آمدید',
      'اتصال امن و سریع با یک لمس روی دکمهٔ اصلی.'
    ),
    (
      Icons.add_link_rounded,
      'سرور اضافه کنید',
      'لینک سرور یا اشتراک را از کلیپ‌بورد یا از دکمهٔ افزودن وارد کنید.'
    ),
    (
      Icons.speed_rounded,
      'بهترین سرور را پیدا کنید',
      'با تست پینگ سرورها را مقایسه کنید یا از «بهترین سرور» استفاده کنید.'
    ),
  ];

  Future<void> _finish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_done', true);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final last = _index == _pages.length - 1;
    const accent = Color(0xFF3B82F6);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _finish,
                    child: const Text('رد کردن'),
                  ),
                ),
                Expanded(
                  child: PageView(
                    controller: _controller,
                    onPageChanged: (i) => setState(() => _index = i),
                    children: [
                      for (final page in _pages)
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 120,
                              height: 120,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: accent.withOpacity(0.15),
                              ),
                              child: Icon(page.$1, size: 56, color: accent),
                            ),
                            const SizedBox(height: 28),
                            Text(
                              page.$2,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              page.$3,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 14,
                                color: Colors.grey,
                                height: 1.7,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < _pages.length; i++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: i == _index ? 20 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: i == _index
                              ? accent
                              : Colors.grey.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: last
                        ? _finish
                        : () => _controller.nextPage(
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeOut,
                            ),
                    child: Text(last ? 'شروع' : 'بعدی'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
