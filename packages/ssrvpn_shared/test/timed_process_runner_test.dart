import 'dart:io';

import 'package:ssrvpn_shared/services/timed_process_runner.dart';
import 'package:test/test.dart';

void main() {
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
}

String get _shellExecutable => Platform.isWindows ? 'cmd.exe' : '/bin/sh';

List<String> _shellArguments(String command) =>
    Platform.isWindows ? ['/c', command] : ['-c', command];

String get _sleepCommand =>
    Platform.isWindows ? 'ping -n 2 127.0.0.1 > nul' : 'sleep 1';
