import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/startup/startup_flags.dart';
import 'package:ssrvpn_windows/startup/startup_logger.dart';
import 'package:ssrvpn_windows/startup/startup_orchestrator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const window = MethodChannel('window_manager');
  const screen = MethodChannel('dev.leanflutter.plugins/screen_retriever');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late StartupOrchestrator orchestrator;
  late List<String> calls;
  late Rect current;
  late List<Rect> areas;
  String? failure;
  Completer<void>? gate;
  Map<String, Object> display(Rect a) => {
        'id': '${a.left}',
        'size': {'width': a.width, 'height': a.height},
        'visiblePosition': {'dx': a.left, 'dy': a.top},
        'visibleSize': {'width': a.width, 'height': a.height},
        'scaleFactor': 1,
      };
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tray-window-');
    await StartupLogger.init(
        verbose: false, fileOverride: File('${directory.path}/startup.log'));
    orchestrator = StartupOrchestrator(StartupFlags.parse([]));
    calls = [];
    failure = null;
    gate = null;
    current = const Rect.fromLTWH(2200, 100, 460, 840);
    areas = [const Rect.fromLTWH(0, 0, 1920, 1040)];
    messenger.setMockMethodCallHandler(window, (c) async {
      calls.add(c.method);
      if (c.method == failure) throw PlatformException(code: 'unavailable');
      if (c.method == 'restore') await gate?.future;
      if (c.method == 'isMinimized') return false;
      if (c.method == 'getBounds') {
        return {
          'x': current.left,
          'y': current.top,
          'width': current.width,
          'height': current.height
        };
      }
      if (c.method == 'setBounds') {
        final a = c.arguments as Map;
        if (a['x'] != null) {
          current = Rect.fromLTWH(a['x'] as double, a['y'] as double,
              a['width'] as double, a['height'] as double);
        }
      }
      return null;
    });
    messenger.setMockMethodCallHandler(screen, (c) async {
      if (failure == 'display') throw PlatformException(code: 'unavailable');
      return c.method == 'getAllDisplays'
          ? {'displays': areas.map(display).toList()}
          : display(areas.first);
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(window, null);
    messenger.setMockMethodCallHandler(screen, null);
    await directory.delete(recursive: true);
  });
  test('removed secondary monitor returns to primary before showing', () async {
    await orchestrator.showWindowFromTray();
    expect(current, const Rect.fromLTWH(730, 100, 460, 840));
    expect(
        calls,
        containsAllInOrder(
            ['restore', 'getBounds', 'setBounds', 'show', 'focus']));
  });
  test('each opening queries fresh monitors and keeps a visible window',
      () async {
    areas.add(const Rect.fromLTWH(1920, 0, 1920, 1040));
    await orchestrator.showWindowFromTray();
    expect(current.left, 2200);
    expect(calls, isNot(contains('setBounds')));
    areas.removeLast();
    await orchestrator.showWindowFromTray();
    expect(current.left, 730);
  });
  test('clipped window fits smaller negative-coordinate work area', () async {
    areas = [const Rect.fromLTWH(-1280, 24, 1280, 680)];
    current = const Rect.fromLTWH(-100, 600, 460, 840);
    await orchestrator.showWindowFromTray();
    expect(current.left, greaterThanOrEqualTo(-1280));
    expect(current.right, lessThanOrEqualTo(0));
    expect(current.top, greaterThanOrEqualTo(24));
    expect(current.bottom, lessThanOrEqualTo(704));
    expect(current.height, 648);
    expect(current.width / current.height, closeTo(460 / 840, .0001));
  });
  test('display failure still attempts sizing and opens window', () async {
    failure = 'display';
    await orchestrator.showWindowFromTray();
    expect(
        calls,
        containsAllInOrder([
          'setMinimumSize',
          'setMaximumSize',
          'setBounds',
          'show',
          'focus'
        ]));
  });
  for (final method in ['restore', 'getBounds', 'setBounds']) {
    test('$method failure still shows and focuses window', () async {
      failure = method;
      await orchestrator.showWindowFromTray();
      expect(calls, containsAllInOrder(['show', 'focus']));
    });
  }
  test('overlapping clicks coalesce and later clicks can retry', () async {
    gate = Completer<void>();
    final first = orchestrator.showWindowFromTray();
    final second = orchestrator.showWindowFromTray();
    expect(identical(first, second), isTrue);
    gate!.complete();
    await Future.wait([first, second]);
    expect(calls.where((c) => c == 'show'), hasLength(1));
    await orchestrator.showWindowFromTray();
    expect(calls.where((c) => c == 'show'), hasLength(2));
  });
}
