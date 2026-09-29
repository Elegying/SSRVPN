part of 'system_proxy_service.dart';

// Journal I/O only. Transaction locks and recovery ordering stay in the service.
extension _SystemProxyRecoveryJournal on SystemProxyService {
  Future<_NativeProxyJournal?> _readNativeRecoveryJournal(
    String ownedProxyServer,
  ) async {
    final encodedServer = base64Encode(utf8.encode(ownedProxyServer));
    final encodedOverride =
        base64Encode(utf8.encode(SystemProxyService._ownedProxyOverride));
    final result = await _runPowerShell('''
\$path = '${SystemProxyService._nativeBackupRegistryPath}'
if (-not (Test-Path -LiteralPath \$path)) {
  [Console]::Out.Write('TERMINAL')
  exit 0
}
\$item = Get-ItemProperty -LiteralPath \$path
\$expectedServer = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedServer'))
\$expectedOverride = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedOverride'))
\$required = @('Valid', 'OwnedProxyServer', 'OwnedProxyOverride',
  'RestoreInProgress', 'EndpointRestoreInProgress', 'ActivationInProgress')
foreach (\$name in \$required) {
  if (\$null -eq \$item.PSObject.Properties[\$name]) {
    [Console]::Out.Write('TERMINAL')
    exit 0
  }
}
if ([int]\$item.Valid -ne 1 -or
    [string]\$item.OwnedProxyServer -cne \$expectedServer -or
    [string]\$item.OwnedProxyOverride -cne \$expectedOverride) {
  [Console]::Out.Write('TERMINAL')
  exit 0
}
if ([int]\$item.EndpointRestoreInProgress -eq 1 -and
    [int]\$item.RestoreInProgress -eq 0) {
  [Console]::Out.Write('ENDPOINT_RESTORE')
} elseif ([int]\$item.RestoreInProgress -eq 1 -and
    [int]\$item.EndpointRestoreInProgress -eq 0) {
  [Console]::Out.Write('FULL_RESTORE')
} elseif ([int]\$item.ActivationInProgress -eq 1 -and
    [int]\$item.RestoreInProgress -eq 0 -and
    [int]\$item.EndpointRestoreInProgress -eq 0) {
  [Console]::Out.Write('ACTIVATION')
} else {
  [Console]::Out.Write('TERMINAL')
}
''');
    if (result.exitCode != 0) {
      _lastError =
          formatWindowsPowerShellError('读取 Windows 原生代理恢复阶段失败', result);
      return null;
    }
    final output = result.stdout.toString().trim();
    return switch (output) {
      'ACTIVATION' => const _NativeProxyJournal(
          WindowsProxyTransactionPhase.activation,
        ),
      'FULL_RESTORE' => const _NativeProxyJournal(
          WindowsProxyTransactionPhase.fullRestore,
        ),
      'ENDPOINT_RESTORE' => const _NativeProxyJournal(
          WindowsProxyTransactionPhase.endpointRestore,
        ),
      'TERMINAL' => const _NativeProxyJournal(null),
      _ => null,
    };
  }

  Future<void> _writeNativeRecoveryBackup(
    _ProxySnapshot snapshot,
    String ownedProxyServer, {
    Future<void>? cancellation,
  }) async {
    String encoded(String value) => base64Encode(utf8.encode(value));
    final script = '''
\$backupPath = '${SystemProxyService._nativeBackupRegistryPath}'
if (Test-Path -LiteralPath \$backupPath) {
  Remove-Item -LiteralPath \$backupPath -Recurse -Force
}
New-Item -Path \$backupPath -Force | Out-Null
Set-ItemProperty -Path \$backupPath -Name OriginalProxyEnable -Type DWord -Value ${snapshot.proxyEnable}
Set-ItemProperty -Path \$backupPath -Name HasProxyEnable -Type DWord -Value ${snapshot.hasProxyEnable ? 1 : 0}
Set-ItemProperty -Path \$backupPath -Name HasProxyServer -Type DWord -Value ${snapshot.hasProxyServer ? 1 : 0}
\$value = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${encoded(snapshot.proxyServer)}'))
Set-ItemProperty -Path \$backupPath -Name OriginalProxyServer -Type String -Value \$value
Set-ItemProperty -Path \$backupPath -Name HasProxyOverride -Type DWord -Value ${snapshot.hasProxyOverride ? 1 : 0}
\$value = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${encoded(snapshot.proxyOverride)}'))
Set-ItemProperty -Path \$backupPath -Name OriginalProxyOverride -Type String -Value \$value
Set-ItemProperty -Path \$backupPath -Name HasAutoConfigURL -Type DWord -Value ${snapshot.hasAutoConfigUrl ? 1 : 0}
\$value = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${encoded(snapshot.autoConfigUrl)}'))
Set-ItemProperty -Path \$backupPath -Name OriginalAutoConfigURL -Type String -Value \$value
Set-ItemProperty -Path \$backupPath -Name HasAutoDetect -Type DWord -Value ${snapshot.hasAutoDetect ? 1 : 0}
Set-ItemProperty -Path \$backupPath -Name OriginalAutoDetect -Type DWord -Value ${snapshot.autoDetect}
Set-ItemProperty -Path \$backupPath -Name OwnedProxyServer -Type String -Value '$ownedProxyServer'
Set-ItemProperty -Path \$backupPath -Name OwnedProxyOverride -Type String -Value '${SystemProxyService._ownedProxyOverride}'
Set-ItemProperty -Path \$backupPath -Name RestoreInProgress -Type DWord -Value 0
Set-ItemProperty -Path \$backupPath -Name EndpointRestoreInProgress -Type DWord -Value 0
Set-ItemProperty -Path \$backupPath -Name ActivationInProgress -Type DWord -Value 1
Set-ItemProperty -Path \$backupPath -Name Valid -Type DWord -Value 1
''';
    final result = await _runPowerShell(script, cancellation: cancellation);
    if (result.exitCode == 125) {
      throw const _SystemProxyAcquisitionCancelled();
    }
    if (result.exitCode != 0) {
      throw StateError(
          formatWindowsPowerShellError('写入 Windows 原生代理恢复状态失败', result));
    }
  }

  Future<void> _markActivationComplete({
    _SystemProxyAcquisitionCancellation? cancellation,
  }) async {
    cancellation?.throwIfRequested();
    final result = await _runPowerShell('''
\$backupPath = '${SystemProxyService._nativeBackupRegistryPath}'
Set-ItemProperty -Path \$backupPath -Name ActivationInProgress -Type DWord -Value 0
''', cancellation: cancellation?.future);
    if (result.exitCode == 125) {
      throw const _SystemProxyAcquisitionCancelled();
    }
    if (result.exitCode != 0) {
      throw StateError(
          formatWindowsPowerShellError('更新 Windows 原生代理恢复状态失败', result));
    }

    final statePath = _statePath;
    if (statePath == null) {
      throw StateError('System proxy state path is missing');
    }
    final file = File(statePath);
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    cancellation?.throwIfRequested();
    json['_activationInProgress'] = false;
    final temp = File('$statePath.tmp');
    await temp.writeAsString(jsonEncode(json), flush: true);
    await temp.rename(statePath);
    cancellation?.throwIfRequested();
  }
}
