import 'dart:convert';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Opt-in acceptance instrumentation. Never records screen content or nodes.
class SsrvpnFrameDiagnostics {
  final _frames = <FrameTiming>[];
  bool _started = false;
  double _refreshRate = 60;
  double get refreshRate => _refreshRate;
  set refreshRate(double value) {
    if (!value.isFinite || value <= 0) return;
    if ((value - _refreshRate).abs() > .5) _frames.clear();
    _refreshRate = value;
  }

  double? _targetFps;
  set targetFps(double? value) {
    if (_targetFps != value) _frames.clear();
    _targetFps = value;
  }

  static const enabled = bool.fromEnvironment('SSRVPN_FRAME_DIAGNOSTICS');
  void start() {
    if (!enabled || _started) return;
    SchedulerBinding.instance.addTimingsCallback(_collect);
    _started = true;
  }

  void stop() {
    if (_started) {
      SchedulerBinding.instance.removeTimingsCallback(_collect);
      _started = false;
    }
    _frames.clear();
  }

  void _collect(List<FrameTiming> timings) {
    _frames.addAll(timings);
    if (_frames.length < 240) return;
    debugPrint('SSRVPN_FRAME ${jsonEncode(summarizeFrames(
      _frames,
      refreshRate: refreshRate,
      targetFps: _targetFps,
    ))}');
    _frames.clear();
  }

  /// Preparation-time diagnostics, not measured display presentation latency.
  @visibleForTesting
  static Map<String, num> summarizeFrames(List<FrameTiming> frames,
      {required double refreshRate, double? targetFps}) {
    assert(frames.isNotEmpty);
    final build = frames
        .map((f) => f.buildDuration.inMicroseconds / 1000)
        .toList()
      ..sort();
    final raster = frames
        .map((f) => f.rasterDuration.inMicroseconds / 1000)
        .toList()
      ..sort();
    final budget = 1000 / (targetFps ?? refreshRate);
    var overBudget = 0;
    var streak = 0;
    var longestStreak = 0;
    for (final frame in frames) {
      if (frame.buildDuration.inMicroseconds / 1000 > budget ||
          frame.rasterDuration.inMicroseconds / 1000 > budget) {
        overBudget++;
        streak++;
        if (streak > longestStreak) longestStreak = streak;
      } else {
        streak = 0;
      }
    }
    final elapsed =
        (frames.last.timestampInMicroseconds(FramePhase.vsyncStart) -
                frames.first.timestampInMicroseconds(FramePhase.vsyncStart)) /
            1000000;
    return {
      'count': frames.length,
      'displayHz': refreshRate,
      'targetFps': targetFps ?? refreshRate,
      'producedFps': elapsed > 0 ? (frames.length - 1) / elapsed : 0,
      'buildP95Ms': build[(build.length * .95).floor()],
      'rasterP95Ms': raster[(raster.length * .95).floor()],
      'buildP99Ms': build[(build.length * .99).floor()],
      'rasterP99Ms': raster[(raster.length * .99).floor()],
      'buildMaxMs': build.last,
      'rasterMaxMs': raster.last,
      'overBudgetFrames': overBudget,
      // Runs are bounded by this diagnostic window, not across app pauses.
      'maxConsecutiveOverBudgetFrames': longestStreak,
    };
  }
}
