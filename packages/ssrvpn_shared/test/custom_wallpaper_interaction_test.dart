import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
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

class _Fixture {
  _Fixture(this.directory, this.source, this.old);
  final Directory directory;
  final File source, old;
  final core = _Core();
  late AppSettings settings;
  late StateSetter update;
  int picks = 0, saves = 0;
  Future<XFile?> Function()? picker;
  bool failSave = false;
  Completer<void>? saveGate;

  static Future<_Fixture> create() async {
    final directory = await Directory.systemTemp.createTemp('wallpaper-entry-');
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(16, 16);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    final source = File('${directory.path}/source.png');
    await source.writeAsBytes(png!.buffer.asUint8List());
    final old = File('${directory.path}/backgrounds/image-old/background.png');
    await old.parent.create(recursive: true);
    await old.writeAsBytes(await source.readAsBytes());
    return _Fixture(directory, source, old);
  }

  Future<void> mount(WidgetTester tester, TargetPlatform platform,
      {bool custom = false, bool saved = true}) async {
    settings = AppSettings(
        glassEffectLevel: GlassEffectLevel.none,
        backgroundStyle: custom ? BackgroundStyle.custom : BackgroundStyle.gray,
        customBackgroundPath: saved ? old.path : '',
        dynamicBackground: true);
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark().copyWith(platform: platform),
        home: StatefulBuilder(builder: (context, setState) {
          update = setState;
          return SsrvpnAppearanceScope(
              settings: settings,
              child: Scaffold(
                  body: SsrvpnSettingsPage(
                      settings: settings,
                      core: core,
                      dataDirectory: directory.path,
                      pickBackgroundImage: () {
                        picks++;
                        return picker?.call() ??
                            Future.value(XFile(source.path));
                      },
                      onAppearanceChanged: (
                          {glassEffectLevel,
                          backgroundStyle,
                          customBackgroundPath,
                          dynamicBackground}) async {
                        saves++;
                        if (saveGate != null) await saveGate!.future;
                        if (failSave) {
                          throw const FileSystemException('disk full');
                        }
                        final next = settings.copyWith(
                            backgroundStyle: backgroundStyle,
                            customBackgroundPath: customBackgroundPath);
                        await File('${directory.path}/settings.json')
                            .writeAsString(jsonEncode(next.toJson()),
                                flush: true);
                        update(() => settings = next);
                      },
                      onPortChanged: (_) async {},
                      checkForUpdate: () async => null,
                      onUpdateFound: (_) {})));
        })));
  }

  Future<void> finish(WidgetTester tester) async {
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
      if (find.byType(LinearProgressIndicator).evaluate().isEmpty) return;
    }
    fail('Wallpaper action did not finish');
  }
}

