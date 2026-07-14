// ignore_for_file: deprecated_member_use, deprecated_member_use_from_same_package

import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:test/test.dart';

void main() {
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
}
