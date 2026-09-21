part of 'clash_service.dart';

/// 记录 Android 最近一次数据面观察完成的时间，供诊断页说明结论新鲜度。
///
/// 诊断页读的是**缓存告警**而不是重新探测：完整探测最坏约 41 秒
/// （6 次尝试 × 6 秒超时 + 5 次 1 秒间隔），远超诊断检查 10 秒的预算。
/// 既然无法在诊断时刷新，就必须把观察时间一并说出来，否则用户无法判断
/// 「暂未通过」是当前状态还是几十秒前的旧状态。桌面两端各自记录时间戳，
/// Android 此前没有，同一句话在手机上因此缺少新鲜度信息。
///
/// 独立成 mixin 而不是直接写进 [ClashService]：`clash_service.dart` 受
/// 850 行架构边界约束（当前 832 行），按守卫要求新增职责应当离开该文件。
mixin _AndroidDataPlaneObservationClock on ClashServiceBase {
  DateTime? _lastDataPlaneObservationAt;

  @override
  @protected
  DateTime? get dataPlaneObservationAt => _lastDataPlaneObservationAt;

  /// 会话失效（断开、换路由、换配置）时共享层会一并清空告警，
  /// 此时留下旧时间戳会让「没有结论」看起来像「刚看过」。
  @override
  @protected
  void onDataPlaneObservationSessionReset() {
    _lastDataPlaneObservationAt = null;
  }

  /// 观察完成且会话仍然有效时才记录，与 macOS 的记录时机一致。
  @protected
  void recordDataPlaneObservation() {
    _lastDataPlaneObservationAt = DateTime.now();
  }
}