void main() {
  final entry = find.byKey(const Key('settings-custom-background'));
  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.windows,
    TargetPlatform.macOS
  ]) {
    for (final outcome in [
      'first import',
      'first save failure',
      'replace',
      'cancel',
      'import failure',
      'save failure'
    ]) {
      testWidgets('$platform wallpaper $outcome is atomic at narrow width',
          (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = (await tester.runAsync(_Fixture.create))!;
        addTearDown(() => fixture.directory.delete(recursive: true));
        addTearDown(fixture.core.dispose);
        fixture.failSave =
            outcome == 'save failure' || outcome == 'first save failure';
        if (outcome == 'cancel') fixture.picker = () async => null;
        if (outcome == 'import failure') {
          final invalid = File('${fixture.directory.path}/invalid.png');
          await tester.runAsync(() => invalid.writeAsString('invalid image'));
          fixture.picker = () async => XFile(invalid.path);
        }
        await fixture.mount(tester, platform,
            custom: !outcome.startsWith('first'),
            saved: !outcome.startsWith('first'));
        final before = fixture.settings.toJson();
        expect(entry, findsOneWidget);
        expect(
            find.byKey(const Key('settings-saved-background')), findsNothing);
        expect(find.text(outcome.startsWith('first') ? '上传壁纸' : '点击更换壁纸'),
            findsOneWidget);
        await tester.ensureVisible(entry);
        await tester.runAsync(() => tester.tap(entry));
        await fixture.finish(tester);
        final success = outcome == 'first import' || outcome == 'replace';
        expect(fixture.picks, 1);
        expect(fixture.saves,
            outcome == 'cancel' || outcome == 'import failure' ? 0 : 1);
        expect(find.text('背景预览'), findsNothing);
        await tester.runAsync(() async {
          if (success) {
            expect(fixture.settings.backgroundStyle, BackgroundStyle.custom);
            expect(
                fixture.settings.customBackgroundPath, isNot(fixture.old.path));
            expect(await File(fixture.settings.customBackgroundPath).exists(),
                isTrue);
            expect(await fixture.old.exists(), outcome == 'first import');
            final loaded = AppSettings.fromJson(jsonDecode(
                await File('${fixture.directory.path}/settings.json')
                    .readAsString()) as Map<String, dynamic>);
            expect(loaded.customBackgroundPath,
                fixture.settings.customBackgroundPath);
            expect(loaded.backgroundStyle, BackgroundStyle.custom);
            expect(loaded.dynamicBackground, isTrue);
          } else {
            expect(fixture.settings.toJson(), before);
            expect(await fixture.old.exists(), isTrue);
            expect(
                await Directory('${fixture.directory.path}/backgrounds')
                    .list()
                    .length,
                1);
          }
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('$platform failed restore preserves saved wallpaper and theme',
        (tester) async {
      final fixture = (await tester.runAsync(_Fixture.create))!;
      addTearDown(() => fixture.directory.delete(recursive: true));
      addTearDown(fixture.core.dispose);
      fixture.failSave = true;
      await fixture.mount(tester, platform);
      final before = fixture.settings.toJson();
      await tester.ensureVisible(entry);
      await tester.runAsync(() => tester.tap(entry));
      await fixture.finish(tester);
      expect(fixture.picks, 0);
      expect(fixture.saves, 1);
      expect(fixture.settings.toJson(), before);
      expect(await tester.runAsync(fixture.old.exists), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
        '$platform restores saved wallpaper with constant hints and keyboard support',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = (await tester.runAsync(_Fixture.create))!;
      addTearDown(() => fixture.directory.delete(recursive: true));
      addTearDown(fixture.core.dispose);
      await fixture.mount(tester, platform);
      await tester.ensureVisible(entry);
      expect(find.text('使用自定义壁纸'), findsOneWidget);
      expect(find.text('点击恢复，无须重新上传'), findsOneWidget);
      expect(find.descendant(of: entry, matching: find.byType(Image)),
          findsOneWidget);
      if (platform == TargetPlatform.android) {
        await tester.runAsync(() => tester.tap(entry));
      } else {
        final mouse =
            await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
        await mouse.addPointer();
        await mouse.moveTo(tester.getCenter(entry));
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('使用自定义壁纸，点击恢复，无须重新上传'), findsOneWidget);
        await mouse.removePointer();
        Focus.of(tester.element(find.text('使用自定义壁纸'))).requestFocus();
        await tester.pump();
        await tester
            .runAsync(() => tester.sendKeyEvent(LogicalKeyboardKey.space));
      }
      await fixture.finish(tester);
      expect(fixture.picks, 0);
      expect(fixture.settings.customBackgroundPath, fixture.old.path);
      expect(fixture.settings.backgroundStyle, BackgroundStyle.custom);
      expect(find.text('使用中'), findsOneWidget);
      expect(find.text('点击更换壁纸'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final outcome in ['cancel', 'stale', 'disposed']) {
    testWidgets(
        'late picker $outcome cannot overwrite settings or repeat selection',
        (tester) async {
      final fixture = (await tester.runAsync(_Fixture.create))!;
      addTearDown(() => fixture.directory.delete(recursive: true));
      addTearDown(fixture.core.dispose);
      final selection = Completer<XFile?>();
      fixture.picker = () => selection.future;
      await fixture.mount(tester, TargetPlatform.android, custom: true);
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pump();
      await tester.tap(entry);
      expect(fixture.picks, 1);
      if (outcome == 'stale') {
        fixture.update(() => fixture.settings =
            fixture.settings.copyWith(backgroundStyle: BackgroundStyle.blue));
        await tester.pump();
      }
      if (outcome == 'disposed') await tester.pumpWidget(const SizedBox());
      selection
          .complete(outcome == 'cancel' ? null : XFile(fixture.source.path));
      await fixture.finish(tester);
      expect(fixture.saves, 0);
      expect(fixture.settings.customBackgroundPath, fixture.old.path);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'old resource remains until successful save and repeated taps are blocked',
      (tester) async {
    final fixture = (await tester.runAsync(_Fixture.create))!;
    addTearDown(() => fixture.directory.delete(recursive: true));
    addTearDown(fixture.core.dispose);
    fixture.saveGate = Completer<void>();
    await fixture.mount(tester, TargetPlatform.windows, custom: true);
    await tester.ensureVisible(entry);
    await tester.runAsync(() => tester.tap(entry));
    for (var i = 0; i < 100 && fixture.saves == 0; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(fixture.saves, 1);
    expect(await tester.runAsync(fixture.old.exists), isTrue);
    expect(fixture.settings.customBackgroundPath, fixture.old.path);
    await tester.tap(entry);
    expect(fixture.picks, 1);
    fixture.saveGate!.complete();
    await fixture.finish(tester);
    expect(await tester.runAsync(fixture.old.exists), isFalse);
    expect(fixture.settings.customBackgroundPath, isNot(fixture.old.path));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
