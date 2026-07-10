import 'dart:convert';
import 'dart:io';

import 'package:ssrvpn_shared/services/crash_reporter.dart';
import 'package:test/test.dart';

void main() {
  late Directory reportsDirectory;

  setUp(() async {
    reportsDirectory = await Directory.systemTemp.createTemp('ssrvpn_crashes_');
    await CrashReporter.init(reportsDirectory.path);
  });

  tearDown(() async {
    if (await reportsDirectory.exists()) {
      await reportsDirectory.delete(recursive: true);
    }
  });

  test('creates unique report files for rapid consecutive crashes', () async {
    final first = CrashReporter.recordSync('first', StateError('one'));
    final second = CrashReporter.recordSync('second', StateError('two'));

    expect(first, isNot(equals(second)));
    expect(await File(first).exists(), isTrue);
    expect(await File(second).exists(), isTrue);
  });

  test('keeps only the newest bounded number of crash reports', () async {
    for (var i = 0; i < CrashReporter.maxPendingReports + 5; i++) {
      CrashReporter.recordSync('crash $i', StateError('$i'));
    }

    expect(
      await CrashReporter.pendingReports(),
      hasLength(CrashReporter.maxPendingReports),
    );
  });

  test('prunes legacy-named reports by modification time', () async {
    final legacy = File('${reportsDirectory.path}/crash_2026-01-01.txt');
    await legacy.writeAsString('old');
    await legacy.setLastModified(DateTime.utc(2020));

    for (var i = 0; i < CrashReporter.maxPendingReports; i++) {
      CrashReporter.recordSync('new crash $i', StateError('$i'));
    }

    expect(await legacy.exists(), isFalse);
  });

  test('bounds a single crash report on disk', () async {
    final path = CrashReporter.recordSync(
      'large crash',
      StateError('x' * (CrashReporter.maxReportBytes * 2)),
    );

    expect(await File(path).length(),
        lessThanOrEqualTo(CrashReporter.maxReportBytes));
  });

  test('does not read or delete files outside the managed directory', () async {
    final outsideDirectory =
        await Directory.systemTemp.createTemp('ssrvpn_outside_');
    addTearDown(() async {
      if (await outsideDirectory.exists()) {
        await outsideDirectory.delete(recursive: true);
      }
    });
    final outside = File('${outsideDirectory.path}/crash_stolen.txt');
    await outside.writeAsString('outside-secret');

    expect(await CrashReporter.readReports([outside]), isEmpty);
    await CrashReporter.deleteReports([outside]);
    expect(await outside.exists(), isTrue);
  });

  test('bounds the combined report text returned to the UI', () async {
    for (var i = 0; i < 5; i++) {
      CrashReporter.recordSync('crash $i', StateError('x' * 1024));
    }
    final reports = await CrashReporter.pendingReports();
    final text = await CrashReporter.readReports(
      reports,
      maxBytesPerFile: 2048,
      maxTotalBytes: 2500,
    );

    expect(utf8.encode(text).length, lessThanOrEqualTo(2500));
  });
}
