import 'dart:async';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import '../services/update_service.dart';
import 'startup_flags.dart';
import 'startup_logger.dart';
import 'startup_status.dart';

typedef StartupUpdateChecker = Future<AppUpdateInfo?> Function(
  String currentVersion,
);
typedef StartupUpdateHandler = Future<void> Function(AppUpdateInfo update);

/// Android 启动流程编排器
class StartupOrchestrator {
  final StartupFlags flags;
  final StartupStatus status = StartupStatus();
  final StartupUpdateChecker _updateChecker;
  final StartupUpdateHandler? onUpdateAvailable;

  StartupOrchestrator({
    required this.flags,
    StartupUpdateChecker? checkForUpdate,
    this.onUpdateAvailable,
  }) : _updateChecker = checkForUpdate ?? UpdateService.checkForUpdate;

  Future<void> start() async {
    status.start();
    StartupLogger.info('启动流程开始');

    try {
      if (!flags.skipUpdateCheck) {
        status.recordStep('更新检查', '检查新版本');
        await _checkForUpdate();
      }

      status.complete();
      StartupLogger.info('启动流程完成');
    } catch (e, stack) {
      status.fail(e.toString());
      StartupLogger.error('启动流程失败: $e', stack);
    }
  }

  Future<void> _checkForUpdate() async {
    try {
      final update = await _updateChecker(AppConstants.appVersion);
      if (update != null) await onUpdateAvailable?.call(update);
    } catch (e) {
      StartupLogger.warn('更新检查失败: $e');
    }
  }
}
