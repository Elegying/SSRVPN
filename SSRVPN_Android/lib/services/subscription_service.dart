import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:yaml/yaml.dart';
import 'package:uuid/uuid.dart';
import 'package:ssrvpn_shared/models/subscription.dart';
import 'http_client_adapter.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/models/proxy_group.dart';
import 'package:ssrvpn_shared/services/subscription_parser.dart';

/// 订阅管理服务
class SubscriptionService extends ChangeNotifier {
  static SubscriptionService? _instance;
  static const int _maxSubscriptionBytes = 20 * 1024 * 1024;
  static const int _maxYamlBytes = 2 * 1024 * 1024; // 2MB rawYaml 限制
  final Uuid _uuid = const Uuid();

  /// 可注入的 HTTP 客户端适配器（测试时可替换为 FakeHttpClientAdapter）
  static HttpClientAdapter? _httpClientOverride;

  /// 设置自定义 HttpClientAdapter（仅用于测试）
  @visibleForTesting
  static void overrideHttpClient(HttpClientAdapter adapter) {
    _httpClientOverride = adapter;
  }

  @visibleForTesting
  static void resetHttpClientOverride() {
    _httpClientOverride = null;
  }

  List<Subscription> _subscriptions = [];
  String? _rawYaml; // 合并后的原始YAML配置
  String? _cacheDir;
  // 配置内容版本号：rawYaml 内容变化时递增（节点数相同但内容变了也能感知）
  int _revision = 0;

  List<ProxyNode> _allNodes = [];
  List<ProxyGroup> _allGroups = [];

  SubscriptionService._();

  static Future<SubscriptionService> getInstance(String cacheDir) async {
    if (_instance == null) {
      _instance = SubscriptionService._();
      _instance!._cacheDir = cacheDir;
      await _instance!._loadFromDisk();
    }
    return _instance!;
  }

  List<Subscription> get subscriptions => List.unmodifiable(_subscriptions);
  String? get rawYaml => _rawYaml;
  int get revision => _revision;
  List<ProxyNode> get allNodes => List.unmodifiable(_allNodes);
  List<ProxyGroup> get allGroups => List.unmodifiable(_allGroups);

  /// 添加订阅
  Future<Subscription> addSubscription(String name, String url) async {
    final sub = Subscription(
      id: _uuid.v4(),
      name: name,
      url: url,
    );
    _subscriptions.add(sub);
    await _saveToDisk();
    notifyListeners();
    return sub;
  }

  /// 删除订阅
  ///
  /// 先尝试删除；失败时不清理缓存节点，仅通知调用方处理异常
  Future<void> removeSubscription(String id) async {
    _subscriptions.removeWhere((s) => s.id == id);
    await _saveToDisk();

    if (_subscriptions.isEmpty) {
      await _clearCachedNodes();
      notifyListeners();
      return;
    }

    try {
      await refreshAllSubscriptions();
    } catch (e) {
      // 失败时不清理缓存节点，原有节点仍可用
      notifyListeners();
      // 转为中文友好异常
      throw Exception('删除订阅失败，请检查网络后重试');
    }
  }

  /// 更新订阅
  Future<void> updateSubscription(Subscription updated) async {
    final index = _subscriptions.indexWhere((s) => s.id == updated.id);
    if (index >= 0) {
      _subscriptions[index] = updated;
      await _saveToDisk();
      notifyListeners();
    }
  }

  /// 从URL拉取订阅配置（含重试机制，移动网络更可靠）
  /// 使用原生 HttpClient + 多IP逐个尝试，解决移动数据下 TLS 被 reset 的问题
  Future<String?> fetchSubscription(String url, {int maxRetries = 3}) async {
    Exception? lastException;

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      final stopwatch = Stopwatch()..start();
      try {
        final uri = Uri.parse(url);
        final result = await _fetchWithMultiIpFallback(uri, stopwatch, attempt);
        if (result != null) return result;
      } on SocketException catch (e) {
        debugPrint(
            '[订阅] Socket异常 (尝试$attempt/$maxRetries): ${e.message} (${stopwatch.elapsedMilliseconds}ms)');
        lastException = Exception('网络连接失败: ${e.message}');
      } on TimeoutException catch (e) {
        debugPrint(
            '[订阅] 超时 (尝试$attempt/$maxRetries): ${e.duration} (${stopwatch.elapsedMilliseconds}ms)');
        lastException =
            Exception('连接超时: ${e.duration ?? Duration(seconds: attempt * 30)}');
      } on HttpException catch (e) {
        debugPrint(
            '[订阅] HTTP错误 (尝试$attempt/$maxRetries): ${e.message} (${stopwatch.elapsedMilliseconds}ms)');
        lastException = Exception('HTTP错误: ${e.message}');
      } catch (e) {
        debugPrint(
            '[订阅] 未知异常 (尝试$attempt/$maxRetries): $e (${stopwatch.elapsedMilliseconds}ms)');
        lastException = Exception('获取订阅失败: $e');
      }

      // 非最后一次尝试，等待后重试
      if (attempt < maxRetries) {
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }

    throw lastException ?? Exception('获取订阅失败: 未知错误');
  }

