import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// A best-effort file sink with bounded disk and in-memory usage.
///
/// Calls to [add] never wait for disk I/O. One drain operation owns all writes,
/// so a burst cannot create an unbounded chain of pending futures.
class BoundedFileLogger {
  BoundedFileLogger(
    this.file, {
    this.maxFileBytes = 2 * 1024 * 1024,
    this.maxPendingBytes = 128 * 1024,
    this.onError,
  })  : assert(maxFileBytes > 512),
        assert(maxPendingBytes > 0),
        assert(maxPendingBytes < maxFileBytes);

  final File file;
  final int maxFileBytes;
  final int maxPendingBytes;
  final void Function(Object error, StackTrace stack)? onError;

  final Queue<_LogEntry> _pending = Queue<_LogEntry>();
  int _pendingBytes = 0;
  int _droppedEntries = 0;
  bool _draining = false;
  Completer<void>? _idle;

  void add(String line) {
    final entry = _boundedEntry(line);
    while (
        _pending.isNotEmpty && _pendingBytes + entry.bytes > maxPendingBytes) {
      _pendingBytes -= _pending.removeFirst().bytes;
      _droppedEntries++;
    }
    _pending.addLast(entry);
    _pendingBytes += entry.bytes;
    if (!_draining) unawaited(_drain());
  }

  Future<void> flush() async {
    while (_draining || _pending.isNotEmpty) {
      final idle = _idle;
      if (idle == null) {
        await Future<void>.delayed(Duration.zero);
      } else {
        await idle.future;
      }
    }
  }

  _LogEntry _boundedEntry(String line) {
    final encoded = utf8.encode(line);
    if (encoded.length <= maxPendingBytes) {
      return _LogEntry(line, encoded.length);
    }
    const marker = '[log entry truncated]\n';
    final markerBytes = utf8.encode(marker);
    if (markerBytes.length >= maxPendingBytes) {
      final clippedMarker = marker.substring(0, maxPendingBytes);
      return _LogEntry(clippedMarker, maxPendingBytes);
    }
    final tailLength = maxPendingBytes - markerBytes.length;
    final tail = _decodeUtf8Tail(encoded, tailLength);
    final text = '$marker$tail';
    return _LogEntry(text, utf8.encode(text).length);
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    final idle = Completer<void>();
    _idle = idle;
    try {
      await file.parent.create(recursive: true);
      while (_pending.isNotEmpty) {
        final batch = StringBuffer();
        final dropped = _droppedEntries;
        _droppedEntries = 0;
        if (dropped > 0) {
          batch.writeln('[dropped $dropped log entries while disk was busy]');
        }
        while (_pending.isNotEmpty) {
          batch.write(_pending.removeFirst().text);
        }
        _pendingBytes = 0;

        final text = _fitToFileLimit(batch.toString());
        await _rotateBeforeWrite(utf8.encode(text).length);
        await file.writeAsString(text, mode: FileMode.append);
      }
    } catch (error, stack) {
      _pending.clear();
      _pendingBytes = 0;
      _droppedEntries = 0;
      onError?.call(error, stack);
    } finally {
      _draining = false;
      if (!idle.isCompleted) idle.complete();
    }
  }

  String _fitToFileLimit(String text) {
    final encoded = utf8.encode(text);
    if (encoded.length <= maxFileBytes) return text;
    const marker = '[log batch truncated]\n';
    final markerBytes = utf8.encode(marker);
    final tail = _decodeUtf8Tail(
      encoded,
      maxFileBytes - markerBytes.length,
    );
    return '$marker$tail';
  }

  Future<void> _rotateBeforeWrite(int incomingBytes) async {
    if (!await file.exists()) return;
    if (await file.length() + incomingBytes <= maxFileBytes) return;
    final oldFile = File('${file.path}.old');
    if (await oldFile.exists()) await oldFile.delete();
    await file.rename(oldFile.path);
  }
}

String _decodeUtf8Tail(List<int> encoded, int maxBytes) {
  var start = encoded.length - maxBytes;
  while (start < encoded.length) {
    try {
      return utf8.decode(encoded.sublist(start));
    } on FormatException {
      start++;
    }
  }
  return '';
}

class _LogEntry {
  const _LogEntry(this.text, this.bytes);

  final String text;
  final int bytes;
}
