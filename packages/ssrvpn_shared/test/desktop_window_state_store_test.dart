import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  late Directory tempDirectory;
  late File stateFile;
  late List<String> errors;
  late DesktopWindowStateStore store;

  setUp(() async {
    tempDirectory =
        await Directory.systemTemp.createTemp('desktop_window_state_test_');
    stateFile = File(
      '${tempDirectory.path}${Platform.pathSeparator}window_state.json',
    );
    errors = <String>[];
    store = DesktopWindowStateStore(
      stateFile,
      onError: (message, error, stack) => errors.add(message),
    );
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('desktop defaults use a compact portrait-friendly width', () {
    expect(
      DesktopWindowStateStore.defaultSize,
      const Size(440, 720),
    );
    expect(
      DesktopWindowStateStore.minimumSize,
      const Size(380, 560),
    );
  });

  test('initial portrait bounds fit and center in logical work areas', () {
    for (final area in [
      const Rect.fromLTWH(0, 24, 1920, 1032),
      const Rect.fromLTWH(-1280, 0, 1280, 680),
      const Rect.fromLTWH(0, 0, 400, 600),
      const Rect.fromLTWH(20, 28, 380, 560),
    ]) {
      final bounds = DesktopWindowStateStore.initialBounds(area);
      expect(bounds.center, area.center);
      expect(bounds.width, inInclusiveRange(380, 440));
      expect(bounds.height, inInclusiveRange(560, 720));
      expect(bounds.left, greaterThanOrEqualTo(area.left));
      expect(bounds.top, greaterThanOrEqualTo(area.top));
      expect(bounds.right, lessThanOrEqualTo(area.right));
      expect(bounds.bottom, lessThanOrEqualTo(area.bottom));
    }
    expect(
        DesktopWindowStateStore.initialBounds(
                const Rect.fromLTWH(0, 24, 1920, 1032))
            .size,
        const Size(440, 720));
    expect(() => DesktopWindowStateStore.initialBounds(Rect.zero),
        throwsArgumentError);
  });

  test('round-trips valid bounds through an atomic save', () async {
    const bounds = Rect.fromLTWH(24, 48, 1180, 760);

    await store.save(bounds);

    expect(await store.load(), bounds);
    expect(await File('${stateFile.path}.tmp').exists(), isFalse);
    expect(errors, isEmpty);
  });

  test('overlapping resize saves commit the latest complete bounds', () async {
    final bounds =
        List.generate(30, (i) => Rect.fromLTWH(24.0 + i, 48.0 + i, 440, 720));
    await Future.wait(bounds.map(store.save));
    expect(await store.load(), bounds.last);
    expect(errors, isEmpty);
    expect(await File('${stateFile.path}.tmp').exists(), isFalse);
  });

  test('clear follows pending saves and permits a later save', () async {
    const before = Rect.fromLTWH(1, 2, 440, 720);
    const after = Rect.fromLTWH(3, 4, 440, 720);
    await Future.wait([store.save(before), store.clear()]);
    expect(await store.load(), isNull);
    await store.save(after);
    expect(await store.load(), after);
    expect(errors, isEmpty);
  });

  test('load waits for the latest pending resize', () async {
    const bounds = Rect.fromLTWH(11, 12, 440, 720);
    final write = store.save(bounds);
    expect(await store.load(), bounds);
    await write;
  });

  test('backs up malformed state and returns no bounds', () async {
    await stateFile.writeAsString('{not-json');

    expect(await store.load(), isNull);
    expect(await stateFile.exists(), isFalse);
    expect(
      tempDirectory.listSync().whereType<File>().single.path,
      startsWith('${stateFile.path}.bad-'),
    );
    expect(errors, ['Invalid window state; backing it up']);
  });

  test('migrates legacy wide bounds to the compact desktop width', () async {
    await stateFile.writeAsString(
      '{"schemaVersion":1,"left":100,"top":48,'
      '"width":1180,"height":760}',
    );

    expect(
      await store.load(),
      const Rect.fromLTWH(470, 48, 440, 720),
    );
    expect(
      await stateFile.readAsString(),
      '{"schemaVersion":4,"left":470.0,"top":48.0,'
      '"width":440.0,"height":720.0}',
    );
    expect(errors, isEmpty);
  });

  test('migrates the previous compact schema to the portrait width', () async {
    await stateFile.writeAsString(
      '{"schemaVersion":2,"left":330,"top":48,'
      '"width":720,"height":760}',
    );

    expect(
      await store.load(),
      const Rect.fromLTWH(470, 48, 440, 720),
    );
    expect(
      await stateFile.readAsString(),
      '{"schemaVersion":4,"left":470.0,"top":48.0,'
      '"width":440.0,"height":720.0}',
    );
    expect(errors, isEmpty);
  });

  test('migrates the interim 500px schema to the reference width', () async {
    await stateFile.writeAsString(
      '{"schemaVersion":3,"left":359,"top":54,'
      '"width":500,"height":760}',
    );

    expect(
      await store.load(),
      const Rect.fromLTWH(389, 54, 440, 720),
    );
    expect(
      await stateFile.readAsString(),
      '{"schemaVersion":4,"left":389.0,"top":54.0,'
      '"width":440.0,"height":720.0}',
    );
    expect(errors, isEmpty);
  });

  test('legacy migration preserves a user window narrower than default',
      () async {
    await stateFile.writeAsString(
      '{"schemaVersion":3,"left":359,"top":54,'
      '"width":420,"height":760}',
    );

    expect(
      await store.load(),
      const Rect.fromLTWH(359, 54, 420, 720),
    );
    expect(
      await stateFile.readAsString(),
      '{"schemaVersion":4,"left":359.0,"top":54.0,'
      '"width":420.0,"height":720.0}',
    );
    expect(errors, isEmpty);
  });

  test('ignores bounds smaller than the desktop minimum', () async {
    await store.save(const Rect.fromLTWH(0, 0, 640, 480));

    expect(await stateFile.exists(), isFalse);
  });

  test('clear removes saved state', () async {
    await stateFile.writeAsString('{}');

    await store.clear();

    expect(await stateFile.exists(), isFalse);
  });
}
