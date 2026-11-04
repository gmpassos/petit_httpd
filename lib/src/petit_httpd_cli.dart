import 'dart:io';

import 'package:args_simple/args_simple_io.dart';

import 'petit_httpd_base.dart';

/// The `petit_httpd` CLI usage example.
const String petitHTTPDUsage =
    '  \$> petit_httpd ./www --port 8080 --secure-port 443 --address 0.0.0.0 '
    '--letsencrypt-path /etc/letsencrypt/live --domain domain.com '
    '--email contact@domain.com --cache-control no-cache '
    '-cors -force-https -serve-hidden-files -verbose';

/// Creates a [PetitHTTPD] from the parsed CLI [args].
///
/// Throws a [FormatException] if an option has an invalid value.
PetitHTTPD petitHTTPDFromArgs(ArgsSimple args) {
  var documentRoot = args.argumentAsDirectory(0, Directory('./'))!.absolute;

  var port = _optionAsPort(args, 'port', 80);
  var securePort = _optionAsPort(args, 'secure-port', 443);
  var address = args.optionAsString('address', 'localhost')!;

  var cors = args.flag('cors');

  var letsEncrypt = args.optionAsDirectory(
    'letsencrypt-path',
    Directory('/etc/letsencrypt/live'),
  );

  var domain = args.optionAsString('domain')?.trim();
  if (domain != null && domain.isEmpty) {
    domain = null;
  }

  var domains = <String, String>{};
  if (domain != null) {
    var email = args.optionAsString('email')?.trim();
    domains[domain] = email != null && email.isNotEmpty
        ? email
        : 'contact@$domain';
  }

  var cacheControl = args.optionAsString('cache-control')?.trim();
  if (cacheControl != null && cacheControl.isEmpty) {
    cacheControl = null;
  }

  var forceHttps = args.flag('force-https');

  // `--serve-hidden-files` would be parsed as an option, taking the next
  // argument (possibly the document root) as its value:
  if (args.optionAsString('serve-hidden-files') != null) {
    throw FormatException(
      '`-serve-hidden-files` is a flag (single `-`), not `--serve-hidden-files`',
    );
  }

  var serveHiddenFiles = args.flag('serve-hidden-files');

  return PetitHTTPD(
    documentRoot,
    port: port,
    securePort: securePort,
    bindingAddress: address,
    setCORSHeaders: cors,
    headerCacheControl: cacheControl,
    letsEncryptDirectory: letsEncrypt,
    domains: domains,
    redirectToHTTPS: forceHttps,
    serveHiddenFiles: serveHiddenFiles,
  );
}

int _optionAsPort(ArgsSimple args, String key, int def) {
  var s = args.optionAsString(key)?.trim();
  if (s == null) return def;

  var port = int.tryParse(s);
  if (port == null || port < 0 || port > 65535) {
    throw FormatException('Invalid `--$key`: $s');
  }

  return port;
}

/// Runs the `petit_httpd` CLI with the arguments [argsOrig].
///
/// Returns the exit code if the process should exit, or `null` if the
/// server was started and the process should keep running. If [onStart]
/// is provided it receives the started [PetitHTTPD].
Future<int?> runPetitHTTPD(
  List<String> argsOrig, {
  void Function(Object? o) log = print,
  void Function(PetitHTTPD petitHTTPD)? onStart,
}) async {
  var args = ArgsSimple.parse(argsOrig);

  if (args.flag('version')) {
    log('petit_httpd/${PetitHTTPD.VERSION}');
    return 0;
  }

  log(
    '========================================================================',
  );
  log('[ petit_httpd/${PetitHTTPD.VERSION} ]\n');

  if (args.arguments.isEmpty) {
    log('USAGE:');
    log('$petitHTTPDUsage\n');
    return 0;
  }

  PetitHTTPD petitHTTPD;
  try {
    petitHTTPD = petitHTTPDFromArgs(args);
  } on FormatException catch (e) {
    log('** ERROR: ${e.message}');
    log('USAGE:');
    log('$petitHTTPDUsage\n');
    return 64;
  }

  if (!petitHTTPD.documentRoot.existsSync()) {
    log('** ERROR: document root not found: ${petitHTTPD.documentRoot.path}');
    return 1;
  }

  if (args.flag('verbose')) {
    log('-- Document root: ${petitHTTPD.documentRoot.path}');
    log('-- Port: ${petitHTTPD.port}');
    log('-- Secure port: ${petitHTTPD.securePort}');
    log('-- Binding address: ${petitHTTPD.bindingAddress}');
    log('-- CORS: ${petitHTTPD.setCORSHeaders}');
    log('-- Serve hidden files: ${petitHTTPD.serveHiddenFiles}');
    var cacheControl = petitHTTPD.headerCacheControl;
    if (cacheControl != null) {
      log('-- Cache-Control: $cacheControl');
    }
    var domains = petitHTTPD.domains;
    if (domains != null && domains.isNotEmpty) {
      log('-- Force HTTPS: ${petitHTTPD.redirectToHTTPS}');
      for (var e in domains.entries) {
        log('-- Domain: ${e.key} > ${e.value}');
      }
      log(
        '-- Let\'s Encrypt directory: ${petitHTTPD.letsEncryptDirectory?.path}',
      );
      log('');
    }
  }

  bool ok;
  try {
    ok = await petitHTTPD.start();
  } catch (e) {
    log('** ERROR Starting: $petitHTTPD');
    log('** $e');
    return 1;
  }

  if (!ok) {
    log('** ERROR Starting: $petitHTTPD');
    return 1;
  }

  log('-- STARTED: $petitHTTPD');

  onStart?.call(petitHTTPD);

  return null;
}
