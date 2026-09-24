import 'support/verified_update_publisher.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_settings_page.dart';

void main() {
  testWidgets('verified update refuses to open when safe preparation fails',
      (tester) async {
    final outputDirectory =
        Directory.systemTemp.createTempSync('ssrvpn-update-prepare-');
    addTearDown(() {
      if (outputDirectory.existsSync()) {
        outputDirectory.deleteSync(recursive: true);
      }
    });
    final bytes = utf8.encode('verified-dmg');
    final client = _StreamClient(
      (_) async => http.StreamedResponse(
        Stream<List<int>>.value(bytes),
        HttpStatus.ok,
        contentLength: bytes.length,
      ),
    );
    var prepared = 0;
    var opened = false;
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

    final task = SharedUpdateService.downloadAndOpenVerifiedUpdate(
      context,
      AppUpdateInfo(
        version: '9.9.9',
        downloadUrl: 'https://example.com/SSRVPN.dmg',
        changelog: '',
        sha256: sha256.convert(bytes).toString(),
      ),
      fileName: 'SSRVPN.dmg',
      filePublisher: testVerifiedUpdatePublisher,
      outputDirectory: outputDirectory,
      client: client,
      beforeOpen: () async {
        prepared++;
        return false;
      },
      openFile: (_) async {
        opened = true;
      },
    );
    for (var attempt = 0;
        attempt < 1000 && find.text('更新失败').evaluate().isEmpty;
        attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(prepared, 1);
    expect(opened, isFalse);
    expect(find.text('更新失败'), findsOneWidget);
    expect(find.textContaining('无法安全断开当前连接'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    await task;
  });

  testWidgets('cancelling a desktop update closes the progress dialog',
      (tester) async {
    final outputDirectory =
        Directory.systemTemp.createTempSync('ssrvpn-update-dialog-');
    addTearDown(() {
      if (outputDirectory.existsSync()) {
        outputDirectory.deleteSync(recursive: true);
      }
    });
    final response = Completer<http.StreamedResponse>();
    final client = _StreamClient((_) => response.future);
    var opened = false;
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

    unawaited(
      SharedUpdateService.downloadAndOpenVerifiedUpdate(
        context,
        const AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN.dmg',
          changelog: '',
          sha256:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        ),
        fileName: 'SSRVPN.dmg',
        filePublisher: testVerifiedUpdatePublisher,
        outputDirectory: outputDirectory,
        client: client,
        openFile: (_) async {
          opened = true;
        },
      ),
    );

    await tester.pump();
    expect(find.text('取消更新'), findsOneWidget);
    await tester.tap(find.text('取消更新'));
    await tester.pumpAndSettle();

    expect(find.text('正在下载更新'), findsNothing);
    expect(find.text('更新失败'), findsNothing);
    expect(opened, isFalse);
    expect(SharedUpdateService.isVerifiedDownloadInProgress, isFalse);
  });

  testWidgets('background import preview cannot strand a completed update',
      (tester) async {
    final output =
        Directory.systemTemp.createTempSync('ssrvpn-update-preview-');
    addTearDown(() => output.deleteSync(recursive: true));
    final source = File('${output.path}/source.png');
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(16, 16);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      await source.writeAsBytes(data!.buffer.asUint8List());
    });
    final imageRead = Completer<void>();
    var imageReadStarted = false;
    final selectedImage = _DelayedImageFile(source.path, () async {
      imageReadStarted = true;
      await imageRead.future;
    });
    final navigator = GlobalKey<NavigatorState>();
    final observer = _PopupObserver();
    final core = _SettingsCore();
    addTearDown(core.dispose);
    final settings = AppSettings(glassEffectLevel: GlassEffectLevel.none);
    final bytes = utf8.encode('verified-covered-update');
    final response = Completer<http.StreamedResponse>();
    final update = AppUpdateInfo(
      version: '9.9.9',
      downloadUrl: 'https://example.com/SSRVPN.dmg',
      changelog: '',
      sha256: sha256.convert(bytes).toString(),
    );
    var requested = false;
    var verified = false;
    Future<void>? task;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      navigatorObservers: [observer],
      home: Builder(builder: (context) {
        return SsrvpnAppearanceScope(
          settings: settings,
          child: Scaffold(
            body: SsrvpnHomeShell(
              body: SsrvpnSettingsPage(
                settings: settings,
                core: core,
                dataDirectory: output.path,
                pickBackgroundImage: () async => selectedImage,
                onAppearanceChanged: (
                    {glassEffectLevel,
                    backgroundStyle,
                    customBackgroundPath,
                    dynamicBackground}) async {},
                onPortChanged: (_) async {},
                checkForUpdate: () async => update,
                onUpdateFound: (_) {},
              ),
              navigation: SsrvpnBottomNavigation(
                currentIndex: 2,
                version: '9.9.8',
                availableVersion: update.version,
                onTap: (_) {},
                onUpdateTap: () =>
                    unawaited(SharedUpdateService.showUpdateDialog(
                  context,
                  latestVersion: update.version,
                  currentVersion: '9.9.8',
                  downloadUrl: update.downloadUrl,
                  changelog: '',
                  primaryColor: Colors.blue,
                  accentColor: Colors.cyan,
                  textPrimary: Colors.white,
                  textSecondary: Colors.white70,
                  lightTextPrimary: Colors.black,
                  lightTextSecondary: Colors.black54,
                  primaryActionLabel: '下载到桌面',
                  openDownload: (_) {
                    return task =
                        SharedUpdateService.downloadVerifiedUpdateWithProgress(
                      context,
                      update,
                      fileName: 'SSRVPN.dmg',
                      outputDirectory: output,
                      filePublisher: testVerifiedUpdatePublisher,
                      progressDescription: '验证更新',
                      client: _StreamClient((_) {
                        requested = true;
                        return response.future;
                      }),
                      onVerified: (_) async => verified = true,
                    );
                  },
                )),
              ),
            ),
          ),
        );
      }),
    ));
    try {
      await tester.ensureVisible(find.text('添加背景图'));
      await tester.runAsync(() => tester.tap(find.text('添加背景图')));
      for (var i = 0; i < 200 && !imageReadStarted; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(imageReadStarted, isTrue);
      // The real settings page disables its appearance controls during import,
      // while the independent desktop footer still admits the update flow.
      expect(
          tester
              .widget<OutlinedButton>(
                  find.widgetWithText(OutlinedButton, '添加背景图'))
              .onPressed,
          isNull);
      expect(find.text('立即更新').hitTestable(), findsOneWidget);
      await tester.tap(find.text('立即更新'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('下载到桌面'));
      for (var i = 0; i < 200 && !requested; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(requested, isTrue);
      expect(find.text('正在下载更新'), findsOneWidget);
      // Resume the actual BackgroundImageStore read/decode/write path. Its
      // production settings callback creates the preview; no test popup is pushed.
      imageRead.complete();
      for (var i = 0; i < 200 && find.text('背景预览').evaluate().isEmpty; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('背景预览'), findsOneWidget);
      expect(find.text('正在下载更新', skipOffstage: false), findsOneWidget);
      response.complete(http.StreamedResponse(
        Stream<List<int>>.value(bytes),
        HttpStatus.ok,
        contentLength: bytes.length,
      ));
      for (var i = 0; i < 200 && !verified; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
        if (find.text('背景预览').evaluate().isEmpty) break;
      }
      expect(find.text('背景预览'), findsOneWidget);
      expect(find.text('正在下载更新', skipOffstage: false), findsNothing);
      expect(verified, isTrue);
      await task;
      expect(SharedUpdateService.isVerifiedDownloadInProgress, isFalse);
    } finally {
      if (!imageRead.isCompleted) imageRead.complete();
      if (!response.isCompleted) {
        response.complete(http.StreamedResponse(
            Stream<List<int>>.value(bytes), HttpStatus.ok,
            contentLength: bytes.length));
      }
      for (final route in observer.routes.reversed) {
        if (route.isActive) navigator.currentState!.removeRoute(route);
      }
      await tester.pump(const Duration(milliseconds: 400));
      await task;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
    }
  });

  testWidgets(
      'long desktop update errors remain dismissible on compact screens',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final outputDirectory =
        Directory.systemTemp.createTempSync('ssrvpn-update-error-dialog-');
    addTearDown(() {
      if (outputDirectory.existsSync()) {
        outputDirectory.deleteSync(recursive: true);
      }
    });
    var requests = 0;
    final client = _StreamClient(
      (_) async {
        requests++;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        throw StateError(
          List<String>.generate(
            40,
            (index) => '更新源响应异常 ${index + 1}',
          ).join('\n'),
        );
      },
    );
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

    final task = SharedUpdateService.downloadAndOpenVerifiedUpdate(
      context,
      const AppUpdateInfo(
        version: '9.9.9',
        downloadUrl: 'https://example.com/SSRVPN.dmg',
        changelog: '',
        sha256:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      ),
      fileName: 'SSRVPN.dmg',
      filePublisher: testVerifiedUpdatePublisher,
      outputDirectory: outputDirectory,
      client: client,
      openFile: (_) async {},
    );
    for (var attempt = 0;
        attempt < 1000 && find.text('更新失败').evaluate().isEmpty;
        attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(requests, 1);
    expect(find.text('更新失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final errorDialog = find.ancestor(
      of: find.text('更新失败'),
      matching: find.byType(SsrvpnLiquidAlertDialog),
    );
    expect(
        tester.widget<SsrvpnLiquidAlertDialog>(errorDialog).scrollable, isTrue);
    final dismiss = find.widgetWithText(TextButton, '知道了');
    await tester.ensureVisible(dismiss);
    expect(dismiss.hitTestable(), findsOneWidget);
    await tester.tap(dismiss);
    await tester.pumpAndSettle();
    await task;

    expect(SharedUpdateService.isVerifiedDownloadInProgress, isFalse);
  });
}

class _StreamClient extends http.BaseClient {
  _StreamClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
      handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

class _PopupObserver extends NavigatorObserver {
  final routes = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) routes.add(route);
  }
}

class _DelayedImageFile extends XFile {
  _DelayedImageFile(super.path, this.beforeRead);
  final Future<void> Function() beforeRead;

  @override
  Future<Uint8List> readAsBytes() async {
    await beforeRead();
    return super.readAsBytes();
  }
}

class _SettingsCore extends ClashServiceBase {
  @override
  Future<void> onStopRequired() async {}
  @override
  Future<bool> diagnosticCoreAvailable() async => false;
  @override
  String get diagnosticConfigPath => '';
  @override
  bool get diagnosticConfigRequired => false;
  @override
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks() async => [];
  @override
  Future<AppRepairResult> repairDiagnosticIssue(AppRepairAction action) async =>
      const AppRepairResult(success: false, message: '未连接');
}
