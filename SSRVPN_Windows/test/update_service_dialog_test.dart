import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/services/update_service.dart';

void main() {
  test(
      'stale private update artifacts are recovered without touching user files',
      () async {
    final desktop =
        Directory.systemTemp.createTempSync('ssrvpn-windows-artifacts-');
    addTearDown(() {
      if (desktop.existsSync()) desktop.deleteSync(recursive: true);
    });
    final now = DateTime.utc(2026, 7, 21, 1);
    final staleAt = now.subtract(const Duration(days: 2));
    final previousDestination = File('${desktop.path}/SSRVPN_Setup_v8.8.8.exe');
    final previous = File(
      '${previousDestination.path}.previous.1_2_3',
    );
    final stalePart = File(
      '${desktop.path}/SSRVPN_Setup_v8.8.7.exe.part.4_5_6',
    );
    final recentPart = File(
      '${desktop.path}/SSRVPN_Setup_v9.9.9.exe.part.7_8_9',
    );
    final unrelated = File('${desktop.path}/customer.previous.1_2_3');
    await previous.writeAsString('previous verified installer', flush: true);
    await stalePart.writeAsString('incomplete', flush: true);
    await recentPart.writeAsString('active', flush: true);
    await unrelated.writeAsString('keep', flush: true);
    await previous.setLastModified(staleAt);
    await stalePart.setLastModified(staleAt);
    await recentPart.setLastModified(now);
    await unrelated.setLastModified(staleAt);

    await UpdateService.recoverStaleDesktopArtifacts(
      desktop,
      now: now,
      staleAfter: const Duration(days: 1),
    );

    expect(await previousDestination.readAsString(),
        'previous verified installer');
    expect(await previous.exists(), isFalse);
    expect(await stalePart.exists(), isFalse);
    expect(await recentPart.exists(), isTrue);
    expect(await unrelated.exists(), isTrue);
  });

  testWidgets('Windows update action downloads to Desktop without changing URL',
      (tester) async {
    final desktop =
        Directory.systemTemp.createTempSync('ssrvpn-windows-desktop-');
    addTearDown(() {
      if (desktop.existsSync()) desktop.deleteSync(recursive: true);
    });
    final bytes = utf8.encode('verified-windows-installer');
    final response = Completer<http.Response>();
    Uri? requestedUrl;
    addTearDown(() {
      if (!response.isCompleted) {
        response.completeError(StateError('test download cancelled'));
      }
    });
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final updateDialog = UpdateService.showUpdateDialog(
      context,
      latestVersion: '9.9.9',
      currentVersion: '1.0.0',
      downloadUrl: 'https://example.com/SSRVPN_Setup.exe',
      changelog: '修复 Windows 更新流程',
      sha256: sha256.convert(bytes).toString(),
      desktopDirectory: desktop,
      client: MockClient((request) {
        requestedUrl = request.url;
        return response.future;
      }),
    );
    await tester.pumpAndSettle();

    expect(find.text('下载到桌面'), findsOneWidget);
    expect(find.text('立即更新'), findsNothing);
    await tester.tap(find.text('下载到桌面'));
    await tester.pump();
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (find
          .text('下载完成并通过 SHA256 校验后会保存到桌面，不会自动启动安装程序。')
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }

    final showedDesktopProgress =
        find.text('下载完成并通过 SHA256 校验后会保存到桌面，不会自动启动安装程序。').evaluate().isNotEmpty;

    response.complete(http.Response.bytes(bytes, HttpStatus.ok));
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (find.text('最新版安装包已下载到桌面，请直接安装').evaluate().isNotEmpty) {
        break;
      }
    }

    final showedCompletion =
        find.text('最新版安装包已下载到桌面，请直接安装').evaluate().isNotEmpty;

    final installers = desktop
        .listSync()
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.exe'))
        .toList();

    final acknowledgement = find.text('知道了');
    if (acknowledgement.evaluate().isNotEmpty) {
      await tester.tap(acknowledgement.last);
      await tester.pumpAndSettle();
    }
    for (var attempt = 0; attempt < 100; attempt++) {
      if (!SharedUpdateService.isVerifiedDownloadInProgress) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await updateDialog;

    expect(showedDesktopProgress, isTrue);
    expect(showedCompletion, isTrue);
    expect(SharedUpdateService.isVerifiedDownloadInProgress, isFalse);
    expect(
      requestedUrl,
      Uri.parse('https://example.com/SSRVPN_Setup.exe'),
    );
    expect(installers, hasLength(1));
    expect(installers.single.readAsBytesSync(), bytes);
    expect(installers.single.path, contains('SSRVPN_Setup_v9.9.9.exe'));
    expect(desktop.listSync(), hasLength(1));
  });
}
