enum ConnectionPhase {
  queued('连接排队与设置同步'),
  ports('检查连接端口'),
  config('生成节点和分流规则'),
  write('保存内部运行配置'),
  preparation('检查启动条件'),
  cleanup('检查并清理上次运行资源'),
  process('启动连接服务'),
  readiness('等待本地服务和规则就绪'),
  authorization('系统授权与提权交接'),
  nativeStartup('原生 VPN 启动（含授权等待）'),
  proxy('提交系统代理'),
  recoveryRecord('保存网络恢复信息'),
  restore('恢复上次网络设置'),
  node('应用所选节点');

  const ConnectionPhase(this.label);
  final String label;
}

enum ConnectionTimingOutcome {
  advanced,
  localReady,
  notCompleted,
  replaced,
  disposed
}

/// Only owned, fixed progress messages enter diagnostics; never node names,
/// credentials, paths or arbitrary platform text. Unknown messages still work
/// in the UI but cannot become a diagnostic field.
const _progressPhases = <String, ConnectionPhase>{
  '正在检查连接端口…': ConnectionPhase.ports,
  '正在准备节点和分流规则…': ConnectionPhase.config,
  '正在保存本次连接设置…': ConnectionPhase.write,
  '正在检查连接设置…': ConnectionPhase.preparation,
  '正在检查上次运行资源…': ConnectionPhase.cleanup,
  '正在启动连接服务…': ConnectionPhase.process,
  '正在等待连接服务和分流规则就绪…': ConnectionPhase.readiness,
  '正在请求系统授权，请留意授权弹窗…': ConnectionPhase.authorization,
  '正在启用 VPN，等待分流规则就绪…': ConnectionPhase.readiness,
  '正在启用 VPN，请留意系统授权弹窗…': ConnectionPhase.nativeStartup,
  '正在设置系统代理…': ConnectionPhase.proxy,
  '连接服务已就绪，正在保存网络恢复信息…': ConnectionPhase.recoveryRecord,
  '正在恢复上次的网络设置…': ConnectionPhase.restore,
  '正在应用所选节点…': ConnectionPhase.node,
};

/// An in-memory, monotonic trace with no timers or I/O.
/// The existing bounded/redacted service logger owns retention and delivery.
class ConnectionPhaseTrace {
  ConnectionPhaseTrace({
    required this.attempt,
    required this.emit,
    Duration Function()? clock,
  }) : _clock = clock;

  final int attempt;
  final void Function(String) emit;
  final Duration Function()? _clock;
  final Stopwatch _watch = Stopwatch()..start();
  ConnectionPhase _phase = ConnectionPhase.queued;
  int _phaseStartedAt = 0;
  int _lastElapsed = 0;
  bool _finished = false;
  final List<String> _samples = [];
  ConnectionTimingOutcome? _outcome;

  /// Only the latest attempt is retained by the service. Bound even a broken
  /// caller that alternates phases indefinitely, independently of log limits.
  String get summary {
    final state = switch (_outcome) {
      ConnectionTimingOutcome.localReady => '本地服务已就绪',
      ConnectionTimingOutcome.replaced => '已被新的连接请求替代',
      ConnectionTimingOutcome.disposed => '客户端会话已结束',
      ConnectionTimingOutcome.notCompleted => '本地连接未完成',
      _ => '连接仍在进行',
    };
    final elapsed = _elapsed();
    final current =
        _finished ? '' : '；当前${_phase.label} ${elapsed - _phaseStartedAt}ms';
    return '第 $attempt 次连接记录：$state；累计 ${elapsed}ms$current。'
        '${_samples.isEmpty ? '' : '${_samples.join('；')}。'}'
        '本地就绪不代表外网已验证；TUN 创建、路由和规则等待可能包含在同一阶段，不能视为纯网卡创建耗时。';
  }

  int _elapsed() {
    if (_finished) return _lastElapsed;
    final value = (_clock?.call() ?? _watch.elapsed).inMilliseconds;
    if (value > _lastElapsed) _lastElapsed = value;
    return _lastElapsed;
  }

  void progress(String message) {
    final phase = _progressPhases[message];
    if (_finished || phase == null || phase == _phase) return;
    final previous = _phase;
    final startedAt = _phaseStartedAt;
    final elapsed = _elapsed();
    _phase = phase;
    _phaseStartedAt = elapsed;
    _write(previous, elapsed - startedAt, elapsed,
        ConnectionTimingOutcome.advanced);
  }

  void finish(ConnectionTimingOutcome outcome) {
    if (_finished) return;
    final elapsed = _elapsed();
    _finished = true;
    _outcome = outcome;
    _watch.stop();
    _write(_phase, elapsed - _phaseStartedAt, elapsed, outcome);
  }

  void _write(ConnectionPhase phase, int duration, int total,
      ConnectionTimingOutcome outcome) {
    if (_samples.length == 32) _samples.removeAt(0);
    _samples.add('${phase.label} ${duration}ms');
    try {
      emit('连接阶段：${phase.label}；耗时 ${duration}ms；累计 ${total}ms；'
          'attempt=$attempt outcome=${outcome.name}');
    } catch (_) {
      // Diagnostics cannot change startup/cancellation if a log sink fails.
    }
  }
}
