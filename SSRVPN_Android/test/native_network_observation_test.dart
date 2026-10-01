import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/services/clash_service.dart';

class _NetworkObservationService extends ClashService {
  String fingerprint = 'wifi:192.0.2.1';
  Completer<String?>? pendingFingerprint;
  int observations = 0;

  void publishWarning() => setConnectivityWarning('previous network warning');

  @override
  Duration? get networkChangeWatchInterval => const Duration(days: 1);

  @override
  Future<String?> buildNetworkFingerprint() =>
      pendingFingerprint?.future ?? Future.value(fingerprint);

  @override
  Future<void> observeDataPlaneHealth() async {
    observations++;
  }

  @override
  Future<void> refreshRuleProvidersOnce() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.ssrvpn/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _NetworkObservationService service;
  late int sessionGeneration;

  setUp(() async {
    sessionGeneration = 8;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'getConnectionState') return null;
      return <String, Object?>{
        'running': true,
        'transitioning': false,
        'protectedConfigPath': null,
        'sessionGeneration': sessionGeneration,
      };
    });
    service = _NetworkObservationService();
    expect(await service.refreshNativeConnectionState(), isTrue);
    await service.runNetworkChangeCheck();
    service.publishWarning();
  });

  tearDown(() {
    service.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'same-session native broadcast retains the physical network baseline',
    () async {
      service.fingerprint = 'mobile:198.51.100.1';
      await service.handleNativeStateChangedForTesting(true);
      await service.runNetworkChangeCheck();

      expect(service.observations, 1);
      expect(service.connectivityWarning, isNull);
      expect(service.isRunning, isTrue);
      expect(service.connectionDesired, isTrue);
    },
  );

  test(
    'same-session refresh preserves an in-flight fingerprint comparison',
    () async {
      final fingerprint = Completer<String?>();
      service.pendingFingerprint = fingerprint;
      final checking = service.runNetworkChangeCheck();
      expect(await service.refreshNativeConnectionState(), isTrue);
      fingerprint.complete('mobile:198.51.100.1');
      await checking;

      expect(service.observations, 1);
      expect(service.connectivityWarning, isNull);
      expect(service.isRunning, isTrue);
      expect(service.connectionDesired, isTrue);
    },
  );

  test(
    'unchanged native refresh does not invent a network transition',
    () async {
      expect(await service.refreshNativeConnectionState(), isTrue);
      await service.runNetworkChangeCheck();

      expect(service.observations, 0);
      expect(service.connectivityWarning, 'previous network warning');
    },
  );

  test(
    'replacement native session still retires the previous baseline',
    () async {
      sessionGeneration++;
      service.fingerprint = 'mobile:198.51.100.1';
      expect(await service.refreshNativeConnectionState(), isTrue);
      await service.runNetworkChangeCheck();

      expect(service.observations, 0);
      expect(service.connectivityWarning, isNull);
      service.fingerprint = 'wifi:203.0.113.1';
      await service.runNetworkChangeCheck();
      expect(service.observations, 1);
      expect(service.isRunning, isTrue);
      expect(service.connectionDesired, isTrue);
    },
  );
}
