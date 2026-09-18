part of desktop_home_screen;

extension _DesktopHomePublicIpActions on _HomeScreenState {
  void _schedulePublicIpRefresh() {
    _publicIpTimer?.cancel();
    if (!_isConnected || _isConnecting || !mounted || _disposed) return;
    final generation = ++_publicIpGeneration;
    _publicIpTimer = Timer(Duration.zero, () {
      unawaited(_refreshPublicIpInfo(generation: generation));
    });
  }

  Future<void> _refreshPublicIpInfo({
    int? generation,
    bool retried = false,
  }) async {
    if (!_isConnected || _isConnecting || !mounted || _disposed) return;
    final effectiveGeneration = generation ?? ++_publicIpGeneration;
    _publicIpTimer?.cancel();
    setState(() {
      _isRefreshingPublicIp = true;
      _publicIpError = null;
    });

    try {
      final info =
          await context.read<ClashService>().fetchCurrentPublicIpInfo();
      if (!mounted || _disposed || effectiveGeneration != _publicIpGeneration) {
        return;
      }
      setState(() {
        _publicIpInfo = info;
        _publicIpError = null;
        _isRefreshingPublicIp = false;
      });
    } catch (e) {
      AppLogger.warning('PublicIP', '获取公网 IP 失败: $e');
      if (!mounted || _disposed || effectiveGeneration != _publicIpGeneration) {
        return;
      }
      if (!_isConnected || _isConnecting) return;
      if (!retried) {
        // One bounded retry for startup/transient request failures. A new
        // session, node selection or manual refresh invalidates this timer.
        _publicIpTimer = Timer(const Duration(seconds: 2), () {
          if (effectiveGeneration != _publicIpGeneration) return;
          unawaited(_refreshPublicIpInfo(
              generation: effectiveGeneration, retried: true));
        });
        return;
      }
      setState(() {
        _publicIpError = 'IP 暂未查到，点击重试';
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