  /// 拉取单个 URL（含重定向跟随：订阅服务器经常 301/302 到 CDN 地址）
  Future<String?> _fetchWithMultiIpFallback(
      Uri uri, Stopwatch stopwatch, int attempt) async {
    var current = uri;
    for (var hop = 0; hop <= 4; hop++) {
      final resp = await _fetchOnce(current, stopwatch, attempt);

      if (resp.statusCode >= 300 && resp.statusCode < 400) {
        final location = resp.headers['location'];
        if (location == null || location.isEmpty) {
          throw HttpException('HTTP ${resp.statusCode} 重定向缺少 Location 头');
        }
        current = current.resolve(location);
        debugPrint('[订阅] 重定向 (${resp.statusCode}) -> $current');
        continue;
      }

      if (resp.statusCode == 200) {
        var bodyBytes = resp.bodyBytes;
        // 防御性处理：个别服务器无视 Accept-Encoding 仍返回 gzip
        if (resp.headers['content-encoding']?.toLowerCase() == 'gzip') {
          bodyBytes = gzip.decode(bodyBytes);
        }
        String body = utf8.decode(bodyBytes, allowMalformed: true);
        if (body.trim().isEmpty) {
          throw Exception('服务器返回空内容');
        }

        // 尝试 Base64 解码
        final compact = body.replaceAll(RegExp(r'\s'), '');
        if (_isLikelyBase64(compact)) {
          try {
            final decoded = utf8.decode(base64Decode(compact));
            if (decoded.trim().isNotEmpty) {
              body = decoded;
            }
          } catch (_) {}
        }
        return body;
      } else if (resp.statusCode == 429) {
        throw Exception('请求过于频繁 (HTTP 429)');
      } else if (resp.statusCode == 403) {
        throw Exception('访问被拒绝 (HTTP 403)，可能需要更换订阅地址');
      } else {
        throw Exception('HTTP ${resp.statusCode}: 订阅获取失败');
      }
    }
    throw Exception('重定向次数过多');
  }

  /// 多IP逐个尝试策略：DNS 解析出多个 IPv4 地址后，逐个尝试 TLS 连接
  /// 解决移动数据下某些 CDN IP 被运营商 reset 的问题
  Future<_RawHttpResponse> _fetchOnce(
      Uri uri, Stopwatch stopwatch, int attempt) async {
    final clientOverride = _httpClientOverride;
    if (clientOverride != null) {
      final response = await clientOverride.get(
        uri,
        timeout: const Duration(seconds: 60),
      );
      return _RawHttpResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        bodyBytes: response.bodyBytes,
      );
    }

    // 阶段1: DNS 预解析
    List<InternetAddress> addresses;
    try {
      addresses = await InternetAddress.lookup(
        uri.host,
        type: InternetAddressType.IPv4,
      ).timeout(const Duration(seconds: 10));
      debugPrint(
          '[订阅] DNS 解析成功: ${uri.host} -> ${addresses.map((a) => a.address).join(", ")} (${stopwatch.elapsedMilliseconds}ms)');
    } on SocketException catch (e) {
      debugPrint(
          '[订阅] DNS 解析失败: ${uri.host} -> ${e.message} (${stopwatch.elapsedMilliseconds}ms)');
      throw SocketException('DNS解析失败: ${e.message}');
    } on TimeoutException {
      debugPrint('[订阅] DNS 解析超时: ${uri.host} (10s)');
      throw TimeoutException('DNS解析超时', const Duration(seconds: 10));
    }

