@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
    bool serveHiddenFiles = false,
  }) async {
    var petitHTTPD = PetitHTTPD(
      docRoot,
      port: 0,
      bindingAddress: '127.0.0.1',
      setCORSHeaders: setCORSHeaders,
      setHeaderCacheControl: setHeaderCacheControl,
      headerCacheControl: headerCacheControl,
      serveHiddenFiles: serveHiddenFiles,
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

    for (var serveHiddenFiles in [false, true]) {
      group('path traversal (serveHiddenFiles: $serveHiddenFiles)', () {
        test('control: a raw request inside the root is served', () async {
          var httpd = await startServer(serveHiddenFiles: serveHiddenFiles);

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
          '/.well-known/../../secret.txt',
          '/.well-known/..%2f..%2fsecret.txt',
        ]) {
          test(path, () async {
            var httpd = await startServer(serveHiddenFiles: serveHiddenFiles);

            var r = await _rawGet(httpd.boundPort!, path);

            expect(r.status, isNot(equals(200)), reason: r.raw);
            expect(r.raw, isNot(contains(secret)));
          });
        }
      });
    }

    group('range requests', () {
      // `large.txt` is larger than the gzip threshold, but a partial response
      // must not be compressed (`Content-Range` refers to the raw bytes).
      test('a byte range (206)', () async {
        var httpd = await startServer();

        var r = await get(
          httpd,
          '/large.txt',
          headers: {'range': 'bytes=6-15', 'accept-encoding': 'gzip'},
        );
        expect(r.status, equals(206));
        expect(r.bodyAsString, equals(largeText.substring(6, 16)));
        expect(r.header('content-encoding'), isNull);
        expect(
          r.header('content-range'),
          equals('bytes 6-15/${largeText.length}'),
        );
        expect(r.header('accept-ranges'), equals('bytes'));
        // A successful response: the configured headers are set.
        expect(r.header('cache-control'), contains('must-revalidate'));
        expect(r.header('access-control-allow-origin'), isNotNull);
      });

      test('a suffix range', () async {
        var httpd = await startServer();

        var r = await get(httpd, '/hello.txt', headers: {'range': 'bytes=-6'});
        expect(r.status, equals(206));
        expect(r.bodyAsString, equals('World!'));
        expect(r.header('content-range'), equals('bytes 6-11/12'));
      });

      test('an open range', () async {
        var httpd = await startServer();

        var r = await get(httpd, '/hello.txt', headers: {'range': 'bytes=6-'});
        expect(r.status, equals(206));
        expect(r.bodyAsString, equals('World!'));
      });

      test('an unsatisfiable range (416)', () async {
        var httpd = await startServer();

        var r = await get(
          httpd,
          '/hello.txt',
          headers: {'range': 'bytes=100-200'},
        );
        expect(r.status, equals(416));
        expect(r.bodyAsString, isNot(contains('Hello')));
        // Not a successful response:
        expect(r.header('cache-control'), isNull);
      });
    });

    test('HEAD has the same headers as GET, without a body', () async {
      var httpd = await startServer();

      var g = await get(httpd, '/large.txt', headers: {'accept-encoding': ''});
      var h = await get(
        httpd,
        '/large.txt',
        headers: {'accept-encoding': ''},
        method: 'HEAD',
      );

      expect(h.status, equals(200));
      expect(h.body, isEmpty);
      expect(h.header('content-length'), equals('${largeText.length}'));
      for (var name in [
        'content-type',
        'content-length',
        'last-modified',
        'server',
        'cache-control',
        'access-control-allow-origin',
      ]) {
        expect(h.header(name), equals(g.header(name)), reason: name);
      }
    });

    test('a large binary file is served intact', () async {
      var httpd = await startServer();

      // 3 MiB of non-repeating bytes (deterministic):
      var bytes = Uint8List(3 * 1024 * 1024);
      var x = 2463534242;
      for (var i = 0; i < bytes.length; ++i) {
        x ^= (x << 13) & 0xFFFFFFFF;
        x ^= x >> 17;
        x ^= (x << 5) & 0xFFFFFFFF;
        bytes[i] = x & 0xFF;
      }
      File(p.join(docRoot.path, 'data.bin')).writeAsBytesSync(bytes);

      var r = await get(httpd, '/data.bin', headers: {'accept-encoding': ''});
      expect(r.status, equals(200));
      expect(r.header('content-type'), equals('application/octet-stream'));
      expect(r.header('content-length'), equals('${bytes.length}'));
      expect(r.body.length, equals(bytes.length));
      expect(r.body, equals(bytes));

      // With gzip negotiated the decoded content is also intact:
      r = await get(httpd, '/data.bin', headers: {'accept-encoding': 'gzip'});
      expect(r.status, equals(200));
      var decoded = r.header('content-encoding') == 'gzip'
          ? gzip.decode(r.body)
          : r.body;
      expect(decoded, equals(bytes));
    });

    test('concurrent requests', () async {
      var httpd = await startServer();

      for (var i = 0; i < 20; ++i) {
        File(p.join(docRoot.path, 'f$i.txt')).writeAsStringSync('file #$i');
      }

      var responses = await Future.wait([
        for (var i = 0; i < 20; ++i) get(httpd, '/f$i.txt'),
        for (var i = 0; i < 10; ++i) get(httpd, '/missing-$i.txt'),
      ]);

      for (var i = 0; i < 20; ++i) {
        expect(responses[i].status, equals(200));
        expect(responses[i].bodyAsString, equals('file #$i'));
      }
      for (var r in responses.skip(20)) {
        expect(r.status, equals(404));
      }
    });

    test('MIME types', () async {
      var httpd = await startServer();

      var types = {
        'page.html': 'text/html',
        'style.css': 'text/css',
        'app.js': 'text/javascript',
        'data.json': 'application/json',
        'image.png': 'image/png',
        'image.svg': 'image/svg+xml',
        'doc.pdf': 'application/pdf',
        // Current behaviour: an unknown type gets no `Content-Type` from
        // `shelf_static`, so `dart:io` sends its default `text/plain`.
        'no-extension': 'text/plain',
        'file.unknown-ext': 'text/plain',
      };

      for (var name in types.keys) {
        File(p.join(docRoot.path, name)).writeAsStringSync('x');
      }

      for (var e in types.entries) {
        var r = await get(httpd, '/${e.key}');
        expect(r.status, equals(200), reason: e.key);
        expect(
          r.header('content-type')?.split(';').first,
          equals(e.value),
          reason: e.key,
        );
      }
    });

    test('URL-encoded file names', () async {
      var httpd = await startServer();

      File(p.join(docRoot.path, 'café.txt')).writeAsStringSync('unicode');
      File(p.join(docRoot.path, '100%.txt')).writeAsStringSync('percent');
      File(p.join(docRoot.path, 'a+b.txt')).writeAsStringSync('plus');
      File(p.join(docRoot.path, 'a%20b.txt')).writeAsStringSync('literal');

      Future<String> body(String path) async {
        var r = await get(httpd, path);
        expect(r.status, equals(200), reason: path);
        return r.bodyAsString;
      }

      expect(await body('/caf%C3%A9.txt'), equals('unicode'));
      expect(await body('/100%25.txt'), equals('percent'));
      // `+` is not a space in a path:
      expect(await body('/a+b.txt'), equals('plus'));
      expect(await body('/a%2Bb.txt'), equals('plus'));
      // `%2520` is a literal `%20` in the file name:
      expect(await body('/a%2520b.txt'), equals('literal'));
      expect(await body('/a%20b.txt'), equals('with space'));
    });

    test('index files in nested directories', () async {
      var httpd = await startServer();

      var deep = Directory(p.join(docRoot.path, 'sub', 'deep', 'er'))
        ..createSync(recursive: true);
      File(p.join(deep.path, 'index.html')).writeAsStringSync('deeper index');
      File(p.join(deep.path, 'page.txt')).writeAsStringSync('deeper page');

      var r = await get(httpd, '/sub/deep/er/');
      expect(r.status, equals(200));
      expect(r.bodyAsString, equals('deeper index'));
      expect(r.header('content-type'), startsWith('text/html'));

      r = await get(httpd, '/sub/deep/er/index.html');
      expect(r.status, equals(200));
      expect(r.bodyAsString, equals('deeper index'));

      r = await get(httpd, '/sub/deep/er/page.txt');
      expect(r.bodyAsString, equals('deeper page'));

      // An intermediate directory without an index:
      r = await get(httpd, '/sub/deep/');
      expect(r.status, equals(404));

      r = await get(httpd, '/sub/deep/er');
      expect(r.status, equals(301));
      expect(r.header('location'), endsWith('/sub/deep/er/'));
    });

    test('a modified file is served with its new content', () async {
      var httpd = await startServer();

      var file = File(p.join(docRoot.path, 'hello.txt'));

      var r = await get(httpd, '/hello.txt');
      expect(r.bodyAsString, equals('Hello World!'));

      file.writeAsStringSync('Changed!');
      file.setLastModifiedSync(DateTime.now().add(const Duration(hours: 1)));

      r = await get(httpd, '/hello.txt');
      expect(r.bodyAsString, equals('Changed!'));

      file.deleteSync();
      r = await get(httpd, '/hello.txt');
      expect(r.status, equals(404));
    });

    test('any method is answered as a GET, read-only', () async {
      // Current behaviour (pinned, see the CHANGELOG notes): `shelf_static`
      // doesn't check the method, so no `405`; nothing is ever written.
      var httpd = await startServer();

      for (var method in ['POST', 'PUT', 'DELETE', 'PATCH']) {
        var r = await get(httpd, '/hello.txt', method: method);
        expect(r.status, equals(200), reason: method);
        expect(r.bodyAsString, equals('Hello World!'), reason: method);
      }

      // The file is untouched:
      expect(
        File(p.join(docRoot.path, 'hello.txt')).readAsStringSync(),
        equals('Hello World!'),
      );

      var r = await get(httpd, '/new-file.txt', method: 'PUT');
      expect(r.status, equals(404));
      expect(File(p.join(docRoot.path, 'new-file.txt')).existsSync(), isFalse);
    });

    test('CORS preflight (OPTIONS) gets the CORS headers', () async {
      var httpd = await startServer();

      var r = await get(
        httpd,
        '/hello.txt',
        method: 'OPTIONS',
        headers: {
          'origin': 'https://example.com',
          'access-control-request-method': 'GET',
        },
      );
      expect(r.status, equals(200));
      expect(
        r.header('access-control-allow-origin'),
        equals('https://example.com'),
      );
      expect(r.header('access-control-allow-methods'), contains('OPTIONS'));
    });

    test('CORS: any Origin is echoed, with credentials', () async {
      // Current behaviour (pinned, see the CHANGELOG notes): the `Origin` is
      // not checked against an allow-list.
      var httpd = await startServer();

      for (var origin in ['https://evil.example', 'null']) {
        var r = await get(httpd, '/hello.txt', headers: {'origin': origin});
        expect(r.header('access-control-allow-origin'), equals(origin));
        expect(r.header('access-control-allow-credentials'), equals('true'));
      }
    });

    group('hidden files', () {
      const hiddenMark = 'HIDDEN-CONTENT';

      void writeFile(String path, String content) {
        var file = File(p.joinAll([docRoot.path, ...path.split('/')]));
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(content);
      }

      setUp(() {
        writeFile('.env', 'KEY=$hiddenMark');
        writeFile('.git/config', '[core] $hiddenMark');
        writeFile('.git/index.html', 'git index $hiddenMark');
        writeFile('sub/.secret', 'sub secret $hiddenMark');
        writeFile('.hidden/x.txt', 'hidden x $hiddenMark');
        writeFile('.hidden/index.html', 'hidden index $hiddenMark');
        writeFile('.well-known/security.txt', 'Contact: mailto:a@b.com');
        writeFile('.well-known/acme-challenge/token-1', 'token-1.thumbprint');
        writeFile('.well-known/.secret', 'well-known secret $hiddenMark');
        writeFile('sub/.well-known/x.txt', 'nested well-known $hiddenMark');
        // A visible name with dots (not hidden):
        writeFile('dir.d/file.min.js', 'visible');
        // A visible name with a literal `%2e` (served as is, never decoded
        // twice):
        writeFile('%2eenv', 'literal percent');
      });

      // Hidden paths, sent raw (not normalized by a client):
      const hiddenPaths = [
        '/.env',
        '/.env/',
        '/.env?x=1',
        '/.env?.well-known/',
        '/.git/config',
        '/.git/',
        '/.git',
        '/sub/.secret',
        '/sub/.secret/',
        '/.hidden/x.txt',
        '/.hidden/',
        '/.hidden',
        '/.hidden/index.html',
        '//.env',
        '/./.env',
        '/sub/../.env',
        '/sub/./.secret',
        // Encoded dots, any case:
        '/%2eenv',
        '/%2Eenv',
        '/%2e%65nv',
        '/%2Egit/config',
        '/%2egit/config',
        '/%2e%67%69%74/%63onfig',
        '/sub/%2esecret',
        '/sub/%2Esecret',
        '/%2Ehidden/',
        // Encoded separators:
        '/sub%2f.secret',
        '/sub%2F%2esecret',
        '/%5c.env',
        '/%5C.env',
        '/sub%5c.secret',
        '/x/..%2f.env',
        '/x/..%5c.env',
        // Only `/.well-known/` is allowed, case-sensitive:
        '/.well-known/.secret',
        '/.well-known/%2esecret',
        '/.well-known%2f.secret',
        '/sub/.well-known/x.txt',
        '/.WELL-KNOWN/security.txt',
        '/.Well-Known/security.txt',
        '/%2EWELL-KNOWN/security.txt',
        '/x/../.well-known/.secret',
        '//.well-known/.secret',
        // Control characters:
        '/%00.env',
        '/.env%00',
        '/sub/%00/.secret',
      ];

      for (var path in hiddenPaths) {
        test('404: $path', () async {
          var httpd = await startServer();

          var r = await _rawGet(httpd.boundPort!, path);
          expect(r.status, equals(404), reason: r.raw);
          expect(r.raw, isNot(contains(hiddenMark)));
          // Not a successful response: no Cache-Control nor CORS headers.
          expect(r.raw.toLowerCase(), isNot(contains('cache-control')));
        });
      }

      test('404 for any method, HEAD and range requests', () async {
        var httpd = await startServer();

        for (var method in ['GET', 'HEAD', 'POST', 'PUT', 'OPTIONS']) {
          for (var path in ['/.env', '/.git/config', '/%2eenv']) {
            var r = await _rawGet(httpd.boundPort!, path, method: method);
            expect(r.status, equals(404), reason: '$method $path');
            expect(r.raw, isNot(contains(hiddenMark)));
          }
        }

        for (var range in ['bytes=0-3', 'bytes=-6', 'bytes=2-']) {
          var r = await get(httpd, '/.env', headers: {'range': range});
          expect(r.status, equals(404), reason: range);
          expect(r.header('content-range'), isNull);
          expect(r.bodyAsString, isNot(contains(hiddenMark)));
        }

        var r = await get(
          httpd,
          '/.git/config',
          headers: {'if-modified-since': HttpDate.format(DateTime(2000))},
        );
        expect(r.status, equals(404));
      });

      test('the same 404 as a missing file (existence not revealed)', () async {
        var httpd = await startServer();

        var missing = await get(httpd, '/.missing');
        var existing = await get(httpd, '/.env');

        expect(existing.status, equals(missing.status));
        expect(existing.bodyAsString, equals(missing.bodyAsString));
        expect(
          existing.header('content-length'),
          equals(missing.header('content-length')),
        );
      });

      test('visible files are still served', () async {
        var httpd = await startServer();

        var r = await get(httpd, '/hello.txt');
        expect(r.bodyAsString, equals('Hello World!'));

        r = await get(httpd, '/dir.d/file.min.js');
        expect(r.status, equals(200));
        expect(r.bodyAsString, equals('visible'));

        // `%252e` is a literal `%2e` (a visible name), not a `.`:
        var raw = await _rawGet(httpd.boundPort!, '/%252eenv');
        expect(raw.status, equals(200), reason: raw.raw);
        expect(raw.raw, contains('literal percent'));
        expect(raw.raw, isNot(contains(hiddenMark)));

        r = await get(httpd, '/');
        expect(r.bodyAsString, equals('<html>root index</html>'));
      });

      test('/.well-known/ is served', () async {
        var httpd = await startServer();

        var r = await get(httpd, '/.well-known/security.txt');
        expect(r.status, equals(200));
        expect(r.bodyAsString, equals('Contact: mailto:a@b.com'));
        // A successful response, with the configured headers:
        expect(r.header('cache-control'), isNotNull);

        r = await get(httpd, '/.well-known/acme-challenge/token-1');
        expect(r.status, equals(200));
        expect(r.bodyAsString, equals('token-1.thumbprint'));

        r = await get(httpd, '/.well-known/security.txt', method: 'HEAD');
        expect(r.status, equals(200));
        expect(r.body, isEmpty);

        r = await get(
          httpd,
          '/.well-known/security.txt',
          headers: {'range': 'bytes=0-6'},
        );
        expect(r.status, equals(206));
        expect(r.bodyAsString, equals('Contact'));

        // Encoded, it's the same path:
        var raw = await _rawGet(
          httpd.boundPort!,
          '/%2ewell-known/security.txt',
        );
        expect(raw.status, equals(200), reason: raw.raw);
        expect(raw.raw, contains('Contact: mailto:a@b.com'));

        // The same segments (the empty one is dropped):
        raw = await _rawGet(httpd.boundPort!, '//.well-known/security.txt');
        expect(raw.status, equals(200), reason: raw.raw);

        // A directory without an index is not listed:
        r = await get(httpd, '/.well-known/');
        expect(r.status, equals(404));
        r = await get(httpd, '/.well-known/acme-challenge/');
        expect(r.status, equals(404));

        // With an index (visible name) it's served:
        File(p.join(docRoot.path, '.well-known', 'index.html'))
            .writeAsStringSync('well-known index');
        r = await get(httpd, '/.well-known');
        expect(r.status, equals(301));
        expect(r.header('location'), endsWith('/.well-known/'));
        r = await get(httpd, '/.well-known/');
        expect(r.status, equals(200));
        expect(r.bodyAsString, equals('well-known index'));
      });

      test('serveHiddenFiles: true serves them (previous behaviour)', () async {
        var httpd = await startServer(serveHiddenFiles: true);

        var r = await get(httpd, '/.env');
        expect(r.status, equals(200));
        expect(r.bodyAsString, equals('KEY=$hiddenMark'));

        r = await get(httpd, '/.git/config');
        expect(r.status, equals(200));
        expect(r.bodyAsString, equals('[core] $hiddenMark'));

        r = await get(httpd, '/sub/.secret');
        expect(r.bodyAsString, equals('sub secret $hiddenMark'));

        r = await get(httpd, '/.hidden/');
        expect(r.status, equals(200));
        expect(r.bodyAsString, equals('hidden index $hiddenMark'));

        r = await get(httpd, '/.hidden');
        expect(r.status, equals(301));

        r = await get(httpd, '/.well-known/.secret');
        expect(r.bodyAsString, equals('well-known secret $hiddenMark'));

        var raw = await _rawGet(httpd.boundPort!, '/%2Egit/config');
        expect(raw.status, equals(200), reason: raw.raw);
        expect(raw.raw, contains('[core] $hiddenMark'));

        r = await get(httpd, '/.env', method: 'HEAD');
        expect(r.status, equals(200));
        expect(r.body, isEmpty);

        r = await get(httpd, '/.env', headers: {'range': 'bytes=0-2'});
        expect(r.status, equals(206));
        expect(r.bodyAsString, equals('KEY'));

        r = await get(httpd, '/.well-known/security.txt');
        expect(r.status, equals(200));

        // Still a 404 for a missing hidden file:
        r = await get(httpd, '/.missing');
        expect(r.status, equals(404));
      });

      group('symbolic links', () {
        void link(String path, String target) =>
            Link(p.joinAll([docRoot.path, ...path.split('/')]))
                .createSync(p.joinAll([docRoot.path, ...target.split('/')]));

        setUp(() {
          link('env-link.txt', '.env');
          link('git-link', '.git');
          link('hidden-link', '.hidden');
          link('sub/secret-link', 'sub/.secret');
          link('security-link.txt', '.well-known/security.txt');
          link('hello-link.txt', 'hello.txt');
          link('sub-link', 'sub');
          // A visible directory whose index is a link to a hidden file:
          Directory(p.join(docRoot.path, 'tricky')).createSync();
          link('tricky/index.html', '.hidden/index.html');
          link('tricky/page.txt', '.hidden/x.txt');
        });

        for (var path in [
          '/env-link.txt',
          '/git-link/config',
          '/git-link/',
          '/git-link',
          '/hidden-link/x.txt',
          '/hidden-link/',
          '/sub/secret-link',
          '/tricky/',
          '/tricky',
          '/tricky/index.html',
          '/tricky/page.txt',
        ]) {
          test('to a hidden entry, 404: $path', () async {
            var httpd = await startServer();

            var r = await _rawGet(httpd.boundPort!, path);
            expect(r.status, equals(404), reason: r.raw);
            expect(r.raw, isNot(contains(hiddenMark)));
          });
        }

        test('to visible and /.well-known/ entries are served', () async {
          var httpd = await startServer();

          var r = await get(httpd, '/hello-link.txt');
          expect(r.status, equals(200));
          expect(r.bodyAsString, equals('Hello World!'));

          r = await get(httpd, '/sub-link/');
          expect(r.status, equals(200));
          expect(r.bodyAsString, equals('sub index'));

          r = await get(httpd, '/security-link.txt');
          expect(r.status, equals(200));
          expect(r.bodyAsString, equals('Contact: mailto:a@b.com'));
        });

        test('serveHiddenFiles: true serves them', () async {
          var httpd = await startServer(serveHiddenFiles: true);

          var r = await get(httpd, '/env-link.txt');
          expect(r.status, equals(200));
          expect(r.bodyAsString, equals('KEY=$hiddenMark'));

          r = await get(httpd, '/tricky/');
          expect(r.status, equals(200));
          expect(r.bodyAsString, equals('hidden index $hiddenMark'));
        });
      }, skip: Platform.isWindows ? 'No symbolic links on Windows' : false);

      test('a document root inside a hidden directory is served', () async {
        var root = Directory(p.join(tempDir.path, '.site', 'www'))
          ..createSync(recursive: true);
        File(p.join(root.path, 'index.html')).writeAsStringSync('site index');
        File(p.join(root.path, 'page.txt')).writeAsStringSync('site page');
        File(p.join(root.path, '.env')).writeAsStringSync('KEY=$hiddenMark');

        var httpd = PetitHTTPD(root, port: 0, bindingAddress: '127.0.0.1');
        addTearDown(() => httpd.stop(force: true));
        await httpd.start();

        var r = await get(httpd, '/');
        expect(r.status, equals(200));
        expect(r.bodyAsString, equals('site index'));

        r = await get(httpd, '/page.txt');
        expect(r.bodyAsString, equals('site page'));

        r = await get(httpd, '/.env');
        expect(r.status, equals(404));
      });
    });

    test('stop and start cycles', () async {
      var httpd = await startServer();

      for (var i = 0; i < 3; ++i) {
        var r = await get(httpd, '/hello.txt');
        expect(r.status, equals(200), reason: 'cycle $i');
        expect(r.bodyAsString, equals('Hello World!'));

        // Close the idle keep-alive connection to the server being stopped:
        client.close(force: true);
        client = HttpClient()..autoUncompress = false;

        await httpd.stop();
        expect(httpd.isStarted, isFalse);

        expect(await httpd.start(), isTrue);
        expect(httpd.isStarted, isTrue);
        expect(httpd.boundPort, greaterThan(0));
      }
    });

    for (var force in [false, true]) {
      test('stop(force: $force) closes idle keep-alive connections', () async {
        var httpd = await startServer();
        var port = httpd.boundPort!;

        var socket = await Socket.connect('127.0.0.1', port);
        addTearDown(socket.destroy);

        var received = StringBuffer();
        var responded = Completer<void>();
        var closed = Completer<void>();
        socket.listen(
          (data) {
            received.write(latin1.decode(data));
            if (!responded.isCompleted &&
                received.toString().contains('Hello World!')) {
              responded.complete();
            }
          },
          onDone: closed.complete,
          onError: (_) => closed.complete(),
        );

        // HTTP/1.1: the connection is kept alive after the response.
        socket.write(
          'GET /hello.txt HTTP/1.1\r\n'
          'Host: 127.0.0.1:$port\r\n'
          '\r\n',
        );
        await responded.future;
        expect(closed.isCompleted, isFalse);

        await httpd.stop(force: force);
        expect(httpd.isStarted, isFalse);

        // The server closed the connection:
        await closed.future;
      });
    }

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
Future<_RawResponse> _rawGet(
  int port,
  String path, {
  String method = 'GET',
}) async {
  var socket = await Socket.connect('127.0.0.1', port);
  socket.write(
    '$method $path HTTP/1.1\r\n'
    'Host: 127.0.0.1:$port\r\n'
    'Connection: close\r\n'
    '\r\n',
  );
  await socket.flush();
  var bytes = await socket.fold<List<int>>([], (a, b) => a..addAll(b));
  socket.destroy();
  return _RawResponse(latin1.decode(bytes));
}
