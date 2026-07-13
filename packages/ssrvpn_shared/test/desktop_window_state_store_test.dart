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
    stateFile = File('${tempDirectory.path}/window_state.json');
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
