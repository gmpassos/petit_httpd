import 'dart:io';

import 'package:args_simple/args_simple_io.dart';
import 'package:petit_httpd/petit_httpd.dart';

void _printLine() => print(
    '========================================================================');

void main(List<String> argsOrig) async {
  var args = ArgsSimple.parse(argsOrig);

  var version = args.flag('version');

  if (version) {
    print('petit_httpd/${PetitHTTPD.VERSION}');
    exit(0);
  }

  _printLine();
  print('[ petit_httpd/${PetitHTTPD.VERSION} ]\n');

  if (args.arguments.isEmpty) {
    print('USAGE:');
    print(
        '  \$> petit_httpd ./www --port 8080 --securePort 443 --address 0.0.0.0 --letsencrypt-path /etc/letsencrypt --domain domain.com -cors -cache-control no-cache -force-https -verbose\n');
    exit(0);
  }

  var documentRoot = args.argumentAsDirectory(0, Directory('./'))!.absolute;

  var port = args.optionAsInt('port', 80)!;
  var securePort = args.optionAsInt('secure-port', 443)!;
  var address = args.optionAsString('address', 'localhost')!;

  var cors = args.flag('cors');

  var letsEncrypt = args.optionAsDirectory(
      'letsencrypt-path', Directory('/etc/letsencrypt/live'));

  var domain = args.optionAsString('domain');
  var email =
      args.optionAsString('email', (domain != null ? 'contact@$domain' : null));

  var cacheControl = args.optionAsString('cache-control')?.trim();
  if (cacheControl != null && cacheControl.isEmpty) {
    cacheControl = null;
  }

  var forceHttps = args.flag('force-https');

  var verbose = args.flag('verbose');

  if (verbose) {
    print('-- Document root: ${documentRoot.path}');
    print('-- Port: $port');
    print('-- Secure port: $securePort');
    print('-- Binding address: $address');
    print('-- CORS: $cors');
    if (cacheControl != null) {
      print('-- Cache-Control: $cacheControl');
    }
    if (domain != null) {
      print('-- Force HTTPS: $forceHttps');
      print('-- Domain: $domain > $email');
      print('-- Let\'s Encrypt directory: ${letsEncrypt?.path}');
      print('');
    }
  }

  var petitHTTPD = PetitHTTPD(documentRoot,
      port: port,
      securePort: securePort,
      bindingAddress: address,
      setCORSHeaders: cors,
      headerCacheControl: cacheControl,
      letsEncryptDirectory: letsEncrypt,
      domains: {
        if (domain != null) domain: email!,
      },
      redirectToHTTPS: forceHttps);

  var ok = await petitHTTPD.start();

  if (!ok) {
    print('** ERROR Starting: $petitHTTPD');
    exit(1);
  }

  print('-- STARTED: $petitHTTPD');
}
