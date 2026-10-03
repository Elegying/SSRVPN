import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:ssrvpn_shared/services/public_ip_info_service.dart';
import 'package:ssrvpn_shared/services/subscription_parser.dart';
import 'package:ssrvpn_shared/services/subscription_yaml_merger.dart';
import 'package:ssrvpn_shared/services/update_checker.dart';
import 'package:ssrvpn_shared/utils/bounded_file_logger.dart';
import 'package:ssrvpn_shared/utils/bounded_yaml.dart';
import 'package:ssrvpn_shared/utils/log_redactor.dart';

void main() {
  test('cancellation stops headers and never starts fallback or geolocation',
      () async {
    final headers = Completer<http.StreamedResponse>();
    final requests = <http.BaseRequest>[];
    var bodyCancelled = false;
    final body =
        StreamController<List<int>>(onCancel: () => bodyCancelled = true);
    final client = _Client((request) {
      requests.add(request);
      return headers.future;
    });
    final query = PublicIpInfoService(client: client);
    final pending = query.fetch();
    final assertion =
        expectLater(pending, throwsA(isA<PublicIpInfoException>()));
    query.cancel();
    await assertion;
    headers.complete(http.StreamedResponse(body.stream, 200));
    await Future<void>.delayed(Duration.zero);
    expect(bodyCancelled, isTrue);
    expect(requests, hasLength(1));
    await body.close();
  });

  test(
      'cancellation while reading geolocation closes its body without fallback',
      () async {
    final geoStarted = Completer<void>();
    var bodyCancelled = false;
    final geo =
        StreamController<List<int>>(onCancel: () => bodyCancelled = true);
    final hosts = <String>[];
    final client = _Client((request) async {
      hosts.add(request.url.host);
      if (request.url == PublicIpInfoService.ipv4Endpoint) {
        return http.StreamedResponse(
            Stream.value(utf8.encode('{"ip":"8.8.8.8"}')), 200);
      }
      geoStarted.complete();
      return http.StreamedResponse(geo.stream, 200);
    });
    final query = PublicIpInfoService(client: client);
    final pending = query.fetch();
    final assertion =
        expectLater(pending, throwsA(isA<PublicIpInfoException>()));
    await geoStarted.future;
    query.cancel();
    await assertion;
    expect(bodyCancelled, isTrue);
    expect(hosts, ['api4.ipify.org', 'api.ip.sb']);
    await geo.close();
  });

  for (final value in ['false', '0', 'none', '', 'true', 'tls', '1']) {
    test('VMess TLS handles explicit $value without guessing', () {
      final uri = 'vmess://${base64Encode(utf8.encode(jsonEncode({
            'add': 'node.invalid',
            'port': 443,
            'id': 'test-uuid',
            'tls': value
          })))}';
      final proxy = SubscriptionParser.proxyFromUri(uri)!;
      expect(proxy['tls'] == true, ['true', 'tls', '1'].contains(value));
    });
  }
  test('unknown transports fail closed rather than silently using TCP', () {
    expect(
        SubscriptionParser.proxyFromUri(
            'trojan://test@node.invalid:443?type=kcp'),
        isNull);
    final supported = SubscriptionParser.proxyFromUri(
        'trojan://test@node.invalid:443?type=httpupgrade&path=%2Ftransport')!;
    expect(supported['network'], 'ws');
    expect(supported['ws-opts'], containsPair('v2ray-http-upgrade', true));
  });
  for (final key in ['pinSHA256', 'pinsha256', 'pin-sha256']) {
    test('HY2 preserves certificate pin alias $key', () {
      expect(
          SubscriptionParser.proxyFromUri(
              'hy2://test@node.invalid:443?$key=abcdef')!['fingerprint'],
          'abcdef');
    });
  }
  test('URI parsers reject invalid ports at import boundary', () {
    expect(SubscriptionParser.proxyFromUri('trojan://test@node.invalid:65536'),
        isNull);
    for (final port in [0, -1, 65536]) {
      expect(
          SubscriptionParser.proxyFromUri(
              'vmess://${base64Encode(utf8.encode(jsonEncode({
                'add': 'node.invalid',
                'port': port,
                'id': 'test-uuid'
              })))}'),
          isNull);
    }
  });

  test('section extraction agrees for quoted keys, nested keys and CRLF', () {
    const yaml = 'metadata:\r\n  proxies:\r\n    - ignored\r\n'
        '"proxies": # actual root\r\n    - name: "Node"\r\n'
        '      type: ss\r\n      server: node.invalid\r\n      port: 443\r\n'
        'proxy-groups:\r\n  - name: PROXY\r\n';
    final sections = [
      ClashConfigGenerator.extractSection(yaml, 'proxies'),
      SubscriptionParser.extractSection(yaml, 'proxies'),
      SubscriptionYamlMerger.extractSection(yaml, 'proxies'),
    ];
    expect(sections.toSet(), hasLength(1));
    expect(sections.first, isNot(contains('ignored')));
    final document = BoundedYaml.load('proxies:\n${sections.first}');
    expect((document as Map)['proxies'], hasLength(1));
    expect(document['proxies'][0]['name'], 'Node');
  });

  for (final marker in ['|', '|+', '|-', '>', '>+', '>-']) {
    test('section extraction preserves literal/folded content $marker', () {
      final yaml = 'proxies:\n  - name: Node\n    note: $marker\n'
          '      first\n\n      third\n\n\n';
      for (final extract in [
        ClashConfigGenerator.extractSection,
        SubscriptionParser.extractSection,
        SubscriptionYamlMerger.extractSection,
      ]) {
        final original = BoundedYaml.load(yaml) as Map;
        final rebuilt =
            BoundedYaml.load('proxies:\n${extract(yaml, 'proxies')}\n\n')
                as Map;
        expect(rebuilt['proxies'][0]['note'], original['proxies'][0]['note']);
      }
    });
  }

  test('drop marker survives a batch exceeding a nearly equal file budget',
      () async {
    final directory = await Directory.systemTemp.createTemp('audit-log-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/log');
    final sink =
        BoundedFileLogger(file, maxFileBytes: 1024, maxPendingBytes: 1023);
    for (var i = 0; i < 200; i++) {
      sink.add('${'x' * 100}\n');
    }
    await sink.flush();
    expect(await file.length(), lessThanOrEqualTo(1024));
    expect(await file.readAsString(), contains('dropped'));
  });

  test('unclosed sensitive values crossing truncation remain redacted', () {
    for (final text in [
      '"password":"',
      "'token':'",
      'Authorization: Bearer ',
      'https://username:',
      'vmess://'
    ]) {
      final input = '${'x' * (LogRedactor.maxInputCharacters - 40)} '
          '$text${'sensitive' * 100}';
      final sanitized = LogRedactor.sanitize(input);
      expect(sanitized, isNot(contains('sensitive')));
      expect(sanitized, contains('truncated'));
    }
  });

  for (final metadata in [
    {'tag_name': 'v99.0.0-beta.1'},
    {'tag_name': 'v99.0.0', 'prerelease': true},
    {'tag_name': 'v99.0.0', 'draft': true},
  ]) {
    test('stable updater skips prerelease/draft metadata $metadata', () async {
      var requests = 0;
      final result = await UpdateChecker.checkLatest(
          currentVersion: '5.0.28',
          assetExtension: '.exe',
          client: _Client((request) async {
            requests++;
            return http.StreamedResponse(
                Stream.value(utf8.encode(jsonEncode(metadata))), 200);
          }));
      expect(result, isNull);
      expect(requests, 1);
    });
  }
}

class _Client extends http.BaseClient {
  _Client(this.onSend);
  final Future<http.StreamedResponse> Function(http.BaseRequest) onSend;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      onSend(request);
}
