import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/models/app_settings.dart';
import 'package:ssrvpn_android/theme/app_theme.dart';
import 'package:ssrvpn_android/utils/responsive.dart';
import 'package:ssrvpn_android/widgets/force_proxy_sites_dialog.dart';

void main() {
  testWidgets('dialog validates one host per field and returns trimmed input',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    List<String>? result;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Builder(
          builder: (context) {
            Responsive.init(context);
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await ForceProxySitesDialog.show(
                      context,
                      savedSites: List.filled(
                        AppSettings.forceProxySiteLimit,
                        '',
                      ),
                    );
                  },
                  child: const Text('打开设置'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    expect(find.text('添加强制代理网站'), findsOneWidget);
    expect(find.textContaining('默认规则已涵盖绝大部分网站'), findsOneWidget);
    expect(
        find.byType(TextField), findsNWidgets(AppSettings.forceProxySiteLimit));

    await tester.enterText(find.byType(TextField).first, 'one.com two.com');
    await tester.tap(find.widgetWithText(ElevatedButton, '确定'));
    await tester.pump();
    expect(find.text('第 1 个输入框：一个输入框只能填写一个网址'), findsOneWidget);
    expect(result, isNull);

    await tester.enterText(find.byType(TextField).first, 'bad_domain.example');
    await tester.tap(find.widgetWithText(ElevatedButton, '确定'));
    await tester.pump();
    expect(find.text('第 1 个输入框：请输入有效的网址或域名'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField).first,
      '  https://Blocked.Example/path  ',
    );
    if (AppSettings.forceProxySiteLimit > 1) {
      await tester.enterText(find.byType(TextField).at(1), 'youtube.com');
    }
    await tester.tap(find.widgetWithText(ElevatedButton, '确定'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result, hasLength(AppSettings.forceProxySiteLimit));
    expect(result!.first, 'https://Blocked.Example/path');
    if (AppSettings.forceProxySiteLimit > 1) {
      expect(result![1], 'youtube.com');
    }
    expect(find.text('添加强制代理网站'), findsNothing);
  });

  testWidgets('cancel closes the dialog without changing settings',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var completed = false;
    List<String>? result = const ['unchanged'];
    final saved = List<String>.filled(AppSettings.forceProxySiteLimit, '');
    saved[0] = 'example.com';

    await tester.pumpWidget(
      MaterialApp(
        darkTheme: AppTheme.darkTheme,
        themeMode: ThemeMode.dark,
        home: Builder(
          builder: (context) {
            Responsive.init(context);
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await ForceProxySitesDialog.show(
                      context,
                      savedSites: saved,
                    );
                    completed = true;
                  },
                  child: const Text('打开设置'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    expect(find.text('example.com'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(completed, isTrue);
    expect(result, isNull);
  });
}
