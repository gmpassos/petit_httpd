import 'dart:io';

import 'package:petit_httpd/src/petit_httpd_cli.dart';

void main(List<String> args) async {
  var exitCode = await runPetitHTTPD(args);
  if (exitCode != null) {
    exit(exitCode);
  }
}
