enum WindowsProxyTransactionPhase { activation, fullRestore, endpointRestore }

class WindowsProxyState {
  const WindowsProxyState({
    required this.proxyEnable,
    required this.hasProxyServer,
    required this.proxyServer,
    required this.hasProxyOverride,
    required this.proxyOverride,
    required this.hasAutoConfigUrl,
    required this.autoConfigUrl,
    required this.hasAutoDetect,
    required this.autoDetect,
  });

  final int proxyEnable;
  final bool hasProxyServer;
  final String proxyServer;
  final bool hasProxyOverride;
  final String proxyOverride;
  final bool hasAutoConfigUrl;
  final String autoConfigUrl;
  final bool hasAutoDetect;
  final int autoDetect;

  WindowsProxyState copyWith({
    int? proxyEnable,
    bool? hasProxyServer,
    String? proxyServer,
    bool? hasProxyOverride,
    String? proxyOverride,
    bool? hasAutoConfigUrl,
    String? autoConfigUrl,
    bool? hasAutoDetect,
    int? autoDetect,
  }) =>
      WindowsProxyState(
        proxyEnable: proxyEnable ?? this.proxyEnable,
        hasProxyServer: hasProxyServer ?? this.hasProxyServer,
        proxyServer: proxyServer ?? this.proxyServer,
        hasProxyOverride: hasProxyOverride ?? this.hasProxyOverride,
        proxyOverride: proxyOverride ?? this.proxyOverride,
        hasAutoConfigUrl: hasAutoConfigUrl ?? this.hasAutoConfigUrl,
        autoConfigUrl: autoConfigUrl ?? this.autoConfigUrl,
        hasAutoDetect: hasAutoDetect ?? this.hasAutoDetect,
        autoDetect: autoDetect ?? this.autoDetect,
      );

  @override
  bool operator ==(Object other) =>
      other is WindowsProxyState &&
      proxyEnable == other.proxyEnable &&
      hasProxyServer == other.hasProxyServer &&
      proxyServer == other.proxyServer &&
      hasProxyOverride == other.hasProxyOverride &&
      proxyOverride == other.proxyOverride &&
      hasAutoConfigUrl == other.hasAutoConfigUrl &&
      autoConfigUrl == other.autoConfigUrl &&
      hasAutoDetect == other.hasAutoDetect &&
      autoDetect == other.autoDetect;

  @override
  int get hashCode => Object.hash(
        proxyEnable,
        hasProxyServer,
        proxyServer,
        hasProxyOverride,
        proxyOverride,
        hasAutoConfigUrl,
        autoConfigUrl,
        hasAutoDetect,
        autoDetect,
      );
}

List<WindowsProxyState> windowsProxyActivationPrefixes({
  required WindowsProxyState original,
  required WindowsProxyState owned,
}) {
  final states = <WindowsProxyState>[original];
  var state = original.copyWith(
    hasProxyServer: owned.hasProxyServer,
    proxyServer: owned.proxyServer,
  );
  states.add(state);
  state = state.copyWith(
    hasProxyOverride: owned.hasProxyOverride,
    proxyOverride: owned.proxyOverride,
  );
  states.add(state);
  state = state.copyWith(
    hasAutoDetect: owned.hasAutoDetect,
    autoDetect: owned.autoDetect,
  );
  states.add(state);
  state = state.copyWith(
    hasAutoConfigUrl: owned.hasAutoConfigUrl,
    autoConfigUrl: owned.autoConfigUrl,
  );
  states.add(state);
  states.add(state.copyWith(proxyEnable: owned.proxyEnable));
  return states;
}

bool isReachableWindowsProxyTransactionState({
  required WindowsProxyState current,
  required WindowsProxyState original,
  required WindowsProxyState owned,
  required WindowsProxyTransactionPhase phase,
}) {
  final activationStates = windowsProxyActivationPrefixes(
    original: original,
    owned: owned,
  );
  if (phase == WindowsProxyTransactionPhase.activation) {
    return activationStates.contains(current);
  }
  if (phase == WindowsProxyTransactionPhase.endpointRestore) {
    final ownedServer = current.hasProxyServer == owned.hasProxyServer &&
        current.proxyServer == owned.proxyServer;
    final originalServer = current.hasProxyServer == original.hasProxyServer &&
        current.proxyServer == original.proxyServer;
    if (original.proxyEnable == 0) {
      return (ownedServer &&
              (current.proxyEnable == owned.proxyEnable ||
                  current.proxyEnable == 0)) ||
          (originalServer && current.proxyEnable == 0);
    }
    return (ownedServer || originalServer) &&
        current.proxyEnable == original.proxyEnable;
  }

  for (final activationState in activationStates) {
    var state = activationState;
    if (state == current) return true;
    if (original.proxyEnable == 0) {
      state = state.copyWith(proxyEnable: 0);
      if (state == current) return true;
    }
    state = state.copyWith(
      hasProxyServer: original.hasProxyServer,
      proxyServer: original.proxyServer,
    );
    if (state == current) return true;
    state = state.copyWith(
      hasProxyOverride: original.hasProxyOverride,
      proxyOverride: original.proxyOverride,
    );
    if (state == current) return true;
    state = state.copyWith(
      hasAutoConfigUrl: original.hasAutoConfigUrl,
      autoConfigUrl: original.autoConfigUrl,
    );
    if (state == current) return true;
    state = state.copyWith(
      hasAutoDetect: original.hasAutoDetect,
      autoDetect: original.autoDetect,
    );
    if (state == current) return true;
    if (original.proxyEnable != 0) {
      state = state.copyWith(proxyEnable: original.proxyEnable);
      if (state == current) return true;
    }
  }
  return false;
}

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
    (!hasAutoDetect || autoDetect == 0);
