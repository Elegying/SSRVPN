import 'package:ssrvpn_shared/controllers/home_exit_country_controller.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:test/test.dart';

void main() {
  ProxyNode node(String name, {String server = 'example.com'}) => ProxyNode(
        name: name,
        type: 'ss',
        server: server,
        port: 443,
      );

  group('HomeExitCountryController', () {
    test('resolves countries from node metadata without runtime switching', () {
      final result = HomeExitCountryController.resolveMissingCountries(
        [
          node('日本东京 01'),
          node('US CN2'),
          node('Unknown Node'),
        ],
        const {},
      );

      expect(result, {'日本东京 01': 'JP', 'US CN2': 'US'});
    });

    test('keeps existing country values', () {
      final result = HomeExitCountryController.resolveMissingCountries(
        [node('日本东京 01')],
        const {'日本东京 01': 'SG'},
      );

      expect(result, isEmpty);
    });
  });
}
