import '../models/proxy_node.dart';

const _nodeCountryKeys = [
  'country',
  'countryCode',
  'country-code',
  'region',
  'regionCode',
  'ipCountry',
];

const _countryPatterns = <String, List<String>>{
  'HK': ['HK', 'HKG', '香港', 'HONG KONG'],
  'SG': ['SG', 'SGP', '新加坡', 'SINGAPORE'],
  'TW': ['TW', 'TWN', '台湾', '台灣', 'TAIWAN'],
  'JP': ['JP', 'JPN', '日本', 'JAPAN', 'TOKYO', 'OSAKA'],
  'US': ['US', 'USA', '美国', '美國', 'UNITED STATES', 'LOS ANGELES'],
  'GB': ['GB', 'UK', '英国', '英國', 'UNITED KINGDOM', 'LONDON'],
  'KR': ['KR', 'KOR', '韩国', '韓國', 'KOREA', 'SEOUL'],
  'DE': ['DE', 'DEU', '德国', '德國', 'GERMANY'],
  'FR': ['FR', 'FRA', '法国', '法國', 'FRANCE'],
  'NL': ['NL', 'NLD', '荷兰', '荷蘭', 'NETHERLANDS'],
  'CA': ['CA', 'CAN', '加拿大', 'CANADA'],
  'AU': ['AU', 'AUS', '澳大利亚', '澳洲', 'AUSTRALIA'],
  'IN': ['IN', 'IND', '印度', 'INDIA'],
  'TH': ['TH', 'THA', '泰国', '泰國', 'THAILAND'],
  'VN': ['VN', 'VNM', '越南', 'VIETNAM'],
  'MY': ['MY', 'MYS', '马来', '馬來', 'MALAYSIA'],
  'PH': ['PH', 'PHL', '菲律宾', '菲律賓', 'PHILIPPINES'],
  'ID': ['ID', 'IDN', '印尼', '印度尼西亚', 'INDONESIA'],
  'RU': ['RU', 'RUS', '俄罗斯', '俄羅斯', 'RUSSIA'],
  'BR': ['BR', 'BRA', '巴西', 'BRAZIL'],
};

String countryCodeForProxyNode(ProxyNode node) {
  for (final key in _nodeCountryKeys) {
    final value = node.extra[key]?.toString().trim().toUpperCase();
    if (value != null && value.length == 2) {
      return normalizeNodeCountryCode(value);
    }
  }

  final haystack = '${node.name} ${node.server}'.toUpperCase();
  for (final entry in _countryPatterns.entries) {
    for (final token in entry.value) {
      if (RegExp(
        '(^|[^A-Z])${RegExp.escape(token)}([^A-Z]|\$)',
      ).hasMatch(haystack)) {
        return entry.key;
      }
    }
  }

  return 'UN';
}

String normalizeNodeCountryCode(String code) {
  final upper = code.toUpperCase();
  if (upper == 'UK') return 'GB';
  if (upper == 'EL') return 'GR';
  return upper;
}
