import 'package:country_flags/country_flags.dart' show FlagCode;

import '../models/proxy_node.dart';

const _nodeCountryKeys = [
  'country',
  'countryCode',
  'country-code',
  'region',
  'regionCode',
  'ipCountry',
];

// Location names are hints supplied by the subscription, never network lookups.
// ISO codes and regional-indicator emoji use the packaged flag library's map.
const _countryNames = <String, List<String>>{
  'HK': ['香港', 'HONG KONG'],
  'MO': ['澳门', '澳門', 'MACAU', 'MACAO'],
  'SG': ['新加坡', '狮城', '獅城', 'SINGAPORE'],
  'TW': ['台湾', '台灣', '台北', 'TAIWAN', 'TAIPEI'],
  'JP': ['日本', '东京', '東京', '大阪', 'JAPAN', 'TOKYO', 'OSAKA'],
  'US': [
    '美国',
    '美國',
    '洛杉矶',
    '洛杉磯',
    '纽约',
    '紐約',
    '圣何塞',
    '聖何塞',
    '硅谷',
    '矽谷',
    '西雅图',
    '西雅圖',
    'UNITED STATES',
    'LOS ANGELES',
    'NEW YORK',
    'SAN JOSE',
    'SEATTLE'
  ],
  'GB': ['英国', '英國', '伦敦', '倫敦', 'UNITED KINGDOM', 'LONDON'],
  'KR': ['韩国', '韓國', '首尔', '首爾', '南韩', '南韓', 'KOREA', 'SEOUL'],
  'DE': ['德国', '德國', '法兰克福', '法蘭克福', 'GERMANY', 'FRANKFURT'],
  'FR': ['法国', '法國', '巴黎', 'FRANCE', 'PARIS'],
  'NL': ['荷兰', '荷蘭', '阿姆斯特丹', 'NETHERLANDS', 'AMSTERDAM'],
  'CA': ['加拿大', '多伦多', '多倫多', '温哥华', '溫哥華', 'CANADA', 'TORONTO', 'VANCOUVER'],
  'AU': ['澳大利亚', '澳大利亞', '澳洲', '悉尼', '雪梨', 'AUSTRALIA', 'SYDNEY'],
  'NZ': ['新西兰', '新西蘭', '紐西蘭', 'NEW ZEALAND', 'AUCKLAND'],
  'ID': ['印尼', '印度尼西亚', '印度尼西亞', 'INDONESIA'],
  'IN': ['印度', '孟买', '孟買', 'INDIA', 'MUMBAI'],
  'TH': ['泰国', '泰國', '曼谷', 'THAILAND', 'BANGKOK'],
  'VN': ['越南', 'VIETNAM'],
  'MY': ['马来', '馬來', '吉隆坡', 'MALAYSIA', 'KUALA LUMPUR'],
  'PH': ['菲律宾', '菲律賓', 'PHILIPPINES'],
  'RU': ['俄罗斯', '俄羅斯', '莫斯科', 'RUSSIA', 'MOSCOW'],
  'BR': ['巴西', '圣保罗', '聖保羅', 'BRAZIL', 'SAO PAULO'],
  'AR': ['阿根廷', 'ARGENTINA'],
  'MX': ['墨西哥', 'MEXICO'],
  'CL': ['智利', 'CHILE'],
  'AE': ['阿联酋', '阿聯酋', '迪拜', '杜拜', 'UNITED ARAB EMIRATES', 'DUBAI'],
  'TR': ['土耳其', 'TURKEY', 'TURKIYE', 'TÜRKIYE', 'ISTANBUL'],
  'ZA': ['南非', 'SOUTH AFRICA'],
  'SE': ['瑞典', 'SWEDEN', 'STOCKHOLM'],
  'CH': ['瑞士', 'SWITZERLAND', 'ZURICH'],
  'FI': ['芬兰', '芬蘭', 'FINLAND', 'HELSINKI'],
  'NO': ['挪威', 'NORWAY', 'OSLO'],
  'DK': ['丹麦', '丹麥', 'DENMARK'],
  'PL': ['波兰', '波蘭', 'POLAND', 'WARSAW'],
  'IT': ['意大利', '義大利', 'ITALY', 'MILAN'],
  'ES': ['西班牙', 'SPAIN', 'MADRID'],
  'PT': ['葡萄牙', 'PORTUGAL'],
  'IE': ['爱尔兰', '愛爾蘭', 'IRELAND', 'DUBLIN'],
  'AT': ['奥地利', '奧地利', 'AUSTRIA', 'VIENNA'],
  'BE': ['比利时', '比利時', 'BELGIUM'],
  'CZ': ['捷克', 'CZECHIA', 'CZECH REPUBLIC'],
  'GR': ['希腊', '希臘', 'GREECE'],
  'UA': ['乌克兰', '烏克蘭', 'UKRAINE'],
  'KZ': ['哈萨克斯坦', '哈薩克斯坦', 'KAZAKHSTAN'],
  'IL': ['以色列', 'ISRAEL'],
  'IS': ['冰岛', '冰島', 'ICELAND'],
};

