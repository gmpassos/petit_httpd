import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_gzip/shelf_gzip.dart';
import 'package:shelf_letsencrypt/shelf_letsencrypt.dart';
import 'package:shelf_static/shelf_static.dart';

/// A Simple HTTP Daemon.
class PetitHTTPD {
  // ignore: constant_identifier_names
  static const String VERSION = '1.1.0';

  /// The document root [Directory].
  final Directory documentRoot;

  /// The port number. Default: `80`.
  final int port;

  /// The secure port (HTTPS) number. Default: `443`.
  final int securePort;

  /// The server socket binding address: Default: `localhost`.
  final String bindingAddress;

  /// If `true` the `Cache-Control` header will be set for successful responses.
  final bool setHeaderCacheControl;

  /// Personalized value for the header `Cache-Control`.
  /// Will be used if [setHeaderCacheControl] is `true`.
  final String? headerCacheControl;

  /// If `true` CORS` headers will be set for successful responses.
  final bool setCORSHeaders;

  /// If `true` and the secure (HTTPS) server is being started, plain HTTP
  /// requests for one of the [domains] are redirected to HTTPS.
  ///
  /// - See [isLetsEncryptEnabled].
  final bool redirectToHTTPS;

  /// If `true` allows Let's Encrypt.
  final bool allowLetsEncrypt;

  /// The domains to use with Let's Encrypt.
  final Map<String, String>? domains;

  /// The Let's Encrypt [Directory]
  final Directory? letsEncryptDirectory;

  PetitHTTPD(
    this.documentRoot, {
    this.port = 80,
    this.securePort = 443,
    this.bindingAddress = 'localhost',
    this.setHeaderCacheControl = true,
    this.headerCacheControl,
    this.setCORSHeaders = true,
    this.redirectToHTTPS = true,
    this.allowLetsEncrypt = true,
    this.domains,
    this.letsEncryptDirectory,
  });

  /// Returns `true` if Let's Encrypt is enabled and all prerequisites are accomplished.
  bool get isLetsEncryptEnabled =>
      allowLetsEncrypt &&
      letsEncryptDirectory != null &&
      domains != null &&
      domains!.isNotEmpty;

  HttpServer? _server;
  HttpServer? _secureServer;

  /// Returns `true` if the daemon was started and not [stop]ped yet.
  bool get isStarted => _server != null;

  /// The actual port of the HTTP server, or `null` if not started.
  ///
  /// Useful when [port] is `0` (an ephemeral port chosen by the OS).
  int? get boundPort => _server?.port;

  /// The actual port of the HTTPS server, or `null` if it's not running.
  int? get boundSecurePort => _secureServer?.port;

  /// Starts the daemon.
  ///
  /// Throws a [StateError] if it's already started.
  Future<bool> start() async {
    if (isStarted) {
      throw StateError('Already started: $this');
    }

    if (isLetsEncryptEnabled) {
      return _startLetsEncrypt();
    } else {
      return _startNormal();
    }
  }

  /// Stops the daemon, closing its servers.
  /// If [force] is `true` active connections are closed immediately.
  Future<void> stop({bool force = false}) async {
    final server = _server;
    final secureServer = _secureServer;
    _server = null;
    _secureServer = null;

    await Future.wait([
      if (server != null) server.close(force: force),
      if (secureServer != null) secureServer.close(force: force),
    ]);
  }

  Future<bool> _startNormal() async {
    var handler = createHandler();

    var server = await shelf_io.serve(handler, bindingAddress, port);

    _configureServer(server);
    _server = server;

    return true;
  }

  void _configureServer(HttpServer server) {
    // Enable built-in [HttpServer] gzip:
    server.autoCompress = true;
  }

  /// Creates the `shelf` [Handler] that serves the [documentRoot].
  ///
  /// - If [withSecureServer] is `true` and [redirectToHTTPS] is enabled,
  ///   plain HTTP requests for one of the [domains] are redirected to HTTPS.
  Handler createHandler({bool withSecureServer = false}) {
    var pipeline = const Pipeline().addMiddleware(logRequests());

    if (withSecureServer && redirectToHTTPS) {
      pipeline = pipeline.addMiddleware(_redirectToHttpsMiddleware);
    }

    pipeline = pipeline
        .addMiddleware(gzipMiddleware)
        .addMiddleware(_headersMiddleware);

    var handler = pipeline.addHandler(
      createStaticHandler(documentRoot.path, defaultDocument: 'index.html'),
    );

    return handler;
  }

  Handler _redirectToHttpsMiddleware(Handler innerHandler) {
    return (request) {
      var requestedUri = request.requestedUri;

      if (requestedUri.scheme == 'http') {
        final domains = this.domains;
        // `Uri.host` is always lower-case, and so are DNS names:
        final host = requestedUri.host;
        if (domains != null &&
            domains.keys.any((d) => d.toLowerCase() == host)) {
          return Response.seeOther(httpsRedirectUri(requestedUri));
        }
      }

      return innerHandler(request);
    };
  }

  /// Returns the HTTPS version of [uri], pointing to [securePort].
  ///
  /// The port of [uri] is the HTTP [port], so it's never kept. The default
  /// HTTPS port (`443`) is omitted from the returned [Uri]; path and query
  /// are preserved as they are (already encoded).
  Uri httpsRedirectUri(Uri uri) =>
      uri.replace(scheme: 'https', port: securePort);

