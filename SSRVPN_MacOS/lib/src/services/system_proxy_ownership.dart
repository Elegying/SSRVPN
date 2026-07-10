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
