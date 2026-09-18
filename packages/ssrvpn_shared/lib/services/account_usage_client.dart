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
  unavailable
}

class UsageQueryFailure implements Exception {
  const UsageQueryFailure([this.retryAfter])
      : kind = UsageFailureKind.unavailable;
  const UsageQueryFailure.reason(this.kind, {this.retryAfter});
  final UsageFailureKind kind;
  String get userMessage => switch (kind) {
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
    try {
      final port = localProxyPort?.call();
      if (port != null && (port < 1 || port > 65535)) {
        throw const UsageQueryFailure();
      }
      client.findProxy =
          (_) => port == null ? 'DIRECT' : 'PROXY 127.0.0.1:$port';
      return await _read(client, identity).timeout(timeout);
    } on UsageQueryFailure {
      rethrow;
    } on TimeoutException {
      throw const UsageQueryFailure.reason(UsageFailureKind.timeout);
    } on TlsException {
      throw const UsageQueryFailure.reason(UsageFailureKind.certificate);
    } on SocketException {
      throw const UsageQueryFailure.reason(UsageFailureKind.network);
    } on FormatException {
      throw const UsageQueryFailure.reason(UsageFailureKind.invalidResponse);
    } catch (_) {
      throw const UsageQueryFailure();
    } finally {
      // A timed-out response/body cannot leave an overlapping request alive.
      client.close(force: true);
    }
  }

  Future<AccountUsage> _read(HttpClient client, UsageIdentity identity) async {
    final request = await client.getUrl(identity.endpoint);
    request.followRedirects = false;
    request.headers
        .set(HttpHeaders.authorizationHeader, identity.authorization);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache, no-store');
    final response = await request.close();
    if (response.statusCode != 200) {
      throw UsageQueryFailure.reason(UsageFailureKind.rejected,
          retryAfter: _retryAfter(response));
    }
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
    return AccountUsage.parse(jsonDecode(utf8.decode(bytes)));
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
}
