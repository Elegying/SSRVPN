bool isOwnedMacProxy({
  required bool enabled,
  required String server,
  required int port,
  required String? ownedHost,
  required int? ownedPort,
}) =>
    ownedHost != null &&
    ownedHost.isNotEmpty &&
    ownedPort != null &&
    ownedPort > 0 &&
    enabled &&
    server == ownedHost &&
    port == ownedPort;

const macNetworkServiceListHeader =
    'An asterisk (*) denotes that a network service is disabled.';

List<String> restorableMacNetworkServices({
  required Iterable<String> savedServices,
  required Iterable<String> currentServices,
}) {
  final current = currentServices.toSet();
  return savedServices.where(current.contains).toList(growable: false);
}

List<String> pendingMacNetworkServices({
  required Iterable<String> savedServices,
  required Iterable<String> currentServices,
}) {
  final current = currentServices.toSet();
  return savedServices
      .where((service) => !current.contains(service))
      .toList(growable: false);
}

List<String> parseMacNetworkServiceList(String output) {
  final services = <String>[];
  for (final line in output.split('\n')) {
    var service = line.trim();
    if (service.isEmpty || service.startsWith('An asterisk')) continue;
    if (service.startsWith('*')) service = service.substring(1).trimLeft();
    if (service.isNotEmpty) services.add(service);
  }
  return services;
}

List<String>? parseVerifiedMacNetworkServiceList(String output) {
  final services = <String>[];
  var sawHeader = false;
  for (final rawLine in output.split('\n')) {
    var service = rawLine.trim();
    if (service.isEmpty) continue;
    if (!sawHeader) {
      if (service != macNetworkServiceListHeader) return null;
      sawHeader = true;
      continue;
    }
    if (service.startsWith('*')) service = service.substring(1).trimLeft();
    if (service.isEmpty) return null;
    services.add(service);
  }
  return sawHeader ? services : null;
}

Map<String, dynamic>? parseVerifiedMacProxyState(String output) {
  final values = <String, String>{};
  for (final rawLine in output.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final separator = line.indexOf(':');
    if (separator <= 0) continue;
    final key = line.substring(0, separator).trim();
    if (!const {'Enabled', 'Server', 'Port'}.contains(key)) continue;
    if (values.containsKey(key)) return null;
    values[key] = line.substring(separator + 1).trim();
  }

  if (!values.keys.toSet().containsAll(const {'Enabled', 'Server', 'Port'})) {
    return null;
  }
  final enabledText = values['Enabled']!.toLowerCase();
  if (enabledText != 'yes' && enabledText != 'no') return null;
  final enabled = enabledText == 'yes';
  final server = values['Server']!;
  final port = int.tryParse(values['Port']!);
  if (port == null || port < 0 || port > 65535) return null;
  if (enabled && (server.isEmpty || port == 0)) return null;

  return {'enabled': enabled, 'server': server, 'port': port};
}
