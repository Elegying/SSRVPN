import 'dart:ui';

/// Application-wide low-tier pacing on the engine's own vsync clock. No timer,
/// altered animation speed, global display-mode change or synthetic timestamps.
class SsrvpnFramePacing {
  SsrvpnFramePacing(this.dispatcher);
  final PlatformDispatcher dispatcher;
  double? _nextMicros;
  double? _previousMicros;
  bool _skip = false;
  bool _installed = false;
  bool get isInstalled => _installed;
  FrameCallback? _begin;
  VoidCallback? _draw;

  void install() {
    if (_installed ||
        dispatcher.onBeginFrame == null ||
        dispatcher.onDrawFrame == null) {
      return;
    }
    _installed = true;
    _begin = dispatcher.onBeginFrame;
    _draw = dispatcher.onDrawFrame;
    dispatcher.onBeginFrame = _onBegin;
    dispatcher.onDrawFrame = _onDraw;
  }

  void _onBegin(Duration timestamp) {
    _skip = !acceptFrame(timestamp);
    if (!_skip) _begin?.call(timestamp);
  }

  /// The small tolerance accommodates nominal 59.94/119.88 Hz display clocks.
  bool acceptFrame(Duration timestamp) {
    final now = timestamp.inMicroseconds.toDouble();
    if (_previousMicros != null && now < _previousMicros!) _nextMicros = null;
    _previousMicros = now;
    final next = _nextMicros;
    if (next != null && now < next - 500) {
      return false;
    }
    const interval = 1000000 / 60;
    _nextMicros = next == null || now > next + interval
        ? now + interval
        : next + interval;
    return true;
  }

  void _onDraw() {
    if (_skip) {
      // SchedulerBinding still owns the pending frame: leave its callbacks
      // queued, and request the next vsync directly without scheduling twice.
      dispatcher.scheduleFrame();
    } else {
      _draw?.call();
    }
  }

  void dispose() {
    if (!_installed) return;
    dispatcher.onBeginFrame = _begin;
    dispatcher.onDrawFrame = _draw;
    _installed = false;
    _nextMicros = null;
    _previousMicros = null;
  }
}
