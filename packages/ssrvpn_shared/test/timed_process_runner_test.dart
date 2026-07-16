import 'dart:async';
import 'dart:io';

import 'package:ssrvpn_shared/services/timed_process_runner.dart';
import 'package:test/test.dart';

void main() {
  test('cancellation terminates a running process before its timeout',
      () async {
    final cancellation = Completer<void>();
    final watch = Stopwatch()..start();
    final task = TimedProcessRunner.run(
      _shellExecutable,
      _shellArguments(_sleepCommand),
      timeout: const Duration(seconds: 5),
      cancellation: cancellation.future,
    );

    cancellation.complete();
    final result = await task;

    expect(result.exitCode, 125);
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('returns timeout result when a process hangs', () async {
    final result = await TimedProcessRunner.run(
      _shellExecutable,
      _shellArguments(_sleepCommand),
      timeout: const Duration(milliseconds: 20),
      timeoutStderr: 'timeout',
    );

    expect(result.exitCode, 124);
    expect(result.stderr, 'timeout');
  });

  test(
    'timeout does not wait for a descendant holding output pipes open',
    () async {
      final watch = Stopwatch()..start();

      final result = await TimedProcessRunner.run(
        '/bin/sh',
        const ['-c', 'sleep 1 & wait'],
        timeout: const Duration(milliseconds: 20),
        timeoutStderr: 'timeout',
      );

      expect(result.exitCode, 124);
      expect(result.stderr, 'timeout');
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 750)));
    },
    skip: Platform.isWindows ? 'uses POSIX child-process semantics' : false,
  );

  test(
    'normal exit does not wait for a descendant holding output pipes open',
    () async {
      final watch = Stopwatch()..start();

      final result = await TimedProcessRunner.run(
        '/bin/sh',
        const ['-c', 'sleep 2 & exit 0'],
        timeout: const Duration(seconds: 5),
      );

      expect(result.exitCode, 0);
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 750)));
    },
    skip: Platform.isWindows ? 'uses POSIX child-process semantics' : false,
  );
}

String get _shellExecutable => Platform.isWindows ? 'cmd.exe' : '/bin/sh';

List<String> _shellArguments(String command) =>
    Platform.isWindows ? ['/c', command] : ['-c', command];

String get _sleepCommand =>
    Platform.isWindows ? 'ping -n 2 127.0.0.1 > nul' : 'sleep 1';
