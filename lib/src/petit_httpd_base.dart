import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_static/shelf_static.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_gzip/shelf_gzip.dart';
import 'package:shelf_letsencrypt/shelf_letsencrypt.dart';

/// A Simple HTTP Daemon.
class PetitHTTPD {
  // ignore: constant_identifier_names
  static const String VERSION = '1.0.0';

  /// The document root [Directory].
  Directory documentRoot;

  /// The port number. Default: `80`.
  int port;

  /// The secure port (HTTPS) number. Default: `443`.
  int securePort;

  /// The server socket binding address: Default: `localhost`.
  String bindingAddress;

  /// If `true` allows Let's Encrypt.
  bool allowLetsEncrypt;

  /// The domains to use with Let's Encrypt.
  Map<String, String>? domains;

  /// The Let's Encrypt [Directory]
  Directory? letsEncryptDirectory;

  PetitHTTPD(this.documentRoot,
      {this.port = 80,
      this.securePort = 443,
      this.bindingAddress = 'localhost',
      this.allowLetsEncrypt = true,
      this.domains,
      this.letsEncryptDirectory});

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

    server.autoCompress = true;

    return true;
  }

  Handler _createShelfHandler() {
    return const Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(gzipMiddleware)
        .addHandler(createStaticHandler(documentRoot.path,
            defaultDocument: 'index.html'));
  }

  Future<bool> _startLetsEncrypt() async {
    final certificatesHandler = CertificatesHandlerIO(letsEncryptDirectory!);

    final LetsEncrypt letsEncrypt =
        LetsEncrypt(certificatesHandler, production: true);

    var handler = _createShelfHandler();

    final domains = this.domains;

    var domain = domains!.keys.first;
    var domainEmail = domains[domain] ?? 'contact@$domain';

    var servers = await letsEncrypt.startSecureServer(
      handler,
      domain,
      domainEmail,
      port: port,
      securePort: securePort,
      bindingAddress: bindingAddress,
    );

    var server = servers[0]; // HTTP Server.
    var serverSecure = servers[1]; // HTTPS Server.

    // Enable gzip:
    server.autoCompress = true;
    serverSecure.autoCompress = true;

    return true;
  }

  @override
  String toString() {
    var letsEncryptInfo = isLetsEncryptEnabled
        ? ', domains: $domains, letsEncryptDirectory: $letsEncryptDirectory'
        : ', letsEncrypt: disabled';
    return 'PetitHTTPD{ documentRoot: $documentRoot, port: $port, securePort: $securePort, bindingAddress: $bindingAddress$letsEncryptInfo }';
  }
}