    if (addresses.isEmpty) {
      throw const SocketException('DNS解析返回空结果');
    }

    // 阶段2: 逐个 IP 尝试连接
    final isSecure = uri.scheme == 'https';
    final port = uri.port;
    final pathWithQuery = (uri.path.isEmpty ? '/' : uri.path) +
        (uri.hasQuery ? '?${uri.query}' : '');
    SocketException? lastSocketError;

    // 最多尝试前 5 个不同的 IP（避免耗时过长）
    final ipsToTry = addresses.take(5).toList();
    debugPrint('[订阅] 将尝试 ${ipsToTry.length} 个 IP 地址...');

    for (int i = 0; i < ipsToTry.length; i++) {
      final addr = ipsToTry[i];
      final ipStopwatch = Stopwatch()..start();
      try {
        // 直接用 IP 建立 Socket 连接
        final socket = await Socket.connect(
          addr,
          port,
          timeout: Duration(seconds: attempt == 1 ? 15 : 20),
        );

        // 如果是 HTTPS，升级到 TLS
        if (isSecure) {
          final secureSocket = await SecureSocket.secure(
            socket,
            host: uri.host, // SNI 必须用域名
            onBadCertificate: (_) => false,
          );
          return await _sendHttpRequest(
            secureSocket,
            uri.host,
            pathWithQuery,
            stopwatch,
            ipStopwatch,
            addr.address,
            attempt,
          );
        } else {
          return await _sendHttpRequest(
            socket,
            uri.host,
            pathWithQuery,
            stopwatch,
            ipStopwatch,
            addr.address,
            attempt,
          );
        }
      } on SocketException catch (e) {
        lastSocketError = e;
        debugPrint(
            '[订阅] IP ${addr.address} 失败: ${e.message} (${ipStopwatch.elapsedMilliseconds}ms)');
        continue; // 尝试下一个 IP
      } on HandshakeException catch (e) {
        debugPrint(
            '[订阅] IP ${addr.address} TLS握手失败: ${e.message} (${ipStopwatch.elapsedMilliseconds}ms)');
        lastSocketError = SocketException('TLS握手失败: ${e.message}');
        continue;
      } catch (e) {
        debugPrint(
            '[订阅] IP ${addr.address} 异常: $e (${ipStopwatch.elapsedMilliseconds}ms)');
        lastSocketError = SocketException('连接异常: $e');
        continue;
      }
    }

