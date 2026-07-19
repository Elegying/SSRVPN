import '../models/app_settings.dart';

const desktopSubscriptionChangedMessage = '订阅已更新，请重新连接以使用最新配置';

enum DesktopConnectionFailure {
  subscriptionChanged,
  cancelled,
  startFailed,
}

class DesktopConnectionResult {
  const DesktopConnectionResult._({
    this.failure,
    this.failureReason,
    this.runtimeNotice,
    this.preferredNodeSwitchSucceeded,
  });

  const DesktopConnectionResult.connected({
    String? runtimeNotice,
    bool? preferredNodeSwitchSucceeded,
  }) : this._(
          runtimeNotice: runtimeNotice,
          preferredNodeSwitchSucceeded: preferredNodeSwitchSucceeded,
        );

  const DesktopConnectionResult.failed(
    DesktopConnectionFailure failure, {
    String? reason,
  }) : this._(failure: failure, failureReason: reason);

  final DesktopConnectionFailure? failure;
  final String? failureReason;
  final String? runtimeNotice;
  final bool? preferredNodeSwitchSucceeded;

  bool get connected => failure == null;
}

/// Runs the shared, transactional part of a desktop connection attempt.
///
/// Platform recovery, pre-flight validation and user feedback intentionally
/// stay outside this class. The injected operations cover only the sequence
/// whose ordering must be identical on macOS, Windows and the shared Home UI:
/// prepare, generate, write, start, optional preferred-node switch, and
/// rollback when the captured subscription or connection intent becomes stale.
class DesktopConnectionCoordinator {
  const DesktopConnectionCoordinator();

  Future<DesktopConnectionResult> connect({
    required AppSettings preferredSettings,
    required Future<AppSettings> Function(AppSettings settings) prepareForStart,
    required Future<String> Function(AppSettings runtimeSettings)
        generateConfig,
    required Future<void> Function(String config) writeConfig,
    required Future<bool> Function() start,
    required Future<void> Function() stop,
    required bool Function() isRevisionCurrent,
    required bool Function() isIntentCurrent,
    required bool Function() shouldRollbackStaleIntent,
    required void Function() cancelIntent,
    required String? Function() readStartFailureReason,
    Future<bool> Function()? switchPreferredNode,
    String? Function()? readRuntimeNotice,
  }) async {
    var startedByTransaction = false;
    var rollbackAttempted = false;

    Future<void> rollback() async {
      if (rollbackAttempted) return;
      rollbackAttempted = true;
      final ownedCurrentIntent = isIntentCurrent();
      if (ownedCurrentIntent) cancelIntent();
      if (startedByTransaction &&
          (ownedCurrentIntent || shouldRollbackStaleIntent())) {
        await stop();
      }
    }

    Future<DesktopConnectionResult?> rejectStaleState() async {
      if (!isRevisionCurrent()) {
        await rollback();
        return const DesktopConnectionResult.failed(
          DesktopConnectionFailure.subscriptionChanged,
          reason: desktopSubscriptionChangedMessage,
        );
      }
      if (!isIntentCurrent()) {
        await rollback();
        return const DesktopConnectionResult.failed(
          DesktopConnectionFailure.cancelled,
        );
      }
      return null;
    }

    try {
      var rejected = await rejectStaleState();
      if (rejected != null) return rejected;

      final runtimeSettings = await prepareForStart(preferredSettings);
      rejected = await rejectStaleState();
      if (rejected != null) return rejected;
      final runtimeNotice = readRuntimeNotice?.call();

      final config = await generateConfig(runtimeSettings);
      rejected = await rejectStaleState();
      if (rejected != null) return rejected;

      await writeConfig(config);
      rejected = await rejectStaleState();
      if (rejected != null) return rejected;

      final started = await start();
      startedByTransaction = started;
      rejected = await rejectStaleState();
      if (rejected != null) return rejected;
      if (!started) {
        await rollback();
        return DesktopConnectionResult.failed(
          DesktopConnectionFailure.startFailed,
          reason: readStartFailureReason() ?? '无法启动核心',
        );
      }

      final switchNode = switchPreferredNode;
      final switchSucceeded = switchNode == null ? null : await switchNode();
      rejected = await rejectStaleState();
      if (rejected != null) return rejected;

      return DesktopConnectionResult.connected(
        runtimeNotice: runtimeNotice,
        preferredNodeSwitchSucceeded: switchSucceeded,
      );
    } catch (error, stack) {
      if (!rollbackAttempted) await rollback();
      Error.throwWithStackTrace(error, stack);
    }
  }
}
