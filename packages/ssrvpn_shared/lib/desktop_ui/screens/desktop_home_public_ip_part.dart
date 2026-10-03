part of desktop_home_screen;

extension _DesktopHomePublicIpActions on _HomeScreenState {
  bool get _publicIpRefreshBlocked =>
      _isConnecting ||
      (_clashService?.connectionDesired == true &&
          _clashService?.isRunning != true);

  bool _pausePublicIpRefreshIfBlocked() {
    if (!_publicIpRefreshBlocked) return false;
    _publicIpTimer?.cancel();
    if (mounted && !_disposed && _isRefreshingPublicIp) {
      setState(() => _isRefreshingPublicIp = false);
    }
    return true;
  }

  void _schedulePublicIpRefresh() {
    _publicIpTimer?.cancel();
    if (_pausePublicIpRefreshIfBlocked() || !mounted || _disposed) return;
    final generation = ++_publicIpGeneration;
    _publicIpTimer = Timer(Duration.zero, () {
      unawaited(_refreshPublicIpInfo(generation: generation));
    });
  }

  Future<void> _refreshPublicIpInfo({
    int? generation,
    bool retried = false,
  }) async {
    if (_pausePublicIpRefreshIfBlocked() || !mounted || _disposed) return;
    final connected = _isConnected;
    final effectiveGeneration = generation ?? ++_publicIpGeneration;
    _publicIpTimer?.cancel();
    setState(() {
      _isRefreshingPublicIp = true;
      _publicIpError = null;
    });

    try {
      final info =
          await context.read<ClashService>().fetchCurrentPublicIpInfo();
      if (!mounted ||
          _disposed ||
          effectiveGeneration != _publicIpGeneration ||
          connected != _isConnected ||
          _pausePublicIpRefreshIfBlocked()) {
        return;
      }
      setState(() {
        _publicIpInfo = info;
        _publicIpError = null;
        _isRefreshingPublicIp = false;
      });
    } catch (e) {
      AppLogger.warning('PublicIP', '获取公网 IP 失败: $e');
      if (!mounted ||
          _disposed ||
          effectiveGeneration != _publicIpGeneration ||
          connected != _isConnected ||
          _pausePublicIpRefreshIfBlocked()) {
        return;
      }
      if (!retried) {
        // One bounded retry for startup/transient request failures. A new
        // session, node selection or manual refresh invalidates this timer.
        _publicIpTimer = Timer(const Duration(seconds: 2), () {
          if (effectiveGeneration != _publicIpGeneration ||
              connected != _isConnected ||
              _pausePublicIpRefreshIfBlocked()) return;
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
    _schedulePublicIpRefresh();
  }
}
