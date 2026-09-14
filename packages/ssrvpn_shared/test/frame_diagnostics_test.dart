import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_frame_diagnostics.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_liquid_glass.dart';

void main() {
  testWidgets('foreground diagnostics discard frames collected before pause',
      (tester) async {
    final messages = <String>[];
    final originalPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message?.startsWith('SSRVPN_FRAME ') ?? false) messages.add(message!);
    };
    try {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
          wrapSsrvpnLiquidGlass(const MaterialApp(home: Text('诊断'))));
      final frame = FrameTiming(
        vsyncStart: 0,
        buildStart: 0,
        buildFinish: 1000,
        rasterStart: 1000,
        rasterFinish: 2000,
        rasterFinishWallTime: 2000,
      );
      void report(int count) =>
          tester.binding.platformDispatcher.onReportTimings
              ?.call(List.filled(count, frame));
      expect(tester.binding.platformDispatcher.onReportTimings, isNotNull);
      report(239);
      expect(messages, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      report(240);
      expect(messages, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      report(1);
      expect(messages, isEmpty);
      report(239);
      expect(messages, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    } finally {
      debugPrint = originalPrint;
    }
  }, skip: !SsrvpnFrameDiagnostics.enabled);

  test('diagnostics distinguish consecutive stalls and the configured budget',
      () {
    final frames = List.generate(100, (i) {
      final build = i == 10 ? 25000 : 1000;
      final raster = i >= 11 && i <= 13 ? 30000 : 10000;
      final start = i * 16667;
      return FrameTiming(
        vsyncStart: start,
        buildStart: start,
        buildFinish: start + build,
        rasterStart: start + build,
        rasterFinish: start + build + raster,
        rasterFinishWallTime: start + build + raster,
      );
    });
    final result = SsrvpnFrameDiagnostics.summarizeFrames(frames,
        refreshRate: 120, targetFps: 60);
    expect(result['overBudgetFrames'], 4);
    expect(result['maxConsecutiveOverBudgetFrames'], 4);
    expect(result['buildP95Ms'], 1);
    expect(result['buildP99Ms'], 25);
    expect(result['rasterP95Ms'], 10);
    expect(result['rasterP99Ms'], 30);
    expect(result['buildMaxMs'], 25);
    expect(result['rasterMaxMs'], 30);
    expect(result['producedFps'], closeTo(60, .01));
    final highRefresh =
        SsrvpnFrameDiagnostics.summarizeFrames(frames, refreshRate: 120);
    expect(highRefresh['overBudgetFrames'], 100);
    expect(highRefresh['maxConsecutiveOverBudgetFrames'], 100);
    final nextWindow =
        SsrvpnFrameDiagnostics.summarizeFrames([frames.last], refreshRate: 60);
    expect(nextWindow['maxConsecutiveOverBudgetFrames'], 0);
    expect(nextWindow['producedFps'], 0);
  });
}
