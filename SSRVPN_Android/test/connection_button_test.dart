import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/widgets/connection_button.dart';

void main() {
  testWidgets('connecting button remains tappable to cancel', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectionButton(
            isConnected: false,
            isConnecting: true,
            onTap: () => taps++,
          ),
        ),
      ),
    );

    expect(find.text('取消'), findsOneWidget);
    await tester.tap(find.byType(ConnectionButton));
    expect(taps, 1);
  });
}
