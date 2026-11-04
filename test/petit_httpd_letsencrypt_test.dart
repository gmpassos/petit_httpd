@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:path/path.dart' as p;
import 'package:petit_httpd/petit_httpd.dart';
import 'package:test/test.dart';

/// Domains under the reserved `.test` TLD: never resolved through DNS, all
/// connections are routed to the loopback by [_LoopbackHttpOverrides].
const _domain1 = 'petit-httpd.test';
const _domain2 = 'www.petit-httpd.test';

/// Integration tests of the Let's Encrypt mode without network access:
///
/// - A self-signed certificate per domain is pre-installed in the Let's
///   Encrypt directory, so no certificate is requested from the ACME API.
/// - Every [HttpClient] (including the one `shelf_letsencrypt` uses to check
///   the installed certificate) connects to `127.0.0.1` and trusts only the
///   self-signed certificates.
void main() {
  late Directory tempDir;
  late Directory docRoot;
  late Directory letsEncryptDir;
  late SecurityContext trustedContext;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('petit_httpd_le_');
    docRoot = Directory(p.join(tempDir.path, 'www'))..createSync();
    File(p.join(docRoot.path, 'hello.txt')).writeAsStringSync('Hello TLS!');

    letsEncryptDir = Directory(p.join(tempDir.path, 'letsencrypt'))
      ..createSync();

    trustedContext = SecurityContext(withTrustedRoots: false);
    HttpOverrides.global = _LoopbackHttpOverrides(trustedContext);
  });

  tearDown(() {
    HttpOverrides.global = null;
    tempDir.deleteSync(recursive: true);
  });

  /// Generates a self-signed certificate for [domain], stores it in the
  /// Let's Encrypt directory and trusts it.
  void installCertificate(String domain) {
    var keyPair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    var privateKey = keyPair.privateKey as RSAPrivateKey;
    var publicKey = keyPair.publicKey as RSAPublicKey;

    var csr = X509Utils.generateRsaCsrPem(
      {'CN': domain},
      privateKey,
      publicKey,
      san: [domain],
    );
    var certificate = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      30,
      sans: [domain],
      // Required by macOS for a TLS server certificate:
      extKeyUsage: [ExtendedKeyUsage.SERVER_AUTH],
    );

    var dir = Directory(p.join(letsEncryptDir.path, domain))..createSync();
    File(p.join(dir.path, 'fullchain.pem')).writeAsStringSync(certificate);
    File(p.join(dir.path, 'privkey.pem'))
        .writeAsStringSync(CryptoUtils.encodeRSAPrivateKeyToPem(privateKey));

    trustedContext.setTrustedCertificatesBytes(utf8.encode(certificate));
  }

  Future<PetitHTTPD> startServer(
    List<String> domains, {
    bool redirectToHTTPS = true,
  }) async {
    for (var d in domains) {
      installCertificate(d);
    }

    // `shelf_letsencrypt` checks the certificate at
    // `https://<domain>:<securePort>/`, so the ports can't be `0`:
    var port = await _freePort();
    var securePort = await _freePort(exclude: port);

    var httpd = PetitHTTPD(
      docRoot,
      port: port,
      securePort: securePort,
      bindingAddress: '127.0.0.1',
      redirectToHTTPS: redirectToHTTPS,
      domains: {for (var d in domains) d: ''},
      letsEncryptDirectory: letsEncryptDir,
    );
    addTearDown(() => httpd.stop(force: true));

    expect(httpd.isLetsEncryptEnabled, isTrue);
    expect(await httpd.start(), isTrue);

    expect(httpd.isStarted, isTrue);
    expect(httpd.boundPort, equals(port));
    expect(httpd.boundSecurePort, equals(securePort));

    return httpd;
  }

  group("PetitHTTPD (Let's Encrypt)", () {
    test('serves HTTPS with the installed certificate', () async {
      var httpd = await startServer([_domain1]);

      var r = await _fetch(
        Uri.parse('https://$_domain1:${httpd.securePort}/hello.txt'),
        headers: {'accept-encoding': ''},
      );
      expect(r.status, equals(200));
      expect(r.body, equals('Hello TLS!'));
      expect(r.header('server'), equals('petit_httpd/${PetitHTTPD.VERSION}'));
      expect(r.header('cache-control'), contains('must-revalidate'));
      expect(r.certificate?.subject, contains(_domain1));
    });

    test('redirects HTTP to HTTPS (303), preserving path and query', () async {
      var httpd = await startServer([_domain1]);

      var r = await _fetch(
        Uri.parse('http://$_domain1:${httpd.port}/hello.txt?a=1&b=%20'),
      );
      // Current behaviour: `303 See Other` (not `301`/`308`).
      expect(r.status, equals(303));
      var location = r.header('location')!;
      expect(
        location,
        equals('https://$_domain1:${httpd.securePort}/hello.txt?a=1&b=%20'),
      );

      // The redirect target is served:
      r = await _fetch(Uri.parse(location));
      expect(r.status, equals(200));
      expect(r.body, equals('Hello TLS!'));
    });

    test('no redirect for a host that is not a domain', () async {
      var httpd = await startServer([_domain1]);

      var r = await _fetch(
        Uri.parse('http://127.0.0.1:${httpd.port}/hello.txt'),
      );
      expect(r.status, equals(200));
      expect(r.body, equals('Hello TLS!'));
    });

    test('no redirect when `redirectToHTTPS` is disabled', () async {
      var httpd = await startServer([_domain1], redirectToHTTPS: false);

      var r = await _fetch(
        Uri.parse('http://$_domain1:${httpd.port}/hello.txt'),
      );
      expect(r.status, equals(200));
      expect(r.body, equals('Hello TLS!'));
    });

    test('serves all the domains, each with its certificate', () async {
      var httpd = await startServer([_domain1, _domain2]);

      for (var d in [_domain1, _domain2]) {
        var r = await _fetch(
          Uri.parse('https://$d:${httpd.securePort}/hello.txt'),
        );
        expect(r.status, equals(200), reason: d);
        expect(r.body, equals('Hello TLS!'), reason: d);
        // The `CN` is the domain itself (not only a SAN match):
        expect(r.certificate?.subject, endsWith('CN=$d'), reason: d);

        r = await _fetch(Uri.parse('http://$d:${httpd.port}/hello.txt'));
        expect(r.status, equals(303), reason: d);
        expect(
          r.header('location'),
          equals('https://$d:${httpd.securePort}/hello.txt'),
        );
      }
    });

    test('stop closes the HTTP and HTTPS servers; restart', () async {
      var httpd = await startServer([_domain1]);
      var port = httpd.port;
      var securePort = httpd.securePort;

      await httpd.stop();
      expect(httpd.isStarted, isFalse);
      expect(httpd.boundPort, isNull);
      expect(httpd.boundSecurePort, isNull);

      for (var p in [port, securePort]) {
        await expectLater(
          Socket.connect(InternetAddress.loopbackIPv4, p),
          throwsA(isA<SocketException>()),
          reason: 'port $p',
        );
      }

      expect(await httpd.start(), isTrue);
      expect(httpd.boundSecurePort, equals(securePort));

      var r = await _fetch(
        Uri.parse('https://$_domain1:$securePort/hello.txt'),
      );
      expect(r.status, equals(200));
    });

    test('start fails without a certificate and releases the ports', () async {
      // No certificate installed: a certificate is requested from the
      // Let's Encrypt API, which is unreachable (see `_LoopbackHttpOverrides`).
      var port = await _freePort();
      var securePort = await _freePort(exclude: port);

      var httpd = PetitHTTPD(
        docRoot,
        port: port,
        securePort: securePort,
        bindingAddress: '127.0.0.1',
        domains: {_domain1: 'admin@$_domain1'},
        letsEncryptDirectory: letsEncryptDir,
      );
      addTearDown(() => httpd.stop(force: true));

      await expectLater(httpd.start(), throwsA(anything));
      expect(httpd.isStarted, isFalse);
      expect(httpd.boundSecurePort, isNull);

      // The HTTP port bound for the ACME challenge was released:
      var server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await server.close();
    });

    test('toString', () async {
      var httpd = await startServer([_domain1]);
      var s = httpd.toString();
      expect(s, contains('domains: {$_domain1: }'));
      expect(s, contains('letsEncryptDirectory: '));
      expect(s, contains('redirectToHTTPS: true'));
    });
  });
}

