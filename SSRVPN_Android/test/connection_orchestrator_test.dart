import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssrvpn_android/models/app_settings.dart';
import 'package:ssrvpn_android/services/clash_service.dart';
import 'package:ssrvpn_android/services/connection_orchestrator.dart';
import 'package:ssrvpn_android/services/settings_service.dart';
import 'package:ssrvpn_android/services/subscription_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('subscription revision change aborts a delayed config before write',
      () async {
    SharedPreferences.setMockInitialValues({});
    final tempDir = await Directory.systemTemp.createTemp(
      'ssrvpn_connection_snapshot_',
    );
    addTearDown(() async {
      SubscriptionService.resetInstanceForTesting();
      await tempDir.delete(recursive: true);
    });
    SubscriptionService.resetInstanceForTesting();
    final subscriptionService =
        await SubscriptionService.getInstance(tempDir.path);
    await subscriptionService.setRawYaml(_yaml('Old', 'old.example.com'));
    final settingsService = await SettingsService.createForTesting(
      configPath: '${tempDir.path}/settings.json',
      readApiSecret: () async => 'test-secret',
      writeApiSecret: (_) async {},
    );
    final clashService = _DelayedConfigClashService();
    final generation = clashService.requestConnectionIntent(true);
    final orchestrator = ConnectionOrchestrator(
      clashService: clashService,
      settingsService: settingsService,
      subscriptionService: subscriptionService,
    );

    final connecting = orchestrator.connect(
      'Old',
      connectionGeneration: generation,
    );
    await clashService.generationStarted.future;
    await subscriptionService.setRawYaml(_yaml('New', 'new.example.com'));
    clashService.releaseGeneration.complete();

    expect(await connecting, contains('订阅已更新'));
    expect(clashService.writeCalls, 0);
    expect(clashService.startCalls, 0);
  });

  test('subscription revision change during proxy switch stops old config',
      () async {
    SharedPreferences.setMockInitialValues({});
    final tempDir = await Directory.systemTemp.createTemp(
      'ssrvpn_connection_switch_snapshot_',
    );
    addTearDown(() async {
      SubscriptionService.resetInstanceForTesting();
      await tempDir.delete(recursive: true);
    });
    SubscriptionService.resetInstanceForTesting();
    final subscriptionService =
        await SubscriptionService.getInstance(tempDir.path);
    await subscriptionService.setRawYaml(_yaml('Old', 'old.example.com'));
    final settingsService = await SettingsService.createForTesting(
      configPath: '${tempDir.path}/settings.json',
      readApiSecret: () async => 'test-secret',
      writeApiSecret: (_) async {},
    );
    final clashService = _DelayedSwitchClashService();
    final generation = clashService.requestConnectionIntent(true);
    final orchestrator = ConnectionOrchestrator(
      clashService: clashService,
      settingsService: settingsService,
      subscriptionService: subscriptionService,
    );

    final connecting = orchestrator.connect(
      'Old',
      connectionGeneration: generation,
    );
    await clashService.switchStarted.future;
    await subscriptionService.setRawYaml(_yaml('New', 'new.example.com'));
    clashService.releaseSwitch.complete();

    expect(await connecting, contains('订阅已更新'));
    expect(clashService.stopCalls, 1);
    expect(clashService.isRunning, isFalse);
  });

  test('failed current connection clears the desired connection intent', () {
    final clashService = ClashService();
    final generation = clashService.requestConnectionIntent(true);

    expect(
      rollbackFailedAndroidConnectionIntent(clashService, generation),
      isTrue,
    );
    expect(clashService.connectionDesired, isFalse);
  });

  test('failed stale connection cannot cancel a newer intent', () {
    final clashService = ClashService();
    final staleGeneration = clashService.requestConnectionIntent(true);
    final currentGeneration = clashService.requestConnectionIntent(true);

    expect(
      rollbackFailedAndroidConnectionIntent(clashService, staleGeneration),
      isFalse,
    );
    expect(
      clashService.isConnectionIntentCurrent(
        currentGeneration,
        connected: true,
      ),
      isTrue,
    );
  });

  test('a still-running connection preserves its desired intent', () {
    final clashService = ClashService()..setRunning(true);
    final generation = clashService.requestConnectionIntent(true);

    expect(
      rollbackFailedAndroidConnectionIntent(clashService, generation),
      isFalse,
    );
    expect(clashService.connectionDesired, isTrue);
  });

  test('connection waits for a pending network settings transaction', () async {
    SharedPreferences.setMockInitialValues({});
    final tempDir = await Directory.systemTemp.createTemp(
      'ssrvpn_connection_settings_snapshot_',
    );
    final releaseSecureWrite = Completer<void>();
    var blockSecureWrite = false;
    addTearDown(() async {
      SubscriptionService.resetInstanceForTesting();
      if (!releaseSecureWrite.isCompleted) releaseSecureWrite.complete();
      await tempDir.delete(recursive: true);
    });
    SubscriptionService.resetInstanceForTesting();
    final subscriptionService =
        await SubscriptionService.getInstance(tempDir.path);
    await subscriptionService.setRawYaml(_yaml('Node', 'node.example.com'));
    final settingsService = await SettingsService.createForTesting(
      configPath: '${tempDir.path}/settings.json',
      readApiSecret: () async => 'test-secret',
      writeApiSecret: (_) async {
        if (blockSecureWrite) await releaseSecureWrite.future;
      },
    );
    blockSecureWrite = true;
    final blockingWrite = settingsService.setApiSecret('rotated-secret');
    final modeWrite = settingsService.setProxyMode('global');
    final clashService = _SettingsSnapshotClashService();
    final generation = clashService.requestConnectionIntent(true);
    final orchestrator = ConnectionOrchestrator(
      clashService: clashService,
      settingsService: settingsService,
      subscriptionService: subscriptionService,
    );

    final connecting = orchestrator.connect(
      null,
      connectionGeneration: generation,
    );
    await Future<void>.delayed(Duration.zero);

    expect(clashService.generatedSettings, isNull);

    releaseSecureWrite.complete();
    await blockingWrite;
    await modeWrite;
    expect(await connecting, isNull);
    expect(clashService.generatedSettings?.proxyMode, ProxyMode.global);
    expect(clashService.startCalls, 1);
  });

  test('connection prepares collision-free runtime ports before config',
      () async {
    SharedPreferences.setMockInitialValues({});
    final tempDir = await Directory.systemTemp.createTemp(
      'ssrvpn_android_runtime_ports_',
    );
    final occupied = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    addTearDown(() async {
      SubscriptionService.resetInstanceForTesting();
      await occupied.close();
      await tempDir.delete(recursive: true);
    });
    SubscriptionService.resetInstanceForTesting();
    final subscriptionService =
        await SubscriptionService.getInstance(tempDir.path);
    await subscriptionService.setRawYaml(_yaml('Node', 'node.example.com'));
    final settingsService = await SettingsService.createForTesting(
      configPath: '${tempDir.path}/settings.json',
      readApiSecret: () async => 'test-secret',
      writeApiSecret: (_) async {},
    );
    settingsService.settings.proxyPort = occupied.port;
    final clashService = _SettingsSnapshotClashService();
    final generation = clashService.requestConnectionIntent(true);
    final orchestrator = ConnectionOrchestrator(
      clashService: clashService,
      settingsService: settingsService,
      subscriptionService: subscriptionService,
    );

    final result = await orchestrator.connect(
      null,
      connectionGeneration: generation,
    );

    expect(clashService.generatedSettings?.proxyPort, isNot(occupied.port));
    expect(clashService.lastRuntimePortAdjustmentMessage, contains('端口被占用'));
    expect(result, contains('端口被占用'));
  });

  test('connection regenerates config once after a start-time port race',
      () async {
    SharedPreferences.setMockInitialValues({});
    final tempDir = await Directory.systemTemp.createTemp(
      'ssrvpn_android_port_race_',
    );
    addTearDown(() async {
      SubscriptionService.resetInstanceForTesting();
      await tempDir.delete(recursive: true);
    });
    SubscriptionService.resetInstanceForTesting();
    final subscriptionService =
        await SubscriptionService.getInstance(tempDir.path);
    await subscriptionService.setRawYaml(_yaml('Node', 'node.example.com'));
    final settingsService = await SettingsService.createForTesting(
      configPath: '${tempDir.path}/settings.json',
      readApiSecret: () async => 'test-secret',
      writeApiSecret: (_) async {},
    );
    final clashService = _PortRaceClashService();
    final generation = clashService.requestConnectionIntent(true);
    final orchestrator = ConnectionOrchestrator(
      clashService: clashService,
      settingsService: settingsService,
      subscriptionService: subscriptionService,
    );

    final result = await orchestrator.connect(
      null,
      connectionGeneration: generation,
    );

    expect(result, isNull);
    expect(clashService.prepareCalls, 2);
    expect(clashService.startCalls, 2);
    expect(clashService.stopCalls, 1);
    expect(clashService.generatedPorts, [32000, 32001]);
  });

  test('cancelled connection does not resume after pending settings commit',
      () async {
    SharedPreferences.setMockInitialValues({});
    final tempDir = await Directory.systemTemp.createTemp(
      'ssrvpn_cancelled_settings_snapshot_',
    );
    final releaseSecureWrite = Completer<void>();
    var blockSecureWrite = false;
    addTearDown(() async {
      SubscriptionService.resetInstanceForTesting();
      if (!releaseSecureWrite.isCompleted) releaseSecureWrite.complete();
      await tempDir.delete(recursive: true);
    });
    SubscriptionService.resetInstanceForTesting();
    final subscriptionService =
        await SubscriptionService.getInstance(tempDir.path);
    await subscriptionService.setRawYaml(_yaml('Node', 'node.example.com'));
    final settingsService = await SettingsService.createForTesting(
      configPath: '${tempDir.path}/settings.json',
      readApiSecret: () async => 'test-secret',
      writeApiSecret: (_) async {
        if (blockSecureWrite) await releaseSecureWrite.future;
      },
    );
    blockSecureWrite = true;
    final blockingWrite = settingsService.setApiSecret('rotated-secret');
    final modeWrite = settingsService.setProxyMode('global');
    final clashService = _SettingsSnapshotClashService();
    final generation = clashService.requestConnectionIntent(true);
    final orchestrator = ConnectionOrchestrator(
      clashService: clashService,
      settingsService: settingsService,
      subscriptionService: subscriptionService,
    );

    final connecting = orchestrator.connect(
      null,
      connectionGeneration: generation,
    );
    await Future<void>.delayed(Duration.zero);
    clashService.requestConnectionIntent(false);
    releaseSecureWrite.complete();

    await blockingWrite;
    await modeWrite;
    expect(await connecting, isNull);
    expect(clashService.generatedSettings, isNull);
    expect(clashService.startCalls, 0);
  });

  test('completed settings failure does not poison a later connect retry',
      () async {
    SharedPreferences.setMockInitialValues({});
    final tempDir = await Directory.systemTemp.createTemp(
      'ssrvpn_failed_settings_retry_',
    );
    final releaseSecureWrite = Completer<void>();
    var failSecureWrite = false;
    addTearDown(() async {
      SubscriptionService.resetInstanceForTesting();
      if (!releaseSecureWrite.isCompleted) releaseSecureWrite.complete();
      await tempDir.delete(recursive: true);
    });
    SubscriptionService.resetInstanceForTesting();
    final subscriptionService =
        await SubscriptionService.getInstance(tempDir.path);
    await subscriptionService.setRawYaml(_yaml('Node', 'node.example.com'));
    final settingsService = await SettingsService.createForTesting(
      configPath: '${tempDir.path}/settings.json',
      readApiSecret: () async => 'test-secret',
      writeApiSecret: (_) async {
        if (!failSecureWrite) return;
        await releaseSecureWrite.future;
        throw StateError('keystore unavailable');
      },
    );
    failSecureWrite = true;
    final failedWrite = settingsService.setApiSecret('rotated-secret');
    final failedWriteExpectation = expectLater(failedWrite, throwsStateError);
    final clashService = _SettingsSnapshotClashService();
    final generation = clashService.requestConnectionIntent(true);
    final orchestrator = ConnectionOrchestrator(
      clashService: clashService,
      settingsService: settingsService,
      subscriptionService: subscriptionService,
    );

    final firstConnect = orchestrator.connect(
      null,
      connectionGeneration: generation,
    );
    final firstConnectExpectation = expectLater(firstConnect, throwsStateError);
    releaseSecureWrite.complete();
    await failedWriteExpectation;
    await firstConnectExpectation;

    expect(
      await orchestrator.connect(
        null,
        connectionGeneration: generation,
      ),
      isNull,
    );
    expect(clashService.generatedSettings?.apiSecret, 'test-secret');
    expect(clashService.startCalls, 1);
  });
}

