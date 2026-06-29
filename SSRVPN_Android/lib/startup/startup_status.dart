/// 启动流程状态追踪
class StartupStatus {
  final List<_StepRecord> _steps = [];
  DateTime? _startTime;
  DateTime? _endTime;
  bool _complete = false;
  String? _error;

  StartupStatus();

  void start() {
    _startTime = DateTime.now();
  }

  void recordStep(String phase, String detail, {bool failed = false}) {
    _steps.add(_StepRecord(
      phase: phase,
      detail: detail,
      timestamp: DateTime.now(),
      failed: failed,
      elapsed: _startTime != null
          ? DateTime.now().difference(_startTime!).inMilliseconds
          : null,
    ));
    if (failed) {
      _error = '$phase: $detail';
    }
  }

  void complete() {
    _endTime = DateTime.now();
    _complete = true;
  }

  void fail(String error) {
    _error = error;
    _endTime = DateTime.now();
    _complete = true;
  }

  bool get isComplete => _complete;
  String? get error => _error;

  Duration? get totalDuration {
    if (_startTime == null) return null;
    return (_endTime ?? DateTime.now()).difference(_startTime!);
  }

  List<_StepRecord> get steps => List.unmodifiable(_steps);

  @override
  String toString() {
    final buffer = StringBuffer()
      ..writeln('=== SSRVPN 启动状态 ===')
      ..writeln('总耗时: ${totalDuration?.inMilliseconds ?? "N/A"}ms')
      ..writeln('状态: ${_complete ? (_error != null ? "失败" : "完成") : "进行中"}');
    if (_error != null) {
      buffer.writeln('错误: $_error');
    }
    for (final step in _steps) {
      final icon = step.failed ? '❌' : '✅';
      buffer.writeln(
          '  $icon [${step.elapsed ?? 0}ms] ${step.phase}: ${step.detail}');
    }
    return buffer.toString();
  }
}

class _StepRecord {
  final String phase;
  final String detail;
  final DateTime timestamp;
  final bool failed;
  final int? elapsed;

  const _StepRecord({
    required this.phase,
    required this.detail,
    required this.timestamp,
    required this.failed,
    this.elapsed,
  });
}
