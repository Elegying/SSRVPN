import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_frame_pacing.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test('low tier renders sixty frames across display cadences', () {
    for (final hz in [60, 90, 120, 144, 165, 240]) {
      final pacing = SsrvpnFramePacing(binding.platformDispatcher);
      var accepted = 0;
      for (var frame = 0; frame < hz * 10; frame++) {
        if (pacing.acceptFrame(
            Duration(microseconds: (frame * 1000000 / hz).round()))) {
          accepted++;
        }
      }
      expect(accepted, closeTo(600, 1), reason: '$hz Hz');
    }
  });
  test('skipped vsync retains paired callbacks and requests the next frame',
      () {
    final dispatcher = _Dispatcher();
    final events = <String>[];
    void begin(Duration _) => events.add('begin');
    void draw() => events.add('draw');
    dispatcher.onBeginFrame = begin;
    dispatcher.onDrawFrame = draw;
    final pacing = SsrvpnFramePacing(dispatcher)..install();
    for (final micros in [0, 8333, 16667]) {
      dispatcher.onBeginFrame!(Duration(microseconds: micros));
      dispatcher.onDrawFrame!();
    }
    expect(events, ['begin', 'draw', 'begin', 'draw']);
    expect(dispatcher.requests, 1);
    pacing.dispose();
    expect(dispatcher.onBeginFrame, begin);
    expect(dispatcher.onDrawFrame, draw);
  });
  test('idle gaps and timestamp reset do not stall rendering', () {
    final pacing = SsrvpnFramePacing(binding.platformDispatcher);
    expect(pacing.acceptFrame(Duration.zero), isTrue);
    expect(pacing.acceptFrame(const Duration(milliseconds: 8)), isFalse);
    expect(pacing.acceptFrame(const Duration(seconds: 30)), isTrue);
    expect(pacing.acceptFrame(Duration.zero), isTrue);
  });
}

class _Dispatcher extends Fake implements PlatformDispatcher {
  @override
  FrameCallback? onBeginFrame;
  @override
  VoidCallback? onDrawFrame;
  int requests = 0;
  @override
  void scheduleFrame() => requests++;
}
