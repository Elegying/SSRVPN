import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_home_text.dart';

void main() {
  testWidgets('retained text fitting matches fresh fitting after input changes',
      (tester) async {
    Widget scene(int step) => MaterialApp(
          home: MediaQuery(
            data:
                MediaQueryData(textScaler: TextScaler.linear(step < 6 ? 1 : 2)),
            child: Directionality(
              textDirection: step < 8 ? TextDirection.ltr : TextDirection.rtl,
              child: Column(children: [
                for (final fresh in [false, true])
                  SizedBox(
                    width: step < 4 ? 80 : 160,
                    height: 65,
                    child: SsrvpnHomeText(
                      '↑${step * 117}',
                      key: fresh ? ValueKey(step) : const ValueKey('retained'),
                      fitReference: step < 10 ? '↑9999' : null,
                      style: TextStyle(fontSize: step < 12 ? 30 : 40),
                      maxFontSize: step < 14 ? 50 : 20,
                    ),
                  ),
              ]),
            ),
          ),
        );
    for (var step = 0; step < 16; step++) {
      await tester.pumpWidget(scene(step));
      final texts = tester.widgetList<Text>(find.byType(Text)).toList();
      expect(texts, hasLength(2));
      expect(texts.first.style, texts.last.style);
      expect(texts.first.data, texts.last.data);
      expect(tester.getSize(find.byType(Text).first),
          tester.getSize(find.byType(Text).last));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
