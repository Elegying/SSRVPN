part of 'clash_service.dart';

extension _WindowsCoreIdentity on _WindowsCoreLifecycle {
  Future<WindowsCorePidRecord> _captureCorePidRecord(int corePid) async =>
      queryWindowsCoreIdentity(corePid, _corePath);
}
