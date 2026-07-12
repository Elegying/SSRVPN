import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('bounded-file-log-test');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('bounds a burst while one drain owns all writes', () async {
    final file = File('${temp.path}/ssrvpn.log');
    final logger = BoundedFileLogger(
      file,
      maxFileBytes: 1024,
      maxPendingBytes: 256,
    );

    for (var index = 0; index < 500; index++) {
      logger.add('entry-$index-${'x' * 32}\n');
    }
    await logger.flush();

    expect(await file.length(), lessThanOrEqualTo(1024));
    final combined = [
      if (await File('${file.path}.old').exists())
        await File('${file.path}.old').readAsString(),
      await file.readAsString(),
    ].join();
    expect(combined, contains('entry-499'));
    expect(combined, contains('dropped'));
  });

  test('rotates during runtime before the active file exceeds its limit',
      () async {
    final file = File('${temp.path}/ssrvpn.log');
    await file.writeAsString('a' * 900);
    final logger = BoundedFileLogger(
      file,
      maxFileBytes: 1024,
      maxPendingBytes: 256,
    );

    logger.add('${'b' * 200}\n');
    await logger.flush();

    expect(await File('${file.path}.old').length(), 900);
    expect(await file.length(), lessThanOrEqualTo(1024));
    expect(await file.readAsString(), contains('b' * 100));
  });

  test('truncates a single oversized entry without invalid UTF-8', () async {
    final file = File('${temp.path}/ssrvpn.log');
    final logger = BoundedFileLogger(
      file,
      maxFileBytes: 1024,
      maxPendingBytes: 128,
    );

    logger.add('${'测试' * 500}\n');
    await logger.flush();

    final text = await file.readAsString();
    expect(text, startsWith('[log entry truncated]'));
    expect(await file.length(), lessThanOrEqualTo(1024));
  });
}
