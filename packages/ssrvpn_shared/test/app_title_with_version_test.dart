import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/constants/app_constants.dart';
import 'package:ssrvpn_shared/widgets/app_title_with_version.dart';

void main() {
  testWidgets('shows the release version to the right of the SSRVPN title', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: AppTitleWithVersion(
              titleStyle: TextStyle(fontSize: 19),
              versionStyle: TextStyle(fontSize: 10),
            ),
          ),
        ),
      ),
    );

    final title = find.text(AppConstants.appName);
    final version = find.text('v${AppConstants.appVersion}');
    expect(title, findsOneWidget);
    expect(version, findsOneWidget);
    expect(
      tester.getTopLeft(version).dx,
      greaterThan(tester.getTopRight(title).dx),
    );
    expect(
      find.bySemanticsLabel(
        '${AppConstants.appName}，版本 ${AppConstants.appVersion}',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('fits a compact title slot with large accessibility text', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 84,
                child: AppTitleWithVersion(
                  titleStyle: TextStyle(fontSize: 18),
                  versionStyle: TextStyle(fontSize: 9),
                  gap: 4,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('v${AppConstants.appVersion}'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
