part of 'clash_service.dart';

mixin _MacosClashConfig on ClashServiceBase {
  String _macosTunConfig(AppSettings settings) {
    final buffer = StringBuffer()
      ..writeln('tun:')
      ..writeln('  enable: true')
      ..writeln('  stack: ${settings.tunStack}')
      ..writeln('  auto-route: true')
      ..writeln('  auto-detect-interface: true')
      ..writeln('  inet6-address:')
      ..writeln('    - ${AppConstants.tunInet6Address}')
      ..writeln('  route-exclude-address:');
    for (final address in AppConstants.routeExcludeAddresses) {
      buffer.writeln('    - $address');
    }
    buffer
      ..writeln('  dns-hijack:')
      ..writeln('    - any:53')
      ..writeln('  route-address-set:')
      ..writeln('    - ${AppConstants.geoipCnRuleProviderName}')
      ..writeln('    - ${AppConstants.geositeCnRuleProviderName}');
    return buffer.toString().trimRight();
  }

  String generateClashConfig(
    String rawYaml,
    AppSettings settings, {
    String? preferredNodeName,
  }) {
    return buildClashConfig(
      rawYaml,
      settings,
      preferredNodeName: preferredNodeName,
      platformHeader: '# ===== SSRVPN 配置（规则内置，订阅仅加载节点） =====',
      tunConfig: settings.enableTun ? _macosTunConfig(settings) : null,
      latencyTestUrl: settings.latencyTestUrl,
      includeFallbackGroup: true,
      includeGeoIpRules: true,
    );
  }

  Future<void> writeConfig(String configContent) async {
    await writeStringAtomically(
      File(configPath),
      configContent,
      beforeWrite: (temp) async {
        final result = await Process.run('/bin/chmod', ['600', temp.path]);
        if (result.exitCode != 0) {
          throw FileSystemException(
            'Unable to protect runtime configuration',
            temp.path,
          );
        }
      },
    );
  }
}
