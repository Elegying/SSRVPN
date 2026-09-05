// ignore_for_file: deprecated_member_use, deprecated_member_use_from_same_package

import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:test/test.dart';

void main() {
  test(
      'rename ownership survives serialization and clears on independent selection',
      () {
    final settings = AppSettings(
        lastSelectedNodeName: 'Edited', lastSelectedNodeRenameId: 'edit-1');
    expect(AppSettings.fromJson(settings.toJson()), settings);
    expect(
        settings.copyWith(proxyPort: 8890).lastSelectedNodeRenameId, 'edit-1');
    expect(
        settings
            .copyWith(lastSelectedNodeName: 'Other')
            .lastSelectedNodeRenameId,
        isEmpty);
    expect(
        settings.copyWith(lastSelectedNode: 'Other').lastSelectedNodeRenameId,
        isEmpty);
    expect(
        settings
            .copyWith(
                lastSelectedNodeName: 'Next',
                lastSelectedNodeRenameId: 'edit-2')
            .lastSelectedNodeRenameId,
        'edit-2');
    expect(
        settings.copyWith(lastSelectedNodeRenameId: 'edit-2'), isNot(settings));
    settings.lastSelectedNode = 'Other';
    expect(settings.lastSelectedNodeRenameId, isEmpty);
  });

  test('latency checks use HTTPS and migrate the historical HTTP default', () {
    expect(AppSettings().latencyTestUrl, AppConstants.defaultLatencyTestUrl);
    expect(
      AppSettings.fromJson({
        'latencyTestUrl': 'http://www.gstatic.com/generate_204',
      }).latencyTestUrl,
      AppConstants.defaultLatencyTestUrl,
    );
    expect(
      AppSettings.fromJson({
        'latencyTestUrl': 'https://custom.example/check',
      }).latencyTestUrl,
      'https://custom.example/check',
    );
  });

  test('rejects an invalid or injected TUN stack value', () {
    final restored = AppSettings.fromJson({
      'tunStack': 'gvisor\n  auto-route: false',
    });

    expect(restored.tunStack, 'gvisor');
  });

  test('falls back safely when optional setting types are corrupted', () {
    final restored = AppSettings.fromJson({
      'proxyMode': 42,
      'lastSelectedNodeName': 42,
      'lastSelectedNode': 'legacy-node',
    });

    expect(restored.proxyMode, ProxyMode.rule);
    expect(restored.lastSelectedNodeName, 'legacy-node');
  });

  test('deprecated setting aliases remain compatible during migration', () {
    final settings = AppSettings(
      tunMode: true,
      lastSelectedNode: 'legacy-node',
    );
    expect(settings.enableTun, isTrue);
    expect(settings.lastSelectedNodeName, 'legacy-node');

    settings.enableSystemProxy = true;
    settings.lastSelectedNode = 'renamed-node';
    expect(settings.enableTun, isFalse);
    expect(settings.lastSelectedNodeName, 'renamed-node');

    final copied = settings.copyWith(
      tunMode: true,
      lastSelectedNode: 'copied-node',
    );
    expect(copied.enableTun, isTrue);
    expect(copied.lastSelectedNodeName, 'copied-node');
  });

  test('manual direct rules round-trip without changing old settings', () {
    final oldSettings = AppSettings.fromJson({
      'forceProxySites': ['proxy.example'],
    });
    expect(oldSettings.forceDirectSites, everyElement(isEmpty));

    final settings = oldSettings.copyWith(
      forceDirectSites: const ['direct.example', 'https://api.example/path'],
    );
    final restored = AppSettings.fromJson(settings.toJson());

    expect(restored.forceProxySites.first, 'proxy.example');
    expect(restored.forceDirectSites.take(2), [
      'direct.example',
      'https://api.example/path',
    ]);
    expect(restored, settings);
  });
}
