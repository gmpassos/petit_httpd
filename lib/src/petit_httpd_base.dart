import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_gzip/shelf_gzip.dart';
import 'package:shelf_letsencrypt/shelf_letsencrypt.dart';
import 'package:shelf_static/shelf_static.dart';

/// A Simple HTTP Daemon.
class PetitHTTPD {
  // ignore: constant_identifier_names
  static const String VERSION = '1.0.5';

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

  /// If [true] and a [SecureServer] is being started
  ///
  /// - See [isLetsEncryptEnabled].
  final bool redirectToHTTPS;

  /// If `true` allows Let's Encrypt.
  final bool allowLetsEncrypt;

  /// The domains to use with Let's Encrypt.
  final Map<String, String>? domains;

  /// The Let's Encrypt [Directory]
  final Directory? letsEncryptDirectory;

  PetitHTTPD(this.documentRoot,
      {this.port = 80,
      this.securePort = 443,
      this.bindingAddress = 'localhost',
      this.setHeaderCacheControl = true,
      this.headerCacheControl,
      this.setCORSHeaders = true,
      this.redirectToHTTPS = true,
      this.allowLetsEncrypt = true,
      this.domains,
      this.letsEncryptDirectory});

  /// Returns `true` if Let's Encrypt is enabled and all prerequisites are accomplished.
  bool get isLetsEncryptEnabled =>
      allowLetsEncrypt &&
      letsEncryptDirectory != null &&
      domains != null &&
      domains!.isNotEmpty;

  /// Starts the daemon.
  Future<bool> start() async {
    if (isLetsEncryptEnabled) {
      return _startLetsEncrypt();
    } else {
      return _startNormal();
    }
  }

  Future<bool> _startNormal() async {
    var handler = _createShelfHandler();

    var server = await shelf_io.serve(handler, bindingAddress, port);

    _configureServer(server);

    return true;
  }

  void _configureServer(HttpServer server) {
    // Enable built-in [HttpServer] gzip:
    server.autoCompress = true;
  }

  Handler _createShelfHandler({bool withSecureServer = false}) {
    var pipeline = const Pipeline().addMiddleware(logRequests());

    if (withSecureServer && redirectToHTTPS) {
      pipeline = pipeline.addMiddleware(_redirectToHttpsMiddleware);
    }

    pipeline = pipeline
        .addMiddleware(gzipMiddleware)
        .addMiddleware(_headersMiddleware);

    var handler = pipeline.addHandler(
        createStaticHandler(documentRoot.path, defaultDocument: 'index.html'));

    return handler;
  }

  Handler _redirectToHttpsMiddleware(Handler innerHandler) {
    return (request) {
      var requestedUri = request.requestedUri;

      if (requestedUri.scheme == 'http') {
        final domains = this.domains;
        if (domains != null && domains.containsKey(requestedUri.host)) {
          var secureUri = requestedUri.replace(scheme: 'https');
          return Response.seeOther(secureUri);
        }
      }

      return innerHandler(request);
    };
  }

  Handler _headersMiddleware(Handler innerHandler) {
    return (request) {
      return Future.sync(() => innerHandler(request))
          .then((response) => _configureHeaders(request, response));
    };
  }

  Response _configureHeaders(Request request, Response response,
      {Map<String, String>? headers}) {
    headers ??= <String, String>{};

    headers[HttpHeaders.serverHeader] = 'petit_httpd/$VERSION';

    var statusCode = response.statusCode;
    if (statusCode < 200 || statusCode > 299) {
      return response.change(headers: headers);
    }

    if (setHeaderCacheControl) {
      var headerCacheControl = this.headerCacheControl?.trim();

      var cacheControl = headerCacheControl != null &&
              headerCacheControl.isNotEmpty
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

  static Map<String, String> setHeadersCORS(Request request, Response response,
      {Map<String, String>? headers}) {
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
    return connectionInfo?.remoteAddress.address;
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

    final LetsEncrypt letsEncrypt =
        LetsEncrypt(certificatesHandler, production: true);

    var handler = _createShelfHandler(withSecureServer: true);

    final domains = this.domains;

    var domain = domains!.keys.first;
    var domainEmail = domains[domain] ?? 'contact@$domain';

    var servers = await letsEncrypt.startSecureServer(
      handler,
      {domain: domainEmail},
      port: port,
      securePort: securePort,
      bindingAddress: bindingAddress,
    );

    var server = servers[0]; // HTTP Server.
    var serverSecure = servers[1]; // HTTPS Server.

    _configureServer(server);
    _configureServer(serverSecure);

    return true;
  }

  @override
  String toString() {
    var letsEncryptInfo = isLetsEncryptEnabled
        ? ', redirectToHTTPS: $redirectToHTTPS, domains: $domains, letsEncryptDirectory: $letsEncryptDirectory'
        : ', letsEncrypt: disabled';
    return 'PetitHTTPD{ documentRoot: $documentRoot, port: $port, securePort: $securePort, bindingAddress: $bindingAddress$letsEncryptInfo }';
  }
}
