part of 'clash_service.dart';

class _DesktopStartCancelled implements Exception {}

class MacosNativeCoreHandle {
  const MacosNativeCoreHandle({
    required this.pid,
    required this.pidRecordContents,
  });

  final int pid;
  final String pidRecordContents;
}

class MacosNativeCoreStatus {
  const MacosNativeCoreStatus({
    required this.isRunning,
    required this.exitCode,
    required this.standardOutput,
    required this.standardError,
  });

  final bool isRunning;
  final int? exitCode;
  final String standardOutput;
  final String standardError;
}

MacosNativeCoreHandle parseMacosNativeCoreLaunch(Object? value) {
  if (value is! Map) throw StateError('原生核心启动结果无效');
  final rawPid = value['pid'];
  final corePid = rawPid is int ? rawPid : null;
  final record = value['pidRecordContents'];
  if (corePid == null || record is! String) {
    throw StateError('原生核心启动结果无效');
  }
  return MacosNativeCoreHandle(
    pid: corePid,
    pidRecordContents: validateMacosCorePidRecord(record, corePid),
  );
}

MacosNativeCoreStatus parseMacosNativeCoreStatus(Object? value) {
  if (value is! Map ||
      value['isRunning'] is! bool ||
      value['standardOutput'] is! String ||
      value['standardError'] is! String) {
    throw StateError('原生核心状态无效');
  }
  final isRunning = value['isRunning'] as bool;
  final rawExitCode = value['exitCode'];
  final expectedKeys = isRunning
      ? const {'isRunning', 'standardOutput', 'standardError'}
      : const {'isRunning', 'exitCode', 'standardOutput', 'standardError'};
  if (value.keys.toSet().difference(expectedKeys).isNotEmpty ||
      expectedKeys.difference(value.keys.toSet()).isNotEmpty ||
      (isRunning ? rawExitCode != null : rawExitCode is! int)) {
    throw StateError('原生核心退出码无效');
  }
  return MacosNativeCoreStatus(
    isRunning: isRunning,
    exitCode: rawExitCode as int?,
    standardOutput: value['standardOutput'] as String,
    standardError: value['standardError'] as String,
  );
}

String validateMacosCorePidRecord(String? contents, int expectedPid) {
  if (contents == null || !contents.endsWith('\n')) {
    throw StateError('原生进程身份记录无效');
  }
  final fields = contents.substring(0, contents.length - 1).split(' ');
  final recordedPid = fields.length == 4 ? int.tryParse(fields[1]) : null;
  final startSeconds = fields.length == 4 ? int.tryParse(fields[2]) : null;
  final startMicroseconds = fields.length == 4 ? int.tryParse(fields[3]) : null;
  final canonical = fields.length == 4 &&
      fields[0] == 'v2' &&
      recordedPid == expectedPid &&
      expectedPid > 1 &&
      startSeconds != null &&
      startSeconds > 0 &&
      startMicroseconds != null &&
      startMicroseconds >= 0 &&
      startMicroseconds < 1000000 &&
      contents == 'v2 $recordedPid $startSeconds $startMicroseconds\n';
  if (!canonical) throw StateError('原生进程身份记录无效');
  return contents;
}

String buildMacosUnexpectedExitNotice({
  required int exitCode,
  required bool proxyRecovered,
}) =>
    proxyRecovered
        ? '本地代理服务异常退出（退出码 $exitCode），系统代理已恢复。请点击首页“连接”重试。'
        : '本地代理服务异常退出（退出码 $exitCode），系统代理恢复失败。已保留恢复记录并暂停新连接，请点击首页“连接”重试；仍失败请打开日志诊断。';

String? buildMacosStartupRecoveryNotice({
  required bool proxyRecoveryPending,
  required bool corePreparationPending,
}) {
  if (proxyRecoveryPending) {
    return '检测到上次退出遗留的系统代理状态。为保护网络，SSRVPN 已保留原本地代理服务并暂停新连接；请点击首页“连接”重试恢复。';
  }
  if (corePreparationPending) {
    return '系统代理已恢复，但本地代理服务的安全准备尚未完成。SSRVPN 已保留原服务并暂停新连接；请点击首页“连接”重试准备。';
  }
  return null;
}
