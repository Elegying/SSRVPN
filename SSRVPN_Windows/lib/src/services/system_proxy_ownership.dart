bool isOwnedWindowsProxyEndpoint({
  required int proxyEnable,
  required bool hasProxyServer,
  required String proxyServer,
  required String? ownedProxyServer,
}) =>
    ownedProxyServer != null &&
    ownedProxyServer.isNotEmpty &&
    proxyEnable == 1 &&
    hasProxyServer &&
    proxyServer == ownedProxyServer;

bool isOwnedWindowsProxy({
  required int proxyEnable,
  required bool hasProxyServer,
  required String proxyServer,
  required String? ownedProxyServer,
  required bool hasProxyOverride,
  required String proxyOverride,
  required String ownedProxyOverride,
  required bool hasAutoConfigUrl,
  required String autoConfigUrl,
  required bool hasAutoDetect,
  required int autoDetect,
}) =>
    ownedProxyServer != null &&
    ownedProxyServer.isNotEmpty &&
    proxyEnable == 1 &&
    hasProxyServer &&
    proxyServer == ownedProxyServer &&
    hasProxyOverride &&
    proxyOverride == ownedProxyOverride &&
    !hasAutoConfigUrl &&
    autoConfigUrl.isEmpty &&
    hasAutoDetect &&
    autoDetect == 0;
