import 'dart:async';
import 'dart:isolate';

import 'package:meta/meta.dart';

import 'subscription_parser.dart';
import 'subscription_refresh_control.dart';
import 'subscription_yaml_merger.dart';

class MergedSubscriptionResult {
  const MergedSubscriptionResult({required this.yaml, required this.parsed});

  final String yaml;
  final ParsedSubscription parsed;
}

class SubscriptionProcessing {
  static const int isolateThreshold = 256 * 1024;
  static int _activeWorkerCount = 0;
  static int _pendingWorkerCount = 0;
  static Duration _workerStartDelayForTesting = Duration.zero;

  @visibleForTesting
  static int get activeWorkerCount => _activeWorkerCount;

  @visibleForTesting
  static int get pendingWorkerCount => _pendingWorkerCount;

  @visibleForTesting
  static set workerStartDelayForTesting(Duration value) {
    if (value.isNegative) {
      throw ArgumentError.value(value, 'value', 'must not be negative');
    }
    _workerStartDelayForTesting = value;
  }

  static Future<MergedSubscriptionResult> mergeAndParse(
    List<String> yamls,
    List<String> sourceNames,
    SubscriptionRefreshControl control, {
    required String proxySourceKey,
    required String standaloneGroupName,
  }) {
    final input = _SubscriptionProcessingInput(
      yamls: List<String>.of(yamls),
      sourceNames: List<String>.of(sourceNames),
      proxySourceKey: proxySourceKey,
      standaloneGroupName: standaloneGroupName,
      workerStartDelay: _workerStartDelayForTesting,
    );
    final workload = input.yamls.fold<int>(
      0,
      (sum, yaml) => sum + yaml.length,
    );

    if (workload < isolateThreshold) {
      return Future.value(_processSubscription(input));
    }

    // Avoid spawning work that an already stopped refresh can never commit.
    // Keep the error asynchronous, matching SubscriptionRefreshControl.wait.
    try {
      control.throwIfStopped();
    } catch (error, stackTrace) {
      return Future<MergedSubscriptionResult>.error(error, stackTrace);
    }

    final worker = _SubscriptionProcessingWorker.start(input);
    return control.wait(worker.result, onAbort: worker.kill);
  }
}

class _SubscriptionProcessingInput {
  const _SubscriptionProcessingInput({
    required this.yamls,
    required this.sourceNames,
    required this.proxySourceKey,
    required this.standaloneGroupName,
    required this.workerStartDelay,
  });

  final List<String> yamls;
  final List<String> sourceNames;
  final String proxySourceKey;
  final String standaloneGroupName;
  final Duration workerStartDelay;
}

MergedSubscriptionResult _processSubscription(
  _SubscriptionProcessingInput input,
) {
  final yaml = SubscriptionYamlMerger.mergeYamlConfigs(
    input.yamls,
    sourceNames: input.sourceNames,
    proxySourceKey: input.proxySourceKey,
    standaloneGroupName: input.standaloneGroupName,
  );
  return MergedSubscriptionResult(
    yaml: yaml,
    parsed: SubscriptionParser.parseYaml(yaml),
  );
}

class _SubscriptionProcessingWorker {
  _SubscriptionProcessingWorker._(this._input) {
    SubscriptionProcessing._activeWorkerCount++;
    SubscriptionProcessing._pendingWorkerCount++;
    _messages.listen(_handleMessage);
    unawaited(_spawn());
  }

  static _SubscriptionProcessingWorker start(
    _SubscriptionProcessingInput input,
  ) {
    return _SubscriptionProcessingWorker._(input);
  }

  final _SubscriptionProcessingInput _input;
  final ReceivePort _messages = ReceivePort();
  final Completer<MergedSubscriptionResult> _result =
      Completer<MergedSubscriptionResult>();
  Isolate? _isolate;
  bool _killRequested = false;
  bool _spawnResolved = false;
  bool _closed = false;

