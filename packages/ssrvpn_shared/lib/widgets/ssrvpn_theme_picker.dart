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
      LayoutBuilder(builder: (context, constraints) {
        const columns = 4;
        final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
        return Wrap(spacing: 8, runSpacing: 12, children: [
          for (final variant in SsrvpnTheme.selectionOrder)
            SizedBox(
                width: width,
                child: Semantics(
                  button: true,
                  selected: selected == variant,
                  label: '${SsrvpnTheme(variant).selectionLabel}主题',
                  child: Tooltip(
                      message: SsrvpnTheme(variant).selectionLabel,
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
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 3, vertical: 8),
                              child: Column(children: [
                                Stack(children: [
                                  ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: Image.asset(
                                        SsrvpnTheme(variant).icon,
                                        package: 'ssrvpn_shared',
                                        width: (width - 6).clamp(0.0, 60.0),
                                        height: (width - 6).clamp(0.0, 60.0),
                                        cacheWidth: 128,
                                        excludeFromSemantics: true,
                                      )),
                                  if (variant == AppThemeVariant.cloud)
                                    Positioned(
                                        left: 0,
                                        top: 0,
                                        child: DecoratedBox(
                                            decoration: BoxDecoration(
                                                color: colors.surface,
                                                borderRadius:
                                                    BorderRadius.circular(4)),
                                            child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 3,
                                                        vertical: 1),
                                                child: Text('默认',
                                                    style: TextStyle(
                                                        color:
                                                            colors.textPrimary,
                                                        fontSize: 9))))),
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
                                        fontSize: 13,
                                        fontWeight: selected == variant
                                            ? FontWeight.w700
                                            : FontWeight.w600)),
                              ])),
                        ),
                      )),
                )),
        ]);
      }),
    ]);
  }
}
