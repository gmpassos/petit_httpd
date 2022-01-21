import 'dart:io';

import 'package:petit_httpd/petit_httpd.dart';

void main() async {
  var petitHTTPD = PetitHTTPD(Directory('/var/www'),
      port: 8080,
      securePort: 443,
      bindingAddress: '0.0.0.0',
      letsEncryptDirectory: Directory('/etc/letsencrypt/live'),
      domains: {'mydomain.com': 'contact@mydomain.com'});

  var ok = await petitHTTPD.start();

  if (!ok) {
    print('** ERROR Starting: $petitHTTPD');
    exit(1);
  }

  print('-- STARTED: $petitHTTPD');
}
