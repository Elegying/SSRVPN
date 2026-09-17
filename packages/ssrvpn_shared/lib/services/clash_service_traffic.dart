part of 'clash_service_base.dart';

extension _ClashTrafficStatistics on ClashServiceBase {
  Future<bool> _readRecentIPv6TargetFailure() async {
    final client = apiClient;
    if (!isRunning || client == null) return false;
    final generation = _trafficSessionGeneration;
    final abort = Completer<void>();
    try {
      final request = http.AbortableRequest(
          'GET', Uri.parse(_apiUrl('/ssrvpn/traffic')),
          abortTrigger: abort.future)
        ..headers.addAll(apiHeaders())
        ..followRedirects = false;
      final response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 2));
      if (!isRunning ||
          generation != _trafficSessionGeneration ||
          response.statusCode != 200) {
        return false;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final count = data['ipv6TargetFailures'];
      final age = data['ipv6LastFailureAgoMillis'];
      return count is int &&
          count > 0 &&
          age is int &&
          age >= 0 &&
          age <= 60000;
    } catch (_) {
      // Older cores and unavailable observations must not mark a node broken.
      return false;
    } finally {
      abort.complete();
    }
  }

  /// Read proxy-only core totals, including connections that have already closed.
  /// Counters stay in the core while the UI is hidden; no traffic history is saved.
  Future<VpnTrafficSample?> _readTrafficSample() async {
    if (!isRunning) return null;
    final generation = _trafficSessionGeneration;
    final client = _apiClient;
    if (client == null) throw StateError('Core API unavailable');
    final abort = Completer<void>();
    try {
      final request = http.AbortableRequest(
          'GET', Uri.parse(_apiUrl('/ssrvpn/traffic')),
          abortTrigger: abort.future)
        ..headers.addAll(apiHeaders())
        ..followRedirects = false;
      final response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 2));
      if (!isRunning || generation != _trafficSessionGeneration) return null;
      if (response.statusCode != 200) {
        throw const FormatException('Core traffic unavailable');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return VpnTrafficSample.fromMap(data);
    } finally {
      // Sampling repeats while the home page is visible. A timeout must also
      // release its socket instead of accumulating one stalled request per poll.
      abort.complete();
    }
  }
}
