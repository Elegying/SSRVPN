import 'dart:async';

/// Deduplicates an initialization attempt until its underlying work finishes.
///
/// This matters when a caller applies [Future.timeout]: the timeout does not
/// cancel the original future, so a retry must keep awaiting the same work
/// instead of starting a second initialization in parallel.
class InitializationTask {
  Future<void>? _pending;

  Future<void> run(Future<void> Function() initialize) {
    final pending = _pending;
    if (pending != null) return pending;

    late final Future<void> tracked;
    tracked = Future<void>.sync(initialize).whenComplete(() {
      if (identical(_pending, tracked)) _pending = null;
    });
    _pending = tracked;
    return tracked;
  }
}
