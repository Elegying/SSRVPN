part of 'clash_service.dart';

mixin _WindowsClashConfig on ClashServiceBase {
  // ── Config generation ──

  /// 生成 Clash 配置（Windows 专用：含 SSRVPN-GEO 组和 Windows 专用规则）
  bool _geoipDatabaseExists() {
    try {
      final mmdb = File('$configDir${Platform.pathSeparator}country.mmdb');
      if (mmdb.existsSync() && mmdb.lengthSync() > 1024 * 1024) return true;
      final metadb = File('$configDir${Platform.pathSeparator}geoip.metadb');
      if (metadb.existsSync() && metadb.lengthSync() > 1024 * 1024) {
        return true;
      }
    } catch (_) {}
    return false;
  }

  String _windowsTunConfig(AppSettings settings) {
    final buffer = StringBuffer()
      ..writeln('tun:')
      ..writeln('  enable: ${settings.enableTun}')
      ..writeln('  stack: ${settings.tunStack}')
      ..writeln('  dns-hijack:')
      ..writeln('    - any:53')
      ..writeln('  auto-route: true')
      ..writeln('  auto-detect-interface: true')
      ..writeln('  route-exclude-address:');
    for (final address in AppConstants.routeExcludeAddresses) {
      buffer.writeln('    - $address');
    }
    return buffer.toString().trimRight();
  }

  String generateClashConfig(
    String rawYaml,
    AppSettings appSettings, {
    String? preferredNodeName,
  }) {
    return buildClashConfig(
      rawYaml,
      appSettings,
      preferredNodeName: preferredNodeName,
      platformHeader: '# ===== SSRVPN Windows =====',
      tunConfig: _windowsTunConfig(appSettings),
      latencyTestUrl: appSettings.latencyTestUrl,
      extraSelectGroupNames: const [_geoProxyGroupName],
      extraRulesBeforeDirect: _geoLookupHosts.map(
        (host) => 'DOMAIN,$host,$_geoProxyGroupName',
      ),
      includeGeoIpRules: _geoipDatabaseExists(),
    );
  }
}
