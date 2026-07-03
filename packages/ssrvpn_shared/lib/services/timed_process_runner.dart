import 'dart:convert';
import 'dart:io';

class TimedProcessRunner {
  static Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    bool includeParentEnvironment = true,
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 10),
    int timeoutExitCode = 124,
    String timeoutStderr = '命令超时',
  }) async {
    Process? process;
    try {
      process = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        includeParentEnvironment: includeParentEnvironment,
        environment: environment,
      );
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode.timeout(
        timeout,
        onTimeout: () {
          process?.kill(ProcessSignal.sigkill);
          return timeoutExitCode;
        },
      );
      final stdout = await stdoutFuture;
      final stderr =
          exitCode == timeoutExitCode ? timeoutStderr : await stderrFuture;
      return ProcessResult(process.pid, exitCode, stdout, stderr);
    } catch (_) {
      process?.kill(ProcessSignal.sigkill);
      rethrow;
    }
  }
}
