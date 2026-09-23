import 'dart:convert';
import 'dart:io';

import 'package:ssrvpn_shared/services/subscription_parser.dart';

/// Exposes the production parser to the loopback protocol integration probe.
Future<void> main() async {
  final input = jsonDecode(await stdin.transform(utf8.decoder).join()) as List;
  stdout.writeln(jsonEncode([
    for (final link in input) SubscriptionParser.proxyFromUri(link as String),
  ]));
}
