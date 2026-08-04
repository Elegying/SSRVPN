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

enum _ProxyRecoveryAction { restoreFull, restoreEndpoint, discard, unavailable }

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
    bool requiredBool(String key) {
      final value = json[key];
      if (value is! bool) {
        throw FormatException('Windows proxy field $key is invalid');
      }
      return value;
    }

    String requiredString(String key) {
      final value = json[key];
      if (value is! String) {
        throw FormatException('Windows proxy field $key is invalid');
      }
      return value;
    }

    int requiredDword(String key) {
      final value = json[key];
      if (value is! int || value < 0 || value > 1) {
        throw FormatException('Windows proxy field $key is invalid');
      }
      return value;
    }

    final rawHasProxyEnable = json['hasProxyEnable'];
    if (rawHasProxyEnable != null && rawHasProxyEnable is! bool) {
      throw const FormatException(
        'Windows proxy field hasProxyEnable is invalid',
      );
    }
    return _ProxySnapshot(
      // v4.0.1 and older recovery files did not persist this presence bit.
      // Keep that one compatibility default while validating every value that
      // determines what will be written back to the user's registry.
      hasProxyEnable: rawHasProxyEnable as bool? ?? true,
      proxyEnable: requiredDword('proxyEnable'),
      hasProxyServer: requiredBool('hasProxyServer'),
      proxyServer: requiredString('proxyServer'),
      hasProxyOverride: requiredBool('hasProxyOverride'),
      proxyOverride: requiredString('proxyOverride'),
      hasAutoConfigUrl: requiredBool('hasAutoConfigUrl'),
      autoConfigUrl: requiredString('autoConfigUrl'),
      hasAutoDetect: requiredBool('hasAutoDetect'),
      autoDetect: requiredDword('autoDetect'),
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
