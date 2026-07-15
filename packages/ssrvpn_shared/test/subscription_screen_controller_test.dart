import 'dart:async';
import 'dart:io';

import 'package:ssrvpn_shared/controllers/subscription_screen_controller.dart';
import 'package:ssrvpn_shared/models/proxy_group.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/models/subscription.dart';
import 'package:ssrvpn_shared/services/subscription_parser.dart';
import 'package:ssrvpn_shared/services/subscription_service_base.dart';
import 'package:test/test.dart';

void main() {
  ProxyNode node(
    String name, {
    String type = 'ss',
    String server = '127.0.0.1',
    int port = 1000,
  }) =>
      ProxyNode(
        name: name,
        type: type,
        server: server,
        port: port,
      );

  group('SubscriptionScreenController', () {
    test('rejects empty, duplicate, and invalid subscription input', () async {
      final duplicate = Subscription(
        id: 'existing',
        name: 'Existing',
        url: 'https://example.com/sub',
      );
      final controller = SubscriptionScreenController(
        subscriptionService: _FakeSubscriptionService(
          subscriptions: [duplicate],
        ),
      );

      expect(
        (await controller.addSubscription('')).status,
        SubscriptionAddStatus.emptyInput,
      );
      expect(
        (await controller.addSubscription('https://example.com/sub')).status,
        SubscriptionAddStatus.duplicate,
      );
      expect(
        (await controller.addSubscription('not a url')).status,
        SubscriptionAddStatus.invalidUrl,
      );
    });

    test('adds http subscriptions and reports fetched node count', () async {
      final service = _FakeSubscriptionService(
        nodes: [node('A'), node('B')],
        refreshResult: 'proxies: []',
      );
      final controller = SubscriptionScreenController(
        subscriptionService: service,
      );

      final result = await controller.addSubscription('http://example.com/sub');

      expect(result.status, SubscriptionAddStatus.subscriptionAdded);
      expect(result.nodeCount, 2);
      expect(result.clearInput, isTrue);
      expect(service.addedUrls, ['http://example.com/sub']);
    });

    test('reports only runnable nodes after subscription refresh', () async {
      final service = _FakeSubscriptionService(
        nodes: [
          node('套餐到期：长期有效'),
          node('Missing Server', server: ''),
          node('Built In', type: 'builtin'),
          node('A'),
        ],
        refreshResult: 'proxies: []',
      );
      final controller = SubscriptionScreenController(
        subscriptionService: service,
      );

      final result =
          await controller.addSubscription('https://example.com/sub');

      expect(result.status, SubscriptionAddStatus.subscriptionAdded);
      expect(result.nodeCount, 1);
    });

    test('imports single node subscriptions through refresh', () async {
      final service = _FakeSubscriptionService(
        nodes: [node('MySS')],
        refreshResult: 'proxies: []',
      );
      final controller = SubscriptionScreenController(
        subscriptionService: service,
      );

      final result = await controller.addSubscription(
        'ss://aes-256-gcm:pass123@1.2.3.4:8388#MySS',
      );

      expect(result.status, SubscriptionAddStatus.singleNodeImported);
      expect(result.nodeCount, 1);
      expect(result.clearInput, isTrue);
    });

    test('refresh result carries network help detail for socket errors',
        () async {
      final controller = SubscriptionScreenController(
        subscriptionService: _FakeSubscriptionService(
          refreshError: const SocketException('offline'),
        ),
      );

      final result = await controller.refreshAll();

      expect(result.success, isFalse);
      expect(result.message, '刷新失败: 网络连接异常');
      expect(result.networkErrorDetail, 'offline');
      expect(result.shouldShowNetworkHelp, isTrue);
    });

    test('refresh reports structured partial success as a warning', () async {
      final controller = SubscriptionScreenController(
        subscriptionService: _FakeSubscriptionService(
          nodes: [node('Cached')],
          refreshOutcome: const SubscriptionBatchRefreshResult(
            status: SubscriptionBatchRefreshStatus.partialSuccess,
            yaml: 'cached yaml',
            successfulSubscriptionNames: ['Primary'],
            failures: [
              SubscriptionRefreshFailure(
                subscriptionName: 'Backup',
                message: 'temporary timeout',
              ),
            ],
          ),
        ),
      );

      final result = await controller.refreshAll();

      expect(result.status, SubscriptionRefreshStatus.partialSuccess);
      expect(result.success, isFalse);
      expect(result.isPartialSuccess, isTrue);
      expect(result.failureDetails, ['Backup: temporary timeout']);
      expect(result.message, contains('已保留上次有效节点'));
      expect(result.message, contains('Backup'));
      expect(result.shouldShowNetworkHelp, isFalse);
    });

    test('delete stops clash when no nodes remain', () async {
      final service = _FakeSubscriptionService(
        subscriptions: [
          Subscription(id: 'sub-1', name: 'A', url: 'https://example.com'),
        ],
        nodes: [node('A')],
      );
      final controller = SubscriptionScreenController(
        subscriptionService: service,
      );
      var stopped = false;

      final result = await controller.deleteSubscription(
        'sub-1',
        clashRunning: true,
        stopClash: () async => stopped = true,
      );

      expect(result.removed, isTrue);
      expect(result.stoppedClash, isTrue);
      expect(stopped, isTrue);
    });

    test('delete reports stop failure without losing removed state', () async {
      final service = _FakeSubscriptionService(
        subscriptions: [
          Subscription(id: 'sub-1', name: 'A', url: 'https://example.com'),
        ],
        nodes: [node('A')],
      );
      final controller = SubscriptionScreenController(
        subscriptionService: service,
      );

      final result = await controller.deleteSubscription(
        'sub-1',
        clashRunning: true,
        stopClash: () async => throw Exception('stop failed'),
      );

      expect(result.removed, isTrue);
      expect(result.stoppedClash, isFalse);
      expect(result.error.toString(), contains('stop failed'));
    });

    test('delete stops clash when only non-runnable nodes remain', () async {
      final service = _FakeSubscriptionService(
        subscriptions: [
          Subscription(id: 'sub-1', name: 'A', url: 'https://a.example.com'),
          Subscription(id: 'sub-2', name: 'B', url: 'https://b.example.com'),
        ],
        nodes: [node('套餐到期：长期有效')],
      );
      final controller = SubscriptionScreenController(
        subscriptionService: service,
      );
      var stopped = false;

      final result = await controller.deleteSubscription(
        'sub-1',
        clashRunning: true,
        stopClash: () async => stopped = true,
      );

      expect(result.removed, isTrue);
      expect(result.stoppedClash, isTrue);
      expect(stopped, isTrue);
    });

    test('desktop-style delete can continue after refresh failure', () async {
      final service = _FakeSubscriptionService(
        subscriptions: [
          Subscription(id: 'sub-1', name: 'A', url: 'https://example.com'),
        ],
        removeError: Exception('refresh failed'),
      );
      final controller = SubscriptionScreenController(
        subscriptionService: service,
      );

      final result = await controller.deleteSubscription(
        'sub-1',
        clashRunning: false,
        stopClash: null,
        continueAfterRefreshFailure: true,
      );

      expect(result.removed, isTrue);
      expect(result.remainingRefreshFailed, isTrue);
      expect(result.error, isA<Exception>());
    });
  });
}

