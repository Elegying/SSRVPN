bool isOwnedWindowsProxy({
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
