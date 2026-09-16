part of 'clash_service.dart';

extension AndroidClashConfig on ClashService {
  Future<String> _writePreferredNodeConfig(
    String rawYaml,
    AppSettings settings,
    String nodeName, {
    bool Function()? shouldContinue,
    int? expectedSessionGeneration,
  }) async {
    if (shouldContinue?.call() == false) throw StateError('节点切换已取消');
    // A live core may use temporary ports after a collision. Updating its
    // quick-start snapshot must keep the same controller identity and ports.
    if (isRunning) {
      updateLiveSettings(settings);
    } else {
      updateSettings(settings);
    }
    final config = await generateClashConfigAsync(
      rawYaml,
      this.settings,
      preferredNodeName: nodeName,
    );
    final path = await writeConfig(config);
    if (shouldContinue?.call() == false) {
      await discardPreparedConfig(path);
      throw StateError('节点切换已取消');
    }
    if (!await _saveConfigForTile(
      nodeName,
      path,
      shouldContinue: shouldContinue,
      expectedSessionGeneration: expectedSessionGeneration,
    )) {
      await discardPreparedConfig(path);
      throw StateError('无法提交原生快速启动配置');
    }
    return path;
  }

  String get _androidPlatformHeader => '# ===== SSRVPN Android =====\n'
      '# ssrvpn-direct-apps: ${androidDirectAppPackages.join(',')}\n'
      'find-process-mode: strict';

  String _androidTunConfig(AppSettings settings) {
    final buffer = StringBuffer()
      ..writeln('tun:')
      ..writeln('  enable: true')
      ..writeln('  stack: ${settings.tunStack}')
      ..writeln('  dns-hijack:')
      ..writeln('    - any:53')
      ..writeln('  auto-route: true')
      ..writeln('  auto-detect-interface: true')
      ..writeln('  inet6-address:')
      ..writeln('    - ${AppConstants.tunInet6Address}')
      ..writeln('  route-exclude-address:');
    for (final address in AppConstants.routeExcludeAddresses) {
      // Android 原生 VPN 接管 ::/0；不排除 IPv6，避免绕过或黑洞。
      if (address.contains(':')) continue;
      buffer.writeln('    - $address');
    }
    return buffer.toString().trimRight();
  }
}
