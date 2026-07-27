import 'dart:convert';
import 'dart:io';

import '../models/app_diagnostics.dart';
import '../utils/log_redactor.dart';

class AppDiagnosticHistoryEntry {
  const AppDiagnosticHistoryEntry({
    required this.generatedAt,
    required this.failureCount,
    required this.warningCount,
    required this.reportText,
  });

  final DateTime generatedAt;
  final int failureCount;
  final int warningCount;
  final String reportText;
}

/// Stores only the already-redacted export form of diagnostic reports.
///
/// The strict schema, entry count, report length, and total file size bounds
/// keep corrupted or attacker-controlled local files from becoming an
/// unbounded memory or disclosure surface.
class AppDiagnosticHistoryStore {
  AppDiagnosticHistoryStore(
    this.path, {
    this.maxEntries = 20,
    this.maxReportLength = 8192,
    this.maxFileBytes = 256 * 1024,
  })  : assert(maxEntries > 0),
        assert(maxReportLength > 0),
        assert(maxFileBytes > 0);

  static const int _schemaVersion = 1;

  final String path;
  final int maxEntries;
  final int maxReportLength;
  final int maxFileBytes;

  Future<List<AppDiagnosticHistoryEntry>> load() async {
    final file = File(path);
    try {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        return const [];
      }
      if (await file.length() > maxFileBytes) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['schemaVersion'] != _schemaVersion ||
          decoded['entries'] is! List) {
        return const [];
      }
      final entries = <AppDiagnosticHistoryEntry>[];
      for (final value in decoded['entries'] as List) {
        final entry = _decodeEntry(value);
        if (entry == null) return const [];
        entries.add(entry);
        if (entries.length > maxEntries) return const [];
      }
      entries
          .sort((left, right) => right.generatedAt.compareTo(left.generatedAt));
      return List.unmodifiable(entries);
    } on FileSystemException {
      return const [];
    } on FormatException {
      return const [];
    } on TypeError {
      return const [];
    }
  }

  Future<void> append(AppDiagnosticReport report) async {
    final entries = (await load()).toList();
    entries.insert(
      0,
      AppDiagnosticHistoryEntry(
        generatedAt: report.generatedAt,
        failureCount: report.checks
            .where((check) => check.status == AppDiagnosticStatus.failed)
            .length,
        warningCount: report.checks
            .where((check) => check.status == AppDiagnosticStatus.warning)
            .length,
        reportText: report.toText(maxLength: maxReportLength),
      ),
    );
    if (entries.length > maxEntries) {
      entries.removeRange(maxEntries, entries.length);
    }

    var encoded = _encode(entries);
    while (utf8.encode(encoded).length > maxFileBytes && entries.length > 1) {
      entries.removeLast();
      encoded = _encode(entries);
    }
    if (utf8.encode(encoded).length > maxFileBytes) return;

    final target = File(path);
    await target.parent.create(recursive: true);
    final temp = File(
      '$path.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temp.writeAsString(encoded, flush: true);
      if (!Platform.isWindows) {
        final result = await Process.run('chmod', ['600', temp.path])
            .timeout(const Duration(seconds: 2));
        if (result.exitCode != 0) {
          throw FileSystemException('Unable to protect diagnostic history');
        }
      }
      await temp.rename(path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  AppDiagnosticHistoryEntry? _decodeEntry(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final generatedAt =
        DateTime.tryParse(value['generatedAt'] as String? ?? '');
    final failureCount = value['failureCount'];
    final warningCount = value['warningCount'];
    final reportText = value['reportText'];
    if (generatedAt == null ||
        failureCount is! int ||
        failureCount < 0 ||
        warningCount is! int ||
        warningCount < 0 ||
        reportText is! String ||
        reportText.length > maxReportLength) {
      return null;
    }
    final redactedReport = LogRedactor.sanitize(reportText);
    return AppDiagnosticHistoryEntry(
      generatedAt: generatedAt,
      failureCount: failureCount,
      warningCount: warningCount,
      reportText: redactedReport,
    );
  }

  String _encode(List<AppDiagnosticHistoryEntry> entries) => jsonEncode({
        'schemaVersion': _schemaVersion,
        'entries': [
          for (final entry in entries)
            {
              'generatedAt': entry.generatedAt.toUtc().toIso8601String(),
              'failureCount': entry.failureCount,
              'warningCount': entry.warningCount,
              'reportText': entry.reportText,
            },
        ],
      });
}
