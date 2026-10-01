import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/src/services/windows_core_identity_failure.dart';
import 'package:ssrvpn_windows/src/services/windows_core_pid_record.dart';

void main() {
  test('input truncation cannot expose an unterminated quoted path', () {
    for (final quote in ["'", '"']) {
      final path = r'C:\Private Folder\' + 'a' * 5000;
      final error = WindowsCoreIdentityFailure(
          WindowsCoreIdentityFailureKind.execution,
          'Access denied reading $quote$path$quote; osError=5');
      expect(error.toString(), isNot(contains('Private Folder')));
      expect(error.toString(), isNot(contains('Folder')));
      expect(error.toString(), contains('Access denied'));
      expect(error.toString().length, lessThan(650));
    }
  });
  test('double-quoted paths retain no suffix after an apostrophe', () {
    for (final path in [
      r"C:\Users\O'Neil\Private Folder\identity.json",
      r"C:/Users/O'Neil/Private Folder/identity.json",
      r"\\private-share\O'Neil\Private Folder\identity.json",
    ]) {
      final error = WindowsCoreIdentityFailure(
          WindowsCoreIdentityFailureKind.execution,
          'Access denied reading "$path"; osError=5');
      expect(error.reason, contains('[本地路径]'));
      expect(error.reason, isNot(contains('Neil')));
      expect(error.reason, isNot(contains('Private Folder')));
      expect(error.reason, contains('Access denied'));
      expect(error.reason, contains('osError=5'));
    }
  });
  const record = WindowsCorePidRecord(
      pid: 42,
      creationTimeUtcFileTime: '123',
      canonicalExecutablePath: r'C:\SSRVPN\mihomo.exe');
  test(
      'identity outcomes distinguish timeout, execution, invalid data and mismatch',
      () {
    for (final (result, kind) in [
      (
        ProcessResult(0, 124, '', 'probe deadline'),
        WindowsCoreIdentityFailureKind.timeout
      ),
      (
        ProcessResult(0, 1, '', 'Access is denied; password=fixture-secret'),
        WindowsCoreIdentityFailureKind.execution
      ),
      (
        ProcessResult(0, 0, 'invalid json', ''),
        WindowsCoreIdentityFailureKind.invalidData
      ),
      (
        ProcessResult(0, 0, record.encode(), ''),
        WindowsCoreIdentityFailureKind.mismatch
      ),
      (
        ProcessResult(0, 1, '', 'Mihomo identity did not match'),
        WindowsCoreIdentityFailureKind.mismatch
      ),
    ]) {
      expect(
          () => decodeWindowsCoreIdentity(
              result, 43, record.canonicalExecutablePath),
          throwsA(isA<WindowsCoreIdentityFailure>()
              .having((e) => e.kind, 'kind', kind)
              .having((e) => e.toString(), 'redacted cause',
                  isNot(contains('fixture-secret')))));
    }
    expect(
        decodeWindowsCoreIdentity(ProcessResult(0, 0, record.encode(), ''), 42,
            record.canonicalExecutablePath),
        record);
  });
  test(
      'system execution exception preserves cause without command, path or credentials',
      () {
    final error = WindowsCoreIdentityFailure(
        WindowsCoreIdentityFailureKind.execution,
        ProcessException(r'C:\private\powershell.exe',
            ['password=fixture-secret'], 'Access denied', 5));
    expect(error.toString(), contains('Access denied'));
    expect(error.toString(), contains('osError=5'));
    expect(error.toString(), isNot(contains('private')));
    expect(error.toString(), isNot(contains('fixture-secret')));
    final failure = AppFailure.fromMessage(error);
    expect(failure.userMessage, contains('系统命令执行失败'));
    expect(failure.userMessage, isNot(contains('重装')));
  });
  test('all identity categories remain distinct in the user-facing failure',
      () {
    final failures = [
      for (final kind in WindowsCoreIdentityFailureKind.values)
        AppFailure.fromMessage(WindowsCoreIdentityFailure(
            kind, 'private system detail; password=fixture-secret')),
    ];
    expect(
        failures.map((failure) => failure.userMessage).toSet(), hasLength(4));
    expect(failures.first.code, AppErrorCode.coreStartTimeout);
    for (final failure in failures) {
      expect(failure.userMessage, isNot(contains('重装')));
      expect(failure.userMessage, isNot(contains('private system detail')));
      expect(failure.userMessage, isNot(contains('fixture-secret')));
    }
  });
  test('quoted Windows paths with spaces and UNC shares are fully redacted',
      () {
    for (final path in [
      r'C:\Private Folder\Fixture Name\identity.json',
      r'C:/Private Folder/Fixture Name/identity.json',
      r'\\private-share\Fixture Name\identity.json',
    ]) {
      for (final quote in ["'", '"']) {
        final error = WindowsCoreIdentityFailure(
            WindowsCoreIdentityFailureKind.execution,
            'Access denied reading $quote$path$quote; osError=5; password=fixture-secret');
        expect(error.toString(), contains('Access denied'));
        expect(error.toString(), contains('osError=5'));
        expect(error.toString(), isNot(contains('Fixture Name')));
        expect(error.toString(), isNot(contains('private-share')));
        expect(error.toString(), isNot(contains('fixture-secret')));
      }
    }
  });
}
