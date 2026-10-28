import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/src/services/windows_core_process_query.dart';
import 'package:ssrvpn_windows/src/services/windows_powershell.dart';
import 'package:ssrvpn_windows/src/services/windows_proxy_command.dart';

void main() {
  test('invalid command owner is rejected before producing a script', () {
    for (final value in ['-1', "1'; exit 0", '']) {
      expect(
          () => windowsProxyCommandScript(
              script: 'throw',
              transactionLockPath: 'unused',
              parentPid: 7,
              parentCreationTime: value),
          throwsArgumentError);
    }
  });
  test('a hung proxy writer exits when its exact parent dies', () async {
    final dir = await Directory.systemTemp.createTemp('ssrvpn-command-death-');
    addTearDown(() => dir.delete(recursive: true));
    final parent = await Process.start(windowsPowerShellExecutable(), [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r"[Console]::Out.WriteLine([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToFileTimeUtc()); Start-Sleep -Seconds 60",
    ]);
    addTearDown(() async {
      parent.kill();
      await parent.exitCode;
    });
    final parentLines = StreamIterator(
        parent.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    expect(await parentLines.moveNext(), isTrue);
    final creation = parentLines.current.trim();
    final lockPath = '${dir.path}/transaction.lock';
    final writer = await Process.start(windowsPowerShellExecutable(), [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      windowsPowerShellUtf8Script(windowsProxyCommandScript(
        script:
            "[Console]::Out.WriteLine('READY'); Start-Sleep -Seconds 60; [Console]::Out.WriteLine('LATE_MUTATION')",
        transactionLockPath: lockPath,
        parentPid: parent.pid,
        parentCreationTime: creation,
      )),
    ]);
    addTearDown(() async {
      writer.kill();
      await writer.exitCode;
    });
    final lines = StreamIterator(
        writer.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    expect(await lines.moveNext().timeout(const Duration(seconds: 15)), isTrue);
    expect(lines.current, 'READY');
    parent.kill();
    await parent.exitCode;
    expect(await writer.exitCode.timeout(const Duration(seconds: 5)), 125);
    expect(await lines.moveNext(), isFalse);
    await parentLines.cancel();
    await lines.cancel();
    final after = await File('$lockPath.command').open(mode: FileMode.append);
    await after.lock(FileLock.exclusive, 0, 1);
    await after.close();
  }, skip: !Platform.isWindows);
  for (final scenario in ['live', 'exited', 'reused', 'locked']) {
    test('proxy writer requires live exact owner and exclusive lock: $scenario',
        () async {
      final dir = await Directory.systemTemp.createTemp("SSRVPN 用户's command ");
      addTearDown(() => dir.delete(recursive: true));
      final lockPath = '${dir.path}/transaction.lock';
      final owner = queryWindowsCoreIdentity(pid, Platform.resolvedExecutable);
      RandomAccessFile? held;
      if (scenario == 'locked') {
        held = await File('$lockPath.command').open(mode: FileMode.append);
        await held.lock(FileLock.exclusive, 0, 1);
      }
      ProcessResult result;
      try {
        result = await TimedProcessRunner.run(
            windowsPowerShellExecutable(),
            [
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              windowsPowerShellUtf8Script(windowsProxyCommandScript(
                script: "'MUTATION_ALLOWED'",
                transactionLockPath: lockPath,
                parentPid: scenario == 'exited' ? 2147483647 : pid,
                parentCreationTime:
                    scenario == 'reused' ? '1' : owner.creationTimeUtcFileTime,
              )),
            ],
            timeout: const Duration(seconds: 10));
      } finally {
        await held?.close();
      }
      if (scenario == 'live') {
        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(result.stdout.toString().trim(), 'MUTATION_ALLOWED');
      } else {
        expect(result.exitCode, isNot(0));
        expect(result.stdout.toString(), isNot(contains('MUTATION_ALLOWED')));
      }
      // An exception must release the child-side lock for native recovery.
      final after = await File('$lockPath.command').open(mode: FileMode.append);
      await after.lock(FileLock.exclusive, 0, 1);
      await after.close();
    }, skip: !Platform.isWindows);
  }
}
