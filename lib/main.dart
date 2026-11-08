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
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
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

    final tag =
        (data['tag_name'] ?? '').toString().replaceFirst(RegExp(r'^v'), '');
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
  return p.startsWith('ir.') ||
      p.startsWith('cab.snapp.') ||
      kIranianPackages.contains(p);
}

const Map<String, String> kCountryNames = {
  'DE': 'Germany', 'US': 'USA', 'GB': 'UK', 'FI': 'Finland',
  'NL': 'Netherlands', 'TR': 'Turkey', 'FR': 'France', 'CA': 'Canada',
  'JP': 'Japan', 'SG': 'Singapore', 'AE': 'UAE', 'IR': 'Iran',
  'RU': 'Russia', 'SE': 'Sweden', 'CH': 'Switzerland', 'HK': 'Hong Kong',
  'AU': 'Australia', 'NO': 'Norway', 'IT': 'Italy', 'ES': 'Spain',
  'KR': 'South Korea', 'IN': 'India', 'AT': 'Austria', 'PL': 'Poland',
  'CZ': 'Czechia', 'RO': 'Romania', 'UA': 'Ukraine', 'BG': 'Bulgaria',
};

const Map<String, List<String>> kCountryKeywords = {
  'DE': ['germany', 'german', 'آلمان', 'frankfurt', 'berlin', 'de'],
  'US': ['usa', 'united states', 'america', 'آمریکا', 'new york', 'los angeles'],
  'GB': ['united kingdom', 'england', 'london', 'انگلیس', 'بریتانیا', 'uk'],
  'FI': ['finland', 'فنلاند', 'helsinki', 'fi'],
  'NL': ['netherlands', 'holland', 'هلند', 'amsterdam', 'nl'],
  'TR': ['turkey', 'turkiye', 'ترکیه', 'istanbul', 'tr'],
  'FR': ['france', 'فرانسه', 'paris', 'fr'],
  'CA': ['canada', 'کانادا'],
  'JP': ['japan', 'ژاپن', 'tokyo'],
  'SG': ['singapore', 'سنگاپور'],
  'AE': ['uae', 'emirates', 'امارات', 'dubai'],
  'IR': ['iran', 'ایران', 'tehran', 'تهران'],
  'RU': ['russia', 'روسیه', 'moscow'],
  'SE': ['sweden', 'سوئد'],
  'CH': ['switzerland', 'سوئیس'],
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
        blockedApps:
            ((prefs.getStringList('bypassApps') ?? const <String>[]).isEmpty
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
  '208.67.222.222',
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
      final item = ServerItem(
        id: '${subId}_${stamp}_$index',
        rawUrl: '',
        remark: remark.isEmpty ? 'Custom JSON $index' : remark,
        protocol: protocol,
        subId: subId,
        subName: subName,
        fullJsonConfig: jsonEncode(cfg),
      );
      item.countryCode = detectCountryFromText(item.remark);
      report.servers.add(item);
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
    final item = ServerItem(
      id: '${subId}_${stamp}_$index',
      rawUrl: link,
      remark: remark.isEmpty ? '$protocol $index' : remark,
      protocol: protocol == 'SS'
          ? 'SHADOWSOCKS'
          : (protocol == 'SOCKS5' ? 'SOCKS' : protocol),
      subId: subId,
      subName: subName,
      fullJsonConfig: fullConfig!,
    );
    item.countryCode = detectCountryFromText(item.remark);
    report.servers.add(item);
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
    if (item.countryCode.isEmpty) {
      item.countryCode = detectCountryFromText(item.remark);
    }
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

String fmtAgo(int ms) {
  if (ms <= 0) return 'هرگز';
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inMinutes <= 0) return 'همین الان';
  if (d.inMinutes <= 59) return '${d.inMinutes} دقیقه پیش';
  if (d.inHours <= 23) return '${d.inHours} ساعت پیش';
  return '${d.inDays} روز پیش';
}

class ShinVPNApp extends StatefulWidget {
  const ShinVPNApp({super.key});

  @override
  State<ShinVPNApp> createState() => _ShinVPNAppState();
}

class _ShinVPNAppState extends State<ShinVPNApp> {
  AppThemeModeSetting currentTheme = AppThemeModeSetting.dark;

  @override
  void initState() {
    super.initState();
    loadSavedTheme();
  }

  Future<void> loadSavedTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final idx = prefs.getInt('saved_theme_mode_v2') ?? 1;
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

  ThemeData _buildCyberDarkTheme() {
    const bg = Color(0xFF070B1E);
    const card = Color(0xFF101935);
    const text = Color(0xFFF2F6FF);
    const accent = Color(0xFF00F5A0);
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'Vazirmatn',
      scaffoldBackgroundColor: bg,
      cardColor: card,
      dividerColor: const Color(0xFF1E2C54),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF2B6FF7),
        secondary: accent,
        surface: card,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        foregroundColor: text,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: 'Vazirmatn',
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: text,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF131E3E),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFF25376B)),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Color(0xFF0D142B),
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(
          fontFamily: 'Vazirmatn', bodyColor: text, displayColor: text),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'Vazirmatn'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SHIN VPN',
      theme: _buildCyberDarkTheme(),
      darkTheme: _buildCyberDarkTheme(),
      themeMode: ThemeMode.dark,
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

  int activeBottomTab = 0;

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
  bool isTestingAll = false;
  int pingTestsCompleted = 0;
  int pingTestsTotal = 0;

  bool _subUpdateMutex = false;
  bool isCheckingUpdate = false;

  bool isProxyOnly = false;
  final Set<String> _countryGroups = <String>{};
  final Set<String> bypassApps = <String>{};
  bool autoPingOnOpen = true;
  List<StringMap> _installedApps = [];
  bool _appsLoading = false;
  bool iranianAutoDone = false;
  String _appsQuery = '';
  bool enableIPv6 = false;
  int mtuSize = 1500;
  bool keepCpuAlive = true;
  bool bypassLan = true;
  bool bypassIran = true;
  bool enableMux = false;
  bool allowInsecureDefault = false;
  bool autoUpdateSubs = true;
  String selectedDns = '1.1.1.1';
  String hwid = '';
  String updateRepoUrl =
      'https://api.github.com/repos/$kUpdateRepo/releases/latest';
  String availableVersion = '';
  String availableApkUrl = '';
  String availableChangelog = '';

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
    setState(() => coreVersion = 'Xray v26.10.31');
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
      await prefs.setInt('mtuSize', mtuSize);
      await prefs.setBool('keepCpuAlive', keepCpuAlive);
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
        updateRepoUrl =
            'https://api.github.com/repos/$kUpdateRepo/releases/latest';
        selectedPingMode = PingMode.values.firstWhere(
          (mode) => mode.name == prefs.getString('pingMode'),
          orElse: () => PingMode.real,
        );
        sortByPing = prefs.getBool('sortByPing') ?? false;
        pingProxyTimeoutSec = prefs.getInt('pingProxyTimeoutSec') ?? 5;
        pingBestOfTwo = prefs.getBool('pingBestOfTwo') ?? false;
        pingBypassRouting = prefs.getBool('pingBypassRouting') ?? false;
        enableIPv6 = prefs.getBool('enableIPv6') ?? false;
        mtuSize = prefs.getInt('mtuSize') ?? 1500;
        keepCpuAlive = prefs.getBool('keepCpuAlive') ?? true;
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
    if (code.length != 2) return '🌐';
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
                inb['settings'] = {
                  'auth': 'noauth',
                  'udp': true,
                  'userLevel': 8
                };
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
        {
          'type': 'field',
          'network': 'udp',
          'port': '443',
          'outboundTag': 'blackhole',
        },
      ];

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
      return (a.pingFor(PingMode.real) ?? 0)
          .compareTo(b.pingFor(PingMode.real) ?? 0);
    });
    return copy;
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
        showSnack('لطفاً ابتدا با دکمه + یک سرور یا اشتراک اضافه کنید');
        return;
      }

      if (!isProxyOnly && !await flutterV2ray.requestPermission()) {
        showSnack('مجوز ساخت تونل VPN صادر نشد');
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

      final tag =
          (data['tag_name'] ?? '').toString().replaceFirst(RegExp(r'^v'), '');
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
      color: const Color(0xFF00F5A0),
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
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 16)),
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
                '${_fmtBytes(received)} / ${_fmtBytes(total)}'
            : '${_fmtBytes(received)} دانلود شده';
      }
      await sink.close();

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
      _showAddChooser();
      return;
    }
    showSnack('در حال بروزرسانی اشتراک‌ها...');
    for (final sub in List<SubscriptionItem>.from(subscriptions)) {
      await updateSubscription(sub);
    }
  }

  Future<void> _autoUpdateOldSubscriptions() async {
    if (!autoUpdateSubs) return;
    final cutoff = DateTime.now()
        .subtract(const Duration(hours: 6))
        .millisecondsSinceEpoch;
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
            : 'Subscription ${subscriptions.length + 1}';
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

    final report = buildImport(text, subId: 'manual', subName: 'Manual');
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
      lines.add('🌐 سرور یک صفحهٔ وب (HTML) برگرداند.');
    }
    if (r.looksLikeClash) {
      lines.add('📄 خروجی به فرمت Clash است.');
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
              _sheetHeader(Icons.fact_check_rounded, const Color(0xFF00F5A0),
                  'گزارش پردازش', title),
              const SizedBox(height: 14),
              for (final l in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child:
                      Text(l, style: const TextStyle(fontSize: 13, height: 1.6)),
                ),
              const SizedBox(height: 14),
              FilledButton(
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
                _sheetHeader(Icons.add_link_rounded, const Color(0xFF00F5A0),
                    'افزودن سرور یا اشتراک'),
                const SizedBox(height: 14),
                TextField(
                  controller: textCtrl,
                  minLines: 3,
                  maxLines: 5,
                  textDirection: TextDirection.ltr,
                  decoration: InputDecoration(
                    hintText: 'vless://... یا https://...',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.content_paste_rounded),
                      onPressed: () async {
                        final d = await Clipboard.getData(Clipboard.kTextPlain);
                        if (d?.text != null) textCtrl.text = d!.text!.trim();
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'نام دلخواه اشتراک (اختیاری)',
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2B6FF7),
                    padding: const EdgeInsets.symmetric(vertical: 14),
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
          Text(k, style: const TextStyle(fontSize: 12, color: Colors.white60)),
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

  Widget _sheetHeader(IconData icon, Color color, String title,
      [String? subtitle]) {
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
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800)),
              if (subtitle != null)
                Text(subtitle,
                    style:
                        const TextStyle(fontSize: 12, color: Colors.white60)),
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
                  'ویرایش کانفیگ سرور'),
              const SizedBox(height: 14),
              TextField(
                controller: remarkCtrl,
                decoration: const InputDecoration(labelText: 'نام سرور'),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 240,
                child: TextField(
                  controller: jsonCtrl,
                  maxLines: null,
                  expands: true,
                  textDirection: TextDirection.ltr,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 12),
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
                        showSnack('کانفیگ کپی شد');
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
                            throw const FormatException('فرمت نامعتبر');
                          }
                          setState(() {
                            server.remark = remarkCtrl.text.trim().isEmpty
                                ? server.remark
                                : remarkCtrl.text.trim();
                            server.fullJsonConfig = jsonEncode(parsed);
                          });
                          savePersistentData();
                          Navigator.pop(ctx);
                          showSnack('ذخیره شد');
                        } catch (e) {
                          showSnack('خطا در JSON: $e');
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
        backgroundColor: const Color(0xFF152247),
        content: Text(msg,
            textDirection: TextDirection.rtl,
            style: const TextStyle(color: Colors.white)),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
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
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
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

  void Function()? _settingsRebuild;

  void _applySetting(VoidCallback change) {
    setState(change);
    _settingsRebuild?.call();
  }

  void _openSettings() {
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => StatefulBuilder(
            builder: (ctx, setLocal) {
              _settingsRebuild = () => setLocal(() {});
              return Directionality(
                textDirection: TextDirection.rtl,
                child: _buildSettingsTab(),
              );
            },
          ),
        ))
        .then((_) => _settingsRebuild = null);
  }

  void _openAdvancedSettings() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StatefulBuilder(
        builder: (ctx, setLocal) {
          return Directionality(
            textDirection: TextDirection.rtl,
            child: _buildAdvancedSettingsPage(setLocal),
          );
        },
      ),
    ));
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
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                leading: const Icon(Icons.content_paste_rounded,
                    color: Color(0xFF00F5A0)),
                title: const Text('وارد کردن از کلیپ‌بورد'),
                subtitle: const Text('افزودن سریع لینک کپی‌شده'),
                onTap: () {
                  Navigator.pop(ctx);
                  importFromClipboard();
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit_note_rounded,
                    color: Color(0xFF3B82F6)),
                title: const Text('افزودن دستی لینک یا اشتراک'),
                subtitle: const Text('ثبت لینک سابسکریپشن، کانفیگ یا JSON'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showAddSheet();
                },
              ),
              if (subscriptions.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.sync_rounded,
                      color: Color(0xFFF59E0B)),
                  title: const Text('بروزرسانی همه اشتراک‌ها'),
                  subtitle: Text('${subscriptions.length} اشتراک فعال'),
                  onTap: () {
                    Navigator.pop(ctx);
                    updateAllSubscriptions();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF060A17),
      body: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0.0, -0.35),
                  radius: 1.1,
                  colors: [
                    Color(0xFF0E2A47),
                    Color(0xFF09132B),
                    Color(0xFF050814),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 40,
            left: 0,
            right: 0,
            height: 360,
            child: CustomPaint(
              painter: _CyberWorldMapAndOrbitsPainter(
                isConnected: isConnected,
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: _buildCyberTopBar(),
                ),
                if (isTestingAll)
                  LinearProgressIndicator(
                    value: pingTestsTotal == 0
                        ? null
                        : pingTestsCompleted / pingTestsTotal,
                    minHeight: 2,
                    color: const Color(0xFF00F5A0),
                    backgroundColor: Colors.transparent,
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                    children: [
                      _buildCenterOrbSection(),
                      const SizedBox(height: 14),
                      _buildStatusPill(),
                      const SizedBox(height: 12),
                      _buildSpeedGlassPanel(),
                      const SizedBox(height: 10),
                      _buildPingPillButton(),
                      const SizedBox(height: 14),
                      _buildSubscriptionCrownCard(),
                      const SizedBox(height: 16),
                      _buildCyberTabSelector(),
                      const SizedBox(height: 12),
                      _buildActiveTabContent(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCyberTopBar() {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _glassCircleIconButton(
            icon: Icons.settings_rounded,
            onTap: _openSettings,
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        colors: [Color(0xFF00F5A0), Color(0xFF00D9F5)],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF00F5A0).withOpacity(0.45),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.bolt_rounded,
                      color: Color(0xFF04151F),
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'SHIN VPN',
                    style: TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              const Text(
                'Fast • Secure • Free',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white60,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
          _glassCircleIconButton(
            icon: Icons.add_rounded,
            onTap: _showAddChooser,
          ),
        ],
      ),
    );
  }

  Widget _glassCircleIconButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF131F42).withOpacity(0.75),
          border: Border.all(
            color: Colors.white.withOpacity(0.14),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 8,
            ),
          ],
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }

  Widget _buildCenterOrbSection() {
    final pending = _pendingTarget;
    final connected = pending == null ? isConnected : false;
    final connecting = pending != null ||
        isConnecting ||
        v2rayStatus.state == 'DISCONNECTING';

    return Center(
      child: _NeonOrbPowerButton(
        connected: connected,
        connecting: connecting,
        onTap: toggleVpn,
      ),
    );
  }

  Widget _buildStatusPill() {
    final pending = _pendingTarget;
    final connected = pending == null ? isConnected : false;
    final connecting = pending != null ||
        isConnecting ||
        v2rayStatus.state == 'DISCONNECTING';

    final statusText = pending == false
        ? 'Disconnecting...'
        : connected
            ? 'Connected  •  ${v2rayStatus.duration}'
            : connecting
                ? 'Connecting...'
                : 'Disconnected';

    final dotColor = connected
        ? const Color(0xFF00F5A0)
        : connecting
            ? const Color(0xFFF59E0B)
            : const Color(0xFF00E676);

    final active = selectedServer;
    final countryCode = active?.countryCode ?? '';
    final flag = countryCode.isNotEmpty ? flagOf(countryCode) : '🇩🇪';
    final serverLabel = active != null ? active.remark : 'No Server Selected';
    final pingVal = active?.pingFor(PingMode.real);
    final pingStr =
        (pingVal != null && pingVal > 0) ? '$pingVal ms' : '- ms';

    return Center(
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          constraints: const BoxConstraints(minWidth: 220, maxWidth: 310),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF101B3B).withOpacity(0.85),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
              color: const Color(0xFF283E7A).withOpacity(0.7),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.35),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dotColor,
                      boxShadow: [
                        BoxShadow(
                          color: dotColor.withOpacity(0.8),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    statusText,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(flag, style: const TextStyle(fontSize: 14)),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      serverLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    pingStr,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.white54,
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

  Widget _buildSpeedGlassPanel() {
    final st = v2rayStatus;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF0E1733).withOpacity(0.85),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: const Color(0xFF23366E).withOpacity(0.7),
            width: 1.2,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.arrow_upward_rounded,
                    color: Color(0xFF8B5CF6),
                    size: 24,
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _fmtSpeed(st.uploadSpeed),
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                      const Text(
                        'Upload',
                        style: TextStyle(fontSize: 11, color: Colors.white54),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Container(
              width: 1,
              height: 32,
              color: Colors.white.withOpacity(0.12),
            ),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.arrow_downward_rounded,
                    color: Color(0xFF00F5A0),
                    size: 24,
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _fmtSpeed(st.downloadSpeed),
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                      const Text(
                        'Download',
                        style: TextStyle(fontSize: 11, color: Colors.white54),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPingPillButton() {
    final active = selectedServer;
    final ping = active?.pingFor(PingMode.real);
    final busy = active?.isPinging ?? false;

    String label = 'Tap to Ping';
    if (busy) {
      label = 'Testing...';
    } else if (ping != null) {
      label = ping > 0 ? '$ping ms' : 'Timeout';
    }

    return Center(
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: active == null || busy
              ? null
              : () => pingSingleServer(active, mode: PingMode.real),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF101B3B).withOpacity(0.9),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: const Color(0xFF00D9F5).withOpacity(0.35),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.access_time_rounded,
                  size: 16,
                  color: Color(0xFF7DD3FC),
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF38BDF8),
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.speed_rounded,
                  size: 16,
                  color: Color(0xFF7DD3FC),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSubscriptionCrownCard() {
    final sub = subscriptions.isNotEmpty ? subscriptions.first : null;
    String subTitle = sub?.name ?? 'Subscription';
    String subStatus = 'Unlimited Access';

    if (sub != null && sub.expireSec > 0) {
      final days = DateTime.fromMillisecondsSinceEpoch(sub.expireSec * 1000)
          .difference(DateTime.now())
          .inDays;
      subStatus = days >= 0 ? 'Expires in $days days' : 'Expired';
    } else if (sub != null) {
      subStatus = '${sub.serverCount} servers active';
    } else {
      subStatus = '${servers.length} servers ready';
    }

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: const LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Color(0xFF7C3AED),
              Color(0xFF3B43A6),
              Color(0xFF1D4ED8),
            ],
          ),
          border: Border.all(
            color: const Color(0xFFA78BFA).withOpacity(0.45),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF6D28D9).withOpacity(0.35),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.14),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.22)),
              ),
              child: const Center(
                child: Text(
                  '👑',
                  style: TextStyle(fontSize: 26),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    subTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subStatus,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: updateAllSubscriptions,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFBBF24), Color(0xFFF59E0B)],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFF59E0B).withOpacity(0.45),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.calendar_month_rounded,
                      size: 16,
                      color: Color(0xFF1F1600),
                    ),
                    SizedBox(width: 5),
                    Text(
                      'Extend',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1F1600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCyberTabSelector() {
    Widget tabBtn(int index, IconData icon, String label) {
      final selected = activeBottomTab == index;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => activeBottomTab = index),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: selected
                  ? const LinearGradient(
                      colors: [Color(0xFF2563EB), Color(0xFF1D4ED8)],
                    )
                  : null,
              border: selected
                  ? Border.all(
                      color: const Color(0xFF60A5FA).withOpacity(0.6),
                    )
                  : null,
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: const Color(0xFF2563EB).withOpacity(0.45),
                        blurRadius: 12,
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: selected ? Colors.white : Colors.white60,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected ? Colors.white : Colors.white60,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: const Color(0xFF0E1733),
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: const Color(0xFF22356B)),
        ),
        child: Row(
          children: [
            tabBtn(0, Icons.dns_rounded, 'Servers'),
            tabBtn(1, Icons.tune_rounded, 'Settings'),
            tabBtn(2, Icons.more_horiz_rounded, 'More'),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveTabContent() {
    if (activeBottomTab == 1) {
      return _buildInlineQuickSettingsCard();
    }
    if (activeBottomTab == 2) {
      return _buildInlineMoreCard();
    }
    return _buildCyberServersContainer();
  }

  Widget _buildCyberServersContainer() {
    final sub = subscriptions.isNotEmpty ? subscriptions.first : null;
    final used = sub?.usedBytes ?? 0;
    final total = sub?.totalBytes ?? 0;
    final hasQuota = total > 0;
    final ratio =
        hasQuota ? (used / total).clamp(0.0, 1.0).toDouble() : 0.60;
    final usageText = hasQuota
        ? '${_fmtBytes(used)} / ${_fmtBytes(total)}'
        : '${servers.length} Servers Loaded';

    String daysLeftText = 'Unlimited';
    if (sub != null && sub.expireSec > 0) {
      final days = DateTime.fromMillisecondsSinceEpoch(sub.expireSec * 1000)
          .difference(DateTime.now())
          .inDays;
      daysLeftText = days >= 0 ? '$days days left' : 'Expired';
    }

    final ordered = _orderServers(servers, sort: sortByPing);

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0C142C).withOpacity(0.92),
          borderRadius: BorderRadius.circular(26),
          border: Border.all(
            color: const Color(0xFF294282),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF1E3A8A).withOpacity(0.25),
              blurRadius: 20,
            ),
          ],
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: testAllPings,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF38BDF8),
                          width: 2,
                        ),
                      ),
                      child: const Icon(
                        Icons.bolt_rounded,
                        size: 16,
                        color: Color(0xFF38BDF8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Container(
                      height: 26,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: const Color(0xFF152349),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: ratio,
                              heightFactor: 1,
                              child: Container(
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      Color(0xFF2563EB),
                                      Color(0xFF3B82F6),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Text(
                            usageText,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      setState(() => sortByPing = !sortByPing);
                      savePersistentData();
                      showSnack(sortByPing
                          ? 'مرتب‌سازی بر اساس کمترین پینگ فعال شد'
                          : 'مرتب‌سازی پیش‌فرض');
                    },
                    child: Icon(
                      sortByPing
                          ? Icons.sort_rounded
                          : Icons.info_outline_rounded,
                      size: 20,
                      color: Colors.white70,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 1,
                    height: 18,
                    color: Colors.white24,
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.calendar_today_rounded,
                    size: 14,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    daysLeftText,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFF1E2F5D)),
            if (ordered.isEmpty)
              Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  children: [
                    const Icon(Icons.dns_outlined,
                        size: 42, color: Colors.white38),
                    const SizedBox(height: 10),
                    const Text(
                      'No servers added yet',
                      style: TextStyle(
                          color: Colors.white70, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _showAddChooser,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add Server / Subscription'),
                    ),
                  ],
                ),
              )
            else
              for (var i = 0; i < ordered.length; i++) ...[
                _buildCyberServerRow(ordered[i], i),
                if (i < ordered.length - 1)
                  const Divider(
                    height: 1,
                    indent: 16,
                    endIndent: 16,
                    color: Color(0xFF1A2850),
                  ),
              ],
          ],
        ),
      ),
    );
  }

  Widget _buildCyberServerRow(ServerItem server, int index) {
    final isSelected = server.id == selectedServerId;
    final ping = server.pingFor(PingMode.real);
    final busy = server.busyPings.contains(PingMode.real.name);

    Widget leadingAvatar;
    if (server.countryCode.isNotEmpty) {
      leadingAvatar = Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF17254E),
          border: Border.all(color: Colors.white24),
        ),
        child: Center(
          child: Text(
            flagOf(server.countryCode),
            style: const TextStyle(fontSize: 20),
          ),
        ),
      );
    } else if (index % 3 == 0) {
      leadingAvatar = Container(
        width: 38,
        height: 38,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [Color(0xFF38BDF8), Color(0xFF0284C7)],
          ),
        ),
        child: const Icon(Icons.send_rounded, color: Colors.white, size: 18),
      );
    } else {
      leadingAvatar = Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          gradient: const LinearGradient(
            colors: [Color(0xFF8B5CF6), Color(0xFF3B82F6)],
          ),
        ),
        child: const Icon(Icons.storage_rounded, color: Colors.white, size: 20),
      );
    }

    String badgeText = 'Select';
    Color badgeBg = const Color(0xFF1E293B);
    Color badgeBorder = const Color(0xFF475569);
    Color badgeTextColor = Colors.white70;

    if (busy) {
      badgeText = '...';
    } else if (ping != null && ping > 0) {
      badgeText = '$ping ms';
      badgeBg = const Color(0xFF064E3B);
      badgeBorder = const Color(0xFF10B981);
      badgeTextColor = const Color(0xFF34D399);
    } else if (isSelected) {
      badgeText = 'Active';
      badgeBg = const Color(0xFF064E3B);
      badgeBorder = const Color(0xFF10B981);
      badgeTextColor = const Color(0xFF34D399);
    }

    return InkWell(
      onTap: () async {
        setState(() => selectedServerId = server.id);
        await savePersistentData();
        await reconnectIfNeeded();
      },
      onLongPress: () => _showServerSheet(server),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            leadingAvatar,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          server.remark,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight:
                                isSelected ? FontWeight.w800 : FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      if (isSelected) ...[
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.check_circle_rounded,
                          color: Color(0xFF00F5A0),
                          size: 16,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    server.protocol,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => pingSingleServer(server),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: badgeBorder),
                ),
                child: Text(
                  badgeText,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: badgeTextColor,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: () => _showServerSheet(server),
              child: const Icon(
                Icons.open_in_new_rounded,
                size: 18,
                color: Colors.white60,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInlineQuickSettingsCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0C142C).withOpacity(0.92),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFF294282)),
      ),
      child: Column(
        children: [
          _settingsSwitch(
            icon: Icons.flag_circle_rounded,
            iconColor: const Color(0xFF00F5A0),
            title: 'بای‌پس سایت‌ها و برنامه‌های ایرانی',
            subtitle: 'اتصال مستقیم برای دامنه‌های .ir و آی‌پی‌های ایران',
            value: bypassIran,
            onChanged: (v) => _applySetting(() => bypassIran = v),
          ),
          _settingsSwitch(
            icon: Icons.router_rounded,
            iconColor: const Color(0xFF38BDF8),
            title: 'بای‌پس شبکه محلی (LAN)',
            subtitle: 'دسترسی مستقیم به مودم و شبکه داخلی',
            value: bypassLan,
            onChanged: (v) => _applySetting(() => bypassLan = v),
          ),
          _settingsTile(
            icon: Icons.apps_rounded,
            iconColor: const Color(0xFF8B5CF6),
            title: 'برنامه‌های خارج از VPN',
            subtitle: '${bypassApps.length} برنامه انتخاب شده',
            onTap: _openAppsPage,
          ),
          _settingsTile(
            icon: Icons.tune_rounded,
            iconColor: const Color(0xFFF59E0B),
            title: 'باز کردن صفحه کامل تنظیمات',
            subtitle: 'DNS، پشتیبان‌گیری، تنظیمات پیشرفته هسته',
            onTap: _openSettings,
          ),
        ],
      ),
    );
  }

  Widget _buildInlineMoreCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0C142C).withOpacity(0.92),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFF294282)),
      ),
      child: Column(
        children: [
          _settingsTile(
            icon: Icons.speed_rounded,
            iconColor: const Color(0xFF00F5A0),
            title: 'تست پینگ همه سرورها',
            subtitle: '${servers.length} سرور آماده تست',
            onTap: testAllPings,
          ),
          _settingsTile(
            icon: Icons.sync_rounded,
            iconColor: const Color(0xFF38BDF8),
            title: 'بروزرسانی همه اشتراک‌ها',
            subtitle: '${subscriptions.length} اشتراک ثبت‌شده',
            onTap: updateAllSubscriptions,
          ),
          _settingsTile(
            icon: Icons.file_upload_outlined,
            iconColor: const Color(0xFFA855F7),
            title: 'پشتیبان‌گیری در کلیپ‌بورد (Backup)',
            subtitle: 'ذخیره تمام سرورها و تنظیمات',
            onTap: _exportBackup,
          ),
          _settingsTile(
            icon: Icons.system_update_rounded,
            iconColor: const Color(0xFFF59E0B),
            title: 'بررسی بروزرسانی برنامه',
            subtitle: 'نسخه فعلی: $kAppVersion',
            onTap: () => checkForAppUpdate(),
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
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: Colors.white60,
        ),
      ),
    );
  }

  Widget _settingsCard(List<Widget> children) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF24386E)),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1)
              const Divider(height: 1, indent: 56, color: Color(0xFF1D2D59)),
          ],
        ],
      ),
    );
  }

  Widget _settingsSwitch({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      secondary: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: iconColor.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: iconColor, size: 22),
      ),
      title: Text(title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle,
              style: const TextStyle(fontSize: 11, color: Colors.white60)),
      value: value,
      onChanged: (v) {
        onChanged(v);
        savePersistentData();
      },
    );
  }

  Widget _settingsTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: iconColor.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: iconColor, size: 22),
      ),
      title: Text(title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.white60)),
      trailing: trailing ?? const Icon(Icons.chevron_right_rounded, size: 20),
      onTap: onTap,
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
                      fontWeight: FontWeight.bold, fontSize: 14),
                ),
                subtitle: Text(
                  '${server.protocol} • ${server.subName}',
                  style: const TextStyle(fontSize: 11, color: Colors.white60),
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
                  title: const Text('کپی لینک سرور'),
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
                leading: const Icon(Icons.delete_outline_rounded,
                    color: Colors.redAccent),
                title: const Text('حذف سرور',
                    style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() {
                    servers.removeWhere((x) => x.id == server.id);
                    if (selectedServerId == server.id) {
                      selectedServerId =
                          servers.isNotEmpty ? servers.first.id : '';
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
              _sheetHeader(Icons.link_rounded, const Color(0xFF3B82F6),
                  'آدرس تست پینگ'),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(hintText: 'https://...'),
              ),
              const SizedBox(height: 14),
              FilledButton(
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
          ? '$added برنامهٔ ایرانی خارج از VPN قرار گرفت'
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
      apps.sort(
          (a, b) => a['name']!.toLowerCase().compareTo(b['name']!.toLowerCase()));
      _installedApps = apps;
      _autoPickIranianApps();
    } catch (_) {}
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

  void _exportBackup() {
    final data = {
      'app': 'SHIN',
      'version': kAppVersion,
      'servers': servers.map((e) => e.toJson()).toList(),
      'subscriptions': subscriptions.map((e) => e.toJson()).toList(),
      'dns': selectedDns,
      'bypassIran': bypassIran,
      'bypassLan': bypassLan,
      'enableMux': enableMux,
      'enableIPv6': enableIPv6,
      'mtuSize': mtuSize,
    };
    Clipboard.setData(ClipboardData(text: jsonEncode(data)));
    showSnack('پشتیبان کامل در کلیپ‌بورد کپی شد 📋');
  }

  Future<void> _importBackup() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = d?.text?.trim() ?? '';
    if (raw.isEmpty) {
      showSnack('کلیپ‌بورد خالی است!');
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['app'] == 'SHIN') {
        final serverList = decoded['servers'];
        if (serverList is List) {
          for (final s in serverList) {
            try {
              servers.add(ServerItem.fromJson(JsonMap.from(s)));
            } catch (_) {}
          }
        }
        final subList = decoded['subscriptions'];
        if (subList is List) {
          for (final s in subList) {
            try {
              subscriptions.add(SubscriptionItem.fromJson(JsonMap.from(s)));
            } catch (_) {}
          }
        }
        await savePersistentData();
        setState(() {});
        showSnack('پشتیبان با موفقیت بازیابی شد ✅');
      }
    } catch (_) {
      showSnack('خطا در خواندن فایل پشتیبان');
    }
  }

  Widget _buildAdvancedSettingsPage(void Function(void Function()) setLocal) {
    return Scaffold(
      appBar: AppBar(title: const Text('تنظیمات فوق پیشرفته موتور')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _sectionTitle('تنظیمات هسته Xray'),
          _settingsCard([
            _settingsSwitch(
              icon: Icons.alt_route_rounded,
              iconColor: const Color(0xFF6366F1),
              title: 'تجمیع اتصال (Mux)',
              subtitle: 'ارسال چند درخواست روی یک اتصال (برای Reality خاموش باشد)',
              value: enableMux,
              onChanged: (v) {
                _applySetting(() => enableMux = v);
                setLocal(() {});
              },
            ),
            _settingsSwitch(
              icon: Icons.shield_outlined,
              iconColor: const Color(0xFFEF4444),
              title: 'پذیرش TLS نامعتبر',
              subtitle: 'گواهی‌های ناامن یا خودامضا را بپذیر',
              value: allowInsecureDefault,
              onChanged: (v) {
                _applySetting(() => allowInsecureDefault = v);
                setLocal(() {});
              },
            ),
            _settingsSwitch(
              icon: Icons.language_rounded,
              iconColor: const Color(0xFF06B6D4),
              title: 'پشتیبانی از IPv6',
              subtitle: 'فقط در صورت پشتیبانی اپراتور شما',
              value: enableIPv6,
              onChanged: (v) {
                _applySetting(() => enableIPv6 = v);
                setLocal(() {});
              },
            ),
            _settingsSwitch(
              icon: Icons.bolt_rounded,
              iconColor: const Color(0xFFF59E0B),
              title: 'بیدار نگه‌داشتن پردازنده (Keep CPU Awake)',
              subtitle: 'جلوگیری از قطع VPN هنگام قفل صفحه',
              value: keepCpuAlive,
              onChanged: (v) {
                _applySetting(() => keepCpuAlive = v);
                setLocal(() {});
              },
            ),
          ]),
          _sectionTitle('تنظیمات پینگ'),
          _settingsCard([
            _settingsSwitch(
              icon: Icons.filter_2_rounded,
              iconColor: const Color(0xFF3B82F6),
              title: 'بهترین از دو پینگ (Best of Two)',
              subtitle: 'دو پینگ مجزا ارسال و نتیجه سریع‌تر ثبت می‌شود',
              value: pingBestOfTwo,
              onChanged: (v) {
                _applySetting(() => pingBestOfTwo = v);
                setLocal(() {});
              },
            ),
            _settingsTile(
              icon: Icons.link_rounded,
              iconColor: const Color(0xFF00F5A0),
              title: 'آدرس تست تأخیر (Ping URL)',
              subtitle: pingTestUrl,
              trailing: const Icon(Icons.edit_rounded, size: 18),
              onTap: _editPingUrl,
            ),
          ]),
        ],
      ),
    );
  }

  Widget _buildSettingsTab() {
    return Scaffold(
      appBar: AppBar(title: const Text('تنظیمات')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          _sectionTitle('مسیریابی هوشمند و ترافیک'),
          _settingsCard([
            _settingsTile(
              icon: Icons.apps_rounded,
              iconColor: const Color(0xFF3B82F6),
              title: 'برنامه‌های خارج از VPN (Split Tunneling)',
              subtitle: '${bypassApps.length} برنامه مستقیم وصل می‌شوند',
              onTap: _openAppsPage,
            ),
            _settingsSwitch(
              icon: Icons.flag_circle_rounded,
              iconColor: const Color(0xFF00F5A0),
              title: 'بای‌پس ایران',
              subtitle: 'دامنه‌های .ir و سرورهای داخلی مستقیم باز شوند',
              value: bypassIran,
              onChanged: (v) => _applySetting(() => bypassIran = v),
            ),
            _settingsSwitch(
              icon: Icons.router_rounded,
              iconColor: const Color(0xFFF59E0B),
              title: 'بای‌پس شبکهٔ محلی (LAN)',
              subtitle: 'ارتباط مستقیم با مودم و شبکه خانگی',
              value: bypassLan,
              onChanged: (v) => _applySetting(() => bypassLan = v),
            ),
            _settingsSwitch(
              icon: Icons.speed_rounded,
              iconColor: const Color(0xFF8B5CF6),
              title: 'پینگ خودکار در آغاز کار',
              subtitle: 'سنجش تأخیر سرورها به محض باز کردن برنامه',
              value: autoPingOnOpen,
              onChanged: (v) => _applySetting(() => autoPingOnOpen = v),
            ),
          ]),
          _sectionTitle('سرور DNS ترجیحی'),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF24386E)),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final d in kDnsOptions)
                  ChoiceChip(
                    label: Text(
                      d == '94.140.14.14'
                          ? 'AdGuard DNS'
                          : d == '1.1.1.1'
                              ? 'Cloudflare (1.1.1.1)'
                              : d == '8.8.8.8'
                                  ? 'Google (8.8.8.8)'
                                  : d,
                      style: const TextStyle(fontSize: 12),
                    ),
                    selected: selectedDns == d,
                    onSelected: (_) {
                      _applySetting(() => selectedDns = d);
                      savePersistentData();
                    },
                  ),
              ],
            ),
          ),
          _sectionTitle('تنظیمات اختصاصی و پشتیبان'),
          _settingsCard([
            _settingsTile(
              icon: Icons.tune_rounded,
              iconColor: const Color(0xFF6366F1),
              title: 'تنظیمات فوق پیشرفته موتور',
              subtitle: 'Mux، پینگ زنده و پروتکل‌ها',
              onTap: _openAdvancedSettings,
            ),
            _settingsTile(
              icon: Icons.file_upload_outlined,
              iconColor: const Color(0xFF0EA5E9),
              title: 'پشتیبان‌گیری از اطلاعات (Export)',
              subtitle: 'کپی کردن تمام سرورها و کانفیگ‌ها',
              onTap: _exportBackup,
            ),
            _settingsTile(
              icon: Icons.file_download_outlined,
              iconColor: const Color(0xFF10B981),
              title: 'بازیابی اطلاعات (Import Backup)',
              subtitle: 'بازگردانی اطلاعات از کلیپ‌بورد',
              onTap: _importBackup,
            ),
          ]),
          _sectionTitle('اطلاعات برنامه'),
          _settingsCard([
            _settingsTile(
              icon: Icons.fingerprint_rounded,
              iconColor: const Color(0xFF8B5CF6),
              title: 'شناسه اختصاصی دستگاه (HWID)',
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

class _NeonOrbPowerButton extends StatelessWidget {
  final bool connected;
  final bool connecting;
  final VoidCallback onTap;

  const _NeonOrbPowerButton({
    required this.connected,
    required this.connecting,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final primaryGlow =
        connected ? const Color(0xFF00F5A0) : const Color(0xFF00E5A3);
    final secondaryGlow =
        connected ? const Color(0xFF00D9F5) : const Color(0xFF059669);

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 215,
        height: 215,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 205,
              height: 205,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    primaryGlow.withOpacity(0.05),
                    primaryGlow.withOpacity(0.25),
                    secondaryGlow.withOpacity(0.08),
                  ],
                ),
                border: Border.all(
                  color: primaryGlow.withOpacity(0.55),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: primaryGlow.withOpacity(connected ? 0.55 : 0.35),
                    blurRadius: 38,
                    spreadRadius: 6,
                  ),
                ],
              ),
            ),
            Container(
              width: 174,
              height: 174,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF061A2E),
                border: Border.all(
                  color: primaryGlow.withOpacity(0.4),
                  width: 1.5,
                ),
              ),
            ),
            Container(
              width: 154,
              height: 154,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  center: const Alignment(-0.2, -0.25),
                  radius: 0.9,
                  colors: [
                    primaryGlow,
                    const Color(0xFF059669),
                    const Color(0xFF064E3B),
                  ],
                ),
                border: Border.all(
                  color: const Color(0xFF6EE7B7),
                  width: 2.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: primaryGlow.withOpacity(0.6),
                    blurRadius: 24,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (connecting)
                    const SizedBox(
                      width: 44,
                      height: 44,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 3.5,
                      ),
                    )
                  else
                    const Icon(
                      Icons.power_settings_new_rounded,
                      size: 58,
                      color: Colors.white,
                    ),
                  const SizedBox(height: 8),
                  Text(
                    connected
                        ? 'Connected'
                        : connecting
                            ? 'Connecting'
                            : 'Tap to\nConnect',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.15,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CyberWorldMapAndOrbitsPainter extends CustomPainter {
  final bool isConnected;

  _CyberWorldMapAndOrbitsPainter({required this.isConnected});

  @override
  void paint(Canvas canvas, Size size) {
    final dotPaint = Paint()
      ..color = const Color(0xFF38BDF8).withOpacity(0.14)
      ..style = PaintingStyle.fill;

    const step = 9.0;
    for (double y = 15; y < size.height * 0.78; y += step) {
      for (double x = 16; x < size.width - 16; x += step) {
        final nx = x / size.width;
        final ny = y / (size.height * 0.78);
        final continentMask = (sin(nx * 10) * cos(ny * 6) +
                sin((nx - 0.2) * 5) +
                cos((ny - 0.4) * 8)) >
            0.35;
        if (continentMask) {
          canvas.drawCircle(Offset(x, y), 1.4, dotPaint);
        }
      }
    }

    final center = Offset(size.width / 2, size.height * 0.47);
    final orbitPaint1 = Paint()
      ..color = const Color(0xFF00D9F5).withOpacity(0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;

    final orbitPaint2 = Paint()
      ..color = const Color(0xFF00F5A0).withOpacity(0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-0.22);
    canvas.drawOval(
      Rect.fromCenter(
          center: Offset.zero, width: size.width * 0.92, height: 150),
      orbitPaint1,
    );
    canvas.restore();

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(0.24);
    canvas.drawOval(
      Rect.fromCenter(
          center: Offset.zero, width: size.width * 0.88, height: 135),
      orbitPaint2,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CyberWorldMapAndOrbitsPainter oldDelegate) =>
      oldDelegate.isConnected != isConnected;
}

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  Future<void> _finish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_done', true);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.bolt_rounded,
                    size: 72, color: Color(0xFF00F5A0)),
                const SizedBox(height: 20),
                const Text(
                  'به SHIN VPN خوش آمدید',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 12),
                const Text(
                  'اتصال سریع، امن و پایدار با رابط کاربری نسل جدید.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _finish,
                    child: const Text('شروع استفاده'),
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
