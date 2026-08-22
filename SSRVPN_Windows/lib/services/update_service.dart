import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:win32/win32.dart';

import '../theme/app_theme.dart';
import 'windows_desktop_directory.dart';

/// 在线更新服务 - GitHub Releases。
class UpdateService {
  static const String appVersion = AppConstants.appVersion;
  static const String verifiedUpdateMarkerSuffix = '.ssrvpn-verified-update';
  static const String _verifiedUpdateMarkerMagic = 'ssrvpn-verified-update-v2';
  static const String _verifiedUpdateOwnerStreamName = 'ssrvpn-update-owner';

  static Future<AppUpdateInfo?> checkForUpdate(
    String currentVersion,
  ) {
    return SharedUpdateService.checkForUpdate(
      currentVersion: currentVersion,
      assetExtension: '.exe',
    );
  }

  static Future<void> showUpdateDialog(
    BuildContext context, {
    required String latestVersion,
    required String currentVersion,
    required String downloadUrl,
    required String changelog,
    required String? sha256,
    String? fallbackDownloadUrl,
    Directory? desktopDirectory,
    http.Client? client,
    VerifiedUpdateFilePublisher? filePublisher,
    // Kept in the shared desktop API; Windows only downloads the installer.
    VerifiedUpdatePreparer? prepareForInstall,
  }) async {
    final update = AppUpdateInfo(
      version: latestVersion,
      downloadUrl: downloadUrl,
      fallbackDownloadUrl: fallbackDownloadUrl,
      changelog: changelog,
      sha256: sha256,
    );
    await SharedUpdateService.showUpdateDialog(
      context,
      latestVersion: latestVersion,
      currentVersion: currentVersion,
      downloadUrl: downloadUrl,
      fallbackDownloadUrl: fallbackDownloadUrl,
      changelog: changelog,
      primaryColor: AppTheme.primary,
      accentColor: AppTheme.accentColor,
      textPrimary: AppTheme.textPrimary,
      textSecondary: AppTheme.textSecondary,
      lightTextPrimary: AppTheme.lightTextPrimary,
      lightTextSecondary: AppTheme.lightTextSecondary,
      primaryActionLabel: '下载到桌面',
      openDownload: (url) => downloadUpdateToDesktop(
        context,
        SharedUpdateService.preferDownloadUrl(update, url),
        desktopDirectory: desktopDirectory,
        client: client,
        filePublisher: filePublisher,
      ),
    );
  }

  static Future<void> downloadUpdateToDesktop(
    BuildContext context,
    AppUpdateInfo update, {
    Directory? desktopDirectory,
    http.Client? client,
    VerifiedUpdateFilePublisher? filePublisher,
  }) async {
    late final Directory desktop;
    try {
      desktop = desktopDirectory ?? WindowsDesktopDirectory.resolve();
    } catch (error) {
      await _showDesktopResolutionFailure(context, error);
      return;
    }
    if (!context.mounted) return;
    final installerFileName = await installerFileNameForDownload(
      desktop,
      update.version,
      expectedSha256: update.sha256,
    );
    if (!context.mounted) return;
    final installerPublisher =
        filePublisher ?? (Platform.isWindows ? publishVerifiedInstaller : null);
    var publishedByThisDownload = false;

    await SharedUpdateService.downloadVerifiedUpdateWithProgress(
      context,
      update,
      outputDirectory: desktop,
      fileName: installerFileName,
      client: client,
      filePublisher: installerPublisher == null
          ? null
          : trackVerifiedInstallerPublication(
              installerPublisher,
              () => publishedByThisDownload = true,
            ),
      progressDescription: '下载并通过 SHA-256 校验后保存到桌面，不会自动启动；'
          '仅带有效专属标记的应用内安装包会在安装成功后自动清理；'
          '未带标记的已有文件会保留。',
      onVerified: (file) async {
        File? marker;
        try {
          marker = await publishVerifiedInstallerMarkerIfOwned(
            file,
            update,
            publishedByThisDownload: publishedByThisDownload,
          );
        } catch (_) {
          // The verified installer remains usable; the completion dialog tells
          // the user that it cannot be removed automatically after installation.
        }
        marker ??= await matchingVerifiedInstallerMarker(file, update);
        if (!context.mounted) return;
        await _showDesktopDownloadComplete(
          context,
          file,
          markedForAutomaticCleanup: marker != null,
          reusedExistingInstaller: !publishedByThisDownload,
        );
      },
    );
  }

  static String _installerFileName(String version) {
    final normalized = version.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final safeVersion = normalized.replaceAll(
      RegExp(r'[^A-Za-z0-9._-]'),
      '_',
    );
    return safeVersion.isEmpty
        ? 'SSRVPN_Setup.exe'
        : 'SSRVPN_Setup_v$safeVersion.exe';
  }

