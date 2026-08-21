import 'dart:convert';

import 'package:ssrvpn_shared/services/http1_response_decoder.dart';
import 'package:test/test.dart';

void main() {
  test('constructor reports each response limit contract accurately', () {
    expect(
      () => Http1ResponseDecoder(maxBodyBytes: 0),
      returnsNormally,
    );
    expect(
      () => Http1ResponseDecoder(maxBodyBytes: -1),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          contains('maxBodyBytes must be non-negative'),
        ),
      ),
    );
    expect(
      () => Http1ResponseDecoder(maxBodyBytes: 0, maxHeaderBytes: 0),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          contains('maxHeaderBytes must be positive'),
        ),
      ),
    );
  });

  test('content-length keep-alive completes across every byte boundary', () {
    final decoder = Http1ResponseDecoder(maxBodyBytes: 16);
    _addOneByteAtATime(
      decoder,
      'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello',
    );

    expect(decoder.isComplete, isTrue);
    expect(utf8.decode(decoder.finish().bodyBytes), 'hello');
  });

  test('bounds oversized content-length parsing before integer conversion', () {
    final oversizedLength = List.filled(4096, '9').join();

    expect(
      () => Http1ResponseDecoder(maxBodyBytes: 16).add(
        ascii.encode(
          'HTTP/1.1 200 OK\r\nContent-Length: $oversizedLength\r\n\r\n',
        ),
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('16 bytes'),
        ),
      ),
    );
  });

  test('accepts leading zeroes without weakening the body limit', () {
    final decoder = Http1ResponseDecoder(maxBodyBytes: 5)
      ..add(ascii.encode(
        'HTTP/1.1 200 OK\r\nContent-Length: 00000000000000000005\r\n\r\n'
        'hello',
      ));

    expect(utf8.decode(decoder.finish().bodyBytes), 'hello');
  });

  test('skips fragmented informational responses before the final response',
      () {
    final decoder = Http1ResponseDecoder(maxBodyBytes: 16);
    _addOneByteAtATime(
      decoder,
      'HTTP/1.1 103 Early Hints\r\nLink: </app.css>; rel=preload\r\n\r\n'
      'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello',
    );

    final response = decoder.finish();
    expect(response.statusCode, 200);
    expect(utf8.decode(response.bodyBytes), 'hello');
  });

  test('finish rejects a response stream containing only informational headers',
      () {
    final decoder = Http1ResponseDecoder(maxBodyBytes: 16)
      ..add(ascii.encode('HTTP/1.1 103 Early Hints\r\n\r\n'));

    expect(decoder.finish, throwsA(isA<FormatException>()));
  });

  test('rejects an unsupported switching-protocols response', () {
    final decoder = Http1ResponseDecoder(maxBodyBytes: 16);

    expect(
      () => decoder.add(
        ascii.encode('HTTP/1.1 101 Switching Protocols\r\n\r\n'),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  for (final bodylessStatus in const [
    (code: 204, reason: 'No Content', header: ''),
    (code: 304, reason: 'Not Modified', header: 'Content-Length: 5\r\n'),
  ]) {
    test('${bodylessStatus.code} completes at headers without a body', () {
      final decoder = Http1ResponseDecoder(maxBodyBytes: 16)
        ..add(ascii.encode(
          'HTTP/1.1 ${bodylessStatus.code} ${bodylessStatus.reason}\r\n'
          '${bodylessStatus.header}\r\n',
        ));

      expect(decoder.isComplete, isTrue);
      expect(decoder.finish().bodyBytes, isEmpty);
    });

    test('${bodylessStatus.code} rejects bytes after its header block', () {
      final decoder = Http1ResponseDecoder(maxBodyBytes: 16);

      expect(
        () => decoder.add(ascii.encode(
          'HTTP/1.1 ${bodylessStatus.code} ${bodylessStatus.reason}\r\n'
          '${bodylessStatus.header}\r\nx',
        )),
        throwsA(isA<FormatException>()),
      );
    });
  }

  test('304 accepts an oversized numeric representation length without a body',
      () {
    final representationLength = List.filled(4096, '9').join();
    final decoder = Http1ResponseDecoder(maxBodyBytes: 16)
      ..add(ascii.encode(
        'HTTP/1.1 304 Not Modified\r\n'
        'Content-Length: $representationLength\r\n\r\n',
      ));

    expect(decoder.isComplete, isTrue);
    expect(decoder.finish().bodyBytes, isEmpty);
  });

  test('205 follows explicit zero-length framing', () {
    final contentLengthDecoder = Http1ResponseDecoder(maxBodyBytes: 16)
      ..add(ascii.encode(
        'HTTP/1.1 205 Reset Content\r\nContent-Length: 0\r\n\r\n',
      ));
    final chunkedDecoder = Http1ResponseDecoder(maxBodyBytes: 16)
      ..add(ascii.encode(
        'HTTP/1.1 205 Reset Content\r\nTransfer-Encoding: chunked\r\n\r\n'
        '0\r\n\r\n',
      ));

    expect(contentLengthDecoder.isComplete, isTrue);
    expect(contentLengthDecoder.finish().bodyBytes, isEmpty);
    expect(chunkedDecoder.isComplete, isTrue);
    expect(chunkedDecoder.finish().bodyBytes, isEmpty);
  });

  test('205 without explicit framing remains close-delimited', () {
    final decoder = Http1ResponseDecoder(maxBodyBytes: 16)
      ..add(ascii.encode('HTTP/1.1 205 Reset Content\r\n\r\n'));

    expect(decoder.isComplete, isFalse);
    expect(decoder.finish().bodyBytes, isEmpty);
  });

  test('chunk extensions and trailers complete across every byte boundary', () {
    final decoder = Http1ResponseDecoder(maxBodyBytes: 16);
    _addOneByteAtATime(
      decoder,
      'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
      '5;name=value\r\nhello\r\n0\r\nX-Trace: ok\r\n\r\n',
    );

    expect(decoder.isComplete, isTrue);
    expect(utf8.decode(decoder.finish().bodyBytes), 'hello');
  });

  test('rejects trailing bytes after chunked completion in the same add', () {
    final decoder = Http1ResponseDecoder(maxBodyBytes: 16);

    expect(
      () => decoder.add(ascii.encode(
        'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
        '0\r\n\r\nextra',
      )),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects trailing bytes after chunked completion in a later add', () {
    final decoder = Http1ResponseDecoder(maxBodyBytes: 16)
      ..add(ascii.encode(
        'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
        '0\r\n\r\n',
      ));

    expect(decoder.isComplete, isTrue);
    expect(
      () => decoder.add(ascii.encode('extra')),
      throwsA(isA<FormatException>()),
    );
  });

  test('finish rejects a truncated content-length body', () {
    final decoder = Http1ResponseDecoder(maxBodyBytes: 16)
      ..add(ascii.encode('HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel'));

    expect(decoder.finish, throwsA(isA<Exception>()));
  });

  test('finish rejects an incomplete chunked body', () {
    final decoder = Http1ResponseDecoder(maxBodyBytes: 16)
      ..add(ascii.encode(
        'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
        '5\r\nhello\r\n',
      ));

    expect(decoder.finish, throwsA(isA<Exception>()));
  });

  test('bounds oversized chunk-size parsing before integer conversion', () {
    final oversizedSize = List.filled(4096, 'F').join();

    expect(
      () => Http1ResponseDecoder(maxBodyBytes: 16).add(ascii.encode(
        'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
        '$oversizedSize\r\n',
      )),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('16 bytes'),
        ),
      ),
    );
  });

  for (final chunkSizeCase in const [
    (name: 'negative', token: '-1', body: '\r\n'),
    (name: 'positive-signed', token: '+1', body: 'x\r\n'),
  ]) {
    test('rejects ${chunkSizeCase.name} chunk-size token', () {
      final decoder = Http1ResponseDecoder(maxBodyBytes: 16);

      expect(
        () => decoder.add(ascii.encode(
          'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
          '${chunkSizeCase.token}\r\n${chunkSizeCase.body}0\r\n\r\n',
        )),
        throwsA(isA<FormatException>()),
      );
    });
  }

  test('rejects a valid chunk-size beyond the configured body limit', () {
    final decoder = Http1ResponseDecoder(maxBodyBytes: 16);

    expect(
      () => decoder.add(ascii.encode(
        'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
        'FFFFFFFFFFFFFFFF\r\n',
      )),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('16 bytes'),
        ),
      ),
    );
  });

  for (final invalidExtension in const [
    ';',
    ';=value',
    ';name=',
    ';bad name=value',
    ';name="unterminated',
  ]) {
    test('rejects invalid chunk extension: $invalidExtension', () {
      final decoder = Http1ResponseDecoder(maxBodyBytes: 16);

      expect(
        () => decoder.add(ascii.encode(
          'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
          '1$invalidExtension\r\nx\r\n0\r\n\r\n',
        )),
        throwsA(isA<FormatException>()),
      );
    });
  }

  test('accepts token and quoted-string chunk extensions', () {
    final decoder = Http1ResponseDecoder(maxBodyBytes: 16)
      ..add(ascii.encode(
        'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
        '1;first=token; second="quoted value"\r\nx\r\n0\r\n\r\n',
      ));

    expect(utf8.decode(decoder.finish().bodyBytes), 'x');
  });

  for (final invalidTrailer in const [
    'BadTrailer',
    ' : value',
    'Content-Length : 5',
    'Bad(Name): value',
    'Content-Length: 0',
    'Transfer-Encoding: chunked',
  ]) {
    test('rejects invalid or framing trailer: $invalidTrailer', () {
      final decoder = Http1ResponseDecoder(maxBodyBytes: 16);

      expect(
        () => decoder.add(ascii.encode(
          'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
          '0\r\n$invalidTrailer\r\n\r\n',
        )),
        throwsA(isA<FormatException>()),
      );
    });
  }

  for (final invalidTrailerValue in const [
    (name: 'NUL', line: 'X-Test: ok\u0000bad'),
    (name: 'bare CR', line: 'X-Test: ok\rbad'),
    (name: 'bare LF', line: 'X-Test: ok\nbad'),
  ]) {
    test('rejects ${invalidTrailerValue.name} in a trailer value', () {
      final decoder = Http1ResponseDecoder(maxBodyBytes: 16);

      expect(
        () => decoder.add(ascii.encode(
          'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
          '0\r\n${invalidTrailerValue.line}\r\n\r\n',
        )),
        throwsA(isA<FormatException>()),
      );
    });
  }

  test('rejects transfer-encoding and content-length conflict', () {
    final decoder = Http1ResponseDecoder(maxBodyBytes: 16);

    expect(
      () => decoder.add(ascii.encode(
        'HTTP/1.1 200 OK\r\n'
        'Content-Length: 5\r\n'
        'Transfer-Encoding: chunked\r\n\r\n',
      )),
      throwsA(isA<Exception>()),
    );
  });

  test('bodyless status still rejects conflicting framing headers', () {
    final decoder = Http1ResponseDecoder(maxBodyBytes: 16);

    expect(
      () => decoder.add(ascii.encode(
        'HTTP/1.1 304 Not Modified\r\n'
        'Content-Length: 5\r\n'
        'Transfer-Encoding: chunked\r\n\r\n',
      )),
      throwsA(isA<FormatException>()),
    );
  });

  for (final transferEncoding in const [
    '',
    ',',
    'chunked,',
    ',chunked',
    'chunked,,',
  ]) {
    test('rejects empty transfer-encoding member: "$transferEncoding"', () {
      final decoder = Http1ResponseDecoder(maxBodyBytes: 16);

      expect(
        () => decoder.add(ascii.encode(
          'HTTP/1.1 200 OK\r\nTransfer-Encoding: $transferEncoding\r\n\r\n',
        )),
        throwsA(isA<FormatException>()),
      );
    });
  }

  test('never falls back to content-length when transfer-encoding is present',
      () {
    final decoder = Http1ResponseDecoder(maxBodyBytes: 16);

    expect(
      () => decoder.add(ascii.encode(
        'HTTP/1.1 200 OK\r\n'
        'Transfer-Encoding:\r\n'
        'Content-Length: 0\r\n\r\n',
      )),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects invalid content-length and status-line syntax', () {
    expect(
      () => Http1ResponseDecoder(maxBodyBytes: 16).add(
        ascii.encode('HTTP/1.1 200 OK\r\nContent-Length: +5\r\n\r\n'),
      ),
      throwsA(isA<Exception>()),
    );
    expect(
      () => Http1ResponseDecoder(maxBodyBytes: 16).add(
        ascii.encode('HTTP/1.1 20 OK\r\nContent-Length: 0\r\n\r\n'),
      ),
      throwsA(isA<Exception>()),
    );
  });

  for (final fieldLine in const [
    ' : value',
    'Content-Length : 5',
    'Bad(Name): value',
  ]) {
    test('rejects invalid HTTP field-name: $fieldLine', () {
      final decoder = Http1ResponseDecoder(maxBodyBytes: 16);

      expect(
        () => decoder.add(ascii.encode(
          'HTTP/1.1 200 OK\r\n$fieldLine\r\n\r\n',
        )),
        throwsA(isA<FormatException>()),
      );
    });
  }

  for (final invalidHeaderValue in const [
    (name: 'NUL', value: 'ok\u0000bad'),
    (name: 'bare CR', value: 'ok\rbad'),
    (name: 'bare LF', value: 'ok\nbad'),
  ]) {
    test('rejects ${invalidHeaderValue.name} in a header value', () {
      final decoder = Http1ResponseDecoder(maxBodyBytes: 16);

      expect(
        () => decoder.add(ascii.encode(
          'HTTP/1.1 200 OK\r\nX-Test: ${invalidHeaderValue.value}\r\n\r\n',
        )),
        throwsA(isA<FormatException>()),
      );
    });
  }

  test('accepts valid extension HTTP field-name tokens', () {
    final decoder = Http1ResponseDecoder(maxBodyBytes: 16);
    final fieldName = r"X!#$%&'*+.^_`|~Token-9";
    decoder.add(ascii.encode(
      'HTTP/1.1 200 OK\r\n$fieldName: value\r\nContent-Length: 0\r\n\r\n',
    ));

    expect(decoder.finish().headers[fieldName.toLowerCase()], 'value');
  });

  test('accepts valid UTF-8 non-ASCII HTTP field values', () {
    final decoder = Http1ResponseDecoder(maxBodyBytes: 16)
      ..add(utf8.encode(
        'HTTP/1.1 200 OK\r\n'
        'X-Profile-Title: 中文\r\n'
        'Content-Length: 0\r\n\r\n',
      ));

    expect(decoder.finish().headers['x-profile-title'], '中文');
  });

  test('rejects decoded body and wire framing beyond their limits', () {
    Object? bodyLimitError;
    try {
      Http1ResponseDecoder(maxBodyBytes: 4).add(
        ascii.encode('HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n'),
      );
    } catch (error) {
      bodyLimitError = error;
    }
    expect(bodyLimitError, isA<Exception>());
    expect(bodyLimitError.toString(), contains('4 bytes'));
    expect(bodyLimitError.toString(), isNot(contains('20 MB')));

    final decoder = Http1ResponseDecoder(
      maxBodyBytes: 3,
      maxHeaderBytes: 128,
    );
    expect(
      () => decoder.add(ascii.encode(
        'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
        '1;${List.filled(100, 'a').join()}\r\nx\r\n',
      )),
      throwsA(isA<Exception>()),
    );
  });
}

void _addOneByteAtATime(Http1ResponseDecoder decoder, String response) {
  for (final byte in latin1.encode(response)) {
    decoder.add([byte]);
  }
}
