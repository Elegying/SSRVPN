import 'dart:io';
import 'dart:async';
import 'package:ssrvpn_shared/controllers/subscription_screen_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/subscription.dart';
import 'package:ssrvpn_shared/models/subscription_usage.dart';
import 'package:ssrvpn_shared/services/subscription_service_base.dart';
import 'package:ssrvpn_shared/services/subscription_refresh_control.dart';

const _url = 'https://feed.invalid/sub';
const _yaml =
    'proxies:\n  - {name: Node, type: trojan, server: node.invalid, port: 443, password: fixture}\n';

class _Service extends SubscriptionServiceBase {
  Map<String, String> headers = {};
  final requestedUrls = <String>[];
  String body = _yaml;
  bool fail = false, failWrite = false;
  Future<void> Function()? beforeWrite;
  Future<void> Function()? beforeResponse;
  @override
  Future<String?> fetchSubscription(String url,
      {int maxRetries = 3, SubscriptionRefreshControl? control}) async {
    requestedUrls.add(url);
    if (fail) throw const SocketException('offline');
    final responseHeaders = Map<String, String>.of(headers);
    final responseBody = body;
    await beforeResponse?.call();
    recordSubscriptionResponseHeaders(url, responseHeaders);
    return responseBody;
  }

  @override
  Future<void> writeStringAtomically(File file, String content) async {
    if (file.path.endsWith('/subscriptions.json')) {
      await beforeWrite?.call();
      if (failWrite) {
        failWrite = false;
        throw const FileSystemException('fixture');
      }
    }
    await super.writeStringAtomically(file, content);
  }
}