  /// Selects one deterministic alternate basename only when an installer is
  /// absent but its fixed sidecar remains. The alternate is derived from the
  /// canonical versioned name and trusted SHA-256, so every retry targets the
  /// same exact path. The orphan is never adopted, deleted, or found by scan.
  @visibleForTesting
  static Future<String> installerFileNameForDownload(
    Directory desktop,
    String version, {
    required String? expectedSha256,
    Future<FileSystemEntityType> Function(String path)? entityTypeReader,
  }) async {
    final canonicalName = _installerFileName(version);
    final canonicalPath = p.join(desktop.path, canonicalName);
    final markerPath = '$canonicalPath$verifiedUpdateMarkerSuffix';
    final readType = entityTypeReader ??
        (path) => FileSystemEntity.type(path, followLinks: false);
    late final FileSystemEntityType installerType;
    late final FileSystemEntityType markerType;
    try {
      installerType = await readType(canonicalPath);
      markerType = await readType(markerPath);
    } catch (_) {
      // If exact-path inspection is unavailable, retain the canonical flow and
      // let the verified publisher fail closed without inventing a new target.
      return canonicalName;
    }
    if (installerType != FileSystemEntityType.notFound ||
        markerType != FileSystemEntityType.file) {
      return canonicalName;
    }

    final normalizedSha256 = expectedSha256?.trim().toLowerCase();
    if (normalizedSha256 == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(normalizedSha256)) {
      // The shared verifier will report the invalid update metadata. Without a
      // trusted digest there is no safe deterministic alternate identity.
      return canonicalName;
    }
    final suffix = crypto.sha256
        .convert(
          utf8.encode(
            'ssrvpn-windows-update-name-v1\n'
            '$canonicalName\n$normalizedSha256',
          ),
        )
        .toString()
        .substring(0, 32);
    return '${p.basenameWithoutExtension(canonicalName)}_$suffix.exe';
  }

  static String? _verifiedInstallerNameForUpdate(
    File installer,
    AppUpdateInfo update,
  ) {
    final normalizedVersion =
        update.version.trim().replaceFirst(RegExp(r'^[vV]'), '');
    if (!RegExp(r'^\d+\.\d+\.\d+(?:\.\d+)?$').hasMatch(normalizedVersion)) {
      return null;
    }
    final actualName = p.basename(installer.path);
    final canonicalName = _installerFileName(update.version);
    if (actualName == canonicalName) return actualName;
    final variantPattern = RegExp(
      '^${RegExp.escape(p.basenameWithoutExtension(canonicalName))}'
      r'_[a-f0-9]{32}\.exe$',
    );
    return variantPattern.hasMatch(actualName) ? actualName : null;
  }

  @visibleForTesting
  static VerifiedUpdateFilePublisher trackVerifiedInstallerPublication(
    VerifiedUpdateFilePublisher publisher,
    void Function() onPublished,
  ) {
    return (source, destination) async {
      await publisher(source, destination);
      onPublished();
    };
  }

  @visibleForTesting
  static Future<File?> publishVerifiedInstallerMarkerIfOwned(
    File installer,
    AppUpdateInfo update, {
    required bool publishedByThisDownload,
  }) {
    if (!publishedByThisDownload) return Future<File?>.value();
    return publishVerifiedInstallerMarker(installer, update);
  }

