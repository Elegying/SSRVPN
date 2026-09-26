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

// Read-only policy probe. Registry64 matches the shipped x64 application.
const windowsPerUserProxyPolicyScript = r'''
$policyBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
try {
  $policy = $policyBase.OpenSubKey('SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings', $false)
  if ($null -ne $policy) {
    try {
      $value = $policy.GetValue('ProxySettingsPerUser', $null)
      if ($null -ne $value) {
        if ($policy.GetValueKind('ProxySettingsPerUser') -ne [Microsoft.Win32.RegistryValueKind]::DWord -or $value -ne 1) {
          throw 'SSRVPN requires per-user proxy settings; machine proxy policy is active or invalid.'
        }
      }
    } finally { $policy.Dispose() }
  }
} finally { $policyBase.Dispose() }
''';

String formatWindowsPowerShellError(String prefix, ProcessResult result) {
  if (result.exitCode == 124) {
    return 'Windows 系统代理 PowerShell 命令响应超时；可能是系统繁忙或安全软件暂时拦截，请稍后重试';
  }
  final stderr = result.stderr.toString().trim();
  final stdout = result.stdout.toString().trim();
  final detail = stderr.isNotEmpty ? stderr : stdout;
  return detail.isEmpty
      ? '$prefix（退出码 ${result.exitCode}）'
      : '$prefix（退出码 ${result.exitCode}）: $detail';
}
