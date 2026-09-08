import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/utils/node_country_policy.dart';
import 'package:test/test.dart';

void main() {
  group('countryCodeForProxyNode', () {
    ProxyNode sample(String name,
            {Map<String, dynamic> extra = const {},
            String server = 'edge.example.com'}) =>
        ProxyNode(
            name: name, type: 'ss', server: server, port: 443, extra: extra);

    test('recognizes supplied flag emoji before hiding it in the display name',
        () {
      for (final entry in {
        '🇸🇪 专线 01': 'SE',
        'Premium 🇨🇭 02': 'CH',
        '🇦🇪': 'AE',
        '🇵🇱 IPLC': 'PL'
      }.entries) {
        expect(countryCodeForProxyNode(sample(entry.key)), entry.value);
      }
    });

    test('accepts supported metadata codes and skips invalid hints', () {
      expect(countryCodeForProxyNode(sample('入口', extra: {'country': 'swe'})),
          'SE');
      expect(
          countryCodeForProxyNode(sample('🇨🇭 专线', extra: {'country': 'ZZ'})),
          'CH');
      expect(
          countryCodeForProxyNode(
              sample('入口', extra: {'country': '未知', 'countryCode': 'pl'})),
          'PL');
      expect(countryCodeForProxyNode(sample('入口', extra: {'region': '新西兰'})),
          'NZ');
    });

    test('recognizes country codes and common localized location names', () {
      for (final entry in {
        '瑞典 01': 'SE',
        '阿联酋 02': 'AE',
        '洛杉矶 IPLC': 'US',
        '首尔 01': 'KR',
        'PL-01': 'PL',
        'CH02': 'CH',
        'nz03': 'NZ',
        '🇺🇸 日本中转': 'US'
      }.entries) {
        expect(countryCodeForProxyNode(sample(entry.key)), entry.value);
      }
      expect(
          countryCodeForProxyNode(
              sample('日本 01', server: 'hk.edge.example.com')),
          'JP');
      expect(
          countryCodeForProxyNode(
              sample('edge', server: 'pl.edge.example.com')),
          'PL');
    });

    test('does not guess an unsupported or unspecified location', () {
      for (final name in ['🇿🇿 专线', 'SERVER-01', 'node in transit', '高速专线']) {
        expect(countryCodeForProxyNode(sample(name)), 'UN');
      }
    });

    test('uses explicit country metadata first', () {
      final node = ProxyNode(
        name: 'Tokyo node',
        type: 'ss',
        server: 'example.com',
        port: 443,
        extra: {'countryCode': 'uk'},
      );

      expect(countryCodeForProxyNode(node), 'GB');
    });

    test('detects known regions from node name and server', () {
      final node = ProxyNode(
        name: 'VIP 新加坡 01',
        type: 'ss',
        server: 'sg.example.com',
        port: 443,
      );

      expect(countryCodeForProxyNode(node), 'SG');
    });

    test('falls back to unknown when no country hint exists', () {
      final node = ProxyNode(
        name: 'edge',
        type: 'ss',
        server: 'proxy.example.com',
        port: 443,
      );

      expect(countryCodeForProxyNode(node), 'UN');
    });
  });

  group('nodeDisplayNameWithoutLeadingFlag', () {
    test('removes a leading regional flag and following whitespace', () {
      expect(
        nodeDisplayNameWithoutLeadingFlag('🇭🇰 香港 | IEPL ①'),
        '香港 | IEPL ①',
      );
    });

    test('preserves names without a leading regional flag', () {
      expect(nodeDisplayNameWithoutLeadingFlag('私家车-2025'), '私家车-2025');
      expect(nodeDisplayNameWithoutLeadingFlag('🚀 高速节点'), '🚀 高速节点');
      expect(nodeDisplayNameWithoutLeadingFlag('🇯🇵'), '🇯🇵');
    });
  });

  test('long display names keep a recognizable suffix', () {
    const fullName = '香港企业专线超级超级超级超级长名称 | IPLC | 备用节点 ⑩';

    final compact = compactNodeDisplayName(fullName);

    expect(compact, contains('…'));
    expect(compact, startsWith('香港企业专线'));
    expect(compact, endsWith('备用节点 ⑩'));
    expect(compact.runes.length, lessThanOrEqualTo(24));
  });
}
