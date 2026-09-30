part of 'clash_service.dart';

enum _VerifiedCoreTermination {
  terminatedOrGone,
  liveIdentityMismatch,
  wrongInstallation,
}

Future<bool> terminateCoreProcess(
  Process process, {
  Duration gracefulTimeout = const Duration(seconds: 3),
  Duration forcedTimeout = const Duration(seconds: 3),
}) async {
  final exitCode = process.exitCode;
  process.kill(ProcessSignal.sigterm);
  try {
    await exitCode.timeout(gracefulTimeout);
    return true;
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    try {
      await exitCode.timeout(forcedTimeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }
}
