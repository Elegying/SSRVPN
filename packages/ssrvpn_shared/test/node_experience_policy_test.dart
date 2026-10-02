import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/services/node_pin_store.dart';
import 'package:ssrvpn_shared/services/site_access_diagnostic.dart';
import 'package:ssrvpn_shared/utils/node_import_policy.dart';
import 'package:ssrvpn_shared/utils/node_search_policy.dart';

ProxyNode node(String name) => ProxyNode(
    name: name,
    type: 'trojan',
    server: 'node.example.com',
    port: 443,
    group: '香港 Premium');
void main() {
  test('search uses literal words, all terms and case-insensitive matching',
      () {
    final item = node('HK [01]');
    expect(NodeSearchPolicy.matches(item, 'hk premium'), isTrue);
    expect(NodeSearchPolicy.matches(item, '[01]'), isTrue);
    expect(NodeSearchPolicy.matches(item, 'trojan 香港'), isTrue);
    expect(NodeSearchPolicy.matches(item, '.*'), isFalse);
    expect(NodeSearchPolicy.matches(item, 'HK 日本'), isFalse);
    expect(NodeSearchPolicy.matches(item, '  '), isTrue);
  });
  test('clipboard only recognizes runnable, bounded single-node codes', () {
    const valid = 'trojan://secret@node.example.com:443#Test';
    expect(NodeImportPolicy.candidate(valid), valid);
    expect(NodeImportPolicy.candidate(' $valid '), valid);
    for (final input in [
      'ordinary text',
      'https://example.com',
      'https://example.com/feed?token=private',
      'trojan://@node.example.com:443',
      'trojan://secret@node.example.com:0',
      '$valid\n$valid',
      'javascript:alert(1)',
      'x' * 16385
    ]) {
      expect(NodeImportPolicy.candidate(input), isNull,
          reason: input.substring(0, input.length > 100 ? 100 : input.length));
    }
    expect(
        NodeImportPolicy.candidate('https://example.com/feed',
            allowSubscription: true),
        'https://example.com/feed');
  });
  group('pins are persistent display preferences', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('pin-test-');
    });
    tearDown(() async {
      await dir.delete(recursive: true);
    });
    test('restart, toggle, bounded hashes and no credentials on disk',
        () async {
      final store = NodePinStore(dir.path);
      final item = node('A').copyWith(extra: {'password': 'do-not-write'});
      await store.toggle(item);
      expect(store.contains(item), isTrue);
      final content =
          await File('${dir.path}/${NodePinStore.fileName}').readAsString();
      expect(content, isNot(contains('do-not-write')));
      expect(content, isNot(contains('node.example.com')));
      final reopened = NodePinStore(dir.path);
      await reopened.load();
      expect(reopened.contains(item), isTrue);
      await reopened.toggle(item);
      expect(reopened.contains(item), isFalse);
      store.dispose();
      reopened.dispose();
    });
    test('concurrent old and new route instances do not lose each other pins',
        () async {
      final a = NodePinStore(dir.path), b = NodePinStore(dir.path);
      await Future.wait([a.load(), b.load()]);
      await Future.wait([a.toggle(node('A')), b.toggle(node('B'))]);
      final read = NodePinStore(dir.path);
      await read.load();
      expect(read.contains(node('A')), isTrue);
      expect(read.contains(node('B')), isTrue);
      a.dispose();
      b.dispose();
      read.dispose();
    });
    test('corrupt optional preferences do not block connection or later saves',
        () async {
      await File('${dir.path}/${NodePinStore.fileName}').writeAsString('{bad');
      final store = NodePinStore(dir.path);
      await store.load();
      expect(store.contains(node('A')), isFalse);
      await store.toggle(node('A'));
      expect(store.contains(node('A')), isTrue);
      store.dispose();
    });
    test('symlink write refusal preserves the linked file and current order',
        () async {
      final other = File('${dir.path}/other');
      await other.writeAsString('keep');
      await Link('${dir.path}/${NodePinStore.fileName}').create(other.path);
      final store = NodePinStore(dir.path);
      await expectLater(
          store.toggle(node('A')), throwsA(isA<FileSystemException>()));
      expect(await other.readAsString(), 'keep');
      expect(store.contains(node('A')), isFalse);
      store.dispose();
    });
    test('disposing during save does not fail the authorized persistence',
        () async {
      final store = NodePinStore(dir.path);
      final saved = store.toggle(node('A'));
      store.dispose();
      await saved;
      expect(
          jsonDecode(await File('${dir.path}/${NodePinStore.fileName}')
              .readAsString()),
          contains('pins'));
    });
  });
  test(
      'diagnostic targets reject credentials, internal/literal hosts and dangerous schemes',
      () {
    expect(SiteAccessDiagnostic.parseTarget('example.com').toString(),
        'https://example.com');
    expect(SiteAccessDiagnostic.parseTarget('https://example.com/path').path,
        '/path');
    for (final input in [
      'file:///etc/passwd',
      'https://user:pass@example.com',
      'http://127.0.0.1',
      'http://[::1]',
      'localhost',
      'http://a.local',
      'http://a.internal',
      'http://169.254.169.254',
      'http://0x7f.0.0.1',
      'http://2130706433',
      'https://example.com:9090',
      'https://example.com/?token=secret',
      'https://example.com#part',
      'https://-bad.com',
      'example.com\r\nX-Test: value'
    ]) {
      expect(
          () => SiteAccessDiagnostic.parseTarget(input), throwsFormatException,
          reason: input);
    }
  });
}
