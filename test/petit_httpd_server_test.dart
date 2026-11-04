@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:petit_httpd/petit_httpd.dart';
import 'package:test/test.dart';

/// Integration tests: a real [PetitHTTPD] on an ephemeral loopback port,
/// serving a temporary directory.
void main() {
  late Directory tempDir;
  late Directory docRoot;
  late HttpClient client;

  final secret = 'TOP-SECRET-${DateTime.now().microsecondsSinceEpoch}';
  final largeText = List.filled(200, 'Hello petit_httpd! ').join();

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('petit_httpd_test_');
    docRoot = Directory(p.join(tempDir.path, 'www'))..createSync();

    File(p.join(docRoot.path, 'hello.txt')).writeAsStringSync('Hello World!');
    File(p.join(docRoot.path, 'index.html'))
        .writeAsStringSync('<html>root index</html>');
    File(p.join(docRoot.path, 'large.txt')).writeAsStringSync(largeText);
    File(p.join(docRoot.path, 'a b.txt')).writeAsStringSync('with space');

    var sub = Directory(p.join(docRoot.path, 'sub'))..createSync();
    File(p.join(sub.path, 'index.html')).writeAsStringSync('sub index');
    Directory(p.join(docRoot.path, 'empty-dir')).createSync();

    // A file outside the document root:
    File(p.join(tempDir.path, 'secret.txt')).writeAsStringSync(secret);

    if (!Platform.isWindows) {
      Link(p.join(docRoot.path, 'link-to-secret.txt'))
          .createSync(p.join(tempDir.path, 'secret.txt'));
    }

    client = HttpClient()..autoUncompress = false;
  });

  tearDown(() {
    client.close(force: true);
    tempDir.deleteSync(recursive: true);
  });

  Future<PetitHTTPD> startServer({
    bool setCORSHeaders = true,
    bool setHeaderCacheControl = true,
    String? headerCacheControl,
  }) async {
    var petitHTTPD = PetitHTTPD(
      docRoot,
      port: 0,
      bindingAddress: '127.0.0.1',
      setCORSHeaders: setCORSHeaders,
      setHeaderCacheControl: setHeaderCacheControl,
      headerCacheControl: headerCacheControl,
    );
    addTearDown(() => petitHTTPD.stop(force: true));

    expect(petitHTTPD.isStarted, isFalse);
    expect(petitHTTPD.boundPort, isNull);

    expect(await petitHTTPD.start(), isTrue);

    expect(petitHTTPD.isStarted, isTrue);
    expect(petitHTTPD.boundPort, greaterThan(0));
    expect(petitHTTPD.boundSecurePort, isNull);

    return petitHTTPD;
  }

  Future<_Response> get(
    PetitHTTPD httpd,
    String path, {
    Map<String, String> headers = const {},
    String method = 'GET',
  }) async {
    var request = await client.open(
      method,
      '127.0.0.1',
      httpd.boundPort!,
      path,
    );
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    var response = await request.close();
    var body = await response.fold<List<int>>([], (a, b) => a..addAll(b));
    return _Response(response, body);
  }

  group('PetitHTTPD server', () {
    test('serves a file', () async {
      var httpd = await startServer();

      var r = await get(httpd, '/hello.txt');
      expect(r.status, equals(200));
      expect(r.bodyAsString, equals('Hello World!'));
      expect(r.header('content-type'), startsWith('text/plain'));
      expect(r.header('server'), equals('petit_httpd/${PetitHTTPD.VERSION}'));
      expect(
        r.header('cache-control'),
        equals(
          'private, must-revalidate, max-age=1, stale-while-revalidate=60',
        ),
      );
    });

    test('HEAD', () async {
      var httpd = await startServer();

      var r = await get(httpd, '/hello.txt', method: 'HEAD');
      expect(r.status, equals(200));
      expect(r.body, isEmpty);
    });

    test('serves a file with an encoded name', () async {
      var httpd = await startServer();

      var r = await get(httpd, '/a%20b.txt');
      expect(r.status, equals(200));
      expect(r.bodyAsString, equals('with space'));
    });

    test('default document', () async {
      var httpd = await startServer();

      var r = await get(httpd, '/');
      expect(r.status, equals(200));
      expect(r.bodyAsString, equals('<html>root index</html>'));
      expect(r.header('content-type'), startsWith('text/html'));

      r = await get(httpd, '/sub/');
      expect(r.status, equals(200));
      expect(r.bodyAsString, equals('sub index'));
    });

    test('directory without trailing slash redirects', () async {
      var httpd = await startServer();

      var r = await get(httpd, '/sub');
      expect(r.status, equals(301));
      expect(r.header('location'), endsWith('/sub/'));
    });

    test('directory without index is not listed', () async {
      var httpd = await startServer();

      var r = await get(httpd, '/empty-dir/');
      expect(r.status, equals(404));
    });

    test('404', () async {
      var httpd = await startServer();

      var r = await get(httpd, '/not-found.txt');
      expect(r.status, equals(404));
      expect(r.header('server'), equals('petit_httpd/${PetitHTTPD.VERSION}'));
      // Not a successful response: no Cache-Control nor CORS headers.
      expect(r.header('cache-control'), isNull);
      expect(r.header('access-control-allow-origin'), isNull);
    });

    test('conditional request (304)', () async {
      var httpd = await startServer();

      var r = await get(httpd, '/hello.txt');
      var lastModified = r.header('last-modified');
      expect(lastModified, isNotNull);

      r = await get(
        httpd,
        '/hello.txt',
        headers: {'if-modified-since': lastModified!},
      );
      expect(r.status, equals(304));
      expect(r.body, isEmpty);
    });

    test('gzip', () async {
      var httpd = await startServer();

      var r = await get(
        httpd,
        '/large.txt',
        headers: {'accept-encoding': 'gzip'},
      );
      expect(r.status, equals(200));
      expect(r.header('content-encoding'), equals('gzip'));
      expect(r.body.length, lessThan(largeText.length));
      // Compressed only once:
      expect(utf8.decode(gzip.decode(r.body)), equals(largeText));
    });

    test('no gzip without Accept-Encoding', () async {
      var httpd = await startServer();

      var r = await get(httpd, '/large.txt', headers: {'accept-encoding': ''});
      expect(r.status, equals(200));
      expect(r.header('content-encoding'), isNull);
      expect(r.bodyAsString, equals(largeText));
    });

    test('CORS headers', () async {
      var httpd = await startServer();

      var r = await get(
        httpd,
        '/hello.txt',
        headers: {'origin': 'https://example.com'},
      );
      expect(r.status, equals(200));
      expect(
        r.header('access-control-allow-origin'),
        equals('https://example.com'),
      );
      expect(r.header('access-control-allow-credentials'), equals('true'));
      expect(r.header('access-control-allow-methods'), contains('GET'));
      expect(
        r.header('access-control-allow-headers'),
        isNot(contains('x-ijt')),
      );
      expect(
        r.header('access-control-expose-headers'),
        equals(PetitHTTPD.exposeHeaders),
      );

      r = await get(
        httpd,
        '/hello.txt',
        headers: {'origin': 'http://localhost:8080'},
      );
      expect(
        r.header('access-control-allow-origin'),
        equals('http://localhost:8080'),
      );
      expect(r.header('access-control-allow-headers'), contains('x-ijt'));
    });

    test('CORS disabled', () async {
      var httpd = await startServer(setCORSHeaders: false);

      var r = await get(
        httpd,
        '/hello.txt',
        headers: {'origin': 'https://example.com'},
      );
      expect(r.status, equals(200));
      expect(r.header('access-control-allow-origin'), isNull);
    });

    test('custom Cache-Control', () async {
      var httpd = await startServer(headerCacheControl: ' no-cache ');

      var r = await get(httpd, '/hello.txt');
      expect(r.header('cache-control'), equals('no-cache'));
    });

    test('Cache-Control disabled', () async {
      var httpd = await startServer(setHeaderCacheControl: false);

      var r = await get(httpd, '/hello.txt');
      expect(r.status, equals(200));
      expect(r.header('cache-control'), isNull);
    });

    test('symbolic link to a file outside the document root', () async {
      var httpd = await startServer();

      var r = await get(httpd, '/link-to-secret.txt');
      expect(r.status, equals(404));
      expect(r.bodyAsString, isNot(contains(secret)));
    }, skip: Platform.isWindows ? 'No symbolic links on Windows' : false);

    group('path traversal', () {
      test('control: a raw request inside the root is served', () async {
        var httpd = await startServer();

        var r = await _rawGet(httpd.boundPort!, '/hello.txt');
        expect(r.status, equals(200));
        expect(r.raw, contains('Hello World!'));
      });

      for (var path in [
        '/../secret.txt',
        '/../../secret.txt',
        '/sub/../../secret.txt',
        '/%2e%2e/secret.txt',
        '/%2E%2E/secret.txt',
        '/..%2fsecret.txt',
        '/..%2Fsecret.txt',
        '/sub/..%2f..%2fsecret.txt',
        '/..%5csecret.txt',
        '/.%2e/secret.txt',
        '//../secret.txt',
      ]) {
        test(path, () async {
          var httpd = await startServer();

          var r = await _rawGet(httpd.boundPort!, path);

          expect(r.status, isNot(equals(200)), reason: r.raw);
          expect(r.raw, isNot(contains(secret)));
        });
      }
    });

    test('stop', () async {
      var httpd = await startServer();
      var port = httpd.boundPort!;

      await httpd.stop();
      expect(httpd.isStarted, isFalse);
      expect(httpd.boundPort, isNull);

      await expectLater(
        Socket.connect('127.0.0.1', port),
        throwsA(isA<SocketException>()),
      );

      // Stopping again is a no-op:
      await httpd.stop();

      // Can be started again:
      expect(await httpd.start(), isTrue);
      expect(httpd.isStarted, isTrue);
    });

    test('start twice throws', () async {
      var httpd = await startServer();

      await expectLater(httpd.start(), throwsStateError);
    });
  });
}

class _Response {
  final HttpClientResponse response;
  final List<int> body;

  _Response(this.response, this.body);

  int get status => response.statusCode;

  String? header(String name) => response.headers.value(name);

  String get bodyAsString => utf8.decode(body);
}

class _RawResponse {
  final String raw;

  _RawResponse(this.raw);

  int get status {
    var m = RegExp(r'^HTTP/1\.\d (\d{3})').firstMatch(raw);
    return m != null ? int.parse(m.group(1)!) : -1;
  }
}

/// Sends a raw request, so that the [path] is not normalized by a client.
Future<_RawResponse> _rawGet(int port, String path) async {
  var socket = await Socket.connect('127.0.0.1', port);
  socket.write(
    'GET $path HTTP/1.1\r\n'
    'Host: 127.0.0.1:$port\r\n'
    'Connection: close\r\n'
    '\r\n',
  );
  await socket.flush();
  var bytes = await socket.fold<List<int>>([], (a, b) => a..addAll(b));
  socket.destroy();
  return _RawResponse(latin1.decode(bytes));
}
