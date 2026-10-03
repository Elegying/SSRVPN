import 'package:flutter/material.dart';
import '../models/app_settings.dart';
import 'ssrvpn_theme.dart';

class SsrvpnThemePicker extends StatelessWidget {
  const SsrvpnThemePicker(
      {super.key, required this.selected, required this.onChanged});
  final AppThemeVariant selected;
  final ValueChanged<AppThemeVariant>? onChanged;
  @override
  Widget build(BuildContext context) {
    final colors = SsrvpnTheme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('主题', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, constraints) {
        final columns = constraints.maxWidth >= 480
            ? 3
            : constraints.maxWidth >= 280
                ? 3
                : 2;
        final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
        return Wrap(spacing: 10, runSpacing: 12, children: [
          for (final variant in AppThemeVariant.values)
            SizedBox(
                width: width,
                child: Semantics(
                  button: true,
                  selected: selected == variant,
                  label: '${SsrvpnTheme(variant).name}主题',
                  child: Tooltip(
                      message: SsrvpnTheme(variant).name,
                      child: Material(
                        color: selected == variant
                            ? colors.primary.withValues(alpha: .12)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          key: ValueKey('theme-${variant.name}'),
                          borderRadius: BorderRadius.circular(16),
                          onTap: onChanged == null || selected == variant
                              ? null
                              : () {
                                  FocusScope.of(context).unfocus();
                                  onChanged!(variant);
                                },
                          child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Column(children: [
                                Stack(children: [
                                  ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: Image.asset(
                                        SsrvpnTheme(variant).icon,
                                        package: 'ssrvpn_shared',
                                        width: 60,
                                        height: 60,
                                        cacheWidth: 128,
                                        excludeFromSemantics: true,
                                      )),
                                  if (selected == variant)
                                    Positioned(
                                        right: 0,
                                        bottom: 0,
                                        child: DecoratedBox(
                                            decoration: BoxDecoration(
                                                color: colors.primary,
                                                shape: BoxShape.circle),
                                            child: Icon(Icons.check_rounded,
                                                size: 20,
                                                color: colors.onPrimary))),
                                ]),
                                const SizedBox(height: 8),
                                Text(SsrvpnTheme(variant).name,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: selected == variant
                                            ? FontWeight.w700
                                            : FontWeight.w500)),
                              ])),
                        ),
                      )),
                )),
        ]);
      }),
    ]);
  }
}
