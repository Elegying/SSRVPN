import 'package:flutter/foundation.dart';

import '../services/clash_service.dart';
import '../services/settings_service.dart';
import '../services/subscription_service.dart';
import '../services/windows_dpapi_secret_store.dart';

class StartupFailure {
  StartupFailure({
    required this.step,
    required Object error,
    DateTime? time,
  })  : requiresWindowsSecretRecovery =
            error is WindowsApiSecretRecoveryRequired,
        windowsSecretRecoveryPath =
            error is WindowsApiSecretRecoveryRequired ? error.path : null,
        message = _formatError(error),
        time = time ?? DateTime.now();

  final String step;
  final String message;
  final DateTime time;
  final bool requiresWindowsSecretRecovery;
  final String? windowsSecretRecoveryPath;

  String get userSummary {
    if (requiresWindowsSecretRecovery) {
      return '当前 Windows 账户无法解密本机密钥。可使用“保留旧密文并重建密钥”'
          '恢复启动；旧密文位于 $windowsSecretRecoveryPath，绝不会被自动删除。';
    }
    switch (step) {
      case 'window_manager':
        return '窗口组件初始化失败，请尝试安全模式启动。';
      case 'screen_retriever':
        return '显示器信息读取失败，应用会继续尝试打开。';
      case 'system_tray':
        return '系统托盘初始化失败，应用会继续尝试打开。';
      case 'mihomo_core':
        return '核心服务初始化失败，请稍后查看诊断日志。';
      default:
        return '启动组件初始化失败，应用会继续尝试打开。';
    }
  }

  static String _formatError(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '');
    return message.length <= 800 ? message : '${message.substring(0, 800)}...';
  }
}

class StartupStatus extends ChangeNotifier {
  StartupStatus._();

  static final StartupStatus instance = StartupStatus._();

  final List<StartupFailure> _failures = [];
  final Map<String, String> _stepStates = {};

  bool starting = false;
  bool completed = false;
  bool windowManagerReady = false;
  bool screenRetrieverReady = false;
  bool trayReady = false;
  bool coreInitialized = false;
  String? currentStep;

  SettingsService? settingsService;
  ClashService? clashService;
  SubscriptionService? subscriptionService;

  List<StartupFailure> get failures => List.unmodifiable(_failures);
  Map<String, String> get stepStates => Map.unmodifiable(_stepStates);
  bool get servicesReady =>
      settingsService != null &&
      clashService != null &&
      subscriptionService != null;

  void markStarting() {
    starting = true;
    completed = false;
    notifyListeners();
  }

  void prepareCoreRetry() {
    starting = true;
    completed = false;
    currentStep = null;
    coreInitialized = false;
    _stepStates.remove('mihomo_core');
    _failures.removeWhere((failure) => failure.step == 'mihomo_core');
    settingsService = null;
    clashService = null;
    subscriptionService = null;
    notifyListeners();
  }

  void markStepStarted(String name) {
    currentStep = name;
    _stepStates[name] = 'running';
    notifyListeners();
  }

  void markStepOk(String name) {
    if (currentStep == name) currentStep = null;
    _stepStates[name] = 'ok';
    switch (name) {
      case 'window_manager':
        windowManagerReady = true;
        break;
      case 'screen_retriever':
        screenRetrieverReady = true;
        break;
      case 'system_tray':
        trayReady = true;
        break;
      case 'mihomo_core':
        coreInitialized = true;
        break;
    }
    notifyListeners();
  }

  void reportFailure(String step, Object error) {
    if (currentStep == step) currentStep = null;
    _stepStates[step] = 'failed';
    _failures.add(StartupFailure(step: step, error: error));
    notifyListeners();
  }

  void setServices({
    required SettingsService settings,
    required ClashService clash,
    required SubscriptionService subscription,
  }) {
    settingsService = settings;
    clashService = clash;
    subscriptionService = subscription;
    notifyListeners();
  }

  void markCompleted() {
    starting = false;
    completed = true;
    currentStep = null;
    notifyListeners();
  }
}
