import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/account_usage.dart';
import 'account_usage_provider.dart';

enum UsageFailureKind {
  timeout,
  network,
  certificate,
  rejected,
  invalidResponse,
  unavailable,
  deviceLimit,
  nodeMaintenance
}

class UsageQueryFailure implements Exception {
  const UsageQueryFailure([this.retryAfter])
      : kind = UsageFailureKind.unavailable;
  const UsageQueryFailure.reason(this.kind, {this.retryAfter});
  final UsageFailureKind kind;
  String get userMessage => switch (kind) {
        UsageFailureKind.deviceLimit =>
          '设备数达到上限，请断开其他设备后重试 [DEVICE_LIMIT_REACHED]',
        UsageFailureKind.nodeMaintenance =>
          '节点维护中，请稍后重试或手动选择其他节点 [NODE_MAINTENANCE]',
        UsageFailureKind.timeout => '统计服务响应较慢，将自动重试',
        UsageFailureKind.network => '暂时连不上统计服务，将自动重试',
        UsageFailureKind.certificate => '无法确认统计服务身份，请稍后重试',
        UsageFailureKind.rejected => '统计服务暂未提供数据，将自动重试',
        UsageFailureKind.invalidResponse => '统计数据暂不可用，将自动重试',
        UsageFailureKind.unavailable => '账号统计暂未更新，将自动重试',
      };
  final Duration? retryAfter;
}

/// Independent HTTPS client: normal OS routing/TUN, never starts or reconfigures VPN.
class AccountUsageClient {
  const AccountUsageClient(
      {this.createClient,
      this.localProxyPort,
      this.timeout = const Duration(seconds: 8)});
  final HttpClient Function()? createClient;
  final Duration timeout;
  final int? Function()? localProxyPort;

  Future<AccountUsage> fetch(UsageIdentity identity) async {
    final client = (createClient?.call() ?? HttpClient())
      ..connectionTimeout = timeout;
    Duration? serverRetryAfter;
    try {
      final port = localProxyPort?.call();
      if (port != null && (port < 1 || port > 65535)) {
        throw const UsageQueryFailure();
      }
      client.findProxy =
          (_) => port == null ? 'DIRECT' : 'PROXY 127.0.0.1:$port';
      return await _read(client, identity, (value) => serverRetryAfter = value)
          .timeout(timeout);
    } on UsageQueryFailure catch (error) {
      throw UsageQueryFailure.reason(error.kind,
          retryAfter: error.retryAfter ?? serverRetryAfter);
    } on TimeoutException {
      throw UsageQueryFailure.reason(UsageFailureKind.timeout,
          retryAfter: serverRetryAfter);
    } on TlsException {
      throw UsageQueryFailure.reason(UsageFailureKind.certificate,
          retryAfter: serverRetryAfter);
    } on SocketException {
      throw UsageQueryFailure.reason(UsageFailureKind.network,
          retryAfter: serverRetryAfter);
    } on FormatException {
      throw UsageQueryFailure.reason(UsageFailureKind.invalidResponse,
          retryAfter: serverRetryAfter);
    } catch (_) {
      throw UsageQueryFailure(serverRetryAfter);
    } finally {
      // A timed-out response/body cannot leave an overlapping request alive.
      client.close(force: true);
    }
  }

  Future<AccountUsage> _read(HttpClient client, UsageIdentity identity,
      void Function(Duration?) rememberRetryAfter) async {
    final request = await client.getUrl(identity.endpoint);
    request.followRedirects = false;
    request.headers
        .set(HttpHeaders.authorizationHeader, identity.authorization);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache, no-store');
    final host = _maintenanceHost(identity.nodeHost);
    if (host != null) {
      request.headers.set('X-SSRVPN-Node-Host', host);
      request.headers.set('X-SSRVPN-Node-Port', identity.nodePort.toString());
    }
    final response = await request.close();
    final retryAfter = _retryAfter(response);
    // The total request deadline can expire while reading a response body.
    // Keep the trusted server's retry budget even when that body is unusable.
    rememberRetryAfter(retryAfter);
    // Do not consume a cache replay or unbounded response. TLS validation stays default.
    final age = response.headers.value('age');
    if (age != null && (int.tryParse(age) ?? 1) != 0) {
      throw const UsageQueryFailure();
    }
    if (response.contentLength > 32768) throw const UsageQueryFailure();
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > 32768) throw const UsageQueryFailure();
    }
    Object? body;
    try {
      body = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      if (response.statusCode == 200) rethrow;
    }
    if (body is Map<String, dynamic> &&
        body['apiVersion'] is int &&
        body['apiVersion'] == 1 &&
        body['error'] is Map<String, dynamic>) {
      final kind = switch ((body['error'] as Map<String, dynamic>)['code']) {
        'DEVICE_LIMIT_REACHED' => UsageFailureKind.deviceLimit,
        'NODE_MAINTENANCE' => UsageFailureKind.nodeMaintenance,
        _ => UsageFailureKind.rejected,
      };
      throw UsageQueryFailure.reason(kind, retryAfter: retryAfter);
    }
    if (response.statusCode != 200) {
      throw UsageQueryFailure.reason(UsageFailureKind.rejected,
          retryAfter: retryAfter);
    }
    return AccountUsage.parse(body);
  }

  Duration? _retryAfter(HttpClientResponse response) {
    final value = response.headers.value(HttpHeaders.retryAfterHeader);
    if (value == null) return null;
    final seconds = int.tryParse(value);
    if (seconds != null && seconds >= 0 && seconds <= 2147483647) {
      return Duration(seconds: seconds);
    }
    try {
      final date = response.headers.date;
      if (date == null) return null;
      final delay = HttpDate.parse(value).difference(date);
      return delay.isNegative ? Duration.zero : delay;
    } catch (_) {
      return null;
    }
  }

  // Optional evidence must not break legacy statistics for a host spelling the
  // status extension cannot interpret. No DNS resolution or origin expansion.
  String? _maintenanceHost(String value) {
    final host = value.startsWith('[') && value.endsWith(']')
        ? value.substring(1, value.length - 1)
        : value;
    if (host.length > 253) return null;
    if (InternetAddress.tryParse(host) != null) return host;
    return RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
                r'(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$')
            .hasMatch(host)
        ? host
        : null;
  }
}
