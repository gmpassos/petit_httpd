import 'dart:io';

import 'package:mercury_client/mercury_client.dart';
import 'package:path/path.dart' as pack_path;
import 'package:petit_httpd/petit_httpd.dart';
import 'package:test/test.dart';

void main() {
  group('PetitHTTPD', () {
    test('basic', () async {
      var documentRoot = _resolveDocumentRoot();

      expect(documentRoot.existsSync(), isTrue);

      var petitHTTPD = PetitHTTPD(documentRoot, port: 4455);

      var ok = await petitHTTPD.start();
      expect(ok, isTrue);

      var httpClient = HttpClient('http://localhost:4455/');

      {
        var response = await httpClient.get('/foo');
        print(response);

        expect(response.isNotOK, isTrue);
        expect(response.status, equals(404));
        expect(response.getResponseHeader('cache-control'), isNull);

        expect(response.getResponseHeader('server'),
            equals('petit_httpd/${PetitHTTPD.VERSION}'));
      }

      {
        var response = await httpClient.get('/hello-world.txt');
        print(response);

        expect(response.isOK, isTrue);
        expect(response.status, equals(200));
        expect(response.getResponseHeader('cache-control'),
            contains('must-revalidate'));

        expect(response.bodyAsString, equals('Hello World!'));

        expect(response.getResponseHeader('server'),
            equals('petit_httpd/${PetitHTTPD.VERSION}'));
      }
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
