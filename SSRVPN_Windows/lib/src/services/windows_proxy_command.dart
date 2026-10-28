import 'dart:convert';

/// The parent owns the transaction lock; the child owns this second lock.
/// Native recovery takes both, so a child surviving a Flutter crash cannot
/// re-enable the proxy after recovery. A delayed child must reject a dead or
/// reused parent PID after obtaining its lock.
String windowsProxyCommandScript({
  required String script,
  required String transactionLockPath,
  required int parentPid,
  required String parentCreationTime,
}) {
  if (parentPid <= 0 || !RegExp(r'^\d+$').hasMatch(parentCreationTime)) {
    throw ArgumentError('Invalid proxy command owner');
  }
  final path = base64Encode(utf8.encode('$transactionLockPath.command'));
  return '''
$windowsProxyCommandOwnerInterop
\$ssrvpnCommandPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$path'))
\$ssrvpnCommandLock = [IO.File]::Open(\$ssrvpnCommandPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
try {
  \$ssrvpnCommandLock.Lock(0, 1)
  [SsrvpnProxyCommandOwner]::Watch($parentPid, '$parentCreationTime')
$script
} finally { \$ssrvpnCommandLock.Dispose() }
''';
}

// A bounded runner in Flutter cannot kill a hung command after Flutter dies.
// Hold an exact parent process handle and exit this PowerShell process on its
// death, releasing the command lock before native recovery proceeds.
const windowsProxyCommandOwnerInterop = r'''
Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Threading;
public static class SsrvpnProxyCommandOwner {
  public static void Watch(int pid, string expectedCreationTime) {
    var owner = Process.GetProcessById(pid);
    try {
      if (owner.HasExited || owner.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() != expectedCreationTime)
        throw new InvalidOperationException("SSRVPN proxy command owner exited or changed");
      var watcher = new Thread(() => {
        try { owner.WaitForExit(); } finally { Environment.Exit(125); }
      });
      watcher.IsBackground = true;
      watcher.Start();
    } catch { owner.Dispose(); throw; }
  }
}
"@
''';
