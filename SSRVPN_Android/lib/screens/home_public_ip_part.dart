part of 'home_screen.dart';

extension _AndroidHomePublicIpActions on HomeScreenState {
  void _schedulePublicIpRefresh() {
    _publicIpTimer?.cancel();
    if (!_isConnected || _isConnecting || !mounted || _disposed) return;
    final generation = ++_publicIpGeneration;
    _publicIpTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_refreshPublicIpInfo(generation: generation));
    });
  }

  Future<void> _refreshPublicIpInfo({int? generation}) async {
    if (!_isConnected || _isConnecting || !mounted || _disposed) return;
    final effectiveGeneration = generation ?? ++_publicIpGeneration;
    _publicIpTimer?.cancel();
    _updateHomeState(() {
      _isRefreshingPublicIp = true;
      _publicIpError = null;
    });

    try {
      final info =
          await context.read<ClashService>().fetchCurrentPublicIpInfo();
      if (!mounted || _disposed || effectiveGeneration != _publicIpGeneration) {
        return;
      }
      _updateHomeState(() {
        _publicIpInfo = info;
        _publicIpError = null;
        _isRefreshingPublicIp = false;
      });
    } catch (e) {
      AppLogger.warning('PublicIP', '获取公网 IP 失败: $e');
      if (!mounted || _disposed || effectiveGeneration != _publicIpGeneration) {
        return;
      }
      _updateHomeState(() {
        _publicIpError = '获取失败';
        _isRefreshingPublicIp = false;
      });
    }
  }

  void _resetPublicIpState() {
    _publicIpTimer?.cancel();
    _publicIpGeneration++;
    _publicIpInfo = null;
    _isRefreshingPublicIp = false;
    _publicIpError = null;
  }
}
