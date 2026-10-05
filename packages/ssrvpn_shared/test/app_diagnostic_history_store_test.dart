import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  late Directory tempDir;
  late File historyFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ssrvpn-diagnostics-');
    historyFile = File('${tempDir.path}/diagnostic-history.json');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('persists only bounded redacted reports and keeps newest entries',
      () async {
    final store = AppDiagnosticHistoryStore(
      historyFile.path,
      maxEntries: 2,
      maxReportLength: 512,
    );

    for (var index = 0; index < 3; index++) {
      await store.append(
        AppDiagnosticReport(
          generatedAt: DateTime.utc(2026, 7, 27, 0, index),
          checks: [
            AppDiagnosticCheck(
              id: 'check-$index',
              title: '检查 $index',
              status: index == 2
                  ? AppDiagnosticStatus.failed
                  : AppDiagnosticStatus.passed,
              summary: 'token=top-secret-$index',
            ),
          ],
          recentLogs: 'ss://method:password@example.com:443\n${'x' * 2000}',
        ),
      );
    }

    final entries = await store.load();
    final encoded = await historyFile.readAsString();

    expect(entries, hasLength(2));
    expect(entries.first.generatedAt, DateTime.utc(2026, 7, 27, 0, 2));
    expect(entries.first.failureCount, 1);
    expect(entries.last.generatedAt, DateTime.utc(2026, 7, 27, 0, 1));
    expect(entries.every((entry) => entry.reportText.length <= 512), isTrue);
    expect(encoded, isNot(contains('top-secret')));
    expect(encoded, isNot(contains('password')));
  });

  test('rejects hostile schema and oversized persisted files', () async {
    final store = AppDiagnosticHistoryStore(
      historyFile.path,
      maxFileBytes: 256,
    );

    await historyFile.writeAsString('{"schema":999,"entries":[]}');
    expect(await store.load(), isEmpty);

    await historyFile.writeAsString('x' * 257);
    expect(await store.load(), isEmpty);
  });

  test('keeps the end of a report beyond the single log entry limit', () async {
    final store = AppDiagnosticHistoryStore(historyFile.path);
    final report = AppDiagnosticReport(
      generatedAt: DateTime.utc(2026, 10, 5),
      checks: [
        for (var index = 0; index < 24; index++)
          AppDiagnosticCheck(
            id: 'check-$index',
            title: '检查 $index',
            status: AppDiagnosticStatus.passed,
            summary: '检查结果 ${'x' * 200}',
          ),
        const AppDiagnosticCheck(
          id: 'last',
          title: '末尾检查',
          status: AppDiagnosticStatus.warning,
          summary: 'end-of-report token=history-secret',
        ),
      ],
      recentLogs: '',
    );
    final exported = report.toText();
    expect(exported.length, greaterThan(4096));
    expect(exported.length, lessThan(8192));
    await store.append(report);

    final loaded = (await store.load()).single.reportText;
    expect(loaded, contains('end-of-report'));
    expect(loaded, isNot(contains('history-secret')));
    expect(loaded, isNot(contains('log entry truncated')));

    // Appending another report also rewrites the older entries from load().
    await store.append(AppDiagnosticReport(
      generatedAt: DateTime.utc(2026, 10, 6),
      checks: const [],
      recentLogs: '',
    ));
    expect((await store.load()).last.reportText, contains('end-of-report'));
  });

  test('redacts a structurally valid report again when loading local history',
      () async {
    final store = AppDiagnosticHistoryStore(historyFile.path);
    await historyFile.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'entries': [
          {
            'generatedAt': DateTime.utc(2026, 7, 27).toIso8601String(),
            'failureCount': 0,
            'warningCount': 0,
            'reportText': '${'正常检查\n' * 850}'
                'token="manually-injected-secret\n'
                '[2026-10-05] [INFO] [runtime] hidden-secret-tail"\n'
                'history-end-marker',
          },
        ],
      }),
    );

    final entries = await store.load();

    expect(entries, hasLength(1));
    expect(entries.single.reportText, isNot(contains('manually-injected')));
    expect(entries.single.reportText, isNot(contains('hidden-secret-tail')));
    expect(entries.single.reportText, contains('history-end-marker'));
  });

  test('runDiagnostics appends history after producing a report', () async {
    final service = _HistoryDiagnosticService();
    service.setPaths(
      configDir: tempDir.path,
      configPath: '${tempDir.path}/config.yaml',
    );
    await File(service.configPath).writeAsString('mixed-port: 7890');

    await service.runDiagnostics(clock: () => DateTime.utc(2026, 7, 27));

    final history = await service.loadDiagnosticHistory();
    expect(history, hasLength(1));
    expect(history.single.generatedAt, DateTime.utc(2026, 7, 27));
  });
}

class _HistoryDiagnosticService extends ClashServiceBase
    implements ClashPlatformDiagnosticCapability {
  @override
  Future<bool> diagnosticCoreAvailable() async => true;

  @override
  String get diagnosticConfigPath => configPath;

  @override
  bool get diagnosticConfigRequired => true;

  @override
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks() async => const [];

  @override
  Future<AppRepairResult> repairDiagnosticIssue(AppRepairAction action) async =>
      const AppRepairResult(success: false, message: 'unsupported');

  @override
  Future<void> onStopRequired() async {}
}
