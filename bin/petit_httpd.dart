import 'dart:io';

import 'package:args_simple/args_simple_io.dart';
import 'package:petit_httpd/petit_httpd.dart';

void _printLine() => print(
    '========================================================================');

void main(List<String> _args) async {
  _printLine();
  print('[ petit_httpd / ${PetitHTTPD.VERSION} ]\n');

  var args = ArgsSimple.parse(_args);

  if (args.arguments.isEmpty) {
    print('USAGE:');
    print(
        '  \$> petit_httpd ./www --port 8080 --securePort 443 --address 0.0.0.0 --letsencrypt-path /etc/letsencrypt --domain domain.com\n');
    exit(0);
  }

  var documentRoot = args.argumentAsDirectory(0, Directory('./'))!.absolute;

  var port = args.optionAsInt('port', 80)!;
  var securePort = args.optionAsInt('secure-port', 443)!;
  var address = args.optionAsString('address', 'localhost')!;

  var letsEncrypt = args.optionAsDirectory(
      'letsencrypt-path', Directory('/etc/letsencrypt/live'));

  var domain = args.optionAsString('domain');
  var email =
      args.optionAsString('email', (domain != null ? 'contact@$domain' : null));

  var verbose = args.flag('v');

  if (verbose) {
    print('-- Document root: ${documentRoot.path}');
    print('-- Port: $port');
    print('-- Secure port: $securePort');
    print('-- Binding address: $address');
    if (domain != null) {
      print('-- Domain: $domain > $email');
      print('-- Let\'s Encrypt directory: ${letsEncrypt?.path}');
    }
  }

  var petitHTTPD = PetitHTTPD(documentRoot,
      port: port,
      securePort: securePort,
      bindingAddress: address,
      letsEncryptDirectory: letsEncrypt,
      domains: {
        if (domain != null) domain: email!,
      });

  var ok = await petitHTTPD.start();

  if (!ok) {
    print('** ERROR Starting: $petitHTTPD');
    exit(1);
  }

  print('-- STARTED: $petitHTTPD');
}
