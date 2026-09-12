import 'package:flutter/material.dart';
import 'ssrvpn_home_text.dart';

/// Shared whole-page geometry, including notices outside the home overview.
class SsrvpnHomeShell extends StatelessWidget {
  const SsrvpnHomeShell(
      {super.key,
      required this.body,
      required this.navigation,
      this.extendBehindNavigation = false,
      this.notices = const []});
  final Widget body, navigation;
  final bool extendBehindNavigation;
  final List<Widget> notices;
  static double bodyTopOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_HomeBodyOffset>()?.top ?? 0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
      builder: (context, constraints) => Column(children: [
            if (notices.isNotEmpty)
              ConstrainedBox(
                  constraints:
                      BoxConstraints(maxHeight: constraints.maxHeight * .24),
                  child: Column(
                    key: const Key('desktop-startup-banner-region'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final notice in notices) Flexible(child: notice)
                    ],
                  )),
            Expanded(
                child: LayoutBuilder(
                    builder: (context, remaining) => _HomeBodyOffset(
                          top: constraints.maxHeight - remaining.maxHeight,
                          child: Scaffold(
                            backgroundColor: Colors.transparent,
                            extendBody: extendBehindNavigation,
                            body: body,
                            bottomNavigationBar: navigation,
                          ),
                        ))),
          ]));
}

class SsrvpnHomeNotice extends StatelessWidget {
  const SsrvpnHomeNotice(
      {super.key,
      required this.icon,
      required this.color,
      required this.title,
      required this.message});
  final IconData icon;
  final Color color;
  final String title, message;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
        decoration: BoxDecoration(
            color: color.withValues(
                alpha: Theme.of(context).brightness == Brightness.dark
                    ? 20 / 255
                    : 14 / 255),
            border: Border(
                bottom: BorderSide(color: color.withValues(alpha: 55 / 255)))),
        child: Row(children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
              child: SsrvpnHomeText('$title：$message',
                  maxLines: null,
                  maxFontSize: 14,
                  style: TextStyle(color: color, fontSize: 12))),
        ]),
      );
}

class _HomeBodyOffset extends InheritedWidget {
  const _HomeBodyOffset({required this.top, required super.child});
  final double top;
  @override
  bool updateShouldNotify(_HomeBodyOffset oldWidget) => top != oldWidget.top;
}
