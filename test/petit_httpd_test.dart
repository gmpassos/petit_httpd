import 'dart:io';

import 'package:petit_httpd/petit_httpd.dart';
import 'package:path/path.dart' as pack_path;
import 'package:test/test.dart';

void main() {
  group('PetitHTTPD', () {
    test('basic', () async {
      var documentRoot = _resolveDocumentRoot();

      expect(documentRoot.existsSync(), isTrue);

      var petitHTTPD = PetitHTTPD(documentRoot, port: 4455);

      var ok = await petitHTTPD.start();
      expect(ok, isTrue);
    });
  });
}

Directory _resolveDocumentRoot() {
  for (var p in ['./', './test', '../test']) {
    var file = File(pack_path.join(p, 'doc-root/hello-world.txt'));
    if (file.existsSync()) {
      return file.parent.absolute;
    }
  }

  return Directory('.');
}
