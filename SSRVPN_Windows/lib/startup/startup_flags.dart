class StartupFlags {
  const StartupFlags._({
    required this.safeMode,
    required bool disableTray,
    required bool resetWindow,
    required bool disableCoreAutostart,
    required this.verbose,
    required this.rawArgs,
  })  : _disableTray = disableTray,
        _resetWindow = resetWindow,
        _disableCoreAutostart = disableCoreAutostart;

  factory StartupFlags.parse(List<String> args) {
    final normalized = args.map((arg) => arg.trim().toLowerCase()).toSet();
    final safeMode = normalized.contains('--safe-mode');
    return StartupFlags._(
      safeMode: safeMode,
      disableTray: normalized.contains('--disable-tray'),
      resetWindow: normalized.contains('--reset-window'),
      disableCoreAutostart:
          normalized.contains('--disable-core-autostart'),
      verbose: normalized.contains('--verbose'),
      rawArgs: List.unmodifiable(args),
    );
  }

  final bool safeMode;
  final bool _disableTray;
  final bool _resetWindow;
  final bool _disableCoreAutostart;
  final bool verbose;
  final List<String> rawArgs;

  bool get disableTray => safeMode || _disableTray;
  bool get resetWindow => safeMode || _resetWindow;
  bool get disableCoreAutostart => safeMode || _disableCoreAutostart;

  @override
  String toString() {
    return 'StartupFlags('
        'safeMode=$safeMode, '
        'disableTray=$disableTray, '
        'resetWindow=$resetWindow, '
        'disableCoreAutostart=$disableCoreAutostart, '
        'verbose=$verbose)';
  }
}
