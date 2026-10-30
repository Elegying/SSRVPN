part of 'system_proxy_service.dart';

extension _WindowsNativeProxySnapshot on SystemProxyService {
  Future<bool> _readNativeGuardian({Future<void>? cancellation}) async {
    try {
      final operation = _nativeGuardian?.call() ??
          const MethodChannel('com.ssrvpn.windows/platform_info')
              .invokeMethod<Object?>('isProxyGuardianReady');
      final result = await (cancellation == null
              ? operation
              : Future.any<Object?>([
                  operation,
                  cancellation.then<Object?>((_) => false),
                ]))
          .timeout(const Duration(seconds: 20));
      return result is bool && result;
    } catch (_) {
      return false;
    }
  }

  Future<({bool? policySupported, _ProxySnapshot? snapshot})>
      _readNativeProxyState({
    required bool checkGuardian,
    Future<void>? cancellation,
  }) async {
    try {
      final raw = await _timeProxyOperation(
        checkGuardian
            ? _ProxyCommandPhase.preflight
            : _ProxyCommandPhase.verify,
        () async {
          final operation = _nativeSnapshot?.call(checkGuardian) ??
              const MethodChannel('com.ssrvpn.windows/platform_info')
                  .invokeMethod<Object?>('readSystemProxy', checkGuardian);
          // Read-only native work can safely finish after cancellation; its
          // result is discarded and never triggers journal or endpoint writes.
          return await (cancellation == null
                  ? operation
                  : Future.any<Object?>([
                      operation,
                      cancellation.then<Object?>((_) =>
                          throw const _SystemProxyAcquisitionCancelled()),
                    ]))
              .timeout(const Duration(seconds: 20));
        },
      );
      if (raw is! Map || raw['status'] is! int) {
        throw const FormatException('Invalid native proxy read status');
      }
      switch (raw['status']) {
        case 1:
          _lastError = 'Windows 代理策略不允许按用户设置代理，请检查 ProxySettingsPerUser';
          return (policySupported: false, snapshot: null);
        case 2:
          _lastError = '独立系统代理保护未就绪，请通过 ssrvpn_windows.exe 启动或重试';
          return (policySupported: null, snapshot: null);
        case 0:
          final snapshot = raw['snapshot'];
          // Native responses have no legacy-field defaults. Missing flags or
          // presence bits must not produce an incomplete recovery snapshot.
          if (snapshot is! Map ||
              snapshot['hasProxyEnable'] is! bool ||
              snapshot['connectionFlags'] is! int) {
            throw const FormatException('Incomplete native proxy snapshot');
          }
          return (
            policySupported: true,
            snapshot: _ProxySnapshot.fromJson(snapshot.cast<String, dynamic>())
          );
        default:
          _lastError = '无法读取 Windows 原生系统代理状态，未修改代理';
          return (policySupported: null, snapshot: null);
      }
    } on _SystemProxyAcquisitionCancelled {
      rethrow;
    } catch (_) {
      // Missing bridge, timeout and malformed results all fail closed. Do not
      // treat platform failure as permission to write, or log snapshot values.
      _lastError = 'Windows 原生系统代理检查失败，未修改代理';
      return (policySupported: null, snapshot: null);
    }
  }
}