class _FakeSubscriptionService implements SubscriptionScreenServicePort {
  _FakeSubscriptionService({
    List<Subscription>? subscriptions,
    List<ProxyNode>? nodes,
    List<ProxyGroup>? groups,
    this.refreshResult,
    this.refreshOutcome,
    this.refreshError,
    this.removeError,
  })  : _subscriptions = subscriptions ?? <Subscription>[],
        _nodes = nodes ?? <ProxyNode>[],
        _groups = groups ?? <ProxyGroup>[];

  final List<Subscription> _subscriptions;
  List<ProxyNode> _nodes;
  final List<ProxyGroup> _groups;
  String? refreshResult;
  SubscriptionBatchRefreshResult? refreshOutcome;
  Object? refreshError;
  Object? removeError;
  final addedUrls = <String>[];

  @override
  List<Subscription> get subscriptions => List.unmodifiable(_subscriptions);

  @override
  List<ProxyNode> get allNodes => List.unmodifiable(_nodes);

  @override
  List<ProxyGroup> get allGroups => List.unmodifiable(_groups);

  @override
  bool isSingleNodeLink(String input) {
    final value = input.trim();
    final uri = Uri.tryParse(value);
    final scheme = uri?.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      final hasEndpointPath = uri!.path.isNotEmpty && uri.path != '/';
      if (hasEndpointPath || uri.hasQuery) return false;
    }
    return SubscriptionParser.proxyFromUri(value) != null;
  }

  @override
  String defaultSubscriptionName(String input) {
    final node = SubscriptionParser.proxyFromUri(input.trim());
    final nodeName = node?['name']?.toString().trim();
    if (nodeName != null && nodeName.isNotEmpty) return nodeName;
    final uri = Uri.tryParse(input.trim());
    final host = uri?.host.trim();
    if (host != null && host.isNotEmpty) return host;
    return '订阅 ${_subscriptions.length + 1}';
  }

  @override
  Future<Subscription> addSubscription(String name, String url) async {
    addedUrls.add(url);
    final sub = Subscription(
      id: 'sub-${_subscriptions.length + 1}',
      name: name,
      url: url,
    );
    _subscriptions.add(sub);
    return sub;
  }

  @override
  Future<void> removeSubscription(String id) async {
    if (removeError != null) throw removeError!;
    _subscriptions.removeWhere((sub) => sub.id == id);
    if (_subscriptions.isEmpty) _nodes = <ProxyNode>[];
  }

  @override
  Future<SubscriptionBatchRefreshResult>
      refreshAllSubscriptionsDetailed() async {
    if (refreshError != null) throw refreshError!;
    return refreshOutcome ??
        SubscriptionBatchRefreshResult(
          status: refreshResult == null
              ? SubscriptionBatchRefreshStatus.empty
              : SubscriptionBatchRefreshStatus.success,
          yaml: refreshResult,
          successfulSubscriptionNames:
              refreshResult == null ? const [] : const ['Test'],
        );
  }
}
