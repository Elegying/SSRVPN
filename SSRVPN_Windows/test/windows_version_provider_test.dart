import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/windows_version_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test.ssrvpn/platform_info');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('uses the Windows build number instead of stale product naming',
      () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => <String, Object>{
        'major': 10,
        'minor': 0,
        'build': 26200,
        'displayVersion': '25H2',
        'editionId': 'Professional',
      },
    );

    final description = await WindowsVersionProvider(
      channel: channel,
      fallbackVersion: () => 'Windows 10 Pro 10.0.26200',
    ).describe();

    expect(description, 'Windows 11 Pro 25H2 (10.0 build 26200)');
  });

  test('keeps Windows 10 for pre-22000 builds', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => <String, Object>{
        'major': 10,
        'minor': 0,
        'build': 19045,
        'displayVersion': '22H2',
        'editionId': 'Core',
      },
    );

    final description = await WindowsVersionProvider(
      channel: channel,
      fallbackVersion: () => '',
    ).describe();

    expect(description, 'Windows 10 Home 22H2 (10.0 build 19045)');
  });

  test('corrects a misleading platform fallback using its build number',
      () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) => throw PlatformException(code: 'native-failure'),
    );

    final description = await WindowsVersionProvider(
      channel: channel,
      fallbackVersion: () => 'Windows 10 Pro 10.0.26200',
    ).describe();

    expect(description, 'Windows 11 (10.0 build 26200)');
  });

  test('does not relabel a non-Windows test host', () {
    expect(
      WindowsVersionInfo.describeFallback('Version 26.5.0'),
      'Version 26.5.0',
    );
  });
}
