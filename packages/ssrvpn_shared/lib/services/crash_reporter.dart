import 'dart:convert';
import 'dart:io';

import '../utils/log_redactor.dart';

class CrashReporter {
  static const int maxPendingReports = 20;
  static const int maxReportBytes = 256 * 1024;
  static const int defaultMaxCombinedReadBytes = 512 * 1024;

  static Directory? _directory;
  static int _reportSequence = 0;

  static bool get isInitialized => _directory != null;

  static Future<void> init(String directoryPath) async {
    try {
      _directory = Directory(directoryPath);
      await _directory!.create(recursive: true);
      _pruneSync(_directory!);
    } catch (_) {
      _directory = null;
    }
  }

  static void initSync(String directoryPath) {
    try {
      _directory = Directory(directoryPath)..createSync(recursive: true);
      _pruneSync(_directory!);
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
      File file;
      do {
        final id = '${now.microsecondsSinceEpoch}_${pid}_${_reportSequence++}';
        file = File(
          '${directory.path}${Platform.pathSeparator}crash_$id.txt',
        );
      } while (file.existsSync());
      final report = StringBuffer()
        ..writeln('SSRVPN Crash Report')
        ..writeln('time: ${now.toIso8601String()}')
        ..writeln('context: ${_sanitizeForReport(context, 4096)}')
        ..writeln('platform: ${Platform.operatingSystem}')
        ..writeln('platformVersion: ${Platform.operatingSystemVersion}')
        ..writeln('error: ${_sanitizeForReport(error, 16 * 1024)}')
        ..writeln('stack:')
        ..writeln(_sanitizeForReport(stack, 64 * 1024));
      file.writeAsStringSync(
        _fitUtf8(report.toString(), maxReportBytes),
        flush: true,
      );
      _pruneSync(directory);
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
    reports.sort(_newestFirst);
    return reports.take(maxPendingReports).toList(growable: false);
  }

  static Future<String> readReports(
    List<File> reports, {
    int maxBytesPerFile = 128 * 1024,
    int maxTotalBytes = defaultMaxCombinedReadBytes,
  }) async {
    if (maxBytesPerFile <= 0 || maxTotalBytes <= 0) return '';
    final buffer = StringBuffer();
    var usedBytes = 0;
    for (final report in reports) {
      if (!_isManagedReport(report)) continue;
      final chunk = StringBuffer();
      if (buffer.isNotEmpty) chunk.writeln('\n---\n');
      chunk.writeln('file: ${report.uri.pathSegments.last}');
      try {
        chunk.writeln(await _readReport(report, maxBytesPerFile));
      } catch (_) {
        continue;
      }

      final remaining = maxTotalBytes - usedBytes;
      if (remaining <= 0) break;
      final text = chunk.toString();
      final bounded = _fitUtf8(text, remaining);
      buffer.write(bounded);
      usedBytes += utf8.encode(bounded).length;
      if (bounded != text) break;
    }
    return buffer.toString();
  }

  static Future<void> deleteReports(List<File> reports) async {
    for (final report in reports) {
      if (!_isManagedReport(report)) continue;
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

  static bool _isManagedReport(File file) {
    final directory = _directory;
    if (directory == null) return false;
    final candidate = file.absolute;
    final expectedParent = directory.absolute.path;
    final actualParent = candidate.parent.path;
    final sameParent = Platform.isWindows
        ? actualParent.toLowerCase() == expectedParent.toLowerCase()
        : actualParent == expectedParent;
    if (!sameParent) return false;

    final name = candidate.uri.pathSegments.last;
    if (!name.startsWith('crash_') || !name.endsWith('.txt')) return false;
    return FileSystemEntity.typeSync(candidate.path, followLinks: false) ==
        FileSystemEntityType.file;
  }

  static String _sanitizeForReport(Object? value, int maxCharacters) {
    var text = value?.toString() ?? '';
    if (text.length > maxCharacters) {
      text =
          '${text.substring(0, maxCharacters)}\n... truncated before redaction ...';
    }
    return LogRedactor.sanitize(text);
  }

  static String _fitUtf8(String value, int maxBytes) {
    if (maxBytes <= 0) return '';
    if (utf8.encode(value).length <= maxBytes) return value;

    const marker = '\n... truncated ...\n';
    final markerBytes = utf8.encode(marker).length;
    if (markerBytes >= maxBytes) {
      return marker.substring(0, maxBytes);
    }

    var low = 0;
    var high = value.length;
    final contentBudget = maxBytes - markerBytes;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (utf8.encode(value.substring(0, middle)).length <= contentBudget) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    if (low > 0 &&
        low < value.length &&
        _isHighSurrogate(value.codeUnitAt(low - 1)) &&
        _isLowSurrogate(value.codeUnitAt(low))) {
      low--;
    }
    return '${value.substring(0, low)}$marker';
  }

  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  static bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

  static void _pruneSync(Directory directory) {
    try {
      final reports = directory
          .listSync(followLinks: false)
          .whereType<File>()
          .where((file) {
        final name = file.uri.pathSegments.last;
        return name.startsWith('crash_') && name.endsWith('.txt');
      }).toList()
        ..sort(_newestFirst);
      for (final report in reports.skip(maxPendingReports)) {
        try {
          report.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  static int _newestFirst(File a, File b) {
    final modified = _modifiedMicros(b).compareTo(_modifiedMicros(a));
    return modified != 0 ? modified : b.path.compareTo(a.path);
  }

  static int _modifiedMicros(File file) {
    try {
      return file.statSync().modified.microsecondsSinceEpoch;
    } catch (_) {
      return 0;
    }
  }
}
