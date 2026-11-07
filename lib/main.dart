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

Future?> fetchLatestReleaseInfo() async {
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
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        // جلوگیری از کرش هنگام لمس نوتیفیکیشن در اندروید ۱۲+
      },
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

/// برنامه‌های شناخته‌شدهٔ ایرانی (به‌علاوه‌ی هر پکیجی که با ir. شروع شود)
const Set<String> kIranianPackages = {
  'ir.nasim', // بله
  'ir.divar', // دیوار
  'com.bama.consumer', // باما
  'com.farsitel.bazaar', // کافه‌بازار
  'com.bazambazi', // بازم‌بازی
  'com.samanpr.blu', // blu
  'daal.co', // دال
  'com.bmelat.mobile', // دیما
  'com.aparat', // آپارات
  'cab.snapp.passenger.play', // اسنپ
};

const List<String> kIranianBankWords = [
  'بانک', 'بام', 'سکه', 'ویپاد', 'وپاد', 'فراز', 'همراه بانک', 'ملی', 'ملت',
  'سپه', 'صادرات', 'تجارت', 'پاسارگاد', 'ایران زمین', 'دی جت', 'بلو',
  'همراه کارت', 'آپ', 'قبضینو', 'بانکینو', 'پاسارگاد', 'شهر', 'کشاورزی',
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

// نقطه ورود پس‌زمینه برای ویجت و Quick Settings بدون باز شدن صفحه برنامه
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

// ---------------------------------------------------------------------------
//  ثابت‌ها و تنظیمات پایه
// ---------------------------------------------------------------------------

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
          {
            'tag': 'direct',
            'protocol': 'freedom',
            'settings': {'domainStrategy': 'UseIP'}
          },
          {'tag': 'blackhole', 'protocol': 'blackhole', 'settings': {}},
          {'tag': 'dns-out', 'protocol': 'dns'},
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
        },
        {
          'tag': 'in_http',
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
//  دکمه گرافیکی ویژه SHIN
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
                  Container(
                    width: 152,
                    height: 152,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context).cardColor,
                    ),
                  ),
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
          : ColorScheme.light(
              primary: accent, secondary: accent, surface: card),
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
      textTheme: base.textTheme.apply(
          fontFamily: 'Vazirmatn', bodyColor: text, displayColor: text),
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
  final bool lowPowerMode = true;
  final Set<String> _sortedGroups = <String>{};
  final Set<String> _testingGroups = <String>{};
  final Set<String> _countryGroups = <String>{};
  final Set<String> bypassApps = <String>{};
  bool autoPingOnOpen = true;
  List> _installedApps = [];
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
  String updateRepoUrl =
      'https://api.github.com/repos/$kUpdateRepo/releases/latest';
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
          _syncNativeConnectionState(
              status.state == 'CONNECTED', status.state),
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
    try {} catch (_) {}
    await loadPersistentData();
    if (!mounted) return;
    setState(() => coreVersion = ver.isEmpty ? 'هستهٔ Xray v26.9.9' : ver);
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
      await Workmanager()
          .initialize(shinUpdateDispatcher, isInDebugMode: false);
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
              _sheetHeader(Icons.cloud_download_rounded,
                  const Color(0xFF10B981), 'دریافت سرور از سازنده',
                  'درخواست به وب‌سرویس سازنده ارسال می‌شود'),
              const SizedBox(height: 14),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
        showSnack(
            'سرورهای پیش‌فرض SHIN دریافت شدند؛ وب‌هوک درخواست سازنده تنظیم نشده است.');
      } else {
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

  Future<void> checkIpCountry() async {
    if (isCheckingIp) return;
    setState(() => isCheckingIp = true);
    try {
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

  // ------------------------------------------------------------------ ساخت کانفیگ اصلاح‌شده برای کار کردن تمام برنامه‌ها

  String buildCustomizedConfig(String rawJson) {
    try {
      final JsonMap config = JsonMap.from(jsonDecode(rawJson));

      // ۱. تنظیمات کامل DNS برای باز شدن تمام اپلیکیشن‌ها و سایت‌ها
      config['dns'] = {
        'servers': [
          selectedDns,
          '1.1.1.1',
          '8.8.8.8',
          if (bypassIran)
            {
              'address': '217.218.127.127',
              'port': 53,
              'domains': ['regexp:.*\\.ir\$'],
            }
        ],
        'queryStrategy': enableIPv6 ? 'UseIP' : 'UseIPv4',
      };

      // ۲. اطمینان از فعال بودن Sniffing و UDP در تمامی Inboundها
      if (config['inbounds'] is List && (config['inbounds'] as List).isNotEmpty) {
        for (final inb in config['inbounds']) {
          if (inb is Map) {
            if (inb['protocol'] == 'socks' && inb['settings'] is Map) {
              inb['settings']['udp'] = true;
            }
            inb['sniffing'] = {
              'enabled': true,
              'destOverride': ['http', 'tls', 'quic'],
              'routeOnly': false,
            };
          }
        }
      } else {
        config['inbounds'] = LinkParser.standardInbounds();
      }

      // ۳. تنظیمات Outbounds و اضافه کردن dns-out
      if (config['outbounds'] is List &&
          (config['outbounds'] as List).isNotEmpty) {
        final List outbounds = config['outbounds'];
        if (outbounds[0] is Map) {
          outbounds[0]['tag'] ??= 'proxy';
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

      final String mainOutboundTag = (config['outbounds'] is List &&
              (config['outbounds'] as List).isNotEmpty &&
              config['outbounds'][0] is Map)
          ? (config['outbounds'][0]['tag'] ?? 'proxy').toString()
          : 'proxy';

      // ۴. قوانین مسیریابی (هدایت پورت 53 به DNS و ترافیک عمومی به سرور VPN)
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

      // هدایت تمام ترافیک باقی‌مانده (TCP/UDP) به خروجی اصلی VPN
      rules.add({
        'type': 'field',
        'network': 'tcp,udp',
        'outboundTag': mainOutboundTag,
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

  // ------------------------------------------------------------------ اتصال

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
        proxyOnly: isProxyOnly,
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

  // ------------------------------------------------------------------ سیستم پینگ

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
        final ms =
            await flutterV2ray.getServerDelay(config: cfg).timeout(timeout);
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

      final tag =
          (data['tag_name'] ?? '').toString().replaceFirst(RegExp(r'^v'), '');
      final notes = (data['body'] ?? '').toString();

      var apk = '';
      final assets = data['assets'];
      if (assets is List) {
        var fallback = '';
        for (final a in assets) {
          if (a is! Map) continue;
