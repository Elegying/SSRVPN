import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// IP 地理位置查询服务 — 用于节点国旗识别
///
/// 规则：
/// 1. 先尝试本地规则匹配（根据节点名称中的地区关键词）
/// 2. 本地规则匹配不到时，通过 IP API 查询服务器所在地理位置
class IpGeoService {
  static IpGeoService? _instance;
  final Map<String, _GeoCacheEntry> _cache = {};
  static const _cacheDuration = Duration(hours: 24);

  // 并发量控制
  static const _maxConcurrent = 3;
  int _runningCount = 0;
  final List<({Completer<_GeoResult?> completer, String ip})> _queue = [];

  IpGeoService._();

  static IpGeoService get instance {
    _instance ??= IpGeoService._();
    return _instance!;
  }

  /// 根据节点名称查询国旗 emoji + 国家代码
  Future<(String flag, String code)?> lookupFlag(String nodeName) async {
    // 1. 本地规则优先
    final localResult = _localCountryCode(nodeName);
    if (localResult != null) {
      return (_flagEmoji(localResult), localResult);
    }

    // 2. 尝试从节点名提取服务器地址
    final server = _extractServerFromName(nodeName);
    if (server == null) return null;

    return lookupFlagByIp(server);
  }

  /// 根据纯 IP 地址查询国旗
  Future<(String flag, String code)?> lookupFlagByIp(String ipOrDomain) async {
    // 检查缓存
    final cached = _cache[ipOrDomain];
    if (cached != null && !cached.isExpired) {
      return (_flagEmoji(cached.countryCode), cached.countryCode);
    }

    // 并发控制：超限时暂存到队列，保留原始 IP
    if (_runningCount >= _maxConcurrent) {
      final completer = Completer<_GeoResult?>();
      _queue.add((completer: completer, ip: ipOrDomain));
      return completer.future.then((r) {
        if (r != null) return (_flagEmoji(r.countryCode), r.countryCode);
        return null;
      });
    }

    _runningCount++;
    final result = await _doLookup(ipOrDomain);
    _runningCount--;
    _processQueue();
    return result != null
        ? (_flagEmoji(result.countryCode), result.countryCode)
        : null;
  }

  void _processQueue() {
    if (_queue.isEmpty) return;
    final next = _queue.removeAt(0);
    _runningCount++;
    _doLookup(next.ip).then((r) {
      next.completer.complete(r);
      _runningCount--;
      _processQueue();
    });
  }

  Future<_GeoResult?> _doLookup(String ipOrDomain) async {
    // _runningCount managed by caller
    try {
      // 优先用 ip-api.com（无需 API Key，每分钟 45 次）
      final response = await http
          .get(
            Uri.parse('http://ip-api.com/json/$ipOrDomain?fields=countryCode'),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final code = data['countryCode'] as String?;
        if (code != null && code.isNotEmpty) {
          final entry = _GeoCacheEntry(
            countryCode: code,
            timestamp: DateTime.now(),
          );
          _cache[ipOrDomain] = entry;
          return entry;
        }
      }
    } catch (e) {
      debugPrint('[IpGeo] API 查询失败 $ipOrDomain: $e');
    }
    return null;
  }

  /// 从节点名称提取服务器地址（用于 IP 查询）
  String? _extractServerFromName(String name) {
    // 常见格式：🇺🇸 美国 - San Jose、US - San Jose、美国 San Jose
    // 提取 IP 或域名部分
    final ipPattern = RegExp(r'\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b');
    final match = ipPattern.firstMatch(name);
    if (match != null) return match.group(0);

    // 尝试提取看起来像域名后缀的模式
    final domainPattern =
        RegExp(r'\b([a-zA-Z0-9][-a-zA-Z0-9]*\.)+[a-zA-Z]{2,}\b');
    final domainMatch = domainPattern.firstMatch(name);
    if (domainMatch != null) return domainMatch.group(0);

    return null;
  }

