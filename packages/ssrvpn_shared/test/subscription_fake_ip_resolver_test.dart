import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  final uri =
      Uri.parse('https://feed.example.test/subscription?token=synthetic');
  List<InternetAddress> addresses(List<String> values) =>
      values.map(InternetAddress.new).toList();

  test('public system addresses keep their order without DoH', () async {
    final result = await DirectFetcher.resolveSystemAddresses(uri,
        systemLookup: (_) async => addresses(['8.8.8.8', '1.1.1.1']),
        dohLookup: (_) => throw StateError('DoH must not run'));
    expect(result.map((a) => a.address), ['8.8.8.8', '1.1.1.1']);
  });
  test('Fake-IP and mixed public answers resolve once to validated real IPs',
      () async {
    for (final values in [
      ['198.18.0.55'],
      ['198.19.0.61'],
      ['198.18.0.55', '8.8.8.8'],
      ['fdfe:dcba:9877::55'],
      ['198.18.0.55', 'fdfe:dcba:9877::55'],
    ]) {
      var calls = 0;
      final result = await DirectFetcher.resolveSystemAddresses(uri,
          systemLookup: (_) async => addresses(values),
          dohLookup: (host) async {
            expect(host, uri.host);
            calls++;
            return addresses(['1.1.1.1']);
          });
      expect(result.single.address, '1.1.1.1');
      expect(calls, 1);
    }
  });
  test('private system answers cannot trigger an escape through DoH', () async {
    for (final values in [
      ['192.168.1.1'],
      ['198.18.0.55', '127.0.0.1'],
      ['fdfe:dcba:9877::55', 'fc00::1'],
      ['fdfe:dcba:9876::1'],
    ]) {
      await expectLater(
          DirectFetcher.resolveSystemAddresses(uri,
              systemLookup: (_) async => addresses(values),
              dohLookup: (_) => throw StateError('must not run')),
          throwsA(isA<SubscriptionAddressException>()));
    }
  });
  test('DoH private, Fake-IP, mapped loopback and mixed answers are rejected',
      () async {
    for (final values in [
      ['192.168.1.1'],
      ['198.18.0.61'],
      ['fdfe:dcba:9877::61'],
      ['::ffff:127.0.0.1'],
      ['1.1.1.1', '10.0.0.1'],
    ]) {
      await expectLater(
          DirectFetcher.resolveSystemAddresses(uri,
              systemLookup: (_) async => addresses(['198.18.0.55']),
              dohLookup: (_) async => addresses(values)),
          throwsA(isA<SubscriptionAddressException>()));
    }
  });
  test('DoH failure/empty answer fails without returning to system DNS',
      () async {
    for (final fail in [false, true]) {
      var systemCalls = 0;
      await expectLater(
          DirectFetcher.resolveSystemAddresses(uri, systemLookup: (_) async {
            systemCalls++;
            return addresses(['198.18.0.55']);
          }, dohLookup: (_) async {
            if (fail) throw const SocketException('private raw detail');
            return [];
          }),
          throwsA(isA<SubscriptionDnsException>().having((e) => e.toString(),
              'safe message', isNot(contains('private raw')))));
      expect(systemCalls, 1);
    }
  });
  test('system DNS failures are classified without exposing raw errors',
      () async {
    await expectLater(
        DirectFetcher.resolveSystemAddresses(uri,
            systemLookup: (_) => throw const SocketException('token=secret')),
        throwsA(isA<SubscriptionDnsException>()
            .having((e) => e.message, 'safe', isNot(contains('secret')))));
  });
  test('cancel and deadline interrupt pending DoH', () async {
    for (final cancel in [false, true]) {
      final control = SubscriptionRefreshControl(
          timeout: const Duration(milliseconds: 100));
      final started = Completer<void>();
      final future = DirectFetcher.resolveSystemAddresses(uri,
          control: control,
          systemLookup: (_) async => addresses(['198.18.0.55']),
          dohLookup: (_) {
            started.complete();
            return Completer<List<InternetAddress>>().future;
          });
      final check = expectLater(
          future,
          throwsA(cancel
              ? isA<SubscriptionRefreshCancelled>()
              : isA<SubscriptionRefreshDeadlineExceeded>()));
      await started.future;
      if (cancel) control.cancellation.cancel();
      await check;
    }
  });
  test('literal Fake-IP remains forbidden and is never sent to DoH', () async {
    for (final host in ['198.18.0.55', '[fdfe:dcba:9877::55]']) {
      await expectLater(
          DirectFetcher.resolveSystemAddresses(Uri.parse('https://$host/'),
              dohLookup: (_) => throw StateError('must not run')),
          throwsA(isA<SubscriptionAddressException>()));
    }
  });
}
