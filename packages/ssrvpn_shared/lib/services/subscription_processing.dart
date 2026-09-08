import 'dart:async';
import 'dart:isolate';

import 'package:meta/meta.dart';

import '../utils/bounded_yaml.dart';
import 'clash_config_generator.dart';
import 'subscription_parser.dart';
import 'subscription_refresh_control.dart';
import 'subscription_source_cache.dart';
import 'subscription_yaml_merger.dart';

class MergedSubscriptionResult {
  const MergedSubscriptionResult({
    required this.yaml,
    required this.parsed,
    this.runtimeText,
    this.parseWarning,
  });

  final String yaml;
  final ParsedSubscription parsed;
  final String? runtimeText;
  final String? parseWarning;
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
    List<String>? sourceIds,
    String? previousYaml,
  }) {
    final input = _SubscriptionProcessingInput(
      yamls: List<String>.of(yamls),
      sourceNames: List<String>.of(sourceNames),
      sourceIds: sourceIds == null ? null : List<String>.of(sourceIds),
      previousYaml: previousYaml,
      proxySourceKey: proxySourceKey,
      standaloneGroupName: standaloneGroupName,
      workerStartDelay: _workerStartDelayForTesting,
    );
    return _run(input, control);
  }

  static Future<Map<String, String>> extractSources(
    String? yaml,
    Map<String, String> sourceNames,
    SubscriptionRefreshControl control, {
    Map<String, String> localSources = const {},
  }) =>
      _run(
        _SourceCacheInput(yaml, Map.of(sourceNames), Map.of(localSources),
            _workerStartDelayForTesting),
        control,
      );

  static Future<MergedSubscriptionResult> parseSnapshot(
    String yaml,
    SubscriptionRefreshControl control, {
    bool loadingCache = false,
  }) =>
      _run(
        _SnapshotInput(yaml, loadingCache, _workerStartDelayForTesting),
        control,
      );

  static Future<String> buildRuntimeText(
    String yaml,
    SubscriptionRefreshControl control,
  ) =>
      _run(_RuntimeTextInput(yaml, _workerStartDelayForTesting), control);

  static Future<T> _run<T>(
    _ProcessingInput<T> input,
    SubscriptionRefreshControl control,
  ) {
    if (input.workload < isolateThreshold) {
      control.throwIfStopped();
      return Future.value(input.process());
    }

    // Avoid spawning work that an already stopped refresh can never commit.
    // Keep the error asynchronous, matching SubscriptionRefreshControl.wait.
    try {
      control.throwIfStopped();
    } catch (error, stackTrace) {
      return Future<T>.error(error, stackTrace);
    }

    final worker = _SubscriptionProcessingWorker<T>._(input);
    return control.wait(worker.result, onAbort: worker.kill);
  }
}

abstract class _ProcessingInput<T> {
  const _ProcessingInput(this.workerStartDelay);
  final Duration workerStartDelay;
  int get workload;
  T process();
}

class _SourceCacheInput extends _ProcessingInput<Map<String, String>> {
  const _SourceCacheInput(
      this.yaml, this.sourceNames, this.localSources, super.workerStartDelay);
  final String? yaml;
  final Map<String, String> sourceNames;
  final Map<String, String> localSources;

  @override
  int get workload => localSources.values.fold(
        yaml?.length ?? 0,
        (sum, source) => sum + source.length,
      );

  @override
  Map<String, String> process() => SubscriptionSourceCache.extract(
        yaml,
        sourceNames,
        localSources: localSources,
      );
}

class _SnapshotInput extends _ProcessingInput<MergedSubscriptionResult> {
  const _SnapshotInput(this.yaml, this.loadingCache, super.workerStartDelay);
  final String yaml;
  final bool loadingCache;

  @override
  int get workload => yaml.length;

  @override
  MergedSubscriptionResult process() {
    if (loadingCache) {
      final document = BoundedYaml.load(yaml);
      if (document != null && document is! Map) {
        throw const FormatException(
          'subscription_cache.yaml must be a YAML map',
        );
      }
    }
    try {
      return MergedSubscriptionResult(
        yaml: yaml,
        parsed: SubscriptionParser.parseYaml(yaml),
        runtimeText: ClashConfigGenerator.buildProxiesText(yaml),
      );
    } catch (error) {
      if (!loadingCache) rethrow;
      // Preserve the startup policy: structural corruption is quarantined,
      // but semantically invalid runtime data remains available for repair.
      return MergedSubscriptionResult(
        yaml: yaml,
        parsed: ParsedSubscription.empty(),
        parseWarning: error.toString(),
      );
    }
  }
}

class _RuntimeTextInput extends _ProcessingInput<String> {
  const _RuntimeTextInput(this.yaml, super.workerStartDelay);
  final String yaml;

  @override
  int get workload => yaml.length;

  @override
  String process() => ClashConfigGenerator.buildProxiesText(yaml);
}

class _SubscriptionProcessingInput
    extends _ProcessingInput<MergedSubscriptionResult> {
  const _SubscriptionProcessingInput({
    required this.yamls,
    required this.sourceNames,
    required this.sourceIds,
    required this.previousYaml,
    required this.proxySourceKey,
    required this.standaloneGroupName,
    required Duration workerStartDelay,
  }) : super(workerStartDelay);

  final List<String> yamls;
  final List<String> sourceNames;
  final List<String>? sourceIds;
  final String? previousYaml;
  final String proxySourceKey;
  final String standaloneGroupName;

  @override
  int get workload => yamls.fold<int>(
        previousYaml?.length ?? 0,
        (sum, yaml) => sum + yaml.length,
      );

  @override
  MergedSubscriptionResult process() => _processSubscription(this);
}

MergedSubscriptionResult _processSubscription(
  _SubscriptionProcessingInput input,
) {
  final yaml = SubscriptionYamlMerger.mergeYamlConfigs(
    input.yamls,
    sourceNames: input.sourceNames,
    sourceIds: input.sourceIds,
    previousYaml: input.previousYaml,
    proxySourceKey: input.proxySourceKey,
    standaloneGroupName: input.standaloneGroupName,
  );
  return MergedSubscriptionResult(
    yaml: yaml,
    parsed: SubscriptionParser.parseYaml(yaml),
    runtimeText: ClashConfigGenerator.buildProxiesText(yaml),
  );
}

class _SubscriptionProcessingWorker<T> {
  _SubscriptionProcessingWorker._(this._input) {
    SubscriptionProcessing._activeWorkerCount++;
    SubscriptionProcessing._pendingWorkerCount++;
    _messages.listen(_handleMessage);
    unawaited(_spawn());
  }

  final _ProcessingInput<T> _input;
  final ReceivePort _messages = ReceivePort();
  final Completer<T> _result = Completer<T>();
  Isolate? _isolate;
  bool _killRequested = false;
  bool _spawnResolved = false;
  bool _closed = false;

  Future<T> get result => _result.future;

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
      _completeValue(message.result as T);
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

  void _completeValue(T value) {
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

  final _ProcessingInput<Object?> input;
  final SendPort replyTo;
}

class _SubscriptionProcessingWorkerSuccess {
  const _SubscriptionProcessingWorkerSuccess(this.result);

  final Object? result;
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
    final result = request.input.process();
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