void main() {
  test('headers are optional, case insensitive, bounded and preserve zero', () {
    final now = DateTime(2026);
    SubscriptionUsage? parse(String value) =>
        SubscriptionUsage.fromHeaders({'Subscription-Userinfo': value},
            now: now);
    final usage =
        parse('upload=0;download=0;total=107374182400;expire=1793894400')!;
    expect(usage.used, 0);
    expect(usage.total, 100 * 1024 * 1024 * 1024);
    expect(usage.expire, 1793894400);
    expect(SubscriptionUsage.fromJson(usage.toJson())!.updatedAt, now.toUtc());
    expect(parse('expire=0')!.expire, 0);
    expect(parse('upload=0;download=10')!.total, isNull);
    expect(parse('upload=0;upload=2;download=3'), isNull);
    expect(parse('upload=-1;download=3;expire=bad'), isNull);
    expect(parse('upload=NaN;download=3;expire=253402214401'), isNull);
    expect(parse('upload=9223372036854775808;download=3'), isNull);
    expect(parse('total=100'), isNull);
    expect(parse('x' * 8193), isNull);
  });

  late Directory dir;
  late _Service service;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('subscription-usage-');
    service = _Service();
    await service.init(dir.path);
  });
  tearDown(() async {
    service.dispose();
    await dir.delete(recursive: true);
  });
  Future<Subscription> seed() async {
    final sub = await service.addSubscription('Feed', _url);
    service.headers = {
      'subscription-userinfo': 'upload=1;download=2;total=100;expire=1793894400'
    };
    await service.refreshSubscription(sub.id);
    return sub;
  }

  test('adding fetches only new feed; explicit refresh fetches all', () async {
    final previous = await seed();
    final previousUpdate = previous.lastUpdate;
    service.requestedUrls.clear();
    final controller = SubscriptionScreenController.fromService(service);
    await controller.addSubscription('https://new.invalid/sub');
    expect(service.requestedUrls, ['https://new.invalid/sub']);
    expect(service.subscriptions.first.lastUpdate, previousUpdate);
    service.requestedUrls.clear();
    await controller.refreshAll();
    expect(service.requestedUrls,
        unorderedEquals([_url, 'https://new.invalid/sub']));
  });

  test('persists usage and isolates uncommitted/failed refresh metadata',
      () async {
    final sub = await seed();
    final revision = service.revision;
    final old = service.usageForNode(service.allNodes.single)!;
    expect(old.used, 3);
    service.headers = {
      'subscription-userinfo': 'upload=20;download=30;total=100'
    };
    service.beforeWrite = () async {
      expect(service.usageForNode(service.allNodes.single)!.used, 3);
    };
    service.failWrite = true;
    await expectLater(service.refreshSubscription(sub.id),
        throwsA(isA<FileSystemException>()));
    expect(service.usageForNode(service.allNodes.single)!.used, 3);
    service.beforeWrite = null;
    await service.refreshSubscription(sub.id);
    expect(service.usageForNode(service.allNodes.single)!.used, 50);
    expect(service.revision, revision);
    final restored = _Service();
    await restored.init(dir.path);
    expect(restored.usageForNode(restored.allNodes.single)!.used, 50);
    restored.dispose();
  });
  test('network/invalid body preserve usage; successful missing header clears',
      () async {
    final sub = await seed();
    service.fail = true;
    await expectLater(service.refreshSubscription(sub.id),
        throwsA(isA<SubscriptionBatchRefreshException>()));
    expect(service.subscriptions.single.usage!.used, 3);
    service.fail = false;
    service.body = '<html>error</html>';
    service.headers = {'subscription-userinfo': 'upload=100;download=100'};
    await expectLater(service.refreshSubscription(sub.id),
        throwsA(isA<SubscriptionBatchRefreshException>()));
    expect(service.subscriptions.single.usage!.used, 3);
    service.body = _yaml;
    service.headers = {};
    await service.refreshSubscription(sub.id);
    expect(service.subscriptions.single.usage, isNull);
  });
  test(
      'metadata edits preserve usage, source replacement clears it, shared nodes hide it',
      () async {
    final sub = await seed();
    await service.updateSubscription(Subscription(
        id: sub.id, name: 'Renamed', url: _url, refreshViaProxy: true));
    expect(service.subscriptions.single.usage!.used, 3);
    expect(service.subscriptions.single.refreshViaProxy, isTrue);
    await expectLater(
        service.refreshSubscription(sub.id),
        throwsA(isA<SubscriptionBatchRefreshException>().having(
            (e) => e.failures.single.diagnosticCode,
            'code',
            'SUB_PROXY_REQUIRED')));
    service.headers = {};
    await service.updateSubscription(Subscription(
        id: sub.id, name: 'New', url: 'https://other.invalid/sub'));
    expect(service.subscriptions.single.usage, isNull);
    await service.addSubscription('Shared', _url);
    service.headers = {'subscription-userinfo': 'upload=1;download=2'};
    await service.refreshAllSubscriptionsDetailed();
    expect(service.allNodes, hasLength(1));
    expect(service.usageForNode(service.allNodes.single), isNull);
    expect(service.usageForNode(service.allNodes.single.copyWith(name: '私家车')),
        isNull);
  });
  test('metadata attribution ignores query and fragment content', () {
    final usage =
        SubscriptionUsage(upload: 1, download: 2, updatedAt: DateTime(2026));
    for (final input in [
      (
        url: 'https://VIP.SSRVPN.VIP.:443/sub?data=é#other.invalid',
        allowed: false
      ),
      (
        url: 'https://user:pass@vip.ssrvpn.vip/sub#https://other.invalid',
        allowed: false
      ),
      (url: '//vip.ssrvpn.vip/sub?data=é', allowed: false),
      (url: 'https://vip.ssrvpn.vip.example/sub?data=é', allowed: true),
      (url: 'https://vip.ssrvpn.vip@other.invalid/sub?data=é', allowed: true),
      (url: 'https://other.invalid/sub?host=vip.ssrvpn.vip', allowed: true),
      (url: 'https://other.invalid/sub#https://vip.ssrvpn.vip', allowed: true),
      (url: 'https://[2001:db8::1]/sub?host=vip.ssrvpn.vip', allowed: true),
    ]) {
      final sub = Subscription(
          id: 'query', name: 'Custom', url: input.url, usage: usage);
      expect(sub.usage != null, input.allowed, reason: input.url);
      expect(sub.toJson().containsKey('usage'), input.allowed);
    }
  });

  test('metadata policy follows URL edits without sharing cached decisions',
      () {
    final usage =
        SubscriptionUsage(upload: 1, download: 2, updatedAt: DateTime(2026));
    final sub =
        Subscription(id: 'mutable', name: 'Custom', url: _url, usage: usage);
    final other =
        Subscription(id: 'other', name: 'Other', url: _url, usage: usage);
    expect(sub.name, 'Custom');
    expect(sub.usage, same(usage));
    expect(sub.toJson().containsKey('usage'), isTrue);
    sub.url = 'https://VIP.SSRVPN.VIP./sub?fixture=1';
    expect(sub.name, 'vip.ssrvpn.vip');
    expect(sub.usage, isNull);
    expect(sub.toJson().containsKey('usage'), isFalse);
    expect(other.name, 'Other');
    expect(other.usage, same(usage));
    sub.name = 'Edited';
    sub.usage = usage;
    sub.url = 'https://vip.ssrvpn.vip.example/sub';
    expect(sub.name, 'Edited');
    expect(sub.usage, isNull);
    sub.usage = usage;
    expect(sub.toJson()['usage'], usage.toJson());
    sub.url = 'https://vip.ssrvpn.vip/sub';
    expect(sub.toJson().containsKey('usage'), isFalse);
    expect(Subscription.fromJson(sub.toJson()).usage, isNull);
  });

  test('vip provider never parses, persists or displays subscription usage',
      () async {
    service.headers = {
      'subscription-userinfo':
          'upload=1;download=2;total=100;expire=1793894400',
      'profile-title': 'Ignored provider metadata'
    };
    final sub = await service.addSubscription(
        'VIP', 'https://VIP.SSRVPN.VIP./subscription?fixture=1');
    await service.refreshSubscription(sub.id);
    expect(service.subscriptions.single.usage, isNull);
    expect(service.subscriptions.single.name, 'vip.ssrvpn.vip');
    expect(service.retainedFetchedProfileNameCount, 0);
    expect(service.allNodes, hasLength(1));
    expect(service.usageForNode(service.allNodes.single), isNull);
    final stored = await File('${dir.path}/subscriptions.json').readAsString();
    expect(stored, isNot(contains('"usage"')));
    final legacy = Subscription.fromJson({
      'id': 'old',
      'name': 'VIP',
      'url': 'https://vip.ssrvpn.vip/sub',
      'usage': {
        'upload': 1,
        'download': 2,
        'total': 100,
        'expire': 1793894400,
        'updatedAt': '2026-10-06T00:00:00Z'
      }
    });
    expect(legacy.usage, isNull);
    expect(legacy.name, 'vip.ssrvpn.vip');
    legacy.usage =
        SubscriptionUsage(upload: 1, download: 2, updatedAt: DateTime(2026));
    expect(legacy.usage, isNull);
    expect(legacy.toJson().containsKey('usage'), isFalse);
    final ordinary = Subscription.fromJson(
        {...legacy.toJson(), 'url': 'https://vip.ssrvpn.vip.example/sub'});
    ordinary.usage =
        SubscriptionUsage(upload: 1, download: 2, updatedAt: DateTime(2026));
    expect(ordinary.usage!.used, 3);
  });

  test(
      'ordinary subscriptions adopt the fetched name when no custom name exists',
      () async {
    final sub = await service.addSubscription(
        service.defaultSubscriptionName(_url), _url);
    service.headers = {'profile-title': '服务商订阅名称'};
    await service.refreshSubscription(sub.id);
    expect(service.subscriptions.single.name, '服务商订阅名称');
    expect(service.retainedFetchedProfileNameCount, 1);
  });

  test('selected batch updates only selected subscriptions', () async {
    final first = await seed();
    final second =
        await service.addSubscription('Second', 'https://other.invalid/sub');
    service.headers = {'subscription-userinfo': 'upload=10;download=20'};
    final result =
        await service.refreshAllSubscriptionsDetailed(onlyIds: {second.id});
    expect(result.successfulSubscriptionIds, [second.id]);
    expect(
        service.subscriptions.firstWhere((s) => s.id == first.id).usage!.used,
        3);
    expect(
        service.subscriptions.firstWhere((s) => s.id == second.id).usage!.used,
        30);
  });
  test('cancelled late response cannot replace newer usage or provider name',
      () async {
    final sub = await seed();
    final entered = Completer<void>();
    final release = Completer<void>();
    service.headers = {
      'subscription-userinfo': 'upload=900;download=900',
      'profile-title': 'Stale provider'
    };
    service.beforeResponse = () {
      entered.complete();
      return release.future;
    };
    final cancellation = SubscriptionRefreshCancellation();
    final task =
        service.refreshAllSubscriptionsDetailed(cancellation: cancellation);
    final assertion =
        expectLater(task, throwsA(isA<SubscriptionRefreshCancelled>()));
    await entered.future;
    cancellation.cancel();
    await assertion;
    service.beforeResponse = null;
    service.headers = {'subscription-userinfo': 'upload=10;download=20'};
    await service.refreshSubscription(sub.id);
    release.complete();
    await Future<void>.delayed(Duration.zero);
    expect(service.subscriptions.single.usage!.used, 30);
    expect(service.retainedFetchedProfileNameCount, 0);
    expect(service.subscriptions.single.name, 'Feed');
  });

  test('delete queued behind refresh removes its metadata and nodes durably',
      () async {
    final sub = await seed();
    final entered = Completer<void>();
    final release = Completer<void>();
    service.beforeResponse = () {
      entered.complete();
      return release.future;
    };
    final refresh = service.refreshSubscription(sub.id);
    await entered.future;
    final deletion = service.removeSubscription(sub.id);
    release.complete();
    await refresh;
    await deletion;
    expect(service.subscriptions, isEmpty);
    expect(service.allNodes, isEmpty);
    final restored = _Service();
    await restored.init(dir.path);
    expect(restored.subscriptions, isEmpty);
    expect(restored.allNodes, isEmpty);
    restored.dispose();
  });
}
