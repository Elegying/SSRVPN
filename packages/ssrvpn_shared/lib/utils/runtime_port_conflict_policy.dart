class RuntimePortConflictPolicy {
  const RuntimePortConflictPolicy._();

  /// Mihomo surfaces bind failures through different platform wrappers. Keep
  /// this deliberately narrow: only explicit socket-address collision wording
  /// authorizes regenerating the runtime config with different ports.
  static bool isExplicitBindConflict(String? message) {
    final value = message?.trim().toLowerCase() ?? '';
    if (value.isEmpty) return false;
    return value.contains('address already in use') ||
        value.contains('eaddrinuse') ||
        value.contains('only one usage of each socket address') ||
        RegExp(r'端口.{0,12}(已被|被其他|正在被).{0,8}占用').hasMatch(value) ||
        RegExp(r'(bind|listen).{0,80}(端口|port).{0,20}占用').hasMatch(value);
  }
}
