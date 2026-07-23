import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/startup/startup_flags.dart';

void main() {
  test('elevated TUN relaunch flag is exact and case insensitive', () {
    expect(
      StartupFlags.parse(const [
        '--SSRVPN-ELEVATED-TUN-RELAUNCH',
      ]).resumeTunAfterElevation,
      isTrue,
    );
    expect(
      StartupFlags.parse(const [
        'prefix--ssrvpn-elevated-tun-relaunch',
      ]).resumeTunAfterElevation,
      isFalse,
    );
  });

  test('normal startup never resumes TUN implicitly', () {
    final flags = StartupFlags.parse(const []);

    expect(flags.resumeTunAfterElevation, isFalse);
    expect(flags.toString(), contains('resumeTunAfterElevation=false'));
  });
}
