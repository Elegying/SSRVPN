import 'package:flutter/foundation.dart';

import '../services/clash_service.dart';
import '../services/settings_service.dart';
import '../services/subscription_service.dart';

class StartupFailure {
  StartupFailure({
    required this.step,
    required Object error,
    DateTime? time,
  })  : message = _formatError(error),
        time = time ?? DateTime.now();

  final String step;
  final String message;
  final DateTime time;

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
