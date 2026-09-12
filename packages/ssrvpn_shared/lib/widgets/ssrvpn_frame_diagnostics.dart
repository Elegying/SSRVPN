import 'dart:convert';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Opt-in acceptance instrumentation. Never records screen content or nodes.
class SsrvpnFrameDiagnostics {
  final _frames = <FrameTiming>[];
  double refreshRate = 60;
  static const enabled = bool.fromEnvironment('SSRVPN_FRAME_DIAGNOSTICS');
  void start() {
    if (enabled) SchedulerBinding.instance.addTimingsCallback(_collect);
  }

  void stop() {
    if (enabled) SchedulerBinding.instance.removeTimingsCallback(_collect);
    _frames.clear();
  }

  void _collect(List<FrameTiming> timings) {
    _frames.addAll(timings);
    if (_frames.length < 240) return;
    final build = _frames
        .map((f) => f.buildDuration.inMicroseconds / 1000)
        .toList()
      ..sort();
    final raster = _frames
        .map((f) => f.rasterDuration.inMicroseconds / 1000)
        .toList()
      ..sort();
    final budget = 1000 / refreshRate;
    final elapsed =
        (_frames.last.timestampInMicroseconds(FramePhase.vsyncStart) -
                _frames.first.timestampInMicroseconds(FramePhase.vsyncStart)) /
            1000000;
    final overBudget = _frames
        .where((f) =>
            f.buildDuration.inMicroseconds / 1000 > budget ||
            f.rasterDuration.inMicroseconds / 1000 > budget)
        .length;
    debugPrint('SSRVPN_FRAME ${jsonEncode({
          'count': _frames.length,
          'displayHz': refreshRate,
          'producedFps': elapsed > 0 ? (_frames.length - 1) / elapsed : 0,
          'buildP95Ms': build[(build.length * .95).floor()],
          'rasterP95Ms': raster[(raster.length * .95).floor()],
          'overBudgetFrames': overBudget,
        })}');
    _frames.clear();
  }
}
