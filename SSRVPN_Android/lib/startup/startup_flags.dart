/// 启动参数解析
///
/// Android 通过 Intent extras 传入参数（与 macOS 命令行参数对齐）
class StartupFlags {
  final bool verbose;
  final bool resetWindow; // Android 上用于重置数据
  final bool skipUpdateCheck;

  const StartupFlags({
    this.verbose = false,
    this.resetWindow = false,
    this.skipUpdateCheck = false,
  });

  /// 从 Map（Android Intent extras）解析
  factory StartupFlags.fromMap(Map<String, dynamic>? extras) {
    if (extras == null) return const StartupFlags();
    return StartupFlags(
      verbose: extras['verbose'] == true,
      resetWindow: extras['resetData'] == true || extras['resetWindow'] == true,
      skipUpdateCheck: extras['skipUpdateCheck'] == true,
    );
  }

  /// 默认参数
  factory StartupFlags.defaults() => const StartupFlags();
}