  @visibleForTesting
  static Future<File> publishVerifiedInstallerMarker(
    File installer,
    AppUpdateInfo update, {
    Future<void> Function(File marker, String content)? markerWriter,
    Future<void> Function(File marker)? markerHider,
    Future<void> Function(File installer, String token)? ownerWriter,
    Future<String?> Function(File installer)? ownerReader,
    String Function()? tokenGenerator,
  }) async {
    final installerName = _verifiedInstallerNameForUpdate(installer, update);
    final expectedSha256 = update.sha256?.trim().toLowerCase();
    if (installerName == null ||
        expectedSha256 == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedSha256) ||
        await FileSystemEntity.type(installer.path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw StateError('无法标记已验证的 Windows 更新安装包');
    }

    final marker = File('${installer.path}$verifiedUpdateMarkerSuffix');
    final writeMarker = markerWriter ??
        (file, value) => file.writeAsString(value, encoding: utf8, flush: true);
    final hideMarker = markerHider ?? _hideVerifiedInstallerMarker;
    final writeOwner = ownerWriter ?? _writeVerifiedInstallerOwner;
    final readOwner = ownerReader ?? _readVerifiedInstallerOwner;
    try {
      await marker.create(exclusive: true);
    } on FileSystemException {
      if (await _verifiedInstallerMarkerToken(
            marker,
            installer,
            installerName,
            expectedSha256,
            ownerReader: readOwner,
          ) !=
          null) {
        await hideMarker(marker);
        return marker;
      }
      throw StateError('Windows 更新安装包标记已存在且内容不匹配');
    }
    String? token;
    var content = '';
    try {
      token = (tokenGenerator ?? _generateVerifiedInstallerOwnerToken)();
      if (!_isValidVerifiedInstallerOwnerToken(token)) {
        throw StateError('Windows 更新安装包所有权标记无效');
      }
      content = _verifiedInstallerMarkerContent(
        installerName,
        expectedSha256,
        token,
      );
      await writeOwner(installer, token);
      if (await readOwner(installer) != token) {
        throw StateError('Windows 更新安装包所有权标记写入校验失败');
      }
      await writeMarker(marker, content);
      if (await _verifiedInstallerMarkerToken(
            marker,
            installer,
            installerName,
            expectedSha256,
            ownerReader: readOwner,
          ) !=
          token) {
        throw StateError('Windows 更新安装包标记写入校验失败');
      }
      await hideMarker(marker);
      return marker;
    } catch (_) {
      await _deleteOwnedMarkerBestEffort(marker, content);
      if (token != null && _isValidVerifiedInstallerOwnerToken(token)) {
        await _deleteOwnedInstallerOwnerBestEffort(
          installer,
          token,
          ownerReader: readOwner,
        );
      }
      rethrow;
    }
  }

