import 'startup_flags.dart';
import 'startup_logger.dart';
import 'startup_status.dart';

/// Android 启动流程编排器
class StartupOrchestrator {
  final StartupFlags flags;
  final StartupStatus status = StartupStatus();

  StartupOrchestrator({
    required this.flags,
  });

  Future<void> start() async {
    status.start();
    StartupLogger.info('启动流程开始');

    try {
      // 更新检查由首页在节点连接成功后触发。启动阶段不得发起更新网络请求。
      status.complete();
      StartupLogger.info('启动流程完成');
    } catch (e, stack) {
      status.fail(e.toString());
      StartupLogger.error('启动流程失败: $e', stack);
    }
  }
}
