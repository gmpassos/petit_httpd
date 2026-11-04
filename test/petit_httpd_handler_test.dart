@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:petit_httpd/petit_httpd.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Unit tests: the `shelf` handler and helpers, without sockets.
void main() {
  late Directory tempDir;
  late Directory docRoot;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('petit_httpd_unit_');
    docRoot = Directory(p.join(tempDir.path, 'www'))..createSync();
    File(p.join(docRoot.path, 'hello.txt')).writeAsStringSync('Hello World!');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  PetitHTTPD create({
    int port = 80,
    int securePort = 443,
    bool redirectToHTTPS = true,
    Map<String, String>? domains = const {'example.com': 'admin@example.com'},
  }) => PetitHTTPD(
    docRoot,
    port: port,
    securePort: securePort,
    redirectToHTTPS: redirectToHTTPS,
    domains: domains,
    letsEncryptDirectory: Directory(p.join(tempDir.path, 'letsencrypt')),
  );

  group('PetitHTTPD', () {
    test('defaults', () {
      var httpd = PetitHTTPD(docRoot);
      expect(httpd.port, equals(80));
      expect(httpd.securePort, equals(443));
      expect(httpd.bindingAddress, equals('localhost'));
      expect(httpd.setCORSHeaders, isTrue);
      expect(httpd.setHeaderCacheControl, isTrue);
      expect(httpd.redirectToHTTPS, isTrue);
      expect(httpd.serveHiddenFiles, isFalse);
      expect(httpd.isLetsEncryptEnabled, isFalse);
      expect(httpd.isStarted, isFalse);
      expect(httpd.letsEncryptDomains, isEmpty);
      expect(httpd.toString(), contains('letsEncrypt: disabled'));
      expect(httpd.toString(), isNot(contains('serveHiddenFiles')));

      httpd = PetitHTTPD(docRoot, serveHiddenFiles: true);
      expect(httpd.serveHiddenFiles, isTrue);
      expect(httpd.toString(), contains('serveHiddenFiles: true'));
    });

    test('isLetsEncryptEnabled', () {
      expect(create().isLetsEncryptEnabled, isTrue);
      expect(create(domains: {}).isLetsEncryptEnabled, isFalse);
      expect(create(domains: null).isLetsEncryptEnabled, isFalse);
      expect(
        PetitHTTPD(
          docRoot,
          domains: {'example.com': 'a@example.com'},
        ).isLetsEncryptEnabled,
        isFalse,
      );
      expect(
        PetitHTTPD(
          docRoot,
          allowLetsEncrypt: false,
          domains: {'example.com': 'a@example.com'},
          letsEncryptDirectory: tempDir,
        ).isLetsEncryptEnabled,
        isFalse,
      );

      var s = create().toString();
      expect(s, contains('domains: {example.com: admin@example.com}'));
      expect(s, contains('redirectToHTTPS: true'));
    });

    test('letsEncryptDomains', () {
      var httpd = create(
        domains: {'a.example.com': ' admin@example.com ', 'b.example.com': ''},
      );

      var domains = httpd.letsEncryptDomains;
      expect(domains.map((d) => d.name), ['a.example.com', 'b.example.com']);
      expect(domains.map((d) => d.email), [
        'admin@example.com',
        'contact@b.example.com',
      ]);
    });

    test('httpsRedirectUri', () {
      var httpd = create();
      expect(
        httpd.httpsRedirectUri(Uri.parse('http://example.com/a%20b?x=1&y=2')),
        equals(Uri.parse('https://example.com/a%20b?x=1&y=2')),
      );
      expect(
        httpd
            .httpsRedirectUri(Uri.parse('http://example.com:8080/x'))
            .toString(),
        equals('https://example.com/x'),
      );

      httpd = create(port: 8080, securePort: 8443);
      expect(
        httpd
            .httpsRedirectUri(Uri.parse('http://example.com:8080/x/'))
            .toString(),
        equals('https://example.com:8443/x/'),
      );
    });
  });

  group('isHiddenPath', () {
    test('allowedHiddenDirectories', () {
      expect(PetitHTTPD.allowedHiddenDirectories, equals(['.well-known']));
    });

    List<String> segments(String path) => Uri.parse(path).pathSegments;

    test('hidden', () {
      for (var path in [
        '/.env',
        '/.env/',
        '/.git/config',
        '/sub/.secret',
        '/a/b/c/.secret',
        '/.hidden/x.txt',
        '/sub/.hidden/',
        '/..foo',
        '/%2eenv',
        '/%2Egit/config',
        '/sub%2f.secret',
        '/sub%2F.secret',
        '/%5c.env',
        '/sub%5C.secret',
        '/.well-known/.secret',
        '/.well-known/a/.secret',
        '/.well-known%2f.secret',
        '/.well-known%5c.secret',
        '/sub/.well-known/x',
        '/sub%2f.well-known/x',
        '/.WELL-KNOWN/x',
        '/.Well-Known/x',
        '/.well-known-x/y',
        '/.well-knownx',
      ]) {
        expect(PetitHTTPD.isHiddenPath(segments(path)), isTrue, reason: path);
      }

      // An empty segment before it: `.well-known` is not the first one.
      expect(PetitHTTPD.isHiddenPath(['', '.well-known', 'x']), isTrue);

      // Dot segments (`Uri.parse` would remove them):
      for (var s in [
        ['.'],
        ['..'],
        ['sub', '..'],
        ['.well-known', '..', '.env'],
        ['sub/..'],
        [r'sub\..'],
      ]) {
        expect(PetitHTTPD.isHiddenPath(s), isTrue, reason: '$s');
      }
    });

    test('not hidden', () {
      for (var path in [
        '/',
        '/hello.txt',
        '/sub/',
        '/sub/file.min.js',
        '/dir.d/x',
        '/a.',
        '/a..b',
        '/env.',
        '/%252eenv',
        '/a%2fb',
        '/.well-known',
        '/.well-known/',
        '/.well-known/security.txt',
        '/.well-known/acme-challenge/token',
        '/%2ewell-known/security.txt',
      ]) {
        expect(PetitHTTPD.isHiddenPath(segments(path)), isFalse, reason: path);
      }

      expect(PetitHTTPD.isHiddenPath(const []), isFalse);
    });
  });

  group('createHandler', () {
    Future<Response> call(
      Handler handler,
      String url, {
      Map<String, String>? headers,
    }) async => await handler(Request('GET', Uri.parse(url), headers: headers));

    test('redirects HTTP to HTTPS for a known domain', () async {
      var handler = create(
        port: 8080,
        securePort: 8443,
      ).createHandler(withSecureServer: true);

      var r = await call(handler, 'http://example.com:8080/hello.txt?a=1');
      expect(r.statusCode, equals(303));
      expect(
        r.headers['location'],
        equals('https://example.com:8443/hello.txt?a=1'),
      );

      // Case-insensitive domain match:
      handler = create(domains: {'Example.COM': 'admin@example.com'})
          .createHandler(withSecureServer: true);
      r = await call(handler, 'http://EXAMPLE.com/hello.txt');
      expect(r.statusCode, equals(303));
      expect(r.headers['location'], equals('https://example.com/hello.txt'));
    });

    test('no redirect for HTTPS, unknown domains or when disabled', () async {
      var handler = create().createHandler(withSecureServer: true);

      var r = await call(handler, 'https://example.com/hello.txt');
      expect(r.statusCode, equals(200));
      expect(await r.readAsString(), equals('Hello World!'));

      r = await call(handler, 'http://other.com/hello.txt');
      expect(r.statusCode, equals(200));

      handler = create(redirectToHTTPS: false)
          .createHandler(withSecureServer: true);
      r = await call(handler, 'http://example.com/hello.txt');
      expect(r.statusCode, equals(200));

      // Without the secure server there's nothing to redirect to:
      handler = create().createHandler();
      r = await call(handler, 'http://example.com/hello.txt');
      expect(r.statusCode, equals(200));
    });

    test('headers', () async {
      var handler = create().createHandler();

      var r = await call(handler, 'http://example.com/hello.txt');
      expect(r.statusCode, equals(200));
      expect(r.headers['server'], equals('petit_httpd/${PetitHTTPD.VERSION}'));
      expect(r.headers['cache-control'], contains('must-revalidate'));
      // No `Origin` header: derived from the `Host` header, else `*`.
      expect(r.headers['access-control-allow-origin'], equals('*'));

      r = await call(
        handler,
        'http://example.com/hello.txt',
        headers: {'host': 'example.com'},
      );
      expect(
        r.headers['access-control-allow-origin'],
        equals('http://example.com/'),
      );

      r = await call(handler, 'http://example.com/missing.txt');
      expect(r.statusCode, equals(404));
      expect(r.headers['server'], equals('petit_httpd/${PetitHTTPD.VERSION}'));
      expect(r.headers['cache-control'], isNull);
    });

    test('a blank custom Cache-Control uses the default', () async {
      var handler = PetitHTTPD(
        docRoot,
        headerCacheControl: '   ',
      ).createHandler();

      var r = await call(handler, 'http://example.com/hello.txt');
      expect(
        r.headers['cache-control'],
        equals(
          'private, must-revalidate, max-age=1, stale-while-revalidate=60',
        ),
      );
    });

    test('a custom Cache-Control is ignored when disabled', () async {
      var handler = PetitHTTPD(
        docRoot,
        setHeaderCacheControl: false,
        headerCacheControl: 'no-store',
      ).createHandler();

      var r = await call(handler, 'http://example.com/hello.txt');
      expect(r.statusCode, equals(200));
      expect(r.headers['cache-control'], isNull);
    });

    test('the redirect response has no petit_httpd headers', () async {
      var handler = create().createHandler(withSecureServer: true);

      var r = await call(handler, 'http://example.com/hello.txt');
      expect(r.statusCode, equals(303));
      // Current behaviour: the redirect middleware runs before the headers
      // middleware, so not even the `Server` header is set.
      expect(r.headers['server'], isNull);
      expect(r.headers['cache-control'], isNull);
      expect(r.headers['access-control-allow-origin'], isNull);
    });

    test('hidden files: 404 unless serveHiddenFiles', () async {
      File(p.join(docRoot.path, '.env')).writeAsStringSync('KEY=value');
      var wellKnown = Directory(p.join(docRoot.path, '.well-known'))
        ..createSync();
      File(p.join(wellKnown.path, 'security.txt')).writeAsStringSync('sec');

      var handler = PetitHTTPD(docRoot).createHandler();

      var r = await call(handler, 'http://example.com/.env');
      expect(r.statusCode, equals(404));
      expect(await r.readAsString(), equals('Not Found'));
      // The same headers as any 404:
      expect(r.headers['server'], equals('petit_httpd/${PetitHTTPD.VERSION}'));
      expect(r.headers['cache-control'], isNull);

      r = await call(handler, 'http://example.com/%2Eenv');
      expect(r.statusCode, equals(404));

      r = await call(handler, 'http://example.com/.well-known/security.txt');
      expect(r.statusCode, equals(200));
      expect(await r.readAsString(), equals('sec'));

      handler = PetitHTTPD(docRoot, serveHiddenFiles: true).createHandler();

      r = await call(handler, 'http://example.com/.env');
      expect(r.statusCode, equals(200));
      expect(await r.readAsString(), equals('KEY=value'));
    });

    test('hidden files: the HTTPS redirect comes first', () async {
      File(p.join(docRoot.path, '.env')).writeAsStringSync('KEY=value');

      var handler = create().createHandler(withSecureServer: true);

      var r = await call(handler, 'http://example.com/.env');
      expect(r.statusCode, equals(303));
      expect(r.headers['location'], equals('https://example.com/.env'));

      r = await call(handler, 'https://example.com/.env');
      expect(r.statusCode, equals(404));
    });

    test('the `Origin` keeps the request scheme', () async {
      var handler = create().createHandler();

      var r = await call(
        handler,
        'https://example.com/hello.txt',
        headers: {'host': 'example.com'},
      );
      expect(
        r.headers['access-control-allow-origin'],
        equals('https://example.com/'),
      );
    });
  });

  group('CORS helpers', () {
    Request request(Map<String, String> headers, {Object? connectionInfo}) =>
        Request(
          'GET',
          Uri.parse('http://example.com/x'),
          headers: headers,
          context: {'shelf.io.connection_info': ?connectionInfo},
        );

    test('getOrigin', () {
      expect(
        PetitHTTPD.getOrigin(request({'origin': 'https://a.com'})),
        equals('https://a.com'),
      );
      expect(
        PetitHTTPD.getOrigin(request({'host': 'b.com:8080'})),
        equals('http://b.com:8080/'),
      );
      expect(PetitHTTPD.getOrigin(request({})), isNull);
      expect(
        PetitHTTPD.getOrigin(
          request({}, connectionInfo: _ConnectionInfo('10.0.0.1')),
        ),
        equals('http://10.0.0.1/'),
      );
    });

    test('getRemoteAddress', () {
      expect(PetitHTTPD.getRemoteAddress(request({})), isNull);
      expect(
        PetitHTTPD.getRemoteAddress(
          request({}, connectionInfo: _ConnectionInfo('10.0.0.1')),
        ),
        equals('10.0.0.1'),
      );
      // A connection already gone (`shelf` >= 1.4.3 throws a `StateError`):
      expect(
        PetitHTTPD.getRemoteAddress(
          request({}, connectionInfo: _ConnectionInfo(null)),
        ),
        isNull,
      );
    });

    test('setHeadersCORS', () {
      var response = Response.ok('');

      for (var origin in [
        'http://localhost:8080',
        'http://127.0.0.1:8080',
        'http://::1',
      ]) {
        var headers = PetitHTTPD.setHeadersCORS(
          request({'origin': origin}),
          response,
        );
        expect(headers['Access-Control-Allow-Origin'], equals(origin));
        expect(headers['Access-Control-Allow-Headers'], contains('x-ijt'));
      }

      var headers = PetitHTTPD.setHeadersCORS(
        request({'origin': ''}),
        response,
        headers: {'X-Other': '1'},
      );
      expect(headers['Access-Control-Allow-Origin'], equals('*'));
      expect(headers['Access-Control-Allow-Headers'], isNot(contains('x-ijt')));
      expect(headers['X-Other'], equals('1'));
    });
  });

  group("Let's Encrypt", () {
    test('start fails without a valid domain (no network)', () async {
      var httpd = PetitHTTPD(
        docRoot,
        port: 0,
        securePort: 0,
        bindingAddress: '127.0.0.1',
        domains: {'not a valid domain!': ''},
        letsEncryptDirectory: Directory(p.join(tempDir.path, 'letsencrypt')),
      );
      addTearDown(httpd.stop);

      expect(httpd.isLetsEncryptEnabled, isTrue);

      await expectLater(httpd.start(), throwsArgumentError);
      expect(httpd.isStarted, isFalse);
    });
  });
}

class _ConnectionInfo implements HttpConnectionInfo {
  final String? _address;

  _ConnectionInfo(this._address);

  @override
  InternetAddress get remoteAddress {
    var address = _address;
    if (address == null) throw StateError('Connection gone');
    return InternetAddress(address);
  }

  @override
  int get localPort => 80;

  @override
  int get remotePort => 12345;
}
