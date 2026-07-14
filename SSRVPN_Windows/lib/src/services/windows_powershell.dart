import 'dart:io';

const _utf8OutputPrologue = r'''$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
''';

String windowsPowerShellUtf8Script(String script) =>
    '$_utf8OutputPrologue$script';

String windowsPowerShellExecutable() {
  if (!Platform.isWindows) return 'powershell';
  final windowsDir =
      Platform.environment['SystemRoot'] ?? Platform.environment['WINDIR'];
  if (windowsDir != null && windowsDir.trim().isNotEmpty) {
    final executable = File(
      '$windowsDir${Platform.pathSeparator}System32'
      '${Platform.pathSeparator}WindowsPowerShell'
      '${Platform.pathSeparator}v1.0'
      '${Platform.pathSeparator}powershell.exe',
    );
    if (executable.existsSync()) return executable.path;
  }
  return 'powershell';
}
