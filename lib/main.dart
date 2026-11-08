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

Future<StringMap?> fetchLatestReleaseInfo() async {
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
      onDidReceiveNotificationResponse: (NotificationResponse response) {},
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

const Set<String> kIranianPackages = {
  'ir.nasim',
  'ir.divar',
  'com.bama.consumer',
  'com.farsitel.bazaar',
  'com.bazambazi',
  'com.samanpr.blu',
  'daal.co',
  'com.bmelat.mobile',
  'com.aparat',
  'cab.snapp.passenger.play',
};

const List<String> kIranianBankWords = [
  'بانک', 'بام', 'سکه', 'ویپاد', 'وپاد', 'فراز', 'همراه بانک', 'ملی', 'ملت',
  'سپه', 'صادرات', 'تجارت', 'پاسارگاد', 'ایران زمین', 'دی جت', 'بلو',
  'همراه کارت', 'آپ', 'قبضینو', 'بانکینو', 'شهر', 'کشاورزی',
  'مسکن', 'توسعه', 'رفاه', 'اقتصاد نوین', 'پست بانک', 'سامان', 'سینا',
  'آینده', 'کارآفرین', 'گردشگری', 'خاورمیانه', 'دی', 'ایران',
  'bank', 'Bank',
];

bool isIranianBankLabel(String name) {
  final n = name.toLowerCase();
  return kIranianBankWords.any((w) => n.contains(w.toLowerCase()));
}

bool isIranianPackage(String pkg) {
  final p = pkg.toLowerCase();
  return p.startsWith('ir.') || p.startsWith('cab.snapp.') || kIranianPackages.contains(p);
}

const Map<String, String> kCountryNames = {
  'DE': 'آلمان', 'US': 'آمریکا', 'GB': 'انگلیس', 'FI': 'فنلاند',
  'NL': 'هلند', 'TR': 'ترکیه', 'FR': 'فرانسه', 'CA': 'کانادا',
  'JP': 'ژاپن', 'SG': 'سنگاپور', 'AE': 'امارات', 'IR': 'ایران',
  'RU': 'روسیه', 'SE': 'سوئد', 'CH': 'سوئیس', 'HK': 'هنگ‌کنگ',
  'AU': 'استرالیا', 'NO': 'نروژ', 'IT': 'ایتالیا', 'ES': 'اسپانیا',
  'KR': 'کره جنوبی', 'IN': 'هند', 'AT': 'اتریش', 'PL': 'لهستان',
  'CZ': 'چک', 'RO': 'رومانی', 'UA': 'اوکراین', 'BG': 'بلغارستان',
  'MD': 'مولداوی', 'AL': 'آلبانی', 'BR': 'برزیل', 'ID': 'اندونزی',
};

const Map<String, List<String>> kCountryKeywords = {
  'DE': ['germany', 'german', 'آلمان', 'frankfurt', 'berlin'],
  'US': ['usa', 'united states', 'america', 'آمریکا', 'new york', 'los angeles'],
  'GB': ['united kingdom', 'england', 'london', 'انگلیس', 'بریتانیا'],
  'FI': ['finland', 'فنلاند', 'helsinki'],
  'NL': ['netherlands', 'holland', 'هلند', 'amsterdam'],
  'TR': ['turkey', 'turkiye', 'ترکیه', 'istanbul'],
  'FR': ['france', 'فرانسه', 'paris'],
  'CA': ['canada', 'کانادا'],
  'JP': ['japan', 'ژاپن', 'tokyo'],
  'SG': ['singapore', 'سنگاپور'],
  'AE': ['uae', 'emirates', 'امارات', 'dubai'],
  'IR': ['iran', 'ایران', 'tehran', 'تهران'],
  'RU': ['russia', 'روسیه', 'moscow'],
  'SE': ['sweden', 'سوئد'],
  'CH': ['switzerland', 'سوئیس'],
  'HK': ['hong kong', 'هنگ'],
  'AU': ['australia', 'استرالیا'],
  'NO': ['norway', 'نروژ'],
  'IT': ['italy', 'ایتالیا'],
  'ES': ['spain', 'اسپانیا'],
  'KR': ['korea', 'کره'],
  'IN': ['india', 'هند'],
  'AT': ['austria', 'اتریش'],
  'PL': ['poland', 'لهستان'],
  'UA': ['ukraine', 'اوکراین'],
};

String detectCountryFromText(String text) {
  final runes = text.runes.toList();
  for (var i = 0; i + 1 < runes.length; i++) {
    final a = runes[i];
    final b = runes[i + 1];
    if (a >= 0x1F1E6 && a <= 0x1F1FF && b >= 0x1F1E6 && b <= 0x1F1FF) {
      return String.fromCharCodes([a - 0x1F1E6 + 0x41, b - 0x1F1E6 + 0x41]);
    }
  }
  final lower = text.toLowerCase();
  for (final entry in kCountryKeywords.entries) {
    for (final kw in entry.value) {
      if (lower.contains(kw)) return entry.key;
    }
  }
  return '';
}

@pragma('vm:entry-point')
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
        blockedApps: ((prefs.getStringList('bypassApps') ?? const <String>[]).isEmpty
            ? null
            : prefs.getStringList('bypassApps')),
        bypassSubnets: null,
      );
    }
  } catch (_) {}
}

