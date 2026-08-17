part of 'clash_service.dart';

String? _androidLocalCountryCode(String name) {
  final upper = name.toUpperCase().trim();
  final isoMatch = RegExp(
    r'(?:^|\s|[-/#【\[\(（])'
    r'(US|UK|GB|JP|KR|HK|TW|SG|DE|FR|NL|CA|AU|IN|TH|VN|ID|PH|MY|RU|TR|BR|AR|MX|ZA|IT|ES|SE|NO|FI|DK|IE|CH|AT|BE|PL|UA|CL|CO|PE)'
    r'(?:$|\s|[-/#】\]\)）]|[^A-Z])',
  );
  final match = isoMatch.firstMatch(upper);
  if (match != null) return match.group(1);

  const keywordMap = {
    '美国': 'US',
    '洛杉矶': 'US',
    '圣何塞': 'US',
    '纽约': 'US',
    'USA': 'US',
    'AMERICA': 'US',
    '日本': 'JP',
    '东京': 'JP',
    '大阪': 'JP',
    'JAPAN': 'JP',
    '韩国': 'KR',
    '首尔': 'KR',
    'KOREA': 'KR',
    'SOUTH KOREA': 'KR',
    '香港': 'HK',
    'HONG KONG': 'HK',
    '台湾': 'TW',
    '台北': 'TW',
    'TAIWAN': 'TW',
    '新加坡': 'SG',
    'SINGAPORE': 'SG',
    '德国': 'DE',
    '法兰克福': 'DE',
    'GERMANY': 'DE',
    '法国': 'FR',
    '巴黎': 'FR',
    'FRANCE': 'FR',
    '荷兰': 'NL',
    'NETHERLANDS': 'NL',
    '加拿大': 'CA',
    'CANADA': 'CA',
    '澳大利亚': 'AU',
    '悉尼': 'AU',
    'AUSTRALIA': 'AU',
    '印度': 'IN',
    '孟买': 'IN',
    'INDIA': 'IN',
    '泰国': 'TH',
    '曼谷': 'TH',
    'THAILAND': 'TH',
    '越南': 'VN',
    'VIETNAM': 'VN',
    '印尼': 'ID',
    '雅加达': 'ID',
    '菲律宾': 'PH',
    '马尼拉': 'PH',
    '马来西亚': 'MY',
    '吉隆坡': 'MY',
    'MALAYSIA': 'MY',
    '俄罗斯': 'RU',
    '莫斯科': 'RU',
    'RUSSIA': 'RU',
    '土耳其': 'TR',
    'TURKEY': 'TR',
    '巴西': 'BR',
    'BRAZIL': 'BR',
    '阿根廷': 'AR',
    'ARGENTINA': 'AR',
    '墨西哥': 'MX',
    'MEXICO': 'MX',
    '英国': 'GB',
    '伦敦': 'GB',
    'UNITED KINGDOM': 'GB',
    '意大利': 'IT',
    'ITALY': 'IT',
    '西班牙': 'ES',
    'SPAIN': 'ES',
    '瑞典': 'SE',
    'SWEDEN': 'SE',
    '挪威': 'NO',
    'NORWAY': 'NO',
    '芬兰': 'FI',
    'FINLAND': 'FI',
    '丹麦': 'DK',
    'DENMARK': 'DK',
    '瑞士': 'CH',
    'SWITZERLAND': 'CH',
    '南非': 'ZA',
    'SOUTH AFRICA': 'ZA',
  };
  for (final entry in keywordMap.entries) {
    if (upper.contains(entry.key)) return entry.value;
  }
  return null;
}

String _androidFlagEmoji(String countryCode) {
  if (countryCode.length != 2) return '🏳️';
  final first = countryCode.codeUnitAt(0) - 0x41 + 0x1F1E6;
  final second = countryCode.codeUnitAt(1) - 0x41 + 0x1F1E6;
  return String.fromCharCodes([first, second]);
}