  @visibleForTesting
  static Future<File?> matchingVerifiedInstallerMarker(
    File installer,
    AppUpdateInfo update,
  ) async {
    final installerName = _verifiedInstallerNameForUpdate(installer, update);
    final expectedSha256 = update.sha256?.trim().toLowerCase();
    if (installerName == null ||
        expectedSha256 == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedSha256)) {
      return null;
    }
    final marker = File('${installer.path}$verifiedUpdateMarkerSuffix');
    return await _verifiedInstallerMarkerToken(
              marker,
              installer,
              installerName,
              expectedSha256,
            ) !=
            null
        ? marker
        : null;
  }

  static String _verifiedInstallerMarkerContent(
    String installerName,
    String expectedSha256,
    String ownerToken,
  ) =>
      '$_verifiedUpdateMarkerMagic\n$installerName\n$expectedSha256\n'
      '$ownerToken\n';

  static bool _isValidVerifiedInstallerOwnerToken(String token) =>
      RegExp(r'^[a-f0-9]{64}$').hasMatch(token);

  static String _generateVerifiedInstallerOwnerToken() {
    final random = Random.secure();
    return List<int>.generate(32, (_) => random.nextInt(256))
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static File _verifiedInstallerOwnerStream(File installer) =>
      File('${installer.path}:$_verifiedUpdateOwnerStreamName');

  static Future<void> _writeVerifiedInstallerOwner(
    File installer,
    String token,
  ) =>
      _verifiedInstallerOwnerStream(installer).writeAsString(
        token,
        encoding: ascii,
        flush: true,
      );

  static Future<String?> _readVerifiedInstallerOwner(File installer) async {
    try {
      final value = await _verifiedInstallerOwnerStream(installer).readAsString(
        encoding: ascii,
      );
      return _isValidVerifiedInstallerOwnerToken(value) ? value : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _hideVerifiedInstallerMarker(File marker) async {
    if (!Platform.isWindows) return;
    if (await FileSystemEntity.type(marker.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('Windows 更新安装包标记不是普通文件');
    }

    final markerPath = _toExtendedLengthPath(marker.absolute.path)
        .toNativeUtf16(allocator: calloc);
    try {
      final attributes = GetFileAttributes(PCWSTR(markerPath));
      if (attributes.value == 0xFFFFFFFF) {
        throw WindowsException(
          attributes.error.toHRESULT(),
          message: 'Failed to read verified update marker attributes',
        );
      }
      if (FILE_FLAGS_AND_ATTRIBUTES(attributes.value).has(
        FILE_ATTRIBUTE_HIDDEN,
      )) {
        return;
      }
      final hiddenAttributes = FILE_FLAGS_AND_ATTRIBUTES(
        (attributes.value | FILE_ATTRIBUTE_HIDDEN) & ~FILE_ATTRIBUTE_NORMAL,
      );
      final result = SetFileAttributes(PCWSTR(markerPath), hiddenAttributes);
      if (!result.value) {
        throw WindowsException(
          result.error.toHRESULT(),
          message: 'Failed to hide verified update marker',
        );
      }
    } finally {
      calloc.free(markerPath);
    }
  }

  static Future<void> _deleteOwnedMarkerBestEffort(
    File marker,
    String expected,
  ) async {
    try {
      if (await FileSystemEntity.type(marker.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return;
      }
      final actual = await marker.readAsBytes();
      final expectedBytes = utf8.encode(expected);
      if (actual.length > expectedBytes.length) return;
      for (var index = 0; index < actual.length; index++) {
        if (actual[index] != expectedBytes[index]) return;
      }
      await marker.delete();
    } catch (_) {
      // A failed marker must not make the verified installer unsafe to keep.
    }
  }

  static Future<void> _deleteOwnedInstallerOwnerBestEffort(
    File installer,
    String expectedToken, {
    required Future<String?> Function(File installer) ownerReader,
  }) async {
    try {
      if (await ownerReader(installer) != expectedToken) return;
      await _verifiedInstallerOwnerStream(installer).delete();
    } catch (_) {
      // A failed owner token must never authorize deletion of the installer.
    }
  }

  static Future<String?> _verifiedInstallerMarkerToken(
    File marker,
    File installer,
    String expectedInstallerName,
    String expectedSha256, {
    Future<String?> Function(File installer)? ownerReader,
  }) async {
    try {
      if (await FileSystemEntity.type(marker.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await marker.length() > 320) {
        return null;
      }
      final lines = const LineSplitter().convert(
        await marker.readAsString(encoding: utf8),
      );
      if (lines.length != 4 ||
          lines[0] != _verifiedUpdateMarkerMagic ||
          lines[1] != expectedInstallerName ||
          lines[2] != expectedSha256 ||
          !_isValidVerifiedInstallerOwnerToken(lines[3])) {
        return null;
      }
      final readOwner = ownerReader ?? _readVerifiedInstallerOwner;
      return await readOwner(installer) == lines[3] ? lines[3] : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> publishVerifiedInstaller(
    File source,
    File destination,
  ) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows installer publication is Windows-only');
    }
    final sourcePath = _toExtendedLengthPath(source.absolute.path)
        .toNativeUtf16(allocator: calloc);
    final destinationPath = _toExtendedLengthPath(destination.absolute.path)
        .toNativeUtf16(allocator: calloc);
    try {
      // Resolve GetLastError before the native call so symbol lookup cannot
      // overwrite the error produced by MoveFileExW.
      GetLastError();
      final moved = _moveFileExW(
        sourcePath,
        destinationPath,
        _moveFileWriteThrough,
      );
      final error = GetLastError();
      if (moved == 0) {
        throw WindowsException(
          error.toHRESULT(),
          message: 'Windows 更新安装包安全保存失败',
        );
      }
    } finally {
      calloc.free(sourcePath);
      calloc.free(destinationPath);
    }
  }

  // The staging file and destination are siblings, so MoveFileExW stays on the
  // same volume. Omitting replacement and cross-volume-copy flags preserves
  // atomic no-overwrite publication across supported desktop filesystems.
  static const int _moveFileWriteThrough = 0x00000008;
  static final _moveFileExW =
      DynamicLibrary.open('kernel32.dll').lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
          int Function(
            Pointer<Utf16>,
            Pointer<Utf16>,
            int,
          )>('MoveFileExW');

  static String _toExtendedLengthPath(String path) {
    if (path.startsWith('\\\\?\\')) return path;
    final normalized = p.windows.normalize(path);
    if (normalized.startsWith('\\\\')) {
      return '\\\\?\\UNC\\${normalized.substring(2)}';
    }
    return '\\\\?\\$normalized';
  }

  static Future<void> _showDesktopDownloadComplete(
    BuildContext context,
    File file, {
    required bool markedForAutomaticCleanup,
    required bool reusedExistingInstaller,
  }) async {
    if (!context.mounted) return;
    final completionMessage = markedForAutomaticCleanup
        ? '最新版安装包已下载到桌面并完成安全标记。请手动安装；'
            '安装成功后会自动清理，取消或失败时保留。'
        : reusedExistingInstaller
            ? '桌面已有通过 SHA-256 校验的同版本安装包。请手动安装；'
                '该文件未由本次下载认领，安装后会保留。'
            : '安装包已下载到桌面并通过 SHA-256 校验，但安装后无法自动删除。'
                '请手动安装；安装完成后请自行删除桌面安装包。';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('下载完成'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(completionMessage),
            const SizedBox(height: 8),
            SelectableText(
              file.path,
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  static Future<void> _showDesktopResolutionFailure(
    BuildContext context,
    Object error,
  ) {
    return AppModalCoordinator.run<void>(() async {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          scrollable: true,
          title: const Text('更新失败'),
          content: Text(desktopResolutionFailureMessage(error)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    });
  }

  @visibleForTesting
  static String desktopResolutionFailureMessage(Object error) =>
      safeUserFacingFailureWithAction(
        error,
        '请确认桌面目录可访问后重试。',
      );
}