  Handler _headersMiddleware(Handler innerHandler) {
    return (request) {
      return Future.sync(() => innerHandler(request))
          .then((response) => _configureHeaders(request, response));
    };
  }

  Response _configureHeaders(
    Request request,
    Response response, {
    Map<String, String>? headers,
  }) {
    headers ??= <String, String>{};

    headers[HttpHeaders.serverHeader] = 'petit_httpd/$VERSION';

    var statusCode = response.statusCode;
    if (statusCode < 200 || statusCode > 299) {
      return response.change(headers: headers);
    }

    if (setHeaderCacheControl) {
      var headerCacheControl = this.headerCacheControl?.trim();

      var cacheControl =
          headerCacheControl != null && headerCacheControl.isNotEmpty
          ? headerCacheControl
          : 'private, must-revalidate, max-age=1, stale-while-revalidate=60';

      headers[HttpHeaders.cacheControlHeader] = cacheControl;
    }

    if (setCORSHeaders) {
      headers = setHeadersCORS(request, response, headers: headers);
    }

    return response.change(headers: headers);
  }

  static const String headerXAccessToken = "X-Access-Token";
  static const String headerXAccessTokenExpiration =
      "X-Access-Token-Expiration";
  static const String headerXAccessTokenSource = "X-Access-Token-Source";

  static const String headerAccessControlRequestHeaders =
      "Access-Control-Request-Headers";
  static const String headerAccessControlRequestMethod =
      "Access-Control-Request-Method";

  static const String exposeHeaders =
      "Content-Length, Content-Type, Last-Modified, $headerXAccessToken, $headerXAccessTokenExpiration";

  static Map<String, String> setHeadersCORS(
    Request request,
    Response response, {
    Map<String, String>? headers,
  }) {
    headers ??= <String, String>{};

    var origin = getOrigin(request);

    var localhost = false;

    if (origin == null || origin.isEmpty) {
      headers["Access-Control-Allow-Origin"] = "*";
    } else {
      headers["Access-Control-Allow-Origin"] = origin;

      if (origin.contains("://localhost:") ||
          origin.contains("://127.0.0.1:") ||
          origin.contains("://::1")) {
        localhost = true;
      }
    }

    headers["Access-Control-Allow-Methods"] =
        "GET,HEAD,PUT,POST,PATCH,DELETE,OPTIONS";
    headers["Access-Control-Allow-Credentials"] = "true";

    if (localhost) {
      headers["Access-Control-Allow-Headers"] =
          "Content-Type, Access-Control-Allow-Headers, Authorization, x-ijt";
    } else {
      headers["Access-Control-Allow-Headers"] =
          "Content-Type, Access-Control-Allow-Headers, Authorization";
    }

    headers["Access-Control-Expose-Headers"] = exposeHeaders;

    return headers;
  }

  static String? getRemoteAddress(Request request) {
    final connectionInfo =
        request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
    try {
      return connectionInfo?.remoteAddress.address;
    } on StateError {
      // Since `shelf` 1.4.3 the connection info is resolved lazily,
      // and throws a `StateError` if the connection is already gone.
      return null;
    }
  }

  static String? getOrigin(Request request) {
    var origin = request.headers['origin'];
    if (origin != null) return origin;

    var requestedUri = request.requestedUri;

    var host = request.headers['host'];
    if (host != null) {
      origin = "${requestedUri.scheme}://$host/";
      return origin;
    }

    var remoteHost = getRemoteAddress(request) ?? host;
    if (remoteHost == null) return null;

    origin = "${requestedUri.scheme}://$remoteHost/";
    return origin;
  }

  Future<bool> _startLetsEncrypt() async {
    final certificatesHandler = CertificatesHandlerIO(letsEncryptDirectory!);

    final letsEncrypt = LetsEncrypt(
      certificatesHandler,
      port: port,
      securePort: securePort,
      bindingAddress: bindingAddress,
      production: true,
    );

    var handler = createHandler(withSecureServer: true);

    var servers = await letsEncrypt.startServer(handler, letsEncryptDomains);

    _configureServer(servers.http);
    _configureServer(servers.https);

    _server = servers.http;
    _secureServer = servers.https;

    return true;
  }

  /// The [domains] as Let's Encrypt [Domain]s.
  /// A domain without an e-mail uses `contact@<domain>`.
  List<Domain> get letsEncryptDomains => [
    for (var e in (domains ?? const <String, String>{}).entries)
      Domain(
        name: e.key,
        email: e.value.trim().isNotEmpty ? e.value.trim() : 'contact@${e.key}',
      ),
  ];

  @override
  String toString() {
    var letsEncryptInfo = isLetsEncryptEnabled
        ? ', redirectToHTTPS: $redirectToHTTPS, domains: $domains, letsEncryptDirectory: $letsEncryptDirectory'
        : ', letsEncrypt: disabled';
    return 'PetitHTTPD{ documentRoot: $documentRoot, port: $port, securePort: $securePort, bindingAddress: $bindingAddress$letsEncryptInfo }';
  }
}
