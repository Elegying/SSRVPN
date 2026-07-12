import 'dart:async';
import 'dart:convert';
import 'dart:io';

class TimedProcessRunner {
  static const _outputDrainTimeout = Duration(milliseconds: 250);

  static Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    bool includeParentEnvironment = true,
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 10),
    int timeoutExitCode = 124,
    String timeoutStderr = '命令超时',
    Future<void>? cancellation,
    int cancellationExitCode = 125,
    String cancellationStderr = '命令已取消',
  }) async {
    Process? process;
    _OutputCollector? stdoutCollector;
    _OutputCollector? stderrCollector;
    Timer? timer;
    try {
      process = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        includeParentEnvironment: includeParentEnvironment,
        environment: environment,
      );
      stdoutCollector = _OutputCollector(process.stdout);
      stderrCollector = _OutputCollector(process.stderr);

      final completion = Completer<_ProcessCompletion>();
      process.exitCode.then((exitCode) {
        if (!completion.isCompleted) {
          completion.complete(_ProcessCompletion(exitCode, null));
        }
      });
      timer = Timer(timeout, () {
        if (!completion.isCompleted) {
          completion.complete(
            _ProcessCompletion(timeoutExitCode, timeoutStderr),
          );
        }
      });
      cancellation?.then((_) {
        if (!completion.isCompleted) {
          completion.complete(
            _ProcessCompletion(cancellationExitCode, cancellationStderr),
          );
        }
      });

      final outcome = await completion.future;
      timer.cancel();
      final interrupted = outcome.stderrOverride != null;
      if (interrupted) {
        await _terminateProcessTree(process);
      }

      final outputs = await Future.wait([
        stdoutCollector.finish(timeout: _outputDrainTimeout),
        stderrCollector.finish(timeout: _outputDrainTimeout),
      ]);
      final stdout = outputs[0];
      final stderr = outcome.stderrOverride ?? outputs[1];
      return ProcessResult(process.pid, outcome.exitCode, stdout, stderr);
    } catch (_) {
      timer?.cancel();
      if (process != null) await _terminateProcessTree(process);
      await stdoutCollector?.cancel();
      await stderrCollector?.cancel();
      rethrow;
    }
  }

  static Future<void> _terminateProcessTree(Process process) async {
    if (Platform.isWindows) {
      try {
        final killer = await Process.start(
          'taskkill.exe',
          ['/PID', '${process.pid}', '/T', '/F'],
        );
        try {
          await Future.wait<dynamic>([
            killer.stdout.drain<void>(),
            killer.stderr.drain<void>(),
            killer.exitCode,
          ]).timeout(const Duration(seconds: 2));
        } on TimeoutException {
          killer.kill(ProcessSignal.sigkill);
        }
      } catch (_) {
        // Fall through to the direct-process kill below.
      }
    }
    process.kill(ProcessSignal.sigkill);
  }
}

class _ProcessCompletion {
  const _ProcessCompletion(this.exitCode, this.stderrOverride);

  final int exitCode;
  final String? stderrOverride;
}

class _OutputCollector {
  _OutputCollector(Stream<List<int>> stream) {
    _subscription = stream.transform(utf8.decoder).listen(
      _buffer.write,
      onDone: _complete,
      onError: (Object error, StackTrace stack) {
        if (!_done.isCompleted) _done.completeError(error, stack);
      },
    );
  }

  final _buffer = StringBuffer();
  final _done = Completer<String>();
  late final StreamSubscription<String> _subscription;

  Future<String> finish({Duration? timeout}) async {
    if (timeout == null) return _done.future;
    try {
      return await _done.future.timeout(timeout);
    } on TimeoutException {
      await cancel();
      return _buffer.toString();
    }
  }

  Future<void> cancel() async {
    await _subscription.cancel();
    _complete();
  }

  void _complete() {
    if (!_done.isCompleted) _done.complete(_buffer.toString());
  }
}
