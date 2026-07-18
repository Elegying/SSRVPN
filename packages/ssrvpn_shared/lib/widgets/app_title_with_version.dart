import 'package:flutter/material.dart';

import '../constants/app_constants.dart';

/// The synchronized product title used by every platform's home page.
class AppTitleWithVersion extends StatelessWidget {
  const AppTitleWithVersion({
    required this.titleStyle,
    required this.versionStyle,
    this.gap = 5,
    super.key,
  });

  final TextStyle titleStyle;
  final TextStyle versionStyle;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${AppConstants.appName}，版本 ${AppConstants.appVersion}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: Text(
              AppConstants.appName,
              style: titleStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
            ),
          ),
          SizedBox(width: gap),
          Padding(
            padding: const EdgeInsets.only(bottom: 1),
            child: Text(
              'v${AppConstants.appVersion}',
              style: versionStyle,
              textScaler: TextScaler.noScaling,
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}
