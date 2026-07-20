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

  test('round-trips valid bounds through an atomic save', () async {
    const bounds = Rect.fromLTWH(24, 48, 1180, 760);

    await store.save(bounds);

    expect(await store.load(), bounds);
    expect(await File('${stateFile.path}.tmp').exists(), isFalse);
    expect(errors, isEmpty);
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
