import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/windows_tun_elevation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test.ssrvpn/tun_elevation');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'maps native elevation states without guessing unknown results',
    () async {
      var response = 'elevated';
      messenger.setMockMethodCallHandler(channel, (_) async => response);
      final service = WindowsTunElevationService(channel: channel);

      expect(await service.queryIsElevated(), isTrue);
      response = 'limited';
      expect(await service.queryIsElevated(), isFalse);
      response = 'standard';
      expect(await service.queryIsElevated(), isFalse);
      response = 'unknown';
      expect(await service.queryIsElevated(), isNull);
    },
  );

  test('maps UAC launch, cancellation, and standard-user boundaries', () async {
    var response = 'launched';
    messenger.setMockMethodCallHandler(channel, (_) async => response);
    final service = WindowsTunElevationService(channel: channel);

    expect(
      await service.requestRelaunch(),
      WindowsTunElevationRequestResult.launched,
    );
    response = 'cancelled';
    expect(
      await service.requestRelaunch(),
      WindowsTunElevationRequestResult.cancelled,
    );
    response = 'standardUser';
    expect(
      await service.requestRelaunch(),
      WindowsTunElevationRequestResult.standardUser,
    );
  });

  test('fails closed when the native elevation channel fails', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) => throw PlatformException(code: 'native-failure'),
    );
    final service = WindowsTunElevationService(channel: channel);

    expect(await service.queryIsElevated(), isNull);
    expect(
      await service.requestRelaunch(),
      WindowsTunElevationRequestResult.failed,
    );
  });
}
