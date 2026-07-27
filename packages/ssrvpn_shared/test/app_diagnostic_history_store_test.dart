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
            'reportText': 'token=manually-injected-secret',
          },
        ],
      }),
    );

    final entries = await store.load();

    expect(entries, hasLength(1));
    expect(entries.single.reportText, isNot(contains('manually-injected')));
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
