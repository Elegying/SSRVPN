import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:meta/meta.dart';

import '../utils/node_country_policy.dart';
import 'public_ip_info_service.dart';

part 'node_country_mmdb.dart';

class NodeCountryResolution {
  const NodeCountryResolution({required this.ip, required this.countryCode});

  final String ip;
  final String countryCode;
}

/// Observes the current proxy's final public exit, including relay routes.
/// Never geolocates a node server or resolves its hostname as an exit hint.
class NodeCountryLookup {
  NodeCountryLookup({
    required int proxyPort,
    @visibleForTesting http.Client? client,
    @visibleForTesting Future<Uint8List> Function()? assetLoader,
    @visibleForTesting String? Function(String ip)? countryReader,
    @visibleForTesting this.requestTimeout = const Duration(seconds: 5),
  })  : _client = client ?? _proxyClient(proxyPort),
        _assetLoader = assetLoader,
        _countryReader = countryReader {
    if (proxyPort < 1 || proxyPort > 65535 || requestTimeout <= Duration.zero) {
      throw ArgumentError('Invalid node country lookup configuration');
    }
  }

  static const maxResponseBytes = 64 * 1024;
  static Future<_MmdbCountryReader>? _bundledReader;
  final http.Client _client;
  final Future<Uint8List> Function()? _assetLoader;
  final String? Function(String ip)? _countryReader;
  final Duration requestTimeout;
  final _activeRequests = <Completer<void>>{};
  final _closedSignal = Completer<void>();
  Future<_MmdbCountryReader>? _reader;
  bool _closed = false;

  static http.Client _proxyClient(int port) => IOClient(HttpClient()
    ..connectionTimeout = const Duration(seconds: 3)
    ..findProxy = (_) => 'PROXY 127.0.0.1:$port');

  Future<NodeCountryResolution?> lookup() async {
    if (_closed) return null;
    try {
      final ip = await _fetchExitIp(PublicIpInfoService.ipv4Endpoint) ??
          await _fetchExitIp(PublicIpInfoService.fallbackEndpoint);
      if (_closed || ip == null) return null;
      final reader = _countryReader ?? (await _loadReader()).countryCodeForIp;
      if (_closed) return null;
      final country = normalizeNodeCountryCode(reader(ip) ?? '');
      if (country != 'UN') {
        return NodeCountryResolution(ip: ip, countryCode: country);
      }
    } catch (_) {
      // Background enrichment is optional; only successful results are cached.
    }
    return null;
  }

  Future<_MmdbCountryReader> _loadReader() {
    final future = _reader ??= _assetLoader == null
        ? (_bundledReader ??= _loadBundledReader())
        : _loadMmdb(_assetLoader);
    return Future.any([
      future,
      _closedSignal.future.then<_MmdbCountryReader>(
        (_) => throw StateError('Node country lookup closed'),
      ),
    ]);
  }

  static Future<_MmdbCountryReader> _loadBundledReader() async {
    try {
      return await _loadMmdb(() async {
        final asset = await rootBundle.load('assets/geoip.metadb.gz');
        return asset.buffer
            .asUint8List(asset.offsetInBytes, asset.lengthInBytes);
      });
    } catch (_) {
      _bundledReader = null;
      rethrow;
    }
  }

  static Future<_MmdbCountryReader> _loadMmdb(
    Future<Uint8List> Function() loader,
  ) async {
    final compressed = await loader().timeout(const Duration(seconds: 10));
    return Isolate.run(() => _decodeCountryDatabase(compressed));
  }

  Future<String?> _fetchExitIp(Uri uri) async {
    if (_closed) return null;
    final abort = Completer<void>();
    _activeRequests.add(abort);
    final aborted = abort.future.then<Never>(
      (_) => throw const _NodeCountryRequestAborted(),
    );
    final timer = Timer(requestTimeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    StreamIterator<List<int>>? chunks;
    try {
      final request =
          http.AbortableRequest('GET', uri, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers['Accept'] = 'application/json'
            ..headers['Cache-Control'] = 'no-cache';
      final responseFuture = Future<http.StreamedResponse>.sync(
        () => _client.send(request),
      );
      late final http.StreamedResponse response;
      try {
        response = await Future.any([responseFuture, aborted]);
      } catch (_) {
        unawaited(responseFuture.then<void>((lateResponse) async {
          try {
            await lateResponse.stream.listen(null).cancel().timeout(
                  const Duration(milliseconds: 50),
                );
          } catch (_) {}
        }, onError: (Object _, StackTrace __) {}));
        rethrow;
      }
      chunks = StreamIterator(response.stream);
      if (response case http.BaseResponseWithUrl(:final url)) {
        if (url != uri) return null;
      }
      if (response.statusCode != HttpStatus.ok ||
          (response.contentLength ?? 0) > maxResponseBytes) {
        return null;
      }
      final body = BytesBuilder(copy: false);
      while (await Future.any([chunks.moveNext(), aborted])) {
        final chunk = chunks.current;
        if (body.length + chunk.length > maxResponseBytes) return null;
        body.add(chunk);
      }
      if (_closed) return null;
      final json = jsonDecode(utf8.decode(body.takeBytes()));
      final ip = json is Map && json['ip'] is String
          ? (json['ip'] as String).trim()
          : '';
      return isPublicNodeCountryAddress(ip) ? ip : null;
    } catch (_) {
      return null;
    } finally {
      timer.cancel();
      if (!abort.isCompleted) abort.complete();
      _activeRequests.remove(abort);
      try {
        await chunks?.cancel().timeout(const Duration(milliseconds: 50));
      } catch (_) {}
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _closedSignal.complete();
    for (final abort in _activeRequests) {
      if (!abort.isCompleted) abort.complete();
    }
    _client.close();
  }
}

class _NodeCountryRequestAborted implements Exception {
  const _NodeCountryRequestAborted();
}

/// Restrict country enrichment to native public unicast addresses. In
/// particular, never persist a Clash fake-IP as a proxy's public exit.
bool isPublicNodeCountryAddress(String value) {
  if (value.contains('%')) return false;
  final ip = InternetAddress.tryParse(value);
  if (ip == null || ip.isLoopback || ip.isLinkLocal || ip.isMulticast) {
    return false;
  }
  final b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    return !(b[0] == 0 ||
        b[0] == 10 ||
        b[0] == 127 ||
        b[0] >= 224 ||
        (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
        (b[0] == 169 && b[1] == 254) ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 &&
            (b[1] == 168 ||
                (b[1] == 0 && (b[2] == 0 || b[2] == 2)) ||
                (b[1] == 88 && b[2] == 99))) ||
        (b[0] == 198 &&
            (b[1] == 18 || b[1] == 19 || (b[1] == 51 && b[2] == 100))) ||
        (b[0] == 203 && b[1] == 0 && b[2] == 113));
  }
  if ((b[0] & 0xe0) != 0x20) return false;
  return !(b[0] == 0x20 &&
          (b[1] == 0x02 ||
              (b[1] == 0x01 &&
                  ((b[2] == 0 && b[3] <= 0x2f) ||
                      (b[2] == 0x0d && b[3] == 0xb8))))) &&
      !(b[0] == 0x3f && b[1] == 0xff && (b[2] & 0xf0) == 0);
}