final _countryNamePatterns = _countryNames.map((code, names) => MapEntry(
      code,
      RegExp('(^|[^A-Z])(?:${names.map(RegExp.escape).join('|')})([^A-Z]|\$)',
          caseSensitive: false),
    ));
final _countryCodeToken =
    RegExp(r'(^|[^A-Za-z])([A-Za-z]{2,3})(?=[^A-Za-z]|$)');

String countryCodeForProxyNode(ProxyNode node) {
  for (final key in _nodeCountryKeys) {
    final value = node.extra[key];
    if (value is! String) continue;
    final direct = normalizeNodeCountryCode(value);
    if (direct != 'UN') return direct;
    final named = _countryForText(value, allowLowercaseCodes: true);
    if (named != 'UN') return named;
  }
  final named = _countryForText(node.name);
  if (named != 'UN') return named;
  // A generic DNS suffix such as .com is also an ISO alpha-3 country code.
  // Only subscription-controlled host labels provide location hints.
  final labels = node.server.split('.');
  return _countryForText(
    labels.length > 1 ? labels.take(labels.length - 1).join('.') : node.server,
    allowLowercaseCodes: true,
  );
}

String _countryForText(String text, {bool allowLowercaseCodes = false}) {
  final runes = text.runes.toList(growable: false);
  for (var i = 0; i + 1 < runes.length; i++) {
    if (!_isRegionalIndicator(runes[i]) ||
        !_isRegionalIndicator(runes[i + 1])) {
      continue;
    }
    final code = normalizeNodeCountryCode(String.fromCharCodes([
      runes[i] - 0x1F1E6 + 65,
      runes[++i] - 0x1F1E6 + 65,
    ]));
    if (code != 'UN') return code;
  }
  for (final entry in _countryNamePatterns.entries) {
    if (entry.value.hasMatch(text)) return entry.key;
  }
  for (final match in _countryCodeToken.allMatches(text)) {
    final token = match[2]!;
    final numbered = (match.end < text.length &&
            RegExp(r'[0-9]').hasMatch(text[match.end])) ||
        RegExp(r'[0-9]').hasMatch(match[1]!);
    // Avoid interpreting ordinary lower-case words ("in", "to", "is") as countries.
    if (!allowLowercaseCodes &&
        token != token.toUpperCase() &&
        text.trim() != token &&
        !numbered) {
      continue;
    }
    final code = normalizeNodeCountryCode(token);
    if (code != 'UN') return code;
  }
  return 'UN';
}

String normalizeNodeCountryCode(String code) {
  final upper = code.trim().toUpperCase();
  if (upper == 'UK') return 'GB';
  if (upper == 'EL') return 'GR';
  return FlagCode.fromCountryCode(upper)?.toUpperCase() ?? 'UN';
}

String nodeDisplayNameWithoutLeadingFlag(String name) {
  final runes = name.runes.toList(growable: false);
  if (runes.length < 2 ||
      !_isRegionalIndicator(runes[0]) ||
      !_isRegionalIndicator(runes[1])) {
    return name;
  }
  final withoutFlag = String.fromCharCodes(runes.skip(2)).trimLeft();
  return withoutFlag.isEmpty ? name : withoutFlag;
}

String compactNodeDisplayName(
  String name, {
  int maxRunes = 24,
  int suffixRunes = 10,
}) {
  if (maxRunes < 3) {
    throw ArgumentError.value(maxRunes, 'maxRunes', 'must be at least 3');
  }
  final runes = name.runes.toList(growable: false);
  if (runes.length <= maxRunes) return name;
  final maxSuffixRunes = maxRunes - 2;
  final safeSuffixRunes = suffixRunes < 1
      ? 1
      : suffixRunes > maxSuffixRunes
          ? maxSuffixRunes
          : suffixRunes;
  final prefixRunes = maxRunes - safeSuffixRunes - 1;
  return '${String.fromCharCodes(runes.take(prefixRunes))}'
      '…${String.fromCharCodes(runes.skip(runes.length - safeSuffixRunes))}';
}

bool _isRegionalIndicator(int rune) => rune >= 0x1F1E6 && rune <= 0x1F1FF;
