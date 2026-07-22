import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/widgets/windows_desktop_frame.dart';

void main() {
  testWidgets('custom title bar exposes accessible window controls',
      (tester) async {
    var minimized = false;
    var maximized = false;
    var closed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WindowsTitleBar(
            isMaximized: false,
            onMinimize: () => minimized = true,
            onToggleMaximize: () => maximized = true,
            onClose: () => closed = true,
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('windows-custom-title-bar')), findsOneWidget);
    expect(find.text('SSRVPN'), findsOneWidget);
    expect(find.byTooltip('最小化'), findsOneWidget);
    expect(find.byTooltip('最大化'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);

    await tester.tap(find.byTooltip('最小化'));
    await tester.tap(find.byTooltip('最大化'));
    await tester.tap(find.byTooltip('关闭'));

    expect(minimized, isTrue);
    expect(maximized, isTrue);
    expect(closed, isTrue);
  });

  testWidgets('maximized title bar offers restore and fits compact windows',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 220));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WindowsTitleBar(
            isMaximized: true,
            onMinimize: () {},
            onToggleMaximize: () {},
            onClose: () {},
          ),
        ),
      ),
    );

    expect(find.byTooltip('还原'), findsOneWidget);
    expect(find.byTooltip('最大化'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
