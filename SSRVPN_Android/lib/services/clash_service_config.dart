part of 'clash_service.dart';

extension AndroidClashConfig on ClashService {
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
