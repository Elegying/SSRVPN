import 'package:flutter/material.dart';
import 'ssrvpn_theme.dart';
import 'ssrvpn_soft_inset.dart';

/// Idle is flat; only a confirmed connection depresses the live switch face.
class SsrvpnSoftPowerArt extends StatelessWidget {
  const SsrvpnSoftPowerArt({super.key, required this.active});
  final bool active;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: DecoratedBox(
            decoration: BoxDecoration(
                shape: BoxShape.circle, color: SsrvpnTheme.of(context).surface),
            child: AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 280),
              child: active
                  ? const SsrvpnSoftInset(
                      key: ValueKey('soft-connected-recess'),
                      radius: 1000,
                      child: SizedBox.expand())
                  : const SizedBox.expand(key: ValueKey('soft-idle-flat')),
            ),
          ),
        ),
      );
}
