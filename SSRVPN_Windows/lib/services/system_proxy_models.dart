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

enum _ProxyRecoveryAction {
  restoreFull,
  restoreEndpoint,
  discard,
  unavailable,
}

class _ProxySnapshot {
  const _ProxySnapshot({
    required this.hasProxyEnable,
    required this.proxyEnable,
    required this.hasProxyServer,
    required this.proxyServer,
    required this.hasProxyOverride,
    required this.proxyOverride,
    required this.hasAutoConfigUrl,
    required this.autoConfigUrl,
    required this.hasAutoDetect,
    required this.autoDetect,
  });

  final bool hasProxyEnable;
  final int proxyEnable;
  final bool hasProxyServer;
  final String proxyServer;
  final bool hasProxyOverride;
  final String proxyOverride;
  final bool hasAutoConfigUrl;
  final String autoConfigUrl;
  final bool hasAutoDetect;
  final int autoDetect;

  factory _ProxySnapshot.fromJson(Map<String, dynamic> json) {
    return _ProxySnapshot(
      hasProxyEnable: json['hasProxyEnable'] as bool? ?? true,
      proxyEnable: (json['proxyEnable'] as num?)?.toInt() ?? 0,
      hasProxyServer: json['hasProxyServer'] as bool? ?? false,
      proxyServer: json['proxyServer'] as String? ?? '',
      hasProxyOverride: json['hasProxyOverride'] as bool? ?? false,
      proxyOverride: json['proxyOverride'] as String? ?? '',
      hasAutoConfigUrl: json['hasAutoConfigUrl'] as bool? ?? false,
      autoConfigUrl: json['autoConfigUrl'] as String? ?? '',
      hasAutoDetect: json['hasAutoDetect'] as bool? ?? false,
      autoDetect: (json['autoDetect'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'hasProxyEnable': hasProxyEnable,
        'proxyEnable': proxyEnable,
        'hasProxyServer': hasProxyServer,
        'proxyServer': proxyServer,
        'hasProxyOverride': hasProxyOverride,
        'proxyOverride': proxyOverride,
        'hasAutoConfigUrl': hasAutoConfigUrl,
        'autoConfigUrl': autoConfigUrl,
        'hasAutoDetect': hasAutoDetect,
        'autoDetect': autoDetect,
      };

  WindowsProxyState toWindowsProxyState() => WindowsProxyState(
        hasProxyEnable: hasProxyEnable,
        proxyEnable: proxyEnable,
        hasProxyServer: hasProxyServer,
        proxyServer: proxyServer,
        hasProxyOverride: hasProxyOverride,
        proxyOverride: proxyOverride,
        hasAutoConfigUrl: hasAutoConfigUrl,
        autoConfigUrl: autoConfigUrl,
        hasAutoDetect: hasAutoDetect,
        autoDetect: autoDetect,
      );
}

class _NativeProxyJournal {
  const _NativeProxyJournal(this.phase);

  final WindowsProxyTransactionPhase? phase;
}
