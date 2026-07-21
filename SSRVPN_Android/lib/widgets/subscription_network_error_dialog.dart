import 'package:flutter/material.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

class SubscriptionNetworkErrorDialog extends StatelessWidget {
  const SubscriptionNetworkErrorDialog({
    super.key,
    required this.detail,
  });

  final String detail;

  @override
  Widget build(BuildContext context) =>
      SsrvpnSubscriptionErrorDialog(detail: detail);
}
