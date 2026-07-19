import 'dart:async';

class SubscriptionRefreshCancelled implements Exception {
  const SubscriptionRefreshCancelled();

  @override
  String toString() => '订阅刷新已取消';
}

class SubscriptionRefreshDeadlineExceeded implements Exception {
  const SubscriptionRefreshDeadlineExceeded(this.timeout);

  final Duration timeout;

  @override
  String toString() => '订阅刷新超过总时限（${timeout.inSeconds} 秒）';
}

class SubscriptionRefreshCancellation {
  final Completer<void> _cancelled = Completer<void>();
  final Set<void Function()> _aborters = {};

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (isCancelled) return;
    _cancelled.complete();
    for (final abort in List<void Function()>.of(_aborters)) {
      try {
        abort();
      } catch (_) {}
    }
  }

  void throwIfCancelled() {
    if (isCancelled) throw const SubscriptionRefreshCancelled();
  }

  void Function() attach(void Function() abort) {
    if (isCancelled) {
      abort();
      return () {};
    }
    _aborters.add(abort);
    return () => _aborters.remove(abort);
  }
}

class SubscriptionRefreshControl {
  SubscriptionRefreshControl({
    required this.timeout,
    SubscriptionRefreshCancellation? cancellation,
  })  : cancellation = cancellation ?? SubscriptionRefreshCancellation(),
        _clock = Stopwatch()..start();

  final Duration timeout;
  final SubscriptionRefreshCancellation cancellation;
  final Stopwatch _clock;

  Duration get remaining {
    final value = timeout - _clock.elapsed;
    return value > Duration.zero ? value : Duration.zero;
  }

  void throwIfStopped() {
    cancellation.throwIfCancelled();
    if (remaining == Duration.zero) {
      throw SubscriptionRefreshDeadlineExceeded(timeout);
    }
  }

  Future<T> wait<T>(
    Future<T> operation, {
    void Function()? onAbort,
  }) async {
    try {
      throwIfStopped();
    } catch (_) {
      unawaited(
        operation.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
      );
      rethrow;
    }
    final result = Completer<T>();
    Timer? deadline;
    var abortCalled = false;

    void abort() {
      if (abortCalled) return;
      abortCalled = true;
      try {
        onAbort?.call();
      } catch (_) {}
    }

    void fail(Object error, [StackTrace? stackTrace]) {
      if (result.isCompleted) return;
      abort();
      result.completeError(error, stackTrace ?? StackTrace.current);
    }

    final detach = cancellation.attach(
      () => fail(const SubscriptionRefreshCancelled()),
    );
    deadline = Timer(
      remaining,
      () => fail(SubscriptionRefreshDeadlineExceeded(timeout)),
    );
    operation.then(
      (value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!result.isCompleted) result.completeError(error, stackTrace);
      },
    );

    return result.future.whenComplete(() {
      deadline?.cancel();
      detach();
    });
  }

  Future<void> delay(Duration duration) async {
    if (duration <= Duration.zero) {
      throwIfStopped();
      return;
    }
    await wait(Future<void>.delayed(duration));
  }
}
