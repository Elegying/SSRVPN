import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';

import '../utils/node_country_policy.dart';

class CountryFlagIcon extends StatelessWidget {
  const CountryFlagIcon({
    required this.countryCode,
    required this.size,
    super.key,
  });

  final String countryCode;
  final double size;

  @override
  Widget build(BuildContext context) {
    final code = normalizeNodeCountryCode(countryCode);
    if (code == 'UN' || FlagCode.fromCountryCode(code) == null) {
      return Icon(
        Icons.public_rounded,
        size: size * 0.72,
        color: Theme.of(context).colorScheme.primary,
      );
    }

    return Semantics(
      image: true,
      label: '$code 国旗',
      child: ExcludeSemantics(
        child: CountryFlag.fromCountryCode(
          code,
          theme: ImageTheme(
            width: size,
            height: size,
            shape: const Circle(),
          ),
        ),
      ),
    );
  }
}
