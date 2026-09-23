import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  for (final method in ['PATCH', 'PUT', 'DELETE', 'GET']) {
    for (final bodyStarted in [false, true]) {
      test(
          '$method timeout closes its socket and allows retry (body=$bodyStarted)',
          () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <Socket>[];
        final disconnected = Completer<void>();
        final service = _ControllerService()
          ..initHttpClient()
          ..updateSettings(AppSettings(apiPort: server.port))
          ..setRunning(true);
        addTearDown(service.dispose);
        addTearDown(() async {
          for (final socket in sockets) {
            socket.destroy();
          }
          await server.close();
        });
        var stalled = false;
        var selected = 'Node A';
        server.listen((socket) {
          sockets.add(socket);
          var request = '';
          var responded = false;
          var isStalled = false;
          void closed() {
            if (isStalled && !disconnected.isCompleted) disconnected.complete();
            socket.destroy();
          }

          socket.listen((chunk) {
            request += String.fromCharCodes(chunk);
            if (responded || !request.contains('\r\n\r\n')) return;
            responded = true;
            final line = request.split('\r\n').first;
            if (!stalled &&
                line.startsWith('$method ') &&
                (method != 'GET' || line.contains('/connections'))) {
              stalled = isStalled = true;
              if (bodyStarted) {
                socket.write('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n'
                    '\r\n1\r\n{\r\n');
              }
              return;
            }
            if (line.startsWith('PUT ')) selected = 'Node B';
            final body = '{"now":"$selected","connections":[]}';
            socket.write('HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\n'
                'Connection: close\r\n\r\n$body');
            unawaited(socket.close());
          }, onDone: closed, onError: (Object _) => closed());
        });

        final result = method == 'PATCH'
            ? await service.switchMode('rule')
            : method == 'GET'
                ? await service.switchSelectedProxy('Node B')
                : await service.switchProxy('PROXY', 'Node B');
        expect(stalled, isTrue);
        expect(result, method == 'DELETE' || method == 'GET');
        await disconnected.future.timeout(const Duration(seconds: 1));
        expect(service.isRunning, isTrue);
        expect(await service.switchMode('rule'), isTrue);
      });
    }
  }
}

class _ControllerService extends ClashServiceBase {
  @override
  String get diagnosticConfigPath => '';
  @override
  bool get diagnosticConfigRequired => false;
  @override
  Future<bool> diagnosticCoreAvailable() async => true;
  @override
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks() async => [];
  @override
  Future<AppRepairResult> repairDiagnosticIssue(AppRepairAction action) async =>
      const AppRepairResult(success: false, message: 'test');
  @override
  Future<void> onStopRequired() async => setRunning(false);
}