  /// 本地规则：从节点名称匹配国家代码
  /// 使用 [^A-Z] 而非 [^A-Z0-9]，修复东京/台湾等含有数字的识别
  String? _localCountryCode(String name) {
    final upper = name.toUpperCase().trim();
    // 优先匹配显式的 ISO 代码标记
    final isoMatch = RegExp(r'(?:^|\s|[-/#【\[\(（])'
        r'(US|UK|GB|JP|KR|HK|TW|SG|DE|FR|NL|CA|AU|IN|TH|VN|ID|PH|MY|RU|TR|BR|AR|MX|ZA|IT|ES|SE|NO|FI|DK|IE|CH|AT|BE|PL|UA|CL|CO|PE)'
        r'(?:$|\s|[-/#】\]\)）]|[^A-Z])');
    final match = isoMatch.firstMatch(upper);
    if (match != null) {
      return match.group(1);
    }

    // 常见国家/地区关键字映射（直接用英文地区名匹配）
    const keywordMap = {
      '美国': 'US',
      '洛杉矶': 'US',
      '圣何塞': 'US',
      '纽约': 'US',
      '西雅图': 'US',
      '硅谷': 'US',
      '达拉斯': 'US',
      '芝加哥': 'US',
      '迈阿密': 'US',
      '凤凰城': 'US',
      'USA': 'US',
      'AMERICA': 'US',
      'US ': 'US',
      '日本': 'JP',
      '东京': 'JP',
      '大阪': 'JP',
      'JAPAN': 'JP',
      'JP ': 'JP',
      '韩国': 'KR',
      '首尔': 'KR',
      'KOREA': 'KR',
      'KR ': 'KR',
      'SOUTH KOREA': 'KR',
      '香港': 'HK',
      'HONG KONG': 'HK',
      'HK ': 'HK',
      '台湾': 'TW',
      '台北': 'TW',
      'TAIWAN': 'TW',
      'TW ': 'TW',
      '新加坡': 'SG',
      'SINGAPORE': 'SG',
      'SG ': 'SG',
      '德国': 'DE',
      '法兰克福': 'DE',
      'GERMANY': 'DE',
      'DE ': 'DE',
      '法国': 'FR',
      '巴黎': 'FR',
      'FRANCE': 'FR',
      'FR ': 'FR',
      '荷兰': 'NL',
      'NETHERLANDS': 'NL',
      'NL ': 'NL',
      '加拿大': 'CA',
      'CANADA': 'CA',
      'CA ': 'CA',
      '澳大利亚': 'AU',
      '悉尼': 'AU',
      'AUSTRALIA': 'AU',
      'AU ': 'AU',
      '印度': 'IN',
      '孟买': 'IN',
      'INDIA': 'IN',
      'IN ': 'IN',
      '泰国': 'TH',
      '曼谷': 'TH',
      'THAILAND': 'TH',
      'TH ': 'TH',
      '越南': 'VN',
      '胡志明': 'VN',
      'VIETNAM': 'VN',
      '印度尼西亚': 'ID',
      '雅加达': 'ID',
      'INDONESIA': 'ID',
      '菲律宾': 'PH',
      '马尼拉': 'PH',
      'PHILIPPINES': 'PH',
      '马来西亚': 'MY',
      '吉隆坡': 'MY',
      'MALAYSIA': 'MY',
      'MY ': 'MY',
      '俄罗斯': 'RU',
      '莫斯科': 'RU',
      'RUSSIA': 'RU',
      'RU ': 'RU',
      '土耳其': 'TR',
      '伊斯坦布尔': 'TR',
      'TURKEY': 'TR',
      '巴西': 'BR',
      'BRAZIL': 'BR',
      'BR ': 'BR',
      '阿根廷': 'AR',
      'ARGENTINA': 'AR',
      '墨西哥': 'MX',
      'MEXICO': 'MX',
      '英国': 'GB',
      '伦敦': 'GB',
      'UK ': 'GB',
      'UNITED KINGDOM': 'GB',
      '意大利': 'IT',
      'ITALY': 'IT',
      '西班牙': 'ES',
      'SPAIN': 'ES',
      'ES ': 'ES',
      '瑞典': 'SE',
      'SWEDEN': 'SE',
      '挪威': 'NO',
      'NORWAY': 'NO',
      '芬兰': 'FI',
      'FINLAND': 'FI',
      '丹麦': 'DK',
      'DENMARK': 'DK',
      '爱尔兰': 'IE',
      'IRELAND': 'IE',
      '瑞士': 'CH',
      'SWITZERLAND': 'CH',
      '奥地利': 'AT',
      'AUSTRIA': 'AT',
      '比利时': 'BE',
      'BELGIUM': 'BE',
      '波兰': 'PL',
      'POLAND': 'PL',
      '乌克兰': 'UA',
      'UKRAINE': 'UA',
      '智利': 'CL',
      'CHILE': 'CL',
      '哥伦比亚': 'CO',
      'COLOMBIA': 'CO',
      '秘鲁': 'PE',
      'PERU': 'PE',
      '南非': 'ZA',
      'SOUTH AFRICA': 'ZA',
    };

    for (final entry in keywordMap.entries) {
      if (upper.contains(entry.key)) {
        return entry.value;
      }
    }

    return null;
  }

  /// 国家代码 → 国旗 emoji
  String _flagEmoji(String countryCode) {
    if (countryCode.length != 2) return '🏳️';
    final first = countryCode.codeUnitAt(0) - 0x41 + 0x1F1E6;
    final second = countryCode.codeUnitAt(1) - 0x41 + 0x1F1E6;
    return String.fromCharCodes([first, second]);
  }

  /// 公开的静态方法：国家代码 → 国旗 emoji
  static String flagFromCode(String countryCode) {
    return IpGeoService.instance._flagEmoji(countryCode);
  }

  /// 公开的静态方法：根据名称获取本地国家代码
  static String? localCode(String name) {
    return IpGeoService.instance._localCountryCode(name);
  }
}

class _GeoCacheEntry {
  final String countryCode;
  final DateTime timestamp;

  const _GeoCacheEntry({required this.countryCode, required this.timestamp});

  bool get isExpired =>
      DateTime.now().difference(timestamp) > IpGeoService._cacheDuration;
}

/// 地理位置查询结果
typedef _GeoResult = _GeoCacheEntry;
