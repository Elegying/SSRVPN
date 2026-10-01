part of 'clash_service.dart';

extension _WindowsCoreIdentity on _WindowsCoreLifecycle {
  Future<WindowsCorePidRecord> _captureCorePidRecord(int corePid) async {
    final encodedTrustedPath = base64Encode(utf8.encode(_corePath));
    final script = '''
\$trustedPath = [Text.Encoding]::UTF8.GetString(
  [Convert]::FromBase64String('$encodedTrustedPath'))
\$process = [Diagnostics.Process]::GetProcessById([int]$corePid)
try {
  \$process.Refresh()
  if (\$process.HasExited) {
    throw 'Mihomo exited before its durable identity was captured.'
  }
  \$livePath = [IO.Path]::GetFullPath(\$process.MainModule.FileName)
  \$canonicalTrustedPath = [IO.Path]::GetFullPath(\$trustedPath)
  \$currentSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
  if (\$process.Id -ne [int]$corePid -or
      \$process.SessionId -ne \$currentSessionId -or
      -not \$livePath.Equals(
        \$canonicalTrustedPath,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Mihomo identity did not match the process started by SSRVPN.'
  }
  \$creationTime = \$process.StartTime.ToUniversalTime().ToFileTimeUtc()
  if (\$creationTime -le 0) {
    throw 'Mihomo creation time was invalid.'
  }
  [ordered]@{
    version = $windowsCorePidRecordVersion
    pid = [int]$corePid
    creationTimeUtcFileTime = \$creationTime.ToString(
      [Globalization.CultureInfo]::InvariantCulture)
    canonicalExecutablePath = \$livePath
  } | ConvertTo-Json -Compress
} finally {
  \$process.Dispose()
}
''';
    try {
      final result =
          await _runPowerShell(script, timeout: const Duration(seconds: 8));
      return decodeWindowsCoreIdentity(result, corePid, _corePath);
    } on WindowsCoreIdentityFailure {
      rethrow;
    } on TimeoutException catch (error) {
      throw WindowsCoreIdentityFailure(
          WindowsCoreIdentityFailureKind.timeout, error);
    } catch (error) {
      throw WindowsCoreIdentityFailure(
          WindowsCoreIdentityFailureKind.execution, error);
    }
  }
}
