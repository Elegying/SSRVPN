import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_settings_page.dart';

class _Core extends Fake implements ClashServiceBase {
  @override
  bool get isRunning => false;
  @override
  void addStatusListener(VoidCallback listener) {}
  @override
  void removeStatusListener(VoidCallback listener) {}
}

void main() {
  test('legacy appearance migrates without dropping functional preferences',
      () {
    for (final old in [
      'flowing',
      'blue',
      'gray',
      'forest',
      'orange',
      'yellow',
      'deepBlue',
      'black',
      'custom'
    ]) {
      final settings = AppSettings.fromJson({
        'backgroundStyle': old,
        'customBackgroundPath': '/private/old.png',
        'dynamicBackground': true,
        'glassEffectLevel': 'low',
        'proxyPort': 8900,
        'enableTun': true,
        'lastSelectedNodeName': '私家车·东京',
        'forceDirectSites': ['example.com']
      });
      expect(settings.themeVariant, AppThemeVariant.defaultTheme);
      expect(settings.proxyPort, 8900);
      expect(settings.enableTun, isTrue);
      expect(settings.lastSelectedNodeName, '私家车·东京');
      expect(settings.forceDirectSites, ['example.com', '', '', '', '']);
      expect(settings.toJson().keys, isNot(contains('dynamicBackground')));
      expect(settings.toJson().keys, isNot(contains('customBackgroundPath')));
    }
    for (final theme in AppThemeVariant.values) {
      final value = AppSettings(themeVariant: theme);
      expect(AppSettings.fromJson(value.toJson()), value);
      expect(value.copyWith(proxyPort: 8900).themeVariant, theme);
    }
    expect(AppSettings.fromJson({'themeVariant': 'future'}).themeVariant,
        AppThemeVariant.defaultTheme);
  });
  testWidgets(
      'all themes apply without losing input; failed save retains theme',
      (tester) async {
    var settings = AppSettings();
    var fail = false;
    await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(
            builder: (context, update) => SsrvpnAppearanceScope(
                settings: settings,
                child: Scaffold(
                    body: SsrvpnSettingsPage(
                  settings: settings,
                  core: _Core(),
                  onAppearanceChanged: ({themeVariant}) async {
                    if (fail) throw StateError('disk full');
                    update(() => settings =
                        settings.copyWith(themeVariant: themeVariant));
                  },
                  onPortChanged: (_) async {},
                  checkForUpdate: () async => null,
                  onUpdateFound: (_) {},
                ))))));
    await tester.pumpAndSettle();
    expect(find.text('动态背景'), findsNothing);
    expect(find.text('自定义'), findsNothing);
    expect(find.text('液态玻璃特效'), findsNothing);
    for (final theme in AppThemeVariant.values) {
      final finder = find.byKey(ValueKey('theme-${theme.name}'));
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(settings.themeVariant, theme);
      expect(tester.takeException(), isNull);
    }
    final input = find.byType(TextField);
    await tester.ensureVisible(input);
    await tester.enterText(input, '8999');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final theme = find.byKey(const ValueKey('theme-sakura'));
    await tester.ensureVisible(theme);
    await tester.pumpAndSettle();
    await tester.tap(theme);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).controller!.text, '8999');
    fail = true;
    await tester.tap(find.byKey(const ValueKey('theme-cloud')));
    await tester.pumpAndSettle();
    expect(settings.themeVariant, AppThemeVariant.sakura);
    expect(find.text('保存失败，原设置已保留，请重试'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
