import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/account_usage.dart';
import 'account_usage_provider.dart';

class UsageQueryFailure implements Exception {
  const UsageQueryFailure([this.retryAfter]);
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
      throw UsageQueryFailure(_retryAfter(response));
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
