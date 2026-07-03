import 'dart:convert';
import 'dart:io';

import '../utils/log_redactor.dart';

class CrashReporter {
  static Directory? _directory;

  static bool get isInitialized => _directory != null;

  static Future<void> init(String directoryPath) async {
    try {
      _directory = Directory(directoryPath);
      await _directory!.create(recursive: true);
    } catch (_) {
      _directory = null;
    }
  }

  static void initSync(String directoryPath) {
    try {
      _directory = Directory(directoryPath)..createSync(recursive: true);
    } catch (_) {
      _directory = null;
    }
  }

  static String recordSync(
    String context,
    Object error, [
    StackTrace? stack,
  ]) {
    final directory = _directory;
    if (directory == null) return '';

    try {
      directory.createSync(recursive: true);
      final now = DateTime.now();
      final stamp =
          now.toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
      final file = File(
        '${directory.path}${Platform.pathSeparator}crash_$stamp.txt',
      );
      final report = StringBuffer()
        ..writeln('SSRVPN Crash Report')
        ..writeln('time: ${now.toIso8601String()}')
        ..writeln('context: ${LogRedactor.sanitize(context)}')
        ..writeln('platform: ${Platform.operatingSystem}')
        ..writeln('platformVersion: ${Platform.operatingSystemVersion}')
        ..writeln('error: ${LogRedactor.sanitize(error)}')
        ..writeln('stack:')
        ..writeln(LogRedactor.sanitize(stack));
      file.writeAsStringSync(report.toString(), flush: true);
      return file.path;
    } catch (_) {
      return '';
    }
  }

  static Future<List<File>> pendingReports() async {
    final directory = _directory;
    if (directory == null || !await directory.exists()) return const [];
    final reports = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.startsWith('crash_') && name.endsWith('.txt')) {
        reports.add(entity);
      }
    }
    reports.sort((a, b) => b.statSync().modified.compareTo(
          a.statSync().modified,
        ));
    return reports;
  }

  static Future<String> readReports(
    List<File> reports, {
    int maxBytesPerFile = 128 * 1024,
  }) async {
    final buffer = StringBuffer();
    for (final report in reports) {
      if (buffer.isNotEmpty) buffer.writeln('\n---\n');
      buffer.writeln('file: ${report.uri.pathSegments.last}');
      buffer.writeln(await _readReport(report, maxBytesPerFile));
    }
    return buffer.toString();
  }

  static Future<void> deleteReports(List<File> reports) async {
    for (final report in reports) {
      try {
        if (await report.exists()) await report.delete();
      } catch (_) {}
    }
  }

  static Future<String> _readReport(File file, int maxBytes) async {
    final length = await file.length();
    if (length <= maxBytes) return file.readAsString();
    final bytes = await file.openRead(0, maxBytes).fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    return '${utf8.decode(bytes, allowMalformed: true)}\n... truncated ...';
  }
}