const String kAppVersion =
    String.fromEnvironment('APP_VERSION', defaultValue: '1.00.3');

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
          {
            'tag': 'direct',
            'protocol': 'freedom',
            'settings': {'domainStrategy': 'UseIP'}
          },
          {'tag': 'blackhole', 'protocol': 'blackhole', 'settings': {}},
        ],
      };

  static List<JsonMap> standardInbounds() => [
        {
          'tag': 'socks',
          'port': 10808,
          'protocol': 'socks',
          'listen': '127.0.0.1',
          'settings': {'auth': 'noauth', 'udp': true, 'userLevel': 8},
          'sniffing': {
            'enabled': true,
            'destOverride': ['http', 'tls', 'quic'],
            'routeOnly': false,
          },
        },
        {
          'tag': 'http',
          'port': 10809,
          'protocol': 'http',
          'listen': '127.0.0.1',
          'settings': {'userLevel': 8},
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

      if (cfg['inbounds'] == null || (cfg['inbounds'] as List).isEmpty) {
        cfg['inbounds'] = LinkParser.standardInbounds();
      }
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

class ServerItem {
  String id;
  String rawUrl;
  String remark;
  String protocol;
  String subId;
  String subName;
  String fullJsonConfig;
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
    final bg = isDark ? const Color(0xFF0E1015) : const Color(0xFFEDEDEF);
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
      segmentedButtonTheme: const SegmentedButtonThemeData(
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
  final bool lowPowerMode = true;
  final Set<String> _sortedGroups = <String>{};
  final Set<String> _testingGroups = <String>{};
  final Set<String> _countryGroups = <String>{};
  final Set<String> bypassApps = <String>{};
  bool autoPingOnOpen = true;
  List<StringMap> _installedApps = [];
  bool _appsLoading = false;
  bool iranianAutoDone = false;
  String _appsQuery = '';
  bool enableIPv6 = false;
  bool blockQuic = false;
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
    await loadPersistentData();
    if (!mounted) return;
    setState(() => coreVersion = 'هستهٔ Xray v26.9.9');
    await _syncNativeConnectionState(isConnected, v2rayStatus.state);
    await _consumePendingQuickAction();
    _autoUpdateOldSubscriptions();
    await _maybeShowOnboarding();
    unawaited(checkForAppUpdate(silent: true));
    unawaited(_setupBackgroundUpdates());
    if (autoPingOnOpen && servers.isNotEmpty) {
      unawaited(testAllPings());
    }
  }

  Future<void> _setupBackgroundUpdates() async {
    try {
      await UpdateNotifier.init();
      await UpdateNotifier.requestPermission();
      await Workmanager().initialize(shinUpdateDispatcher, isInDebugMode: false);
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
      await prefs.setBool('enableIPv6', enableIPv6);
      await prefs.setBool('blockQuic', blockQuic);
      await prefs.setStringList('bypassApps', bypassApps.toList());
      await prefs.setBool('autoPingOnOpen', autoPingOnOpen);
      await prefs.setBool('iranianAutoDone', iranianAutoDone);
      await prefs.setString('pingTestUrl', pingTestUrl);
      await prefs.setStringList('countryGroups', _countryGroups.toList());

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
        enableIPv6 = prefs.getBool('enableIPv6') ?? false;
        blockQuic = prefs.getBool('blockQuic') ?? false;
        bypassApps
          ..clear()
          ..addAll(prefs.getStringList('bypassApps') ?? const <String>[]);
        autoPingOnOpen = prefs.getBool('autoPingOnOpen') ?? true;
        iranianAutoDone = prefs.getBool('iranianAutoDone') ?? false;
        pingTestUrl = prefs.getString('pingTestUrl') ?? kDefaultPingUrl;
        _countryGroups
          ..clear()
          ..addAll(prefs.getStringList('countryGroups') ?? const <String>[]);
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

  String buildCustomizedConfig(String rawJson) {
    try {
      final JsonMap config = JsonMap.from(jsonDecode(rawJson));

      config['dns'] = {
        'servers': <dynamic>[
          selectedDns,
          '1.1.1.1',
          '8.8.8.8',
          if (bypassIran)
            {
              'address': '217.218.127.127',
              'port': 53,
              'domains': ['regexp:.*\\.ir\$'],
            },
        ],
        'queryStrategy': enableIPv6 ? 'UseIP' : 'UseIPv4',
      };

      if (config['inbounds'] is! List || (config['inbounds'] as List).isEmpty) {
        config['inbounds'] = LinkParser.standardInbounds();
      } else {
        final List inbounds = config['inbounds'];
        bool hasHttp = false;
        for (final inb in inbounds) {
          if (inb is Map) {
            if (inb['protocol'] == 'socks') {
              inb['port'] ??= 10808;
              inb['listen'] ??= '127.0.0.1';
              if (inb['settings'] is Map) {
                inb['settings']['udp'] = true;
                inb['settings']['auth'] ??= 'noauth';
              } else {
                inb['settings'] = {'auth': 'noauth', 'udp': true, 'userLevel': 8};
              }
            }
            if (inb['protocol'] == 'http') {
              hasHttp = true;
            }
            inb['sniffing'] = {
              'enabled': true,
              'destOverride': ['http', 'tls', 'quic'],
              'routeOnly': false,
            };
          }
        }
        if (!hasHttp) {
          inbounds.add({
            'tag': 'http',
            'port': 10809,
            'protocol': 'http',
            'listen': '127.0.0.1',
            'settings': {'userLevel': 8},
            'sniffing': {
              'enabled': true,
              'destOverride': ['http', 'tls', 'quic'],
              'routeOnly': false,
            },
          });
        }
      }

      String mainProxyTag = 'proxy';
      if (config['outbounds'] is List &&
          (config['outbounds'] as List).isNotEmpty) {
        final List outbounds = config['outbounds'];
        if (outbounds[0] is Map) {
          outbounds[0]['tag'] ??= 'proxy';
          mainProxyTag = outbounds[0]['tag'].toString();
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
        if (!outbounds.any((o) => o is Map && o['tag'] == 'direct')) {
          outbounds.add({
            'tag': 'direct',
            'protocol': 'freedom',
            'settings': {'domainStrategy': 'UseIP'}
          });
        }
        if (!outbounds.any((o) => o is Map && o['tag'] == 'blackhole')) {
          outbounds.add({
            'tag': 'blackhole',
            'protocol': 'blackhole',
            'settings': {}
          });
        }
        if (!outbounds.any((o) => o is Map && o['tag'] == 'dns-out')) {
          outbounds.add({'tag': 'dns-out', 'protocol': 'dns'});
        }
      }

      final List<dynamic> rules = [
        {
          'type': 'field',
          'port': '53',
          'outboundTag': 'dns-out',
        },
      ];

      if (blockQuic) {
        rules.add({
          'type': 'field',
          'network': 'udp',
          'port': '443',
          'outboundTag': 'blackhole',
        });
      }
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

      rules.add({
        'type': 'field',
        'network': 'tcp,udp',
        'outboundTag': mainProxyTag,
      });

      config['routing'] = {
        'domainStrategy': 'IPIfNonMatch',
        'rules': rules,
      };

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

  bool _vpnBusy = false;
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
        proxyOnly: false,
        blockedApps: bypassApps.isEmpty ? null : bypassApps.toList(),
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

  Future<int> _measureThroughTunnel() async {
    final url = Uri.parse(pingTestUrl.replaceFirst('https://', 'http://'));
    final timeout = Duration(seconds: pingProxyTimeoutSec);
    var best = -1;
    for (var attempt = 0; attempt < 2; attempt++) {
      final client = HttpClient()
        ..connectionTimeout = timeout
        ..idleTimeout = Duration.zero;
      try {
        final sw = Stopwatch()..start();
        final req = await client.getUrl(url).timeout(timeout);
        req.headers.set('Connection', 'close');
        final resp = await req.close().timeout(timeout);
        sw.stop();
        await resp.drain<void>();
        if (resp.statusCode == 204 || resp.statusCode == 200) {
          final ms = sw.elapsedMilliseconds;
          if (best < 0 || ms < best) best = ms;
        }
      } catch (_) {
      } finally {
        client.close(force: true);
      }
    }
    return best;
  }

  Future<int> _measureViaProxy(ServerItem server) async {
    if (isConnected) {
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
      } catch (_) {}
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
    final text = ValueNotifier<String>('در حال دانلود...');
    final value = ValueNotifier<double?>(null);
    final client = HttpClient();
    final version = availableVersion.isEmpty ? 'latest' : availableVersion;

    if (mounted) {
      showModalBottomSheet(
        context: context,
        isDismissible: false,
        showDragHandle: true,
        builder: (ctx) => Directionality(
          textDirection: TextDirection.rtl,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: ValueListenableBuilder<double?>(
              valueListenable: value,
              builder: (_, v, __) => ValueListenableBuilder<String>(
                valueListenable: text,
                builder: (_, t, __) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('دانلود نسخهٔ $version',
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    const SizedBox(height: 16),
                    LinearProgressIndicator(value: v, minHeight: 8),
                    const SizedBox(height: 10),
                    Text(t,
                        textAlign: TextAlign.center,
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(fontSize: 13)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
      if (await dir.exists()) {
        await for (final f in dir.list()) {
          if (f is File) await f.delete();
        }
      } else {
        await dir.create(recursive: true);
      }
      final file = File('${dir.path}/shin-$version.apk');

      final req = await client.getUrl(Uri.parse(availableApkUrl));
      req.followRedirects = true;
      req.maxRedirects = 5;
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw 'کد پاسخ سرور: ${resp.statusCode}';
      }
      final total = resp.contentLength;
      var received = 0;
      final sink = file.openWrite();
      await for (final chunk in resp) {
        sink.add(chunk);
        received += chunk.length;
        value.value = total > 0 ? received / total : null;
        text.value = total > 0
            ? '${(received / total * 100).toStringAsFixed(0)}%  •  '
                '${_fmtBytes(received)} از ${_fmtBytes(total)}'
            : '${_fmtBytes(received)} دانلود شده';
      }
      await sink.close();
      if (total > 0 && received != total) {
        throw 'دانلود کامل نشد (${_fmtBytes(received)} از ${_fmtBytes(total)})';
      }

      if (mounted) Navigator.of(context, rootNavigator: true).maybePop();
      final result = await kQuickControlsChannel
          .invokeMethod<String>('installApk', {'path': file.path});
      if (result == 'permission') {
        showSnack('اجازهٔ نصب از این منبع را بدهید و دوباره تلاش کنید');
      }
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).maybePop();
      showSnack('دانلود ناموفق بود: $e');
    } finally {
      client.close(force: true);
      text.dispose();
      value.dispose();
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

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(body: _buildHomeTab()),
    );
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

  void _showAddChooser() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
          child: Column(
            mainAxisSize: min(1, 1) == 1 ? MainAxisSize.min : MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                leading: const Icon(Icons.content_paste_rounded),
                title: const Text('وارد کردن از کلیپ‌بورد'),
                subtitle: const Text('لینک کپی‌شده را همین حالا اضافه کن'),
                onTap: () {
                  Navigator.pop(ctx);
                  importFromClipboard();
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit_note_rounded),
                title: const Text('افزودن دستی'),
                subtitle: const Text('لینک یا JSON را خودت وارد کن'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showAddSheet();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _homeHeader() {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.add_rounded),
          tooltip: 'افزودن سرور یا اشتراک',
          onPressed: _showAddChooser,
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

  Widget _usageBar(double ratio, String text, ColorScheme scheme) {
    final color = ratio > 0.9 ? Colors.redAccent : scheme.primary;
    return Container(
      height: 24,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: scheme.primary.withOpacity(0.08),
        border: Border.all(color: scheme.primary.withOpacity(0.25)),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: ratio,
              heightFactor: 1,
              child: Container(color: color.withOpacity(0.22)),
            ),
          ),
          Text(
            text,
            textDirection: TextDirection.ltr,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _groupSection({
    required String id,
    required String title,
    SubscriptionItem? sub,
    required List<ServerItem> servers,
  }) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: _groupSectionBody(
        id: id,
        title: title,
        sub: sub,
        servers: servers,
      ),
    );
  }

  Widget _groupSectionBody({
    required String id,
    required String title,
    SubscriptionItem? sub,
    required List<ServerItem> servers,
  }) {
    final collapsed = _collapsedGroups.contains(id);
    final sorted = _sortedGroups.contains(id);
    final byCountry = _countryGroups.contains(id);
    final testing = _testingGroups.contains(id);
    final scheme = Theme.of(context).colorScheme;
    final divider = Theme.of(context).dividerColor;
    final used = sub?.usedBytes ?? 0;
    final total = sub?.totalBytes ?? 0;
    final unlimited = total <= 0;
    final ratio = unlimited ? 1.0 : (used / total).clamp(0.0, 1.0).toDouble();
    final usageText =
        unlimited ? 'نامحدود' : '${_fmtBytes(used)} / ${_fmtBytes(total)}';
    var expiry = 'بدون انقضا';
    if (sub != null && sub.expireSec > 0) {
      final days = DateTime.fromMillisecondsSinceEpoch(sub.expireSec * 1000)
          .difference(DateTime.now())
          .inDays;
      expiry = days >= 0 ? 'انقضا: $days روز' : 'منقضی شده';
    }
    final ordered = _orderServers(servers, sort: sorted);

    void toggleCollapsed() {
      setState(() {
        if (collapsed) {
          _collapsedGroups.remove(id);
        } else {
          _collapsedGroups.add(id);
        }
      });
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: divider),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: collapsed ? 'باز کردن' : 'بستن',
                    icon: Icon(collapsed
                        ? Icons.chevron_left_rounded
                        : Icons.expand_more_rounded),
                    onPressed: toggleCollapsed,
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: toggleCollapsed,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            sub == null
                                ? '${servers.length} سرور'
                                : '${servers.length} سرور  •  بروزرسانی ${fmtAgo(sub.updatedAt)}',
                            style: const TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (testing)
                    const Padding(
                      padding: EdgeInsets.all(10),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    IconButton(
                      tooltip: 'تست پینگ این اشتراک',
                      icon: const Icon(Icons.speed_rounded, size: 20),
                      onPressed: () => testGroupPings(id, servers),
                    ),
                  if (sub != null)
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
                    tooltip: 'گزینه‌ها',
                    icon: const Icon(Icons.more_horiz_rounded),
                    onSelected: (v) {
                      if (v == 'sort') {
                        setState(() {
                          if (sorted) {
                            _sortedGroups.remove(id);
                          } else {
                            _sortedGroups.add(id);
                          }
                        });
                      }
                      if (v == 'country') {
                        setState(() {
                          if (byCountry) {
                            _countryGroups.remove(id);
                          } else {
                            _countryGroups.add(id);
                          }
                        });
                        savePersistentData();
                        if (!byCountry) _ensureCountries(servers);
                      }
                      if (sub != null && v == 'copy') {
                        Clipboard.setData(ClipboardData(text: sub.url));
                        showSnack('لینک اشتراک کپی شد');
                      }
                      if (sub != null && v == 'delete') {
                        setState(() {
                          servers.removeWhere((s) => s.subId == sub.id);
                          subscriptions.removeWhere((s) => s.id == sub.id);
                          if (selectedGroupFilter == sub.id) selectedGroupFilter = 'ALL';
                          if (!servers.any((s) => s.id == selectedServerId)) {
                            selectedServerId = servers.isNotEmpty ? servers.first.id : '';
                          }
                        });
                        savePersistentData();
                      }
                    },
                    itemBuilder: (_) => <PopupMenuEntry<String>>[
                      PopupMenuItem<String>(
                        value: 'sort',
                        child: Text(sorted
                            ? 'مرتب‌سازی: پیش‌فرض'
                            : 'مرتب‌سازی: بر اساس پینگ'),
                      ),
                      PopupMenuItem<String>(
                        value: 'country',
                        child: Text(byCountry
                            ? 'گروه‌بندی: بدون کشور'
                            : 'گروه‌بندی: بر اساس کشور'),
                      ),
                      if (sub != null) ...[
                        const PopupMenuItem<String>(
                          value: 'copy',
                          child: Text('کپی لینک'),
                        ),
                        const PopupMenuItem<String>(
                          value: 'delete',
                          child: Text('حذف'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Container(
              color: scheme.primary.withOpacity(0.05),
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'جزئیات',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.info_outline_rounded, color: scheme.primary),
                    onPressed: () => _infoSheet(
                      icon: Icons.info_outline_rounded,
                      color: scheme.primary,
                      title: title,
                      body: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _kv('تعداد سرور', '${servers.length}'),
                          _kv('حجم مصرف', usageText),
                          _kv('انقضا', expiry),
                          if (sub != null)
                            _kv('آخرین بروزرسانی', fmtAgo(sub.updatedAt)),
                        ],
                      ),
                      actions: (ctx) => [
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('بستن'),
                        ),
                      ],
                    ),
                  ),
                  Expanded(child: _usageBar(ratio, usageText, scheme)),
                  const SizedBox(width: 8),
                  Text(
                    expiry,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                  if (sub != null)
                    IconButton(
                      tooltip: 'کپی لینک',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.link_rounded, color: scheme.primary),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: sub.url));
                        showSnack('لینک اشتراک کپی شد');
                      },
                    ),
                ],
              ),
            ),
            if (!collapsed) ...[
              Divider(height: 1, color: divider),
              if (byCountry)
                _countryBlocks(servers, sorted)
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < ordered.length; i++) ...[
                      _serverTile(ordered[i]),
                      if (i < ordered.length - 1)
                        Divider(height: 1, color: divider),
                    ],
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _ensureCountries(List<ServerItem> list) async {
    final missing = list.where((x) => x.countryCode.isEmpty).toList();
    if (missing.isEmpty) return;
    var next = 0;
    Future<void> worker() async {
      while (mounted && next < missing.length) {
        final server = missing[next++];
        await _resolveServerCountry(server);
        if (server.countryCode.isEmpty) {
          server.countryCode = detectCountryFromText(server.remark);
        }
        if (mounted) setState(() {});
      }
    }
    await Future.wait([
      for (var i = 0; i < min(kPingConcurrency, missing.length); i++) worker(),
    ]);
    await savePersistentData();
  }

  Widget _countryBlocks(List<ServerItem> list, bool sorted) {
    final divider = Theme.of(context).dividerColor;
    final buckets = <String, List<ServerItem>>{};
    for (final server in list) {
      final code = server.countryCode.isEmpty ? '??' : server.countryCode.toUpperCase();
      buckets.putIfAbsent(code, () => <ServerItem>[]).add(server);
    }
    final keys = buckets.keys.toList()
      ..sort((a, b) {
        if (a == '??') return 1;
        if (b == '??') return -1;
        return (kCountryNames[a] ?? a).compareTo(kCountryNames[b] ?? b);
      });

    final children = <Widget>[];
    for (final key in keys) {
      final items = _orderServers(buckets[key]!, sort: sorted);
      children.add(Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        child: Row(
          children: [
            Text(key == '??' ? '🌐' : flagOf(key),
                style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                key == '??' ? 'نامشخص' : (kCountryNames[key] ?? key),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
            Text('${items.length}',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ));
      for (var i = 0; i < items.length; i++) {
        children.add(_serverTile(items[i]));
        if (i < items.length - 1) children.add(Divider(height: 1, color: divider));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
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
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.dns_outlined, size: 52, color: Colors.grey.shade400),
                          const SizedBox(height: 14),
                          const Text('هنوز سروری اضافه نشده است',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 14),
                          FilledButton.icon(
                            onPressed: _showAddSheet,
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('افزودن سرور'),
                          ),
                        ],
                      ),
                    ),
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

  Color _pingTone(int? ping) {
    if (ping == null) return Colors.grey;
    if (ping <= 0) return const Color(0xFFFF5252);
    if (ping <= 200) return const Color(0xFF22C55E);
    if (ping <= 400) return const Color(0xFFFFA726);
    return const Color(0xFFFF5252);
  }

  Widget _serverTile(ServerItem server) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: _serverTileBody(server),
    );
  }

  Widget _serverTileBody(ServerItem server) {
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
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
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
              Text(
                ping == null ? '—' : (ping <= 0 ? 'خطا' : '$ping ms'),
                textDirection: TextDirection.ltr,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: tone,
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
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
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
                leading: const Icon(Icons.delete_outline_rounded, color: Colors.red),
                title: const Text('حذف سرور', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() {
                    servers.removeWhere((x) => x.id == server.id);
                    if (selectedServerId == server.id) {
                      selectedServerId = servers.isNotEmpty ? servers.first.id : '';
                    }
                  });
                  savePersistentData();
                },
              ),
            ],
          ),
        ),
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
              _sheetHeader(Icons.link_rounded, const Color(0xFF3B82F6), 'آدرس تست پینگ'),
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

  void _openAppsPage() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _buildAppsPage(),
    ));
  }

  void _autoPickIranianApps({bool force = false}) {
    if (iranianAutoDone && !force) return;
    var added = 0;
    for (final app in _installedApps) {
      final pkg = app['package']!;
      final matched = isIranianPackage(pkg) || isIranianBankLabel(app['name']!);
      if (matched && bypassApps.add(pkg)) added++;
    }
    iranianAutoDone = true;
    savePersistentData();
    if (mounted) {
      showSnack(added > 0
          ? '$added برنامهٔ ایرانی به‌صورت خودکار خارج از VPN قرار گرفت'
          : 'برنامهٔ ایرانی جدیدی پیدا نشد');
    }
  }

  Future<void> _loadInstalledApps() async {
    try {
      final raw = await kQuickControlsChannel
              .invokeListMethod<dynamic>('getLaunchableApps') ??
          <dynamic>[];
      final apps = <StringMap>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final pkg = (item['package'] ?? '').toString();
        if (pkg.isEmpty) continue;
        apps.add({'name': (item['name'] ?? pkg).toString(), 'package': pkg});
      }
      apps.sort((a, b) => a['name']!.toLowerCase().compareTo(b['name']!.toLowerCase()));
      _installedApps = apps;
      _autoPickIranianApps();
    } catch (_) {
      showSnack('فهرست برنامه‌ها گرفته نشد');
    }
    _appsLoading = false;
  }

  Widget _buildAppsPage() {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: StatefulBuilder(
        builder: (ctx, setLocal) {
          if (_installedApps.isEmpty && !_appsLoading) {
            _appsLoading = true;
            _loadInstalledApps().then((_) {
              if (ctx.mounted) setLocal(() {});
            });
          }
          final q = _appsQuery.toLowerCase();
          final shown = _installedApps
              .where((a) =>
                  q.isEmpty ||
                  a['name']!.toLowerCase().contains(q) ||
                  a['package']!.contains(q))
              .toList();

          return Scaffold(
            appBar: AppBar(
              title: const Text('برنامه‌های خارج از VPN'),
              actions: [
                TextButton(
                  onPressed: () {
                    _autoPickIranianApps(force: true);
                    setLocal(() {});
                  },
                  child: const Text('ایرانی‌ها'),
                ),
              ],
            ),
            body: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: TextField(
                    onChanged: (v) {
                      _appsQuery = v;
                      setLocal(() {});
                    },
                    decoration: const InputDecoration(
                      hintText: 'جستجوی برنامه',
                      prefixIcon: Icon(Icons.search_rounded),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'برنامه‌های انتخاب‌شده مستقیم و بدون VPN وصل می‌شوند. تغییرات بعد از قطع و وصل مجدد اعمال می‌شود.',
                    style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.6),
                  ),
                ),
                Expanded(
                  child: _appsLoading && _installedApps.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : ListView.builder(
                          itemCount: shown.length,
                          itemBuilder: (_, i) {
                            final app = shown[i];
                            final pkg = app['package']!;
                            return CheckboxListTile(
                              value: bypassApps.contains(pkg),
                              title: Text(app['name']!),
                              subtitle: Text(pkg,
                                  textDirection: TextDirection.ltr,
                                  style: const TextStyle(fontSize: 11)),
                              onChanged: (v) {
                                _applySetting(() {
                                  if (v == true) {
                                    bypassApps.add(pkg);
                                  } else {
                                    bypassApps.remove(pkg);
                                  }
                                });
                                setLocal(() {});
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
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
          _sectionTitle('برنامه‌ها'),
          _settingsCard([
            _settingsTile(
              icon: Icons.apps_rounded,
              title: 'برنامه‌های خارج از VPN',
              subtitle: '${bypassApps.length} برنامه انتخاب شده',
              onTap: _openAppsPage,
            ),
          ]),
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
              title: 'پینگ خودکار هنگام باز شدن',
              subtitle: 'بعد از هر بار باز کردن برنامه، پینگ همهٔ سرورها گرفته شود',
              value: autoPingOnOpen,
              onChanged: (v) => _applySetting(() => autoPingOnOpen = v),
            ),
            _settingsSwitch(
              title: 'بستن QUIC (UDP 443)',
              subtitle: 'اگر اینستاگرام و بعضی سایت‌ها باز نمی‌شوند، روشن بماند',
              value: blockQuic,
              onChanged: (v) => _applySetting(() => blockQuic = v),
            ),
            _settingsSwitch(
              title: 'IPv6',
              subtitle: 'فقط اگر شبکه‌ات IPv6 دارد روشن کن',
              value: enableIPv6,
              onChanged: (v) => _applySetting(() => enableIPv6 = v),
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
                  const Text('DNS ترجیحی', style: TextStyle(fontSize: 14)),
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
        ],
      ),
    );
  }
}

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