/// Returns a free TCP port on the loopback (other than [exclude]).
Future<int> _freePort({int? exclude}) async {
  while (true) {
    var socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var port = socket.port;
    await socket.close();
    if (port != exclude) return port;
  }
}

/// Routes every [HttpClient] connection to `127.0.0.1`, keeping the
/// requested host for TLS (SNI and certificate verification), and trusts only
/// the certificates in [context].
///
/// Any other host (such as the Let's Encrypt API) is refused, so a test can
/// never reach the network, even if a certificate request is attempted.
class _LoopbackHttpOverrides extends HttpOverrides {
  final SecurityContext context;

  _LoopbackHttpOverrides(this.context);

  static bool _isAllowedHost(String host) =>
      host == '127.0.0.1' || host == _domain1 || host == _domain2;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(this.context)
        ..findProxy = ((_) => 'DIRECT')
        ..connectionFactory = (uri, proxyHost, proxyPort) async {
          if (!_isAllowedHost(uri.host)) {
            throw SocketException('Network access refused in tests: $uri');
          }
          var socket = Socket.connect(InternetAddress.loopbackIPv4, uri.port)
              .then<Socket>(
                (s) => uri.scheme == 'https'
                    ? SecureSocket.secure(
                        s,
                        host: uri.host,
                        context: this.context,
                      )
                    : s,
              );
          return ConnectionTask.fromSocket(socket, () {});
        };
}

class _Response {
  final int status;
  final HttpHeaders headers;
  final String body;
  final X509Certificate? certificate;

  _Response(this.status, this.headers, this.body, this.certificate);

  String? header(String name) => headers.value(name);
}

Future<_Response> _fetch(
  Uri url, {
  Map<String, String> headers = const {},
}) async {
  var client = HttpClient();
  try {
    var request = await client.getUrl(url);
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    var response = await request.close();
    var body = await response.transform(utf8.decoder).join();
    return _Response(
      response.statusCode,
      response.headers,
      body,
      response.certificate,
    );
  } finally {
    client.close(force: true);
  }
}
