import '../models/proxy_node.dart';
import '../utils/node_country_policy.dart';

class HomeExitCountryController {
  static Map<String, String> resolveMissingCountries(
    Iterable<ProxyNode> nodes,
    Map<String, String> existing,
  ) {
    final resolved = <String, String>{};
    for (final node in nodes) {
      if (existing.containsKey(node.name)) continue;
      final country = countryCodeForProxyNode(node);
      if (country == 'UN') continue;
      resolved[node.name] = country;
    }
    return resolved;
  }
}
