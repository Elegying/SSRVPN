part of 'subscription_parser.dart';

class _SubscriptionUriParser {
  const _SubscriptionUriParser._();

  static String? uriListToYaml(String content) {
    final proxies = <Map<String, dynamic>>[];
    for (final rawLine in content.split(RegExp(r'[\r\n]+'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final proxy = proxyFromUri(line);
      if (proxy != null) proxies.add(proxy);
    }
    if (proxies.isEmpty) return null;

    final buffer = StringBuffer()..writeln('proxies:');
    for (final proxy in proxies) {
      buffer.writeln('  - ${_jsonEncode(proxy)}');
    }
    return buffer.toString();
  }

  static Map<String, dynamic>? proxyFromUri(String line) {
    if (_SsrSubscriptionParser.isSsrLink(line)) {
      final yaml = _SsrSubscriptionParser.importSsrLink(line);
      if (yaml == null) return null;
      final proxiesText = _SubscriptionYamlParser.extractSection(
        yaml,
        'proxies',
      );
      final items = _SubscriptionYamlParser.splitProxyItems(proxiesText);
      return items.isEmpty
          ? null
          : _SubscriptionYamlParser.parseProxyItem(items.first);
    }

    final uri = Uri.tryParse(line);
    if (uri == null) return null;
    final scheme = uri.scheme.toLowerCase();

    if (scheme == 'ss') return _parseSsUri(uri);
    if (scheme == 'vmess') return _parseVmessUri(line);
    if (scheme == 'vless') return _parseVlessUri(uri);
    if (scheme == 'hysteria' || scheme == 'hy') return _parseHysteriaUri(uri);
    if (scheme == 'hysteria2' || scheme == 'hy2') {
      return _parseHysteria2Uri(uri);
    }
    if (scheme == 'tuic') return _parseTuicUri(uri);
    if (scheme == 'snell') return _parseSnellUri(uri);
    if (_isSocksScheme(scheme)) return _parseSocksUri(uri);
    if (scheme == 'http' || scheme == 'https') return _parseHttpUri(uri);

    if (uri.host.isEmpty || uri.port <= 0) return null;
    final password = _decodeUriPart(uri.userInfo);
    if (password.isEmpty) return null;

    final name = _proxyNameFromUri(uri);
    final query = uri.queryParameters;

    if (scheme == 'anytls') {
      final proxy = <String, dynamic>{
        'name': name,
        'type': 'anytls',
        'server': uri.host,
        'port': uri.port,
        'password': password,
        'udp': true,
      };
      _putIfNotEmpty(proxy, 'sni', query['sni']);
      _putIfNotEmpty(proxy, 'client-fingerprint', query['fp']);
      if (_isTruthy(query['insecure']) || _isTruthy(query['allowInsecure'])) {
        proxy['skip-cert-verify'] = true;
      }
      return proxy;
    }

    if (scheme == 'trojan') {
      final proxy = <String, dynamic>{
        'name': name,
        'type': 'trojan',
        'server': uri.host,
        'port': uri.port,
        'password': password,
        'udp': true,
      };
      _putIfNotEmpty(proxy, 'sni', query['sni'] ?? query['peer']);
      if (_isTruthy(query['allowInsecure']) || _isTruthy(query['insecure'])) {
        proxy['skip-cert-verify'] = true;
      }
      return proxy;
    }

    return null;
  }

  static Map<String, dynamic>? _parseSsUri(Uri uri) {
    if (uri.host.isEmpty || uri.port <= 0 || uri.userInfo.isEmpty) {
      return null;
    }

    final credentials = _parseSsCredentials(uri.userInfo);
    if (credentials == null) return null;

    final proxy = <String, dynamic>{
      'name': _proxyNameFromUri(uri),
      'type': 'ss',
      'server': uri.host,
      'port': uri.port,
      'cipher': credentials.cipher,
      'password': credentials.password,
      'udp': true,
    };
    _putIfNotEmpty(proxy, 'plugin', uri.queryParameters['plugin']);
    return proxy;
  }

  static Map<String, dynamic>? _parseVmessUri(String line) {
    final encoded = line.trim().substring('vmess://'.length);
    if (encoded.isEmpty) return null;

    try {
      final decoded = _SubscriptionBase64.decodeText(
        encoded,
        fieldName: 'VMess链接',
      );
      final json = jsonDecode(decoded);
      if (json is! Map) return null;

      final server = _stringFrom(json['add'] ?? json['server']);
      final port = _intFrom(json['port']);
      final uuid = _stringFrom(json['id'] ?? json['uuid']);
      if (server == null || port == null || uuid == null) return null;

      final name = _stringFrom(json['ps'] ?? json['name']) ?? '$server:$port';
      final proxy = <String, dynamic>{
        'name': name,
        'type': 'vmess',
        'server': server,
        'port': port,
        'uuid': uuid,
        'alterId': _intFrom(json['aid'] ?? json['alterId']) ?? 0,
        'cipher': _stringFrom(json['scy'] ?? json['cipher']) ?? 'auto',
        'udp': true,
      };

      final network = _normalizeNetwork(_stringFrom(json['net']));
      if (network != null) proxy['network'] = network;

      final tls = _stringFrom(json['tls'])?.toLowerCase();
      if (tls != null && tls.isNotEmpty && tls != 'none') {
        proxy['tls'] = true;
      }

      _putIfNotEmpty(proxy, 'servername', _stringFrom(json['sni']));
      _putIfNotEmpty(proxy, 'client-fingerprint', _stringFrom(json['fp']));
      _putIfNotEmpty(
        proxy,
        'packet-encoding',
        _stringFrom(json['packetEncoding']),
      );
      _putAlpn(proxy, _stringFrom(json['alpn']));
      _putTruthy(proxy, 'skip-cert-verify', _stringFrom(json['allowInsecure']));

      _applyTransportOptions(
        proxy,
        network,
        path: _stringFrom(json['path']),
        host: _stringFrom(json['host']),
        grpcServiceName: _stringFrom(json['path'] ?? json['serviceName']),
      );

      return proxy;
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _parseVlessUri(Uri uri) {
    if (uri.host.isEmpty || uri.port <= 0 || uri.userInfo.isEmpty) {
      return null;
    }

    final query = uri.queryParameters;
    final proxy = <String, dynamic>{
      'name': _proxyNameFromUri(uri),
      'type': 'vless',
      'server': uri.host,
      'port': uri.port,
      'uuid': _decodeUriPart(uri.userInfo),
      'udp': true,
    };

    final network = _normalizeNetwork(query['type']);
    if (network != null) proxy['network'] = network;

    final security = query['security']?.trim().toLowerCase();
    if (security == 'tls' || security == 'reality') {
      proxy['tls'] = true;
    }

    _putIfNotEmpty(proxy, 'flow', query['flow']);
    _putIfNotEmpty(proxy, 'servername', query['sni']);
    _putIfNotEmpty(proxy, 'client-fingerprint', query['fp']);

    final encryption = query['encryption']?.trim();
    if (encryption != null &&
        encryption.isNotEmpty &&
        encryption.toLowerCase() != 'none') {
      proxy['encryption'] = encryption;
    }

    if (_isTruthy(query['allowInsecure']) || _isTruthy(query['insecure'])) {
      proxy['skip-cert-verify'] = true;
    }

    _putAlpn(proxy, query['alpn']);
    _applyTransportOptions(
      proxy,
      network,
      path: query['path'],
      host: query['host'],
      grpcServiceName: query['serviceName'],
    );

    if (security == 'reality') {
      final realityOpts = <String, dynamic>{};
      _putIfNotEmpty(realityOpts, 'public-key', query['pbk']);
      _putIfNotEmpty(realityOpts, 'short-id', query['sid']);
      if (realityOpts.isNotEmpty) proxy['reality-opts'] = realityOpts;
    }

    return proxy;
  }

  static Map<String, dynamic>? _parseHysteriaUri(Uri uri) {
    if (uri.host.isEmpty || uri.port <= 0) return null;

    final query = uri.queryParameters;
    final auth = query['auth'] ??
        query['auth-str'] ??
        query['auth_str'] ??
        (uri.userInfo.isNotEmpty ? _decodeUriPart(uri.userInfo) : null);
    if (auth == null || auth.trim().isEmpty) return null;

    final proxy = <String, dynamic>{
      'name': _proxyNameFromUri(uri),
      'type': 'hysteria',
      'server': uri.host,
      'port': uri.port,
      'auth-str': auth.trim(),
      'protocol': query['protocol']?.trim().isNotEmpty == true
          ? query['protocol']!.trim()
          : 'udp',
    };

    _putIfNotEmpty(proxy, 'ports', query['mport'] ?? query['ports']);
    _putIfNotEmpty(proxy, 'obfs', query['obfs']);
    _putIfNotEmpty(proxy, 'sni', query['sni'] ?? query['peer']);
    _putIfNotEmpty(
      proxy,
      'up',
      _bandwidthValue(query['up'] ?? query['upmbps']),
    );
    _putIfNotEmpty(
      proxy,
      'down',
      _bandwidthValue(query['down'] ?? query['downmbps']),
    );
    _putAlpn(proxy, query['alpn']);
    _putTruthy(proxy, 'skip-cert-verify', query['allowInsecure']);
    _putTruthy(proxy, 'skip-cert-verify', query['insecure']);

    return proxy;
  }

  static Map<String, dynamic>? _parseHysteria2Uri(Uri uri) {
    if (uri.host.isEmpty || uri.port <= 0 || uri.userInfo.isEmpty) {
      return null;
    }

    final query = uri.queryParameters;
    final proxy = <String, dynamic>{
      'name': _proxyNameFromUri(uri),
      'type': 'hysteria2',
      'server': uri.host,
      'port': uri.port,
      'password': _decodeUriPart(uri.userInfo),
    };

    _putIfNotEmpty(proxy, 'ports', query['mport'] ?? query['ports']);
    _putIfNotEmpty(proxy, 'sni', query['sni']);
    _putIfNotEmpty(proxy, 'fingerprint', query['pinSHA256']);
    _putIfNotEmpty(proxy, 'obfs', query['obfs']);
    _putIfNotEmpty(
      proxy,
      'obfs-password',
      query['obfs-password'] ?? query['obfsPassword'],
    );
    _putIfNotEmpty(
      proxy,
      'hop-interval',
      query['hop-interval'] ?? query['hopInterval'],
    );
    _putIfNotEmpty(proxy, 'up', query['up']);
    _putIfNotEmpty(proxy, 'down', query['down']);

    final alpn = query['alpn']?.trim();
    if (alpn != null && alpn.isNotEmpty) {
      proxy['alpn'] = alpn
          .split(',')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList();
    }

    if (_isTruthy(query['allowInsecure']) || _isTruthy(query['insecure'])) {
      proxy['skip-cert-verify'] = true;
    }

    return proxy;
  }

  static Map<String, dynamic>? _parseTuicUri(Uri uri) {
    if (uri.host.isEmpty || uri.port <= 0) return null;

    final query = uri.queryParameters;
    final userInfo = _decodeUriPart(uri.userInfo);
    final proxy = <String, dynamic>{
      'name': _proxyNameFromUri(uri),
      'type': 'tuic',
      'server': uri.host,
      'port': uri.port,
    };

    final token = query['token'];
    final separator = userInfo.indexOf(':');
    if (token != null && token.trim().isNotEmpty) {
      proxy['token'] = token.trim();
    } else if (separator > 0 && separator < userInfo.length - 1) {
      proxy['uuid'] = userInfo.substring(0, separator);
      proxy['password'] = userInfo.substring(separator + 1);
    } else if (userInfo.trim().isNotEmpty) {
      proxy['token'] = userInfo.trim();
    } else {
      return null;
    }

    _putIfNotEmpty(proxy, 'sni', query['sni']);
    _putIfNotEmpty(
      proxy,
      'congestion-controller',
      query['congestion_control'] ??
          query['congestion-controller'] ??
          query['congestionController'],
    );
    _putIfNotEmpty(
      proxy,
      'udp-relay-mode',
      query['udp_relay_mode'] ??
          query['udp-relay-mode'] ??
          query['udpRelayMode'],
    );
    _putIfNotEmpty(
      proxy,
      'heartbeat-interval',
      query['heartbeat_interval'] ??
          query['heartbeat-interval'] ??
          query['heartbeatInterval'],
    );
    _putIfNotEmpty(
      proxy,
      'request-timeout',
      query['request_timeout'] ??
          query['request-timeout'] ??
          query['requestTimeout'],
    );
    _putIfNotEmpty(
      proxy,
      'max-udp-relay-packet-size',
      query['max_udp_relay_packet_size'] ??
          query['max-udp-relay-packet-size'] ??
          query['maxUdpRelayPacketSize'],
    );
    _putAlpn(proxy, query['alpn']);
    _putTruthy(proxy, 'skip-cert-verify', query['allowInsecure']);
    _putTruthy(proxy, 'skip-cert-verify', query['allow_insecure']);
    _putTruthy(proxy, 'skip-cert-verify', query['insecure']);
    _putTruthy(proxy, 'disable-sni', query['disable_sni']);
    _putTruthy(proxy, 'disable-sni', query['disable-sni']);
    _putTruthy(proxy, 'reduce-rtt', query['reduce_rtt']);
    _putTruthy(proxy, 'reduce-rtt', query['reduce-rtt']);

    return proxy;
  }

  static Map<String, dynamic>? _parseSnellUri(Uri uri) {
    if (uri.host.isEmpty || uri.port <= 0) return null;

    final query = uri.queryParameters;
    final psk = query['psk'] ??
        query['password'] ??
        (uri.userInfo.isNotEmpty ? _decodeUriPart(uri.userInfo) : null);
    if (psk == null || psk.trim().isEmpty) return null;

    final proxy = <String, dynamic>{
      'name': _proxyNameFromUri(uri),
      'type': 'snell',
      'server': uri.host,
      'port': uri.port,
      'psk': psk.trim(),
    };

    final version = _intFrom(query['version']);
    if (version != null) proxy['version'] = version;
    _putTruthy(proxy, 'reuse', query['reuse']);
    _putTruthy(proxy, 'udp', query['udp']);

    final obfsMode = query['obfs'] ?? query['obfs-mode'] ?? query['obfsMode'];
    final obfsHost = query['host'] ?? query['obfs-host'] ?? query['obfsHost'];
    final obfsOpts = <String, dynamic>{};
    _putIfNotEmpty(obfsOpts, 'mode', obfsMode);
    _putIfNotEmpty(obfsOpts, 'host', obfsHost);
    if (obfsOpts.isNotEmpty) proxy['obfs-opts'] = obfsOpts;

    return proxy;
  }

  static Map<String, dynamic>? _parseSocksUri(Uri uri) {
    if (uri.host.isEmpty || !uri.hasPort || uri.port <= 0) return null;

    final proxy = <String, dynamic>{
      'name': _proxyNameFromUri(uri),
      'type': 'socks5',
      'server': uri.host,
      'port': uri.port,
      'udp': true,
    };
    if (uri.scheme.toLowerCase() == 'socks5-tls') proxy['tls'] = true;
    _putUserInfo(proxy, uri.userInfo);
    _putTruthy(proxy, 'tls', uri.queryParameters['tls']);
    _putTruthy(proxy, 'skip-cert-verify', uri.queryParameters['allowInsecure']);
    _putTruthy(proxy, 'skip-cert-verify', uri.queryParameters['insecure']);
    _putIfNotEmpty(proxy, 'sni', uri.queryParameters['sni']);
    _putIfNotEmpty(proxy, 'fingerprint', uri.queryParameters['fingerprint']);
    return proxy;
  }

  static Map<String, dynamic>? _parseHttpUri(Uri uri) {
    if (uri.host.isEmpty || !uri.hasPort || uri.port <= 0) return null;

    final proxy = <String, dynamic>{
      'name': _proxyNameFromUri(uri),
      'type': 'http',
      'server': uri.host,
      'port': uri.port,
    };
    if (uri.scheme.toLowerCase() == 'https') proxy['tls'] = true;
    _putUserInfo(proxy, uri.userInfo);
    _putTruthy(proxy, 'tls', uri.queryParameters['tls']);
    _putTruthy(proxy, 'skip-cert-verify', uri.queryParameters['allowInsecure']);
    _putTruthy(proxy, 'skip-cert-verify', uri.queryParameters['insecure']);
    _putIfNotEmpty(proxy, 'sni', uri.queryParameters['sni']);
    _putIfNotEmpty(proxy, 'fingerprint', uri.queryParameters['fingerprint']);
    return proxy;
  }

  static String? _normalizeNetwork(String? value) {
    final network = value?.trim().toLowerCase();
    if (network == null ||
        network.isEmpty ||
        network == 'none' ||
        network == 'tcp') {
      return network == 'tcp' ? 'tcp' : null;
    }
    if (network == 'http') return 'http';
    if (network == 'ws' ||
        network == 'h2' ||
        network == 'grpc' ||
        network == 'xhttp') {
      return network;
    }
    return network;
  }

  static void _applyTransportOptions(
    Map<String, dynamic> proxy,
    String? network, {
    String? path,
    String? host,
    String? grpcServiceName,
  }) {
    if (network == 'ws') {
      final wsOpts = <String, dynamic>{};
      _putIfNotEmpty(wsOpts, 'path', path);
      final headerHost = host?.trim();
      if (headerHost != null && headerHost.isNotEmpty) {
        wsOpts['headers'] = {'Host': headerHost};
      }
      if (wsOpts.isNotEmpty) proxy['ws-opts'] = wsOpts;
    } else if (network == 'grpc') {
      final grpcOpts = <String, dynamic>{};
      _putIfNotEmpty(grpcOpts, 'grpc-service-name', grpcServiceName);
      if (grpcOpts.isNotEmpty) proxy['grpc-opts'] = grpcOpts;
    } else if (network == 'h2' || network == 'http') {
      final httpOpts = <String, dynamic>{};
      final paths = _splitCsv(path);
      final hosts = _splitCsv(host);
      if (paths.isNotEmpty) httpOpts['path'] = paths;
      if (hosts.isNotEmpty) httpOpts['host'] = hosts;
      if (httpOpts.isNotEmpty) proxy['http-opts'] = httpOpts;
    }
  }

  static void _putAlpn(Map<String, dynamic> proxy, String? value) {
    final values = _splitCsv(value);
    if (values.isNotEmpty) proxy['alpn'] = values;
  }

  static List<String> _splitCsv(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return const [];
    return trimmed
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  static void _putTruthy(
    Map<String, dynamic> proxy,
    String key,
    String? value,
  ) {
    if (_isTruthy(value)) proxy[key] = true;
  }

  static void _putUserInfo(Map<String, dynamic> proxy, String rawUserInfo) {
    if (rawUserInfo.isEmpty) return;
    final userInfo = _decodeUriPart(rawUserInfo);
    final separator = userInfo.indexOf(':');
    if (separator < 0) {
      proxy['username'] = userInfo;
      return;
    }
    final username = userInfo.substring(0, separator);
    final password = userInfo.substring(separator + 1);
    if (username.isNotEmpty) proxy['username'] = username;
    if (password.isNotEmpty) proxy['password'] = password;
  }

  static void _putIfNotEmpty(
    Map<String, dynamic> target,
    String key,
    String? value,
  ) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) target[key] = trimmed;
  }

  static String? _bandwidthValue(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return RegExp(r'^\d+(\.\d+)?$').hasMatch(trimmed)
        ? '$trimmed Mbps'
        : trimmed;
  }

  static String? _stringFrom(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  static int? _intFrom(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '');
  }

  static bool _isSocksScheme(String scheme) {
    return scheme == 'socks' ||
        scheme == 'socks5' ||
        scheme == 'socks5h' ||
        scheme == 'socks5-tls';
  }

  static _SsCredentials? _parseSsCredentials(String rawUserInfo) {
    final userInfo = _decodeUriPart(rawUserInfo);
    final split = _splitCipherAndPassword(userInfo);
    if (split != null) return split;

    try {
      return _splitCipherAndPassword(
        _SubscriptionBase64.decodeText(userInfo, fieldName: 'SS认证信息'),
      );
    } on FormatException {
      return null;
    }
  }

  static _SsCredentials? _splitCipherAndPassword(String value) {
    final separator = value.indexOf(':');
    if (separator <= 0 || separator == value.length - 1) return null;
    final cipher = value.substring(0, separator).trim();
    final password = value.substring(separator + 1);
    if (cipher.isEmpty || password.isEmpty) return null;
    return _SsCredentials(cipher: cipher, password: password);
  }

  static String _proxyNameFromUri(Uri uri) {
    final fragment = _decodeUriPart(uri.fragment).trim();
    return fragment.isNotEmpty ? fragment : '${uri.host}:${uri.port}';
  }

  static bool _isTruthy(String? value) {
    final normalized = value?.trim().toLowerCase();
    return normalized == '1' || normalized == 'true' || normalized == 'yes';
  }

  static String _decodeUriPart(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }
}
