part of 'system_proxy_service.dart';

// Ownership predicates do not mutate the transaction or recovery journal.
extension _WindowsSystemProxyOwnership on SystemProxyService {
  bool _isOwnedProxy(_ProxySnapshot current, String? ownedProxyServer) =>
      (current.connectionFlags == null || current.connectionFlags == 3) &&
      isOwnedWindowsProxy(
        proxyEnable: current.proxyEnable,
        hasProxyServer: current.hasProxyServer,
        proxyServer: current.proxyServer,
        ownedProxyServer: ownedProxyServer,
        hasProxyOverride: current.hasProxyOverride,
        proxyOverride: current.proxyOverride,
        ownedProxyOverride: SystemProxyService._ownedProxyOverride,
        hasAutoConfigUrl: current.hasAutoConfigUrl,
        autoConfigUrl: current.autoConfigUrl,
        hasAutoDetect: current.hasAutoDetect,
        autoDetect: current.autoDetect,
      );

  bool _isOwnedEndpoint(_ProxySnapshot current, String? ownedProxyServer) =>
      isOwnedWindowsProxyEndpoint(
        proxyEnable: current.proxyEnable,
        hasProxyServer: current.hasProxyServer,
        proxyServer: current.proxyServer,
        ownedProxyServer: ownedProxyServer,
      );

  WindowsProxyState? _ownedProxyState(String? ownedProxyServer) {
    if (ownedProxyServer == null || ownedProxyServer.isEmpty) return null;
    return WindowsProxyState(
      hasProxyEnable: true,
      proxyEnable: 1,
      hasProxyServer: true,
      proxyServer: ownedProxyServer,
      hasProxyOverride: true,
      proxyOverride: SystemProxyService._ownedProxyOverride,
      hasAutoConfigUrl: false,
      autoConfigUrl: '',
      hasAutoDetect: true,
      autoDetect: 0,
    );
  }
}
