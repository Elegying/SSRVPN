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
}