    // 所有 IP 都失败
    throw lastSocketError ?? const SocketException('所有IP地址连接失败');
  }

  /// 通过已建立的 Socket 发送 HTTP 请求并读取原始响应（状态码语义由调用方处理）
  Future<_RawHttpResponse> _sendHttpRequest(
    Socket socket,
    String host,
    String pathWithQuery,
    Stopwatch totalStopwatch,
    Stopwatch ipStopwatch,
    String ipAddress,
    int attempt,
  ) async {
    try {
      // 构造 HTTP/1.1 请求（identity 编码，避免 gzip；chunked 由下方解码）
      final request = 'GET $pathWithQuery HTTP/1.1\r\n'
          'Host: $host\r\n'
          'User-Agent: SSRVPN/2.0.0\r\n'
          'Accept: text/yaml, application/x-yaml, */*\r\n'
          'Accept-Encoding: identity\r\n'
          'Connection: close\r\n'
          '\r\n';
      socket.write(request);
      await socket.flush();

      debugPrint(
          '[订阅] IP $ipAddress 请求已发送 (${ipStopwatch.elapsedMilliseconds}ms)');

      // 读取完整响应
      final responseBytes = <int>[];
      var totalBytes = 0;
      await for (final chunk in socket.timeout(const Duration(seconds: 60))) {
        totalBytes += chunk.length;
        if (totalBytes > _maxSubscriptionBytes) {
          throw Exception('订阅内容超过 20 MB 限制');
        }
        responseBytes.addAll(chunk);
      }

      debugPrint(
          '[订阅] IP $ipAddress 收到 ${responseBytes.length} bytes (${ipStopwatch.elapsedMilliseconds}ms)');

      if (responseBytes.isEmpty) {
        throw HttpException('IP $ipAddress 返回空响应');
      }

      // 切分头与体（按字节查找 \r\n\r\n，避免多字节字符干扰偏移）
      var headerEnd = -1;
      for (var i = 0; i + 3 < responseBytes.length; i++) {
        if (responseBytes[i] == 13 &&
            responseBytes[i + 1] == 10 &&
            responseBytes[i + 2] == 13 &&
            responseBytes[i + 3] == 10) {
          headerEnd = i;
          break;
        }
      }
      if (headerEnd == -1) {
        throw HttpException('IP $ipAddress 响应格式异常');
      }

      final headerSection = utf8.decode(responseBytes.sublist(0, headerEnd),
          allowMalformed: true);
      var bodyBytes = responseBytes.sublist(headerEnd + 4);

      // 提取状态码
      final headerLines = headerSection.split('\r\n');
      final statusMatch =
          RegExp(r'HTTP/\S+ (\d+)').firstMatch(headerLines.first);
      if (statusMatch == null) {
        throw HttpException('IP $ipAddress 状态行异常: ${headerLines.first}');
      }
      final statusCode = int.parse(statusMatch.group(1)!);

      // 解析响应头
      final headers = <String, String>{};
      for (final line in headerLines.skip(1)) {
        final idx = line.indexOf(':');
        if (idx > 0) {
          headers[line.substring(0, idx).trim().toLowerCase()] =
              line.substring(idx + 1).trim();
        }
      }

      // chunked 传输编码需要还原出真实 body，否则内容混入分块长度行
      if (headers['transfer-encoding']?.toLowerCase().contains('chunked') ==
          true) {
        bodyBytes = _decodeChunked(bodyBytes);
      }

      debugPrint(
          '[订阅] IP $ipAddress HTTP $statusCode (总耗时 ${totalStopwatch.elapsedMilliseconds}ms)');
      return _RawHttpResponse(
          statusCode: statusCode, headers: headers, bodyBytes: bodyBytes);
    } finally {
      socket.destroy();
    }
  }

  /// 解析 chunked 传输编码
  List<int> _decodeChunked(List<int> data) {
    final out = <int>[];
    var pos = 0;
    while (pos < data.length) {
      var lineEnd = pos;
      while (lineEnd + 1 < data.length &&
          !(data[lineEnd] == 13 && data[lineEnd + 1] == 10)) {
        lineEnd++;
      }
      if (lineEnd + 1 >= data.length) break;
      final sizeLine = String.fromCharCodes(data.sublist(pos, lineEnd));
      final size = int.tryParse(sizeLine.split(';').first.trim(), radix: 16);
      if (size == null || size == 0) break;
      final chunkStart = lineEnd + 2;
      final chunkEnd = chunkStart + size;
      if (chunkEnd > data.length) {
        out.addAll(data.sublist(chunkStart));
        break;
      }
      out.addAll(data.sublist(chunkStart, chunkEnd));
      pos = chunkEnd + 2; // 跳过块末尾的 \r\n
    }
    return out;
  }

  /// 刷新所有订阅
  /// 返回值：null 表示没有订阅；空字符串表示全部失败；非空字符串为合并后的 YAML
  Future<String?> refreshAllSubscriptions() async {
    if (_subscriptions.isEmpty) {
      _rawYaml = null;
      _allNodes = [];
      _allGroups = [];
      return null;
    }

    final allYamlBuffers = <String>[];
    final succeededSubs = <Subscription>[];
    final errors = <String>[];

    for (final sub in _subscriptions.where((s) => s.enabled)) {
      try {
        String? yaml;
        if (isSsrLink(sub.url)) {
          yaml = importSsrLink(sub.url);
          if (yaml == null) {
            throw const FormatException('SSR链接格式无效或内容不完整');
          }
        } else {
          yaml = await fetchSubscription(sub.url);
        }
        yaml = _normalizeSubscriptionContent(yaml);
        if (yaml != null && yaml.isNotEmpty) {
          allYamlBuffers.add(yaml);
          succeededSubs.add(sub);
        } else {
          errors.add('${sub.name}: 返回内容为空');
        }
      } catch (e) {
        errors.add('${sub.name}: $e');
        continue;
      }
    }

    if (succeededSubs.isEmpty) {
      // 全部失败，抛出包含所有错误信息的异常
      final errorDetail = errors.isNotEmpty ? errors.join('\n') : '无可用订阅';
      throw Exception('所有订阅刷新失败:\n$errorDetail');
    }

    // 合并多个订阅的YAML
    final oldYaml = _rawYaml;
    _rawYaml = _mergeYamlConfigs(allYamlBuffers);
    if (_rawYaml != oldYaml) _revision++;

    // 缓存到磁盘（含大小检查）
    if (_rawYaml != null) {
      final byteCount = utf8.encode(_rawYaml!).length;
      if (byteCount > _maxYamlBytes) {
        throw Exception(
            '订阅内容过大 (${(byteCount / 1024 / 1024).toStringAsFixed(1)}MB)，超过 2MB 限制');
      }
      await _cacheYaml(_rawYaml!);
    }

    // 解析节点和组
    _parseYaml();

    // 只更新成功拉取的订阅的最后更新时间
    final now = DateTime.now();
    for (final sub in succeededSubs) {
      sub.lastUpdate = now;
    }
    await _saveToDisk();
    notifyListeners();

    return _rawYaml;
  }

  /// 合并多个YAML配置
  /// 从YAML文本中提取指定顶层段的原始内容
  String _extractSection(String yaml, String sectionName) {
    final lines = yaml.split('\n');
    final sectionLines = <String>[];
    bool inSection = false;

    for (final line in lines) {
      // 顶层段检测：不以空格/tab开头
      if (!line.startsWith(' ') && !line.startsWith('\t')) {
        if (line.trim().startsWith('$sectionName:')) {
          inSection = true;
          continue;
        } else if (inSection &&
            line.trim().contains(':') &&
            !line.trim().startsWith('#') &&
            !line.trim().startsWith('-')) {
          // 遇到下一个顶层段，停止
          break;
        }
      }
      if (inSection) {
        sectionLines.add(line);
      }
    }

    // 计算最小缩进（排除空行）
    int minIndent = 999;
    for (final line in sectionLines) {
      final t = line.trimLeft();
      if (t.isEmpty) continue;
      final indent = line.length - t.length;
      if (indent < minIndent) minIndent = indent;
    }
    if (minIndent == 999) minIndent = 0;

    // 重建：保留相对缩进，归一化基准为2空格
    final buffer = StringBuffer();
    for (final line in sectionLines) {
      final trimmed = line.trimLeft();
      if (trimmed.isEmpty) continue;
      final delta = line.length - trimmed.length - minIndent;
      buffer.writeln('${' ' * (delta + 2)}$trimmed');
    }
    return buffer.toString().trimRight();
  }

  /// 合并多个YAML配置（只合并proxies节点，规则和分流不取自订阅）。
  ///
  /// 完全相同的节点去重；名称相同但配置不同的节点自动追加序号，
  /// 避免多个订阅使用相同地区名称时静默丢失后加入的节点。
  String _mergeYamlConfigs(List<String> yamls) {
    if (yamls.isEmpty) return '';

    final usedNames = <String>{};
    final fingerprintsByName = <String, Set<String>>{};
    final buffer = StringBuffer();
    buffer.writeln('proxies:');
    var hasAny = false;

    for (final yaml in yamls) {
      final proxiesText = _extractSection(yaml, 'proxies');
      if (proxiesText.isEmpty) continue;
      for (final item in _splitProxyItems(proxiesText)) {
        final proxy = _parseProxyItem(item);
        final originalName = proxy?['name']?.toString().trim();
        if (proxy == null || originalName == null || originalName.isEmpty) {
          continue;
        }

        final fingerprint = jsonEncode(_canonicalJsonValue(proxy));
        final fingerprints =
            fingerprintsByName.putIfAbsent(originalName, () => <String>{});
        if (!fingerprints.add(fingerprint)) continue;

        proxy['name'] = _uniqueProxyName(originalName, usedNames);
        buffer.writeln('  - ${jsonEncode(proxy)}');
        hasAny = true;
      }
    }

    return hasAny ? buffer.toString() : '';
  }

  /// 将 proxies 段文本按顶层列表项（缩进2的 "- "）拆分
  List<String> _splitProxyItems(String proxiesText) {
    final items = <String>[];
    StringBuffer? current;
    for (final line in proxiesText.split('\n')) {
      if (line.startsWith('  - ')) {
        if (current != null) items.add(current.toString().trimRight());
        current = StringBuffer()..writeln(line);
      } else if (current != null) {
        current.writeln(line);
      }
    }
    if (current != null) items.add(current.toString().trimRight());
    return items;
  }

  /// 解析单个 proxy 列表项
  Map<String, dynamic>? _parseProxyItem(String item) {
    try {
      final parsed = loadYaml('proxies:\n$item');
      final list = (parsed as Map)['proxies'];
      if (list is List && list.isNotEmpty && list.first is Map) {
        final value = _jsonValue(list.first);
        if (value is Map<String, dynamic>) return value;
      }
    } catch (_) {}
    return null;
  }

  String? _normalizeSubscriptionContent(String? content) {
    final trimmed = content?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (_extractSection(trimmed, 'proxies').isNotEmpty) return trimmed;
    return _uriListToYaml(trimmed) ?? trimmed;
  }

  String? _uriListToYaml(String content) {
    final proxies = <Map<String, dynamic>>[];
    for (final rawLine in content.split(RegExp(r'[\r\n]+'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final proxy = _proxyFromUri(line);
      if (proxy != null) proxies.add(proxy);
    }
    if (proxies.isEmpty) return null;

    final buffer = StringBuffer()..writeln('proxies:');
    for (final proxy in proxies) {
      buffer.writeln('  - ${jsonEncode(proxy)}');
    }
    return buffer.toString();
  }

  Map<String, dynamic>? _proxyFromUri(String line) {
    return SubscriptionParser.proxyFromUri(line);
  }

  String _uniqueProxyName(String baseName, Set<String> usedNames) {
    if (usedNames.add(baseName)) return baseName;
    var suffix = 2;
    while (!usedNames.add('$baseName ($suffix)')) {
      suffix++;
    }
    return '$baseName ($suffix)';
  }

  dynamic _jsonValue(dynamic value) {
    if (value is Map) {
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        result[entry.key.toString()] = _jsonValue(entry.value);
      }
      return result;
    }
    if (value is List) {
      return value.map(_jsonValue).toList();
    }
    return value;
  }

  dynamic _canonicalJsonValue(dynamic value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return <String, dynamic>{
        for (final key in keys) key: _canonicalJsonValue(value[key]),
      };
    }
    if (value is List) {
      return value.map(_canonicalJsonValue).toList();
    }
    return value;
  }

  /// 解析YAML获取节点和组
  void _parseYaml() {
    if (_rawYaml == null) return;

    try {
      final parsed = SubscriptionParser.parseYaml(_rawYaml!);
      _allNodes = parsed.nodes;
      _allGroups = parsed.groups;
    } catch (e) {
      // YAML解析失败，保留订阅缓存中的原始数据
      debugPrint('[SubscriptionService] YAML解析失败: $e');
    }
  }

  /// 判断是否为SSR链接
  bool isSsrLink(String input) {
    return input.trim().toLowerCase().startsWith('ssr://');
  }

  /// 导入SSR链接，返回生成的YAML配置片段
  String? importSsrLink(String ssrLink) {
    try {
      final link = ssrLink.trim();
      if (!link.toLowerCase().startsWith('ssr://')) return null;

      final encoded = link.substring(6);
      final decoded = _decodeBase64Text(
        encoded,
        fieldName: 'SSR链接',
        allowTruncatedTail: true,
      );

      // SSR格式: server:port:protocol:method:obfs:base64password/?params
      final mainPart = decoded.split('/?').first;
      final params = decoded.contains('/?') ? decoded.split('/?').last : '';

      final parts = mainPart.split(':');
      if (parts.length < 6) return null;

      final server = parts[0];
      final port = int.tryParse(parts[1]) ?? 0;
      final protocol = parts[2];
      final method = parts[3];
      final obfs = parts[4];
      if (server.isEmpty ||
          port < 1 ||
          port > 65535 ||
          protocol.isEmpty ||
          method.isEmpty ||
          obfs.isEmpty) {
        return null;
      }
      final passwordB64 = parts.sublist(5).join(':');
      if (passwordB64.isEmpty) return null;
      final password = _decodeBase64Text(
        passwordB64,
        fieldName: '密码',
      );

      // 解析参数
      final paramMap = <String, String>{};
      if (params.isNotEmpty) {
        for (final param in params.split('&')) {
          final separator = param.indexOf('=');
          if (separator <= 0) continue;
          paramMap[param.substring(0, separator)] =
              param.substring(separator + 1);
        }
      }

      final remarks = paramMap['remarks'] != null
          ? _decodeBase64Text(
              paramMap['remarks']!,
              fieldName: '备注',
            )
          : '$server:$port';

      final obfsparam = paramMap['obfsparam'] != null
          ? _decodeBase64Text(
              paramMap['obfsparam']!,
              fieldName: '混淆参数',
            )
          : '';
      final protoparam = paramMap['protoparam'] != null
          ? _decodeBase64Text(
              paramMap['protoparam']!,
              fieldName: '协议参数',
            )
          : '';

      // 生成 Clash 格式的 YAML
      // 字符串值用 jsonEncode 转义加引号（JSON 字符串是合法 YAML 标量），
      // 否则备注/密码里的 : # { 等字符会破坏整个配置
      final buffer = StringBuffer();
      buffer.writeln('proxies:');
      buffer.writeln('  - name: ${jsonEncode(remarks)}');
      buffer.writeln('    type: ssr');
      buffer.writeln('    server: ${jsonEncode(server)}');
      buffer.writeln('    port: $port');
      buffer.writeln('    cipher: ${jsonEncode(method)}');
      buffer.writeln('    password: ${jsonEncode(password)}');
      buffer.writeln('    protocol: ${jsonEncode(protocol)}');
      if (protoparam.isNotEmpty) {
        buffer.writeln('    protocol-param: ${jsonEncode(protoparam)}');
      }
      buffer.writeln('    obfs: ${jsonEncode(obfs)}');
      if (obfsparam.isNotEmpty) {
        buffer.writeln('    obfs-param: ${jsonEncode(obfsparam)}');
      }
      buffer.writeln('    udp: true');

      return buffer.toString();
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('SSR链接解析失败: $e');
    }
  }

  String _decodeBase64Text(
    String value, {
    required String fieldName,
    bool allowTruncatedTail = false,
  }) {
    try {
      return utf8.decode(base64Decode(_fixBase64(value)));
    } on FormatException {
      if (allowTruncatedTail) {
        final normalized =
            value.trim().replaceAll('-', '+').replaceAll('_', '/');
        final completeLength = normalized.length - (normalized.length % 4);
        if (completeLength > 0 && completeLength < normalized.length) {
          try {
            return utf8.decode(
              base64Decode(normalized.substring(0, completeLength)),
            );
          } on FormatException {
            // Report a sanitized error below.
          }
        }
      }
      throw FormatException('$fieldName的Base64内容无效');
    }
  }

  /// 修复Base64 padding
  String _fixBase64(String str) {
    var s = str.trim().replaceAll('-', '+').replaceAll('_', '/');
    final mod = s.length % 4;
    if (mod == 1) {
      throw const FormatException('Base64内容长度无效');
    }
    if (mod == 2) s += '==';
    if (mod == 3) s += '=';
    return s;
  }

  /// 判断是否为Base64编码（调用方需先去除空白字符）
  bool _isLikelyBase64(String str) {
    if (str.length < 20) return false;
    // 允许非标准 padding（长度不是4的倍数也尝试）
    final base64Pattern = RegExp(r'^[A-Za-z0-9+/\-_]+=*$');
    if (!base64Pattern.hasMatch(str)) return false;
    // 排除纯数字或明显是YAML的情况
    if (RegExp(r'^\d+$').hasMatch(str)) return false;
    if (str.contains(':') && !str.contains('+') && !str.contains('/')) {
      return false;
    }
    return true;
  }

  /// 缓存YAML到磁盘
  Future<void> _cacheYaml(String yaml) async {
    if (_cacheDir == null) return;
    final file = File('$_cacheDir/subscription_cache.yaml');
    await _writeStringAtomically(file, yaml);
  }

  /// 修改当前缓存中的节点。下次刷新订阅会用远端内容整体覆盖这些本地修改。
  Future<void> updateNode(
    String originalName,
    Map<String, dynamic> updatedConfig,
  ) async {
    if (_rawYaml == null || _rawYaml!.isEmpty) {
      throw StateError('当前没有可编辑的订阅配置');
    }

    final parsed = loadYaml(_rawYaml!);
    final config = _jsonValue(parsed);
    if (config is! Map<String, dynamic> || config['proxies'] is! List) {
      throw const FormatException('订阅配置中没有有效的节点列表');
    }

    final proxies = config['proxies'] as List;
    final index = proxies.indexWhere(
      (proxy) => proxy is Map && proxy['name']?.toString() == originalName,
    );
    if (index < 0) throw StateError('找不到要修改的节点');

    final newName = updatedConfig['name']?.toString().trim() ?? '';
    if (newName.isEmpty) throw const FormatException('节点备注名不能为空');
    final duplicate = proxies.asMap().entries.any((entry) =>
        entry.key != index &&
        entry.value is Map &&
        (entry.value as Map)['name']?.toString() == newName);
    if (duplicate) throw const FormatException('节点备注名已存在');

    proxies[index] = Map<String, dynamic>.from(updatedConfig);

    final groups = config['proxy-groups'];
    if (newName != originalName && groups is List) {
      for (final group in groups) {
        if (group is! Map || group['proxies'] is! List) continue;
        final names = group['proxies'] as List;
        for (var i = 0; i < names.length; i++) {
          if (names[i]?.toString() == originalName) names[i] = newName;
        }
      }
    }

    final yaml = _encodeConfig(config);
    _rawYaml = yaml;
    _revision++;
    _parseYaml();
    await _cacheYaml(yaml);
    notifyListeners();
  }

  String _encodeConfig(Map<String, dynamic> config) {
    final buffer = StringBuffer();
    for (final entry in config.entries) {
      if (entry.key == 'proxies' && entry.value is List) {
        buffer.writeln('proxies:');
        for (final proxy in entry.value as List) {
          buffer.writeln('  - ${jsonEncode(_jsonValue(proxy))}');
        }
      } else {
        buffer.writeln('${entry.key}: ${jsonEncode(_jsonValue(entry.value))}');
      }
    }
    return buffer.toString();
  }

  /// 设置原始YAML并重新解析（用于SSR导入等场景）
  Future<void> setRawYaml(String yaml) async {
    if (yaml != _rawYaml) _revision++;
    _rawYaml = yaml;
    _parseYaml();
    await _cacheYaml(yaml);
    notifyListeners();
  }

  /// 从磁盘加载缓存（使用 Isolate 避免阻塞主线程）
  Future<void> _loadFromDisk() async {
    if (_cacheDir == null) return;

    // 加载订阅列表
    final subsFile = File('$_cacheDir/subscriptions.json');
    if (await subsFile.exists()) {
      try {
        final content = await Isolate.run(() async {
          return await subsFile.readAsString();
        });
        final list = jsonDecode(content) as List;
        _subscriptions = list
            .map((e) => Subscription.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e) {
        _subscriptions = [];
      }
    }

    // 加载缓存的YAML
    final cacheFile = File('$_cacheDir/subscription_cache.yaml');
    if (await cacheFile.exists()) {
      _rawYaml = await Isolate.run(() async {
        return await cacheFile.readAsString();
      });
      _parseYaml();
    }
  }

  /// 保存订阅列表到磁盘（使用 Isolate 避免阻塞主线程）
  Future<void> _saveToDisk() async {
    if (_cacheDir == null) return;
    final file = File('$_cacheDir/subscriptions.json');
    final subs = _subscriptions;
    final jsonStr = await Isolate.run(
      () => jsonEncode(subs.map((s) => s.toJson()).toList()),
    );
    await _writeStringAtomically(file, jsonStr);
  }

  Future<void> _clearCachedNodes() async {
    _rawYaml = null;
    _allNodes = [];
    _allGroups = [];
    _revision++;
    if (_cacheDir == null) return;
    try {
      final cacheFile = File('$_cacheDir/subscription_cache.yaml');
      if (await cacheFile.exists()) await cacheFile.delete();
    } catch (_) {}
  }

  Future<void> _writeStringAtomically(File file, String content) async {
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.tmp.${DateTime.now().microsecondsSinceEpoch}',
    );
    await temp.writeAsString(content, flush: true);
    await temp.rename(file.path);
  }
}

/// 手写 HTTP 通道的原始响应
class _RawHttpResponse {
  final int statusCode;
  final Map<String, String> headers;
  final List<int> bodyBytes;
  _RawHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
  });
}
