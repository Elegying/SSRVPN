part of 'system_proxy_service.dart';

class _SystemProxyAcquisitionCancelled implements Exception {
  const _SystemProxyAcquisitionCancelled();
}

class _SystemProxyAcquisitionCancellation {
  _SystemProxyAcquisitionCancellation(this.future) {
    future?.then<void>(
      (_) => _cancelled = true,
      onError: (_, __) => _cancelled = true,
    );
  }

  final Future<void>? future;
  bool _cancelled = false;

  void throwIfRequested() {
    if (_cancelled) throw const _SystemProxyAcquisitionCancelled();
  }
}
