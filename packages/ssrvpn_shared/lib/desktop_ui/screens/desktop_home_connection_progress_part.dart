part of desktop_home_screen;

extension _DesktopHomeConnectionProgress on _HomeScreenState {
  bool _isConnectionTransitionActive(ClashService service) =>
      _isConnecting || (!service.isRunning && service.connectionDesired);

  void _detachConnectionProgress() => _clashService
      ?.removeConnectionProgressListener(_connectionProgressListener);

  void _attachConnectionProgress(ClashService service) {
    _detachConnectionProgress();
    service.addConnectionProgressListener(_connectionProgressListener);
  }

  void _handleConnectionProgress() {
    final service = _clashService;
    if (_canUpdateUi &&
        service != null &&
        _isConnectionTransitionActive(service)) {
      setState(() {});
    }
  }

  String? _connectionProgressText(ClashService service) {
    if (!_isConnectionTransitionActive(service)) return null;
    return service.connectionDesired
        ? service.connectionProgress ?? '正在准备连接…'
        : '正在结束连接，请稍候…';
  }
}
