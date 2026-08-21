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

    expect((await connecting).message, contains('订阅已更新'));
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

    expect((await connecting).message, contains('订阅已更新'));
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
    await _assignCurrentlyFreeRuntimePorts(settingsService);
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
    expect((await connecting).message, isNull);
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
    expect(result.message, contains('端口被占用'));
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

    expect(result.message, isNull);
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
    expect((await connecting).message, isNull);
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
    await _assignCurrentlyFreeRuntimePorts(settingsService);
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
      (await orchestrator.connect(
        null,
        connectionGeneration: generation,
      ))
          .message,
      isNull,
    );
    expect(clashService.generatedSettings?.apiSecret, 'test-secret');
    expect(clashService.startCalls, 1);
  });

  test('native success is returned before advisory external verification',
      () async {
    SharedPreferences.setMockInitialValues({});
    final tempDir = await Directory.systemTemp.createTemp(
      'ssrvpn_non_blocking_connectivity_',
    );
    final clashService = _BlockingConnectivityClashService();
    addTearDown(() async {
      SubscriptionService.resetInstanceForTesting();
      if (!clashService.releaseVerification.isCompleted) {
        clashService.releaseVerification.complete();
      }
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
    await _assignCurrentlyFreeRuntimePorts(settingsService);
    final generation = clashService.requestConnectionIntent(true);
    final orchestrator = ConnectionOrchestrator(
      clashService: clashService,
      settingsService: settingsService,
      subscriptionService: subscriptionService,
    );

    final result = await orchestrator
        .connect(null, connectionGeneration: generation)
        .timeout(
          const Duration(seconds: 1),
          onTimeout: () => const AndroidConnectionOutcome(message: 'blocked'),
        );

    expect(result.message, isNull);
    expect(clashService.isRunning, isTrue);
    expect(clashService.verificationStarted.isCompleted, isTrue);
    expect(clashService.observationIsCurrent?.call(), isTrue);
    clashService.requestConnectionIntent(false);
    clashService.requestConnectionIntent(true);
    expect(clashService.observationIsCurrent?.call(), isFalse);
  });

  test('connected feedback is a notice while failed startup is an error', () {
    expect(
      resolveAndroidConnectionFeedback(
        connected: true,
        result: '连接已建立，但外部网络暂时无法确认',
        runtimeNotice: null,
      ),
      (
        errorMessage: null,
        connectionNotice: '连接已建立，但外部网络暂时无法确认',
      ),
    );
    expect(
      resolveAndroidConnectionFeedback(
        connected: false,
        result: 'VPN 数据通道不可用，请切换节点或重试',
        runtimeNotice: null,
      ),
      (
        errorMessage: 'VPN 数据通道不可用，请切换节点或重试',
        connectionNotice: null,
      ),
    );
  });

  test('unknown native details never reach the connection error surface', () {
    final message = userFriendlyAndroidConnectionError(
      'Mihomo: parse password secret-value at /data/user/0/private.yaml',
    );

    expect(message, 'VPN 启动失败，请重试；若持续失败请打开诊断与运行日志');
    expect(message, isNot(contains('secret-value')));
    expect(message, isNot(contains('/data/user')));
    expect(
      userFriendlyAndroidConnectionError(
        'VPN 数据通道不可用，请切换节点或重试',
      ),
      'VPN 数据通道不可用，请切换节点或重试',
    );
    expect(
      userFriendlyAndroidConnectionError(
        '上次 VPN 联网检查仍在结束，请稍后重试；若持续出现请重启应用',
      ),
      '上次 VPN 联网检查仍在结束，请稍后重试；若持续出现请重启应用',
    );
    expect(
      userFriendlyAndroidConnectionError(
        'VPN 联网检查超时，请稍后重试；若持续出现请重启应用',
      ),
      'VPN 联网检查超时，请稍后重试；若持续出现请重启应用',
    );
  });

  test('stable native startup stages have actionable friendly messages', () {
    expect(
      userFriendlyAndroidConnectionError('Missing required arguments'),
      '连接参数不完整，请重试',
    );
    expect(
      userFriendlyAndroidConnectionError('VPN establish failed'),
      '系统未能创建 VPN 接口，请检查 VPN 权限后重试',
    );
    expect(
      userFriendlyAndroidConnectionError('Bridge.start timed out'),
      'VPN 核心启动超时，请重新连接',
    );
    expect(
      userFriendlyAndroidConnectionError('Health check timeout'),
      'VPN 核心已启动，但本地控制服务未及时就绪，请重新连接',
    );
    expect(
      userFriendlyAndroidConnectionError(
        'PlatformException(STOP_INCOMPLETE, VPN resources are still releasing)',
      ),
      'VPN 正在释放系统资源，请稍后重试',
    );
    expect(
      userFriendlyAndroidConnectionError(
        'PlatformException(STOP_FAILED, native secret detail)',
      ),
      'VPN 断开失败，请重试；若持续失败请打开诊断与运行日志',
    );
    expect(
      userFriendlyAndroidConnectionError(
        '无法保存连接恢复信息，VPN 已安全回滚',
      ),
      '无法保存连接恢复信息，VPN 已安全回滚，请重试',
    );
  });

  test('failed preferred-node switch preserves the live runtime node',
      () async {
    SharedPreferences.setMockInitialValues({});
    final tempDir = await Directory.systemTemp.createTemp(
      'ssrvpn_failed_preferred_switch_',
    );
    addTearDown(() async {
      SubscriptionService.resetInstanceForTesting();
      await tempDir.delete(recursive: true);
    });
    SubscriptionService.resetInstanceForTesting();
    final subscriptionService =
        await SubscriptionService.getInstance(tempDir.path);
    await subscriptionService.setRawYaml(
      _yaml('Requested Node', 'node.example.com'),
    );
    final settingsService = await SettingsService.createForTesting(
      configPath: '${tempDir.path}/settings.json',
      readApiSecret: () async => 'test-secret',
      writeApiSecret: (_) async {},
    );
    await _assignCurrentlyFreeRuntimePorts(settingsService);
    final clashService = _FailedPreferredNodeSwitchClashService();
    final generation = clashService.requestConnectionIntent(true);
    final orchestrator = ConnectionOrchestrator(
      clashService: clashService,
      settingsService: settingsService,
      subscriptionService: subscriptionService,
    );

    final outcome = await orchestrator.connect(
      'Requested Node',
      connectionGeneration: generation,
    );

    expect(clashService.isRunning, isTrue);
    expect(outcome.preferredNodeSwitchSucceeded, isFalse);
    expect(outcome.runtimeNodeName, 'Actual Node');
    expect(outcome.message, '未能切换节点，当前连接仍保留');
  });

  test('late preferred-node readback promotes the confirmed runtime node',
      () async {
    SharedPreferences.setMockInitialValues({});
    final tempDir = await Directory.systemTemp.createTemp(
      'ssrvpn_late_preferred_switch_',
    );
    addTearDown(() async {
      SubscriptionService.resetInstanceForTesting();
      await tempDir.delete(recursive: true);
    });
    SubscriptionService.resetInstanceForTesting();
    final subscriptionService =
        await SubscriptionService.getInstance(tempDir.path);
    await subscriptionService.setRawYaml(
      _yaml('Requested Node', 'node.example.com'),
    );
    final settingsService = await SettingsService.createForTesting(
      configPath: '${tempDir.path}/settings.json',
      readApiSecret: () async => 'test-secret',
      writeApiSecret: (_) async {},
    );
    await _assignCurrentlyFreeRuntimePorts(settingsService);
    final clashService = _LatePreferredNodeSwitchClashService();
    final generation = clashService.requestConnectionIntent(true);
    final orchestrator = ConnectionOrchestrator(
      clashService: clashService,
      settingsService: settingsService,
      subscriptionService: subscriptionService,
    );

    final outcome = await orchestrator.connect(
      'Requested Node',
      connectionGeneration: generation,
    );

    expect(clashService.isRunning, isTrue);
    expect(outcome.preferredNodeSwitchSucceeded, isTrue);
    expect(outcome.runtimeNodeName, 'Requested Node');
    expect(outcome.message, 'VPN 已连接，但快速启动节点信息保存失败');
  });
}

Future<void> _assignCurrentlyFreeRuntimePorts(
  SettingsService settingsService,
) async {
  final reservations = <ServerSocket>[];
  try {
    for (var index = 0; index < 3; index++) {
      reservations.add(
        await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
          shared: false,
        ),
      );
    }
    settingsService.settings
      ..proxyPort = reservations[0].port
      ..socksPort = reservations[1].port
      ..apiPort = reservations[2].port;
  } finally {
    for (final reservation in reservations) {
      await reservation.close();
    }
  }
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

class _BlockingConnectivityClashService extends _SettingsSnapshotClashService {
  final verificationStarted = Completer<void>();
  final releaseVerification = Completer<void>();
  bool Function()? observationIsCurrent;

  @override
  Future<String?> verifyUserConnectivity({
    int maxAttempts = 3,
    Duration retryDelay = const Duration(seconds: 2),
    Future<http.Response> Function(Uri uri)? request,
    bool Function()? shouldContinue,
  }) async {
    observationIsCurrent = shouldContinue;
    verificationStarted.complete();
    await releaseVerification.future;
    return null;
  }
}

class _FailedPreferredNodeSwitchClashService
    extends _SettingsSnapshotClashService {
  @override
  Future<AndroidProxySwitchResult> switchSelectedProxyForConnection(
    String nodeName, {
    required int connectionGeneration,
  }) async =>
      const AndroidProxySwitchResult(
        liveSwitched: false,
        snapshotPersisted: false,
        intentCurrent: true,
      );

  @override
  Future<String?> currentSelectedProxyName() async => 'Actual Node';
}

class _LatePreferredNodeSwitchClashService
    extends _FailedPreferredNodeSwitchClashService {
  @override
  Future<String?> currentSelectedProxyName() async => 'Requested Node';
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
