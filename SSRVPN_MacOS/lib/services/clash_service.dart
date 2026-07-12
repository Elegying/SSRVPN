import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import 'system_proxy_service.dart';

part 'clash_service_config.dart';
part 'clash_service_lifecycle.dart';

/// macOS Clash Meta 核心管理服务
///
/// 继承 [ClashServiceBase] 复用公共 API、延迟测试、健康检查等逻辑，
/// 仅保留 macOS 特有的进程管理、资源释放和系统代理集成。
class ClashService extends ClashServiceBase
    with _MacosClashConfig, _MacosCoreLifecycle {
  // ── macOS 静态路径 ──
  static const _chmodPath = '/bin/chmod';
  static const _coreName = 'AtlasCore';
  static const _coreManifestAsset = 'assets/AtlasCore-source.txt';
  static const _privilegedModeBits = 0xc00;
  // ── macOS 文件与日志 ──
  File? _logFile;
  BoundedFileLogger? _fileLogger;

  // ── Getters ──
  String get logPath => _logFile?.path ?? '';

  // ═══════════════════════════════════════════════════════════
  // 覆写：Base 方法
  // ═══════════════════════════════════════════════════════════

  @override
  void log(String message) {
    super.log(message);
    // macOS: 写入文件日志
    final fileLogger = _fileLogger;
    if (fileLogger != null) {
      final sanitized = LogRedactor.sanitize(message);
      final line = '[${DateTime.now().toIso8601String()}] $sanitized\n';
      fileLogger.add(line);
    }
  }

  @override
  @protected
  void debugLog(String message) {
    AppLogger.info('Clash', message);
  }

  // ═══════════════════════════════════════════════════════════
  // 初始化
  // ═══════════════════════════════════════════════════════════

  /// 初始化服务，设置路径
  ///
  /// macOS：数据保存在 ~/Library/Application Support/SSRVPN，
  /// 核心与 geoip 数据库随应用打包，首次运行时释放到该目录。
  Future<void> init(
    AppSettings settings, {
    String? dataDir,
    String? storageNotice,
    bool skipCoreProbes = false,
  }) async {
    updateSettings(settings);
    _startupDisabledReason = null;

    String configDir;
    if (dataDir != null && dataDir.isNotEmpty) {
      configDir = dataDir;
    } else {
      final supportDir = await getApplicationSupportDirectory();
      configDir = '${supportDir.path}${Platform.pathSeparator}SSRVPN';
    }
    final configPath = '$configDir${Platform.pathSeparator}config.yaml';
    setPaths(configDir: configDir, configPath: configPath);

    await _ensureRealDirectory(configDir);
    await Directory(
      '$configDir${Platform.pathSeparator}providers',
    ).create(recursive: true);
    _logFile = File('$configDir${Platform.pathSeparator}ssrvpn.log');
    await _rotateLogFile();
    _fileLogger = BoundedFileLogger(_logFile!);
    await _proxyService.initialize(configDir);

    _corePath = '$configDir${Platform.pathSeparator}$_coreName';

    // 初始化 HTTP 客户端
    initHttpClient();

    // 核心是可执行文件：先移除不可信的旧路径项，再安装普通用户文件。
    await _installCoreAsset(
      'assets/AtlasCore.gz',
      _corePath,
    );
    await _installAsset(
      'assets/geoip.metadb.gz',
      '$configDir${Platform.pathSeparator}geoip.metadb',
    );
    if (!skipCoreProbes) {
      await _terminateOrphanedCores();
    }

    log('系统: ${Platform.operatingSystemVersion}');
    log('程序路径: ${Platform.resolvedExecutable}');
    log('配置目录: $configDir');
    log('核心路径: $_corePath');
    log('诊断日志: ${_logFile!.path}');
    if (storageNotice != null && storageNotice.isNotEmpty) {
      log(storageNotice);
    }
    if (_proxyService.lastError != null) {
      log(_proxyService.lastError!);
    }
    if (!skipCoreProbes) {
      await _logCoreVersion();
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 资源配置
  // ═══════════════════════════════════════════════════════════

  Future<void> _rotateLogFile() async {
    final logFile = _logFile;
    if (logFile == null || !await logFile.exists()) return;
    if (await logFile.length() < 2 * 1024 * 1024) return;

    final oldFile = File('${logFile.path}.old');
    if (await oldFile.exists()) await oldFile.delete();
    await logFile.rename(oldFile.path);
  }

  Future<void> _ensureRealDirectory(String path) async {
    final initialType = await FileSystemEntity.type(path, followLinks: false);
    if (initialType == FileSystemEntityType.notFound) {
      await Directory(path).create(recursive: true);
    } else if (initialType != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Refusing to use a linked or non-directory data path',
        path,
      );
    }
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException('Data directory changed during setup', path);
    }
  }

  /// 安装可执行核心。目标和 revision 标记都按不可信路径处理，绝不跟随链接。
  Future<void> _installCoreAsset(String assetKey, String destPath) async {
    final data = await rootBundle.load(assetKey);
    final compressedBytes = data.buffer.asUint8List();
    final revision = crypto.sha256.convert(compressedBytes).toString();
    final expectedExecutableDigest = await _loadExpectedCoreDigest();
    final markerPath = '$destPath.rev';

    if (await _canReuseInstalledCore(
      destPath,
      markerPath,
      revision,
      expectedExecutableDigest,
    )) {
      return;
    }

    // 先解除旧核心在固定路径上的可达性，之后才进行解压和写入。
    await _removeUntrustedPathEntry(destPath);
    await _removeUntrustedPathEntry(markerPath);

    final compressed = compressedBytes;
    final bytes = Uint8List.fromList(
      await Isolate.run(() => gzip.decode(compressed)),
    );
    if (crypto.sha256.convert(bytes).toString() != expectedExecutableDigest) {
      throw StateError('Bundled Mihomo core does not match its trusted digest');
    }
    await _replaceRegularFile(destPath, bytes, executable: true);
    await _replaceRegularFile(markerPath, utf8.encode(revision));
    log('已安全释放核心: $assetKey -> $destPath');
  }

  Future<bool> _canReuseInstalledCore(
    String corePath,
    String markerPath,
    String revision,
    String expectedExecutableDigest,
  ) async {
    if (!await _isRegularUnprivilegedFile(corePath)) return false;
    if (await FileSystemEntity.type(markerPath, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    try {
      final marker = File(markerPath);
      if (await marker.length() != revision.length ||
          await marker.readAsString() != revision) {
        return false;
      }
      if (await _fileSha256(corePath) != expectedExecutableDigest ||
          await FileSystemEntity.type(corePath, followLinks: false) !=
              FileSystemEntityType.file) {
        return false;
      }
      await _setExecutableMode(corePath);
      return _isRegularUnprivilegedFile(corePath);
    } catch (_) {
      return false;
    }
  }

  Future<String> _loadExpectedCoreDigest() async {
    final manifest = await rootBundle.loadString(_coreManifestAsset);
    final match = RegExp(
      r'^Executable SHA256: ([0-9a-f]{64})$',
      multiLine: true,
    ).firstMatch(manifest);
    if (match == null) {
      throw const FormatException(
        'AtlasCore source manifest is missing Executable SHA256',
      );
    }
    return match[1]!;
  }

  Future<String> _fileSha256(String path) async {
    final digest = await crypto.sha256.bind(File(path).openRead()).first;
    return digest.toString();
  }

  Future<void> _replaceRegularFile(
    String path,
    List<int> bytes, {
    bool executable = false,
  }) async {
    final temp = File(
      '$path.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    await temp.create(exclusive: true);
    try {
      final handle = await temp.open(mode: FileMode.writeOnly);
      try {
        await handle.writeFrom(bytes);
        await handle.flush();
      } finally {
        await handle.close();
      }
      if (executable) {
        await _setExecutableMode(temp.path);
        if (!await _isRegularUnprivilegedFile(temp.path)) {
          throw FileSystemException('Unsafe temporary core file', temp.path);
        }
      }

      // Re-check immediately before rename in case the user-writable directory
      // changed while bytes were being written.
      await _removeUntrustedPathEntry(path);
      await temp.rename(path);

      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw FileSystemException('Installed path is not a regular file', path);
      }
      if (executable && !await _isRegularUnprivilegedFile(path)) {
        throw FileSystemException('Installed core has unsafe mode bits', path);
      }
    } finally {
      final type = await FileSystemEntity.type(temp.path, followLinks: false);
      if (type == FileSystemEntityType.file ||
          type == FileSystemEntityType.link) {
        await temp.delete();
      }
    }
  }

  Future<void> _removeUntrustedPathEntry(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type == FileSystemEntityType.file ||
        type == FileSystemEntityType.link) {
      await File(path).delete();
      return;
    }
    throw FileSystemException(
      'Refusing to replace a non-file core path entry',
      path,
    );
  }

  Future<bool> _isRegularUnprivilegedFile(String path) async {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    final stat = await File(path).stat();
    if (stat.type != FileSystemEntityType.file ||
        (stat.mode & _privilegedModeBits) != 0) {
      return false;
    }
    return await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.file;
  }

  Future<void> _setExecutableMode(String path) async {
    final result = await _runProcess(
      _chmodPath,
      ['755', path],
      timeout: const Duration(seconds: 5),
    );
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Unable to set safe executable mode: ${result.stderr}'.trim(),
        path,
      );
    }
  }

  @override
  Future<void> _verifyCoreForExecution() async {
    if (!await _isRegularUnprivilegedFile(_corePath)) {
      throw FileSystemException(
        'Mihomo core is not a regular unprivileged file',
        _corePath,
      );
    }
  }

  /// 从应用包内释放非可执行资源文件到目标路径。
  Future<void> _installAsset(
    String assetKey,
    String destPath,
  ) async {
    try {
      final dest = File(destPath);
      final marker = File('$destPath.rev');
      final data = await rootBundle.load(assetKey);
      final compressedBytes = data.buffer.asUint8List();
      final assetRevision = crypto.sha256.convert(compressedBytes).toString();

      // marker 记录源资源 SHA256；一致则跳过昂贵的 gzip 解压
      if (await dest.exists() &&
          await marker.exists() &&
          (await marker.readAsString()) == assetRevision) {
        return;
      }

      var bytes = compressedBytes;
      if (assetKey.endsWith('.gz')) {
        final compressed = bytes;
        // 核心二进制解压有几十 MB，放后台 isolate 避免卡 UI
        bytes = Uint8List.fromList(
          await Isolate.run(() => gzip.decode(compressed)),
        );
      }
      final existingMatches = await _fileContentMatches(dest, bytes);
      if (!existingMatches) {
        await writeBytesAtomically(dest, bytes);
        log('已释放资源: $assetKey -> $destPath');
      }
      await writeStringAtomically(marker, assetRevision);
    } catch (e) {
      log('释放资源失败 $assetKey: $e');
    }
  }

  Future<bool> _fileContentMatches(File file, List<int> bytes) async {
    if (!await file.exists()) return false;
    if (await file.length() != bytes.length) return false;
    final digest = crypto.sha256.convert(await file.readAsBytes()).toString();
    final expected = crypto.sha256.convert(bytes).toString();
    return digest == expected;
  }
}
