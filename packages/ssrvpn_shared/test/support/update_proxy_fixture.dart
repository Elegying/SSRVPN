import 'dart:async';
import 'dart:io';

/// Real CONNECT/TLS transport shared by update service and desktop UI tests.
/// All sockets are pinned to this fixture; only its private trust context is
/// extended, so no system proxy, global certificate store or public host changes.
class UpdateProxyFixture extends HttpOverrides {
  UpdateProxyFixture._(this.directory, this.context);

  final Directory directory;
  final SecurityContext context;
  late final HttpServer _origin;
  late final HttpServer _firstProxy;
  late final HttpServer _secondProxy;
  final _sockets = <Socket>[];
  final ports = <int>[];
  final hosts = <String?>[];
  int? environmentPort;
  int environmentLookups = 0;
  Completer<void>? tunnelClosed;
  late void Function(HttpRequest) respond;

  int get firstProxyPort => _firstProxy.port;
  int get secondProxyPort => _secondProxy.port;

  static Future<UpdateProxyFixture> create() async {
    final directory =
        await Directory.systemTemp.createTemp('ssrvpn-update-tls-');
    final cert = '${directory.path}/cert.pem';
    final key = '${directory.path}/key.pem';
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      key,
      '-out',
      cert,
      '-days',
      '1',
      '-subj',
      '/CN=api.github.com',
      '-addext',
      'subjectAltName=DNS:api.github.com,DNS:github.com,DNS:release-assets.githubusercontent.com',
      '-addext',
      'basicConstraints=critical,CA:TRUE',
      '-addext',
      'keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign',
      '-addext',
      'extendedKeyUsage=serverAuth',
    ]);
    if (result.exitCode != 0) {
      await directory.delete(recursive: true);
      throw StateError('Could not generate the temporary update TLS fixture');
    }
    final serverContext = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey(key);
    final fixture = UpdateProxyFixture._(
      directory,
      SecurityContext(withTrustedRoots: true)..setTrustedCertificates(cert),
    );
    fixture._origin = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4, 0, serverContext);
    fixture._origin.listen((request) {
      fixture.hosts.add(request.headers.value(HttpHeaders.hostHeader));
      fixture.respond(request);
    }, onError: (_) {}); // A rejected hostname intentionally fails TLS.
    fixture._firstProxy = await fixture._proxy();
    fixture._secondProxy = await fixture._proxy();
    return fixture;
  }

  Future<HttpServer> _proxy() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.method != 'CONNECT') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }
      final downstream =
          await request.response.detachSocket(writeHeaders: false);
      final upstream =
          await Socket.connect(InternetAddress.loopbackIPv4, _origin.port);
      _sockets.addAll([downstream, upstream]);
      final closed = tunnelClosed;
      downstream.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      await downstream.flush();
      unawaited(downstream.cast<List<int>>().pipe(upstream).whenComplete(() {
        if (closed != null && !closed.isCompleted) closed.complete();
      }).catchError((_) {}));
      unawaited(upstream.cast<List<int>>().pipe(downstream).catchError((_) {}));
    });
    return server;
  }

  Future<void> dispose() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await _origin.close(force: true);
    await _firstProxy.close(force: true);
    await _secondProxy.close(force: true);
    await directory.delete(recursive: true);
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    environmentLookups++;
    return environmentPort == null
        ? 'DIRECT'
        : 'PROXY 127.0.0.1:$environmentPort';
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context ?? this.context);
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (proxyHost != '127.0.0.1' ||
          !{firstProxyPort, secondProxyPort}.contains(proxyPort)) {
        throw const SocketException(
            'Test update attempted to bypass the loopback proxy');
      }
      ports.add(proxyPort!);
      return Socket.startConnect(InternetAddress.loopbackIPv4, proxyPort);
    };
    return client;
  }
}
