import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;
import 'package:liquid_glass_widgets/theme/glass_theme_helpers.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/services/background_image_store.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_settings_page.dart';

class _Core extends ClashServiceBase {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'platform photo picker cancellation and failure keep the existing background',
      (tester) async {
    final core = _Core();
    var selections = 0;
    var saves = 0;
    final settings = AppSettings(
        glassEffectLevel: GlassEffectLevel.none,
        backgroundStyle: BackgroundStyle.custom,
        customBackgroundPath: '/old-background.png');
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: SsrvpnAppearanceScope(
            settings: settings,
            child: Scaffold(
                body: SsrvpnSettingsPage(
                    settings: settings,
                    core: core,
                    dataDirectory: '/tmp',
                    pickBackgroundImage: () async {
                      selections++;
                      if (selections == 1) return null;
                      throw const FileSystemException('unavailable');
                    },
                    onAppearanceChanged: (
                        {glassEffectLevel,
                        backgroundStyle,
                        customBackgroundPath}) async {
                      saves++;
                    },
                    onPortChanged: (_) async {},
                    checkForUpdate: () async => null,
                    onUpdateFound: (_) {})))));
    for (var i = 0; i < 2; i++) {
      await tester.ensureVisible(find.text('更换背景图'));
      await tester.tap(find.text('更换背景图'));
      await tester.pump();
    }
    expect(selections, 2);
    expect(saves, 0);
    expect(settings.customBackgroundPath, '/old-background.png');
    expect(find.text('图片导入失败，请选择有效的静态图片重试，原背景已保留'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    core.dispose();
  });

  for (final outcome in ['cancel', 'save failure', 'success']) {
    testWidgets('background replacement $outcome preserves the correct files',
        (tester) async {
      late Directory dir;
      late File source;
      late File old;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('background-flow-');
        source = File('${dir.path}/source.png');
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(16, 16);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        await source.writeAsBytes(bytes!.buffer.asUint8List());
        final oldFolder = await Directory('${dir.path}/backgrounds/image-old')
            .create(recursive: true);
        old = await source.copy('${oldFolder.path}/background.png');
      });
      addTearDown(() => dir.delete(recursive: true));
      var settings = AppSettings(
          glassEffectLevel: GlassEffectLevel.none,
          backgroundStyle: BackgroundStyle.custom,
          customBackgroundPath: old.path);
      final core = _Core();
      addTearDown(core.dispose);
      var saves = 0;
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData.dark(),
          home: StatefulBuilder(
              builder: (context, update) => SsrvpnAppearanceScope(
                  settings: settings,
                  child: Scaffold(
                      body: SsrvpnSettingsPage(
                    settings: settings,
                    core: core,
                    dataDirectory: dir.path,
                    pickBackgroundImage: () async => XFile(source.path),
                    onAppearanceChanged: (
                        {glassEffectLevel,
                        backgroundStyle,
                        customBackgroundPath}) async {
                      saves++;
                      if (outcome == 'save failure') {
                        throw const FileSystemException('disk full');
                      }
                      update(() => settings = settings.copyWith(
                          backgroundStyle: backgroundStyle,
                          customBackgroundPath: customBackgroundPath));
                    },
                    onPortChanged: (_) async {},
                    checkForUpdate: () async => null,
                    onUpdateFound: (_) {},
                  ))))));
      await tester.ensureVisible(find.text('更换背景图'));
      await tester.runAsync(() => tester.tap(find.text('更换背景图')));
      for (var i = 0; i < 100 && find.text('使用这张背景').evaluate().isEmpty; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('使用这张背景'), findsOneWidget,
          reason: tester
              .widgetList<Text>(find.byType(Text))
              .map((text) => text.data)
              .join(' | '));
      await tester.pump(const Duration(milliseconds: 400));
      final preview = tester
          .widget<SsrvpnCustomBackground>(find.byType(SsrvpnCustomBackground));
      final imported = File(preview.path);
      expect(await tester.runAsync(imported.exists), isTrue);
      await tester.runAsync(
          () => tester.tap(find.text(outcome == 'cancel' ? '取消' : '使用这张背景')));
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
        if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(saves, outcome == 'cancel' ? 0 : 1);
      await tester.runAsync(() async {
        expect(await source.exists(), isTrue);
        expect(await old.exists(), outcome != 'success');
        expect(await imported.exists(), outcome == 'success');
        expect(await Directory('${dir.path}/backgrounds').list().length, 1);
      });
      expect(settings.customBackgroundPath,
          outcome == 'success' ? imported.path : old.path);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  test('appearance survives serialization and unknown choices retain defaults',
      () {
    final original = AppSettings(
        glassEffectLevel: GlassEffectLevel.none,
        backgroundStyle: BackgroundStyle.custom,
        customBackgroundPath: '/data/image.png');
    expect(AppSettings.fromJson(original.toJson()), original);
    expect(original.copyWith(proxyPort: 8000).customBackgroundPath,
        '/data/image.png');
    final legacy = AppSettings.fromJson(
        {'glassEffectLevel': 'future', 'backgroundStyle': 'future'});
    expect(legacy.glassEffectLevel, isNull);
    expect(legacy.backgroundStyle, BackgroundStyle.flowing);
  });

  test(
      'import bounds decoded pixels, survives original removal and only removes owned copies',
      () async {
    final dir = await Directory.systemTemp.createTemp('background-test-');
    addTearDown(() => dir.delete(recursive: true));
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(3000, 1500);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    final source = File('${dir.path}/source.png');
    await source.writeAsBytes(bytes!.buffer.asUint8List());
    final imported =
        await BackgroundImageStore.importImage(XFile(source.path), dir.path);
    await BackgroundImageStore.removeOwned(source.path, dir.path);
    expect(await source.exists(), isTrue);
    await source.delete();
    final codec = await ui.instantiateImageCodec(await imported.readAsBytes());
    final decoded = (await codec.getNextFrame()).image;
    expect(decoded.width, 2048);
    expect(decoded.height, 1024);
    decoded.dispose();
    codec.dispose();
    await BackgroundImageStore.removeOwned(imported.path, dir.path);
    expect(await imported.exists(), isFalse);
    final invalid = File('${dir.path}/invalid.png');
    await invalid.writeAsString('not an image');
    await expectLater(
        BackgroundImageStore.importImage(XFile(invalid.path), dir.path),
        throwsA(anything));
    expect(await Directory('${dir.path}/backgrounds').list().length, 0);
  });

  testWidgets(
      'explicit quality overrides device ceiling without losing text input',
      (tester) async {
    var settings = AppSettings(glassEffectLevel: GlassEffectLevel.low);
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(
        home: glass.GlassAdaptiveScope(
            minQuality: glass.GlassQuality.minimal,
            maxQuality: glass.GlassQuality.minimal,
            child: StatefulBuilder(builder: (context, setState) {
              update = setState;
              return SsrvpnAppearanceScope(
                  settings: settings,
                  child: Scaffold(
                      body: Column(children: [
                    const TextField(),
                    Builder(
                        builder: (context) => Text(
                            GlassThemeHelpers.resolveQuality(context,
                                    widgetQuality: glass.GlassQuality.premium)
                                .name)),
                  ])));
            }))));
    await tester.enterText(find.byType(TextField), '8010');
    update(() =>
        settings = settings.copyWith(glassEffectLevel: GlassEffectLevel.high));
    await tester.pump();
    expect(find.text('premium'), findsOneWidget);
    expect(find.text('8010'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'narrow large-text settings validate ports and preserve input on write failure',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = AppSettings(glassEffectLevel: GlassEffectLevel.none);
    final core = _Core()..updateSettings(settings.copyWith());
    var calls = 0;
    var checks = 0;
    AppUpdateInfo? foundUpdate;
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: SsrvpnAppearanceScope(
            settings: settings,
            child: MediaQuery(
                data: const MediaQueryData(
                    size: Size(320, 640), textScaler: TextScaler.linear(2)),
                child: Scaffold(
                    body: SsrvpnSettingsPage(
                        settings: settings,
                        core: core,
                        dataDirectory: '/tmp',
                        onAppearanceChanged: (
                            {glassEffectLevel,
                            backgroundStyle,
                            customBackgroundPath}) async {},
                        onPortChanged: (_) async {
                          calls++;
                          throw const FileSystemException('disk full');
                        },
                        checkForUpdate: () async {
                          checks++;
                          if (checks == 1) {
                            throw const SocketException('offline');
                          }
                          if (checks == 2) return null;
                          return const AppUpdateInfo(
                              version: '9.0.0',
                              downloadUrl: 'https://example.invalid/test.apk',
                              changelog: 'test');
                        },
                        onUpdateFound: (update) => foundUpdate = update))))));
    await tester.scrollUntilVisible(find.byType(TextField), 250,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(find.byType(TextField), '9090');
    await tester.ensureVisible(find.text('保存端口'));
    await tester.tap(find.text('保存端口'));
    await tester.pump();
    expect(calls, 0);
    expect(find.text('不能与 SOCKS 或控制端口重复'), findsOneWidget);
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '8000');
    await tester.ensureVisible(find.text('保存端口'));
    await tester.tap(find.text('保存端口'));
    await tester.pump();
    expect(calls, 1);
    expect(settings.proxyPort, 7890);
    expect(find.text('8000'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('检查更新'), 250,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('检查更新失败，请检查网络后重试'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(foundUpdate, isNull);
    await tester.ensureVisible(find.text('检查更新'));
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('当前已是最新版本'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('当前已是最新版本'), findsOneWidget);
    await tester.ensureVisible(find.text('检查更新'));
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    expect(foundUpdate?.version, '9.0.0');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
