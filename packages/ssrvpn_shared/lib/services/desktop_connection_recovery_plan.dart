import '../models/app_settings.dart';
import 'desktop_connection_coordinator.dart';

/// Immutable source and operation set used to rebuild a desktop connection.
///
/// The plan deliberately contains no widget or UI state. A successful desktop
/// connect installs one plan with a subscription/settings snapshot, and the
/// platform lifecycle supplies the current connection generation when a
/// bounded automatic recovery is needed.
class DesktopConnectionRecoveryPlan {
  const DesktopConnectionRecoveryPlan({
    required this.preferredSettings,
    required this.prepareForStart,
    required this.generateConfig,
    required this.writeConfig,
    required this.start,
    required this.stop,
    required this.isRevisionCurrent,
    required this.isIntentCurrent,
    required this.shouldRollbackStaleIntent,
    required this.cancelIntent,
    required this.readStartFailureReason,
    this.switchPreferredNode,
    this.readRuntimeNotice,
  });

  final AppSettings preferredSettings;
  final Future<AppSettings> Function(AppSettings settings) prepareForStart;
  final Future<String> Function(AppSettings runtimeSettings) generateConfig;
  final Future<void> Function(String config) writeConfig;
  final Future<bool> Function() start;
  final Future<void> Function() stop;
  final bool Function() isRevisionCurrent;
  final bool Function(int generation) isIntentCurrent;
  final bool Function() shouldRollbackStaleIntent;
  final void Function() cancelIntent;
  final String? Function() readStartFailureReason;
  final Future<bool> Function()? switchPreferredNode;
  final String? Function()? readRuntimeNotice;

  Future<DesktopConnectionResult> recover(int connectionGeneration) =>
      const DesktopConnectionCoordinator().connect(
        preferredSettings: preferredSettings,
        prepareForStart: prepareForStart,
        generateConfig: generateConfig,
        writeConfig: writeConfig,
        start: start,
        stop: stop,
        isRevisionCurrent: isRevisionCurrent,
        isIntentCurrent: () => isIntentCurrent(connectionGeneration),
        shouldRollbackStaleIntent: shouldRollbackStaleIntent,
        cancelIntent: cancelIntent,
        readStartFailureReason: readStartFailureReason,
        switchPreferredNode: switchPreferredNode,
        readRuntimeNotice: readRuntimeNotice,
      );
}