String _yaml(String name, String server) => '''
proxies:
  - name: $name
    type: ss
    server: $server
    port: 443
    cipher: aes-128-gcm
    password: test
''';

class _DelayedConfigClashService extends ClashService {
  final generationStarted = Completer<void>();
  final releaseGeneration = Completer<void>();
  int writeCalls = 0;
  int startCalls = 0;

  @override
  Future<String> generateClashConfigAsync(
    String rawYaml,
    AppSettings settings, {
    String? preferredNodeName,
  }) async {
    generationStarted.complete();
    await releaseGeneration.future;
    return 'generated-config';
  }

  @override
  Future<String> writeConfig(String configContent) async {
    writeCalls++;
    return '/tmp/should-not-be-written.yaml';
  }

  @override
  Future<bool> start({String? nodeName, String? preparedConfigPath}) async {
    startCalls++;
    return true;
  }
}

class _DelayedSwitchClashService extends ClashService {
  final switchStarted = Completer<void>();
  final releaseSwitch = Completer<void>();
  int stopCalls = 0;

  @override
  Future<String> generateClashConfigAsync(
    String rawYaml,
    AppSettings settings, {
    String? preferredNodeName,
  }) async =>
      'generated-config';

  @override
  Future<String> writeConfig(String configContent) async =>
      '/tmp/ssrvpn-delayed-switch-test.yaml';