  Future<MergedSubscriptionResult> get result => _result.future;

  Future<void> _spawn() async {
    try {
      final isolate = await Isolate.spawn(
        _subscriptionProcessingWorkerMain,
        _SubscriptionProcessingWorkerRequest(
          input: _input,
          replyTo: _messages.sendPort,
        ),
        debugName: 'ssrvpn-subscription-processing',
        errorsAreFatal: true,
        onError: _messages.sendPort,
        onExit: _messages.sendPort,
      );
      _markSpawnResolved();
      _isolate = isolate;
      if (_closed || _killRequested) {
        isolate.kill(priority: Isolate.immediate);
      }
    } catch (error, stackTrace) {
      _markSpawnResolved();
      _completeError(error, stackTrace);
    }
  }

  void kill() {
    if (_closed) return;
    _killRequested = true;
    _isolate?.kill(priority: Isolate.immediate);
  }

  void _handleMessage(Object? message) {
    if (_closed) return;
    if (message is _SubscriptionProcessingWorkerSuccess) {
      _completeValue(message.result);
      return;
    }
    if (message is _SubscriptionProcessingWorkerFailure) {
      _completeError(
        message.error,
        StackTrace.fromString(message.stackTrace),
      );
      return;
    }
    if (message is _SubscriptionProcessingRemoteFailure) {
      _completeError(
        RemoteError(message.error, message.stackTrace),
        StackTrace.fromString(message.stackTrace),
      );
      return;
    }
    if (message is List && message.length >= 2) {
      _completeError(
        RemoteError(message[0].toString(), message[1].toString()),
        StackTrace.fromString(message[1].toString()),
      );
      return;
    }
    if (message == null) {
      _completeError(
        StateError('订阅处理工作线程意外退出'),
        StackTrace.current,
      );
    }
  }

  void _completeValue(MergedSubscriptionResult value) {
    if (_closed) return;
    _close();
    _result.complete(value);
  }

  void _completeError(Object error, StackTrace stackTrace) {
    if (_closed) return;
    _close();
    _result.completeError(error, stackTrace);
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _messages.close();
    SubscriptionProcessing._activeWorkerCount--;
  }

  void _markSpawnResolved() {
    if (_spawnResolved) return;
    _spawnResolved = true;
    SubscriptionProcessing._pendingWorkerCount--;
  }
}

class _SubscriptionProcessingWorkerRequest {
  const _SubscriptionProcessingWorkerRequest({
    required this.input,
    required this.replyTo,
  });

  final _SubscriptionProcessingInput input;
  final SendPort replyTo;
}

class _SubscriptionProcessingWorkerSuccess {
  const _SubscriptionProcessingWorkerSuccess(this.result);

  final MergedSubscriptionResult result;
}

class _SubscriptionProcessingWorkerFailure {
  const _SubscriptionProcessingWorkerFailure(this.error, this.stackTrace);

  final Object error;
  final String stackTrace;
}

class _SubscriptionProcessingRemoteFailure {
  const _SubscriptionProcessingRemoteFailure(this.error, this.stackTrace);

  final String error;
  final String stackTrace;
}

@pragma('vm:entry-point')
void _subscriptionProcessingWorkerMain(
  _SubscriptionProcessingWorkerRequest request,
) async {
  try {
    if (request.input.workerStartDelay > Duration.zero) {
      await Future<void>.delayed(request.input.workerStartDelay);
    }
    final result = _processSubscription(request.input);
    Isolate.exit(
      request.replyTo,
      _SubscriptionProcessingWorkerSuccess(result),
    );
  } catch (error, stackTrace) {
    try {
      Isolate.exit(
        request.replyTo,
        _SubscriptionProcessingWorkerFailure(error, stackTrace.toString()),
      );
    } catch (_) {
      Isolate.exit(
        request.replyTo,
        _SubscriptionProcessingRemoteFailure(
          error.toString(),
          stackTrace.toString(),
        ),
      );
    }
  }
}
