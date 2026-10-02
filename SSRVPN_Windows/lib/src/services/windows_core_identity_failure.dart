import 'dart:io';

import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import 'windows_core_pid_record.dart';

enum WindowsCoreIdentityFailureKind {
  timeout,
  execution,
  invalidData,
  mismatch
}

/// Only bounded, redacted diagnostic text crosses the startup boundary.
class WindowsCoreIdentityFailure implements Exception {
  WindowsCoreIdentityFailure(this.kind, Object reason)
      : reason = LogRedactor.sanitize(_redactPaths(reason is ProcessException
                ? '${reason.message}; osError=${reason.errorCode}'
                : reason.toString()))
            .replaceAll(RegExp(r'[\r\n]+'), ' ');

  static String _redactPaths(String text) => text
      .replaceAll(RegExp(r'"(?:[A-Za-z]:[\\/]|\\\\)[^"\r\n]*(?:"|$)'), '[本地路径]')
      .replaceAll(
          RegExp(r"'(?:[A-Za-z]:[\\/]|\\\\)[^\r\n]*'"
              r"|'(?:[A-Za-z]:[\\/]|\\\\)[^\r\n]*$"),
          '[本地路径]')
      .replaceAll(RegExp(r'''(?:[A-Za-z]:[\\/]|\\\\)[^;\r\n"]+'''), '[本地路径]');

  final WindowsCoreIdentityFailureKind kind;
  final String reason;

  @override
  String toString() {
    final summary = switch (kind) {
      WindowsCoreIdentityFailureKind.timeout => '读取核心进程身份超时，请稍后重试',
      WindowsCoreIdentityFailureKind.execution => '读取核心进程身份的系统命令执行失败',
      WindowsCoreIdentityFailureKind.invalidData => '核心进程身份返回数据异常',
      WindowsCoreIdentityFailureKind.mismatch => '核心进程身份不符，已拒绝接管该进程',
    };
    final bounded = reason.length > 512 ? reason.substring(0, 512) : reason;
    return 'CORE_IDENTITY_${kind.name.toUpperCase()}: $summary；$bounded';
  }
}

WindowsCorePidRecord decodeWindowsCoreIdentity(
    ProcessResult result, int expectedPid, String expectedPath) {
  if (result.exitCode != 0) {
    final stderr = result.stderr.toString().trim();
    final kind = result.exitCode == 124
        ? WindowsCoreIdentityFailureKind.timeout
        : stderr.contains('Mihomo identity did not match')
            ? WindowsCoreIdentityFailureKind.mismatch
            : WindowsCoreIdentityFailureKind.execution;
    throw WindowsCoreIdentityFailure(kind,
        'exitCode=${result.exitCode}; ${stderr.isEmpty ? '系统命令没有返回错误详情' : stderr}');
  }
  final record = WindowsCorePidRecord.tryParse(result.stdout.toString().trim());
  if (record == null) {
    // Raw identity JSON contains an executable path and is not a safe reason.
    throw WindowsCoreIdentityFailure(
        WindowsCoreIdentityFailureKind.invalidData, '进程记录缺失或格式无效');
  }
  if (record.pid != expectedPid ||
      record.canonicalExecutablePath.toLowerCase() !=
          expectedPath.toLowerCase()) {
    throw WindowsCoreIdentityFailure(
        WindowsCoreIdentityFailureKind.mismatch, 'PID 或可执行文件路径不匹配');
  }
  return record;
}