  @override
  Future<bool> start({String? nodeName, String? preparedConfigPath}) async {
    setRunning(true);
    return true;
  }

  @override
  Future<AndroidProxySwitchResult> switchSelectedProxyForConnection(
    String nodeName, {
    required int connectionGeneration,
  }) async {
    switchStarted.complete();
    await releaseSwitch.future;
    return const AndroidProxySwitchResult(
      liveSwitched: true,
      snapshotPersisted: true,
      intentCurrent: true,
    );
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    setRunning(false);
  }
}

class _SettingsSnapshotClashService extends ClashService {
  AppSettings? generatedSettings;
  int startCalls = 0;

  @override
  Future<String> generateClashConfigAsync(
    String rawYaml,
    AppSettings settings, {
    String? preferredNodeName,
  }) async {
    generatedSettings = settings;
    return 'generated-config';
  }

  @override
  Future<String> writeConfig(String configContent) async =>
      '/tmp/ssrvpn-settings-snapshot-test.yaml';

  @override
  Future<bool> start({String? nodeName, String? preparedConfigPath}) async {
    startCalls++;
    setRunning(true);
    return true;
  }

  @override
  Future<String?> verifyUserConnectivity({
    int maxAttempts = 3,
    Duration retryDelay = const Duration(seconds: 2),
    Future<http.Response> Function(Uri uri)? request,
    bool Function()? shouldContinue,
  }) async =>
      null;
}

class _PortRaceClashService extends _SettingsSnapshotClashService {
  int prepareCalls = 0;
  int stopCalls = 0;
  bool cleanupPending = false;
  final List<int> generatedPorts = [];

  @override
  Future<AppSettings> prepareForStart(AppSettings preferred) async {
    final settings = preferred.copyWith(proxyPort: 32000 + prepareCalls);
    prepareCalls++;
    updateSettings(settings);
    return settings;
  }

  @override
  Future<String> generateClashConfigAsync(
    String rawYaml,
    AppSettings settings, {
    String? preferredNodeName,
  }) async {
    generatedPorts.add(settings.proxyPort);
    return 'generated-config-${settings.proxyPort}';
  }

  @override
  Future<bool> start({String? nodeName, String? preparedConfigPath}) async {
    startCalls++;
    if (startCalls == 1) {
      cleanupPending = true;
      setLastStartError('listen tcp: address already in use');
      return false;
    }
    if (cleanupPending) {
      setLastStartError('VPN 核心正在启动或停止，请稍后重试');
      return false;
    }
    setLastStartError(null);
    setRunning(true);
    return true;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    cleanupPending = false;
    setRunning(false);
  }
}
