part of 'clash_service.dart';

mixin _WindowsCoreValidation on ClashServiceBase {
  String get _corePath;
  Completer<void>? get _startCancellation;

  @protected
  Future<bool> validateConfig(Map<String, String> environment) async {
    log('正在校验 Mihomo 配置...');
    final watch = Stopwatch()..start();
    try {
      final result = await TimedProcessRunner.run(
        _corePath,
        ['-t', '-d', configDir, '-f', configPath],
        includeParentEnvironment: true,
        environment: environment,
        timeout: const Duration(seconds: 40),
        cancellation: _startCancellation?.future,
        timeoutStderr: 'Windows Mihomo 核心启动配置校验响应超时；可能是系统繁忙或安全软件暂时拦截，请稍后重试',
      );
      final stdout = result.stdout.toString().trim();
      final stderr = result.stderr.toString().trim();
      if (stdout.isNotEmpty) log('[配置校验] $stdout');
      if (stderr.isNotEmpty) log('[配置校验 stderr] $stderr');
      if (result.exitCode == 0) {
        log('✅ Mihomo 配置校验通过，耗时 ${watch.elapsedMilliseconds}ms');
        return true;
      }
      if (result.exitCode == 125) throw _DesktopStartCancelled();
      if (result.exitCode == 124) {
        setLastStartError('Windows Mihomo 核心启动配置校验响应超时；可能是系统繁忙或安全软件暂时拦截，请稍后重试');
        log('❌ $lastStartError');
        return false;
      }
      final reason = _describeWindowsExitCode(result.exitCode);
      final detail = stderr.isNotEmpty ? stderr : stdout;
      if (reason != null) {
        setLastStartError('Mihomo 无法在此电脑运行: $reason');
      } else if (detail.isNotEmpty) {
        setLastStartError('Mihomo 配置校验失败: $detail');
      }
      log(
        '❌ Mihomo 配置校验失败，退出码: ${result.exitCode}'
        '${reason == null ? "" : "（$reason）"}',
      );
      if (lastStartError == null) {
        setLastStartError('Mihomo 配置校验失败，请打开运行日志查看具体配置错误');
      }
      return false;
    } on _DesktopStartCancelled {
      rethrow;
    } catch (e) {
      setLastStartError(_friendlyStartException(e));
      final failureCode = AppFailure.fromMessage(lastStartError).code.wireName;
      log('event=windows_config_validation_launch_failed cause=$failureCode');
      return false;
    }
  }
}
