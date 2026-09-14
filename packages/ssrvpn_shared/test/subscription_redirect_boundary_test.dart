import 'dart:io';
import 'package:ssrvpn_shared/services/direct_fetcher.dart';
import 'package:ssrvpn_shared/services/desktop_subscription_fetcher.dart';
import 'package:ssrvpn_shared/services/subscription_fetch_policy.dart';
import 'package:test/test.dart';

void main() {
  for (final direct in [true, false]) {
    test('redirect cannot reach a second private origin (direct: $direct)',
        () async {
      final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var targetRequests = 0;
      var sourceRequests = 0;
      final targetListener = target.listen((request) {
        targetRequests++;
        request.response.close();
      });
      final sourceListener = source.listen((request) {
        sourceRequests++;
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader,
              'http://127.0.0.1:${target.port}/private')
          ..close();
      });
      try {
        final url = 'http://127.0.0.1:${source.port}/subscription';
        await expectLater(
          direct
              ? DirectFetcher.fetchResponse(url)
              : DesktopSubscriptionFetcher.fetch(url,
                  allowDirectFetch: false, maxRetries: 1),
          throwsA(isA<SubscriptionAddressException>()),
        );
        expect(sourceRequests, 1);
        expect(targetRequests, 0);
      } finally {
        await sourceListener.cancel();
        await targetListener.cancel();
        await source.close(force: true);
        await target.close(force: true);
      }
    });
  }
}
