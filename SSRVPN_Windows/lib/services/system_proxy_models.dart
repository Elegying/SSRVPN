part of 'system_proxy_service.dart';

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
    this.connectionFlags,
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
  final int? connectionFlags;

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
    final flags = json['connectionFlags'];
    if (flags != null && (flags is! int || flags < 0 || flags > 15)) {
      throw const FormatException('Invalid WinINet connection flags');
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
      connectionFlags: flags as int?,
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
        if (connectionFlags != null) 'connectionFlags': connectionFlags,
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
