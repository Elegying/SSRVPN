import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/models/app_settings.dart';
import 'package:ssrvpn_android/theme/app_theme.dart';
import 'package:ssrvpn_android/utils/responsive.dart';
import 'package:ssrvpn_android/widgets/force_proxy_sites_dialog.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_info_dialog.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_typography.dart';

const _captureKey = Key('rule-dialog-pixels');
final _evidenceDirectory = Platform.environment['SSRVPN_DIALOG_EVIDENCE_DIR'];
final _fontPath = Platform.environment['SSRVPN_DIALOG_EVIDENCE_FONT'];

ButtonStyle _evidenceButtonStyle(ButtonStyle? style) =>
    (style ?? const ButtonStyle()).copyWith(
      textStyle: WidgetStateProperty.resolveWith((states) =>
          (style?.textStyle?.resolve(states) ?? const TextStyle())
              .copyWith(fontFamily: 'DialogEvidence')),
    );

Future<ByteData> _pixels(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      if (_evidenceDirectory case final String directory) {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(directory).create(recursive: true);
        await File('$directory/$name.png').writeAsBytes(
          png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        );
      }
      return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (_fontPath case final String path) {
      final bytes = ByteData.sublistView(await File(path).readAsBytes());
      for (final family in ['DialogEvidence', SsrvpnTypography.family]) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });

  for (final dark in [false, true]) {
    for (final direct in [false, true]) {
      for (final level in GlassEffectLevel.values) {
        final scenario = '${direct ? 'direct' : 'proxy'}-'
            '${dark ? 'dark' : 'light'}-${level.name}';
        testWidgets('rule form obscures the underlying page: $scenario',
            (tester) async {
          const size = Size(430, 932);
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final background = ValueNotifier<Color>(Colors.black);
          addTearDown(background.dispose);
          final baseTheme = dark ? AppTheme.darkTheme : AppTheme.lightTheme;
          final theme = _fontPath == null
              ? baseTheme
              : baseTheme.copyWith(
                  textTheme:
                      baseTheme.textTheme.apply(fontFamily: 'DialogEvidence'),
                  primaryTextTheme: baseTheme.primaryTextTheme
                      .apply(fontFamily: 'DialogEvidence'),
                  textButtonTheme: TextButtonThemeData(
                      style: _evidenceButtonStyle(
                          baseTheme.textButtonTheme.style)),
                  elevatedButtonTheme: ElevatedButtonThemeData(
                      style: _evidenceButtonStyle(
                          baseTheme.elevatedButtonTheme.style)),
                );
          await tester.pumpWidget(MaterialApp(
            theme: theme,
            builder: (_, child) => RepaintBoundary(
              key: _captureKey,
              child: SsrvpnAppearanceScope(
                settings: AppSettings(glassEffectLevel: level),
                child: child!,
              ),
            ),
            home: Builder(builder: (context) {
              Responsive.init(context);
              return Scaffold(
                body: Stack(fit: StackFit.expand, children: [
                  ValueListenableBuilder<Color>(
                    valueListenable: background,
                    builder: (_, color, __) => ColoredBox(color: color),
                  ),
                  Column(children: [
                    for (var i = 0; i < 12; i++)
                      Expanded(
                        child: Center(
                          child: Text('节点列表 · 测试背景 $i · 88 ms',
                              style: const TextStyle(
                                  color: Colors.cyan, fontSize: 24)),
                        ),
                      ),
                  ]),
                  Align(
                    alignment: Alignment.topCenter,
                    child: TextButton(
                      onPressed: () => ForceProxySitesDialog.show(context,
                          savedSites: const ['https://example.com'],
                          forceDirect: direct),
                      child: const Text('打开规则'),
                    ),
                  ),
                ]),
              );
            }),
          ));
          await tester.tap(find.text('打开规则'));
          await tester.pumpAndSettle();
          final panel = tester.getRect(find.byType(SsrvpnModalGlassPanel));
          final black = await _pixels(tester, '$scenario-black');
          background.value = Colors.white;
          await tester.pumpAndSettle();
          final white = await _pixels(tester, '$scenario-white');

          // The backdrop really changed, including through the modal barrier.
          final outside = (4 * size.width.toInt() + 4) * 4;
          expect((black.getUint8(outside) - white.getUint8(outside)).abs(),
              greaterThan(80));
          // Measure all content, not just a tint property or one empty pixel.
          // Exclude the rounded glass edge, where translucency is intentional.
          final content = panel.deflate(20);
          var changedPixels = 0;
          var measuredPixels = 0;
          for (var y = content.top.ceil(); y < content.bottom.floor(); y++) {
            for (var x = content.left.ceil(); x < content.right.floor(); x++) {
              final offset = (y * size.width.toInt() + x) * 4;
              if (List.generate(
                  3,
                  (channel) => (black.getUint8(offset + channel) -
                          white.getUint8(offset + channel))
                      .abs()).any((change) => change > 1)) {
                changedPixels++;
              }
              measuredPixels++;
            }
          }
          expect(measuredPixels, greaterThan(10000));
          expect(changedPixels, 0,
              reason: 'Page pixels must not bleed through form labels, '
                  'inputs or actions ($scenario).');
          for (final field
              in tester.widgetList<TextField>(find.byType(TextField))) {
            final decoration = field.decoration!;
            final fill = Color.alphaBlend(
                decoration.fillColor!, theme.colorScheme.surface);
            for (final style in [
              decoration.labelStyle!,
              decoration.hintStyle!
            ]) {
              final ink =
                  Color.alphaBlend(style.color!, fill).computeLuminance();
              final paper = fill.computeLuminance();
              final contrast = ink > paper
                  ? (ink + .05) / (paper + .05)
                  : (paper + .05) / (ink + .05);
              expect(contrast, greaterThanOrEqualTo(4.5));
            }
          }
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(find.byType(SsrvpnModalGlassPanel), findsNothing);
        });
      }
    }
  }

  testWidgets(
      'small rule form remains editable above the keyboard at large text',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    tester.view.viewInsets = const FakeViewPadding(bottom: 200);
    addTearDown(tester.view.reset);
    List<String>? result;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(2),
          highContrast: true,
        ),
        child: child!,
      ),
      home: Builder(builder: (context) {
        Responsive.init(context);
        return Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await ForceProxySitesDialog.show(context,
                  savedSites: const [], forceDirect: true);
            },
            child: const Text('打开规则'),
          ),
        );
      }),
    ));
    await tester.tap(find.text('打开规则'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final firstField = find.byType(TextField).first;
    await tester.ensureVisible(firstField);
    await tester.enterText(firstField, 'https://example.com');
    await tester.pumpAndSettle();
    final confirm = find.widgetWithText(ElevatedButton, '确定');
    await tester.ensureVisible(confirm);
    await tester.pumpAndSettle();
    expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(368));
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(result!.first, 'https://example.com');
    expect(find.byType(SsrvpnModalGlassPanel), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
