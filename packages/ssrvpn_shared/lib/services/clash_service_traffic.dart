part of 'clash_service_base.dart';

extension _ClashTrafficStatistics on ClashServiceBase {
  /// Read proxy-only core totals, including connections that have already closed.
  /// Counters stay in the core while the UI is hidden; no traffic history is saved.
  Future<VpnTrafficSample?> _readTrafficSample() async {
    if (!isRunning) return null;
    final generation = _trafficSessionGeneration;
    final client = _apiClient;
    if (client == null) throw StateError('Core API unavailable');
    final response = await client
        .get(Uri.parse(_apiUrl('/ssrvpn/traffic')), headers: apiHeaders())
        .timeout(const Duration(seconds: 2));
    if (!isRunning || generation != _trafficSessionGeneration) return null;
    if (response.statusCode != 200) {
      throw const FormatException('Core traffic unavailable');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return VpnTrafficSample.fromMap(data);
  }
}
