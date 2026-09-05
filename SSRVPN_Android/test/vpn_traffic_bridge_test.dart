import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/services/clash_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.ssrvpn/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Android uses native session totals and validates bridge counters',
      () async {
    final service = ClashService();
    addTearDown(service.dispose);
    Map<String, dynamic>? data = {
      'sessionGeneration': 7,
      'sampledAtMillis': 1234,
      'upload': 1024,
      'download': 2048,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getTrafficStats');
      return data;
    });
    final first = (await service.readTrafficSample())!;
    expect(first.sessionGeneration, 7);
    expect(first.total, 3072);
    data = null;
    expect(await service.readTrafficSample(), isNull);
    data = {
      'sessionGeneration': 8,
      'sampledAtMillis': 2000,
      'upload': -1,
      'download': 0
    };
    await expectLater(service.readTrafficSample(), throwsFormatException);
  });
}
