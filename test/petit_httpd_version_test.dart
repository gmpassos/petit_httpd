@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:petit_httpd/petit_httpd.dart';
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:test/test.dart';

void main() {
  group('PetitHTTPD.VERSION', () {
    test('Check Version', () async {
      var projectDirectory = Directory.current;

      print(projectDirectory);

      var pubspecFile = File(path.join(projectDirectory.path, 'pubspec.yaml'));

      print('pubspecFile: $pubspecFile');

      var pubSpec = Pubspec.parse(
        pubspecFile.readAsStringSync(),
        sourceUrl: pubspecFile.uri,
      );

      print('PubSpec.name: ${pubSpec.name}');
      print('PubSpec.version: ${pubSpec.version}');

      var srcPath = path.join(
        projectDirectory.path,
        'lib/src/petit_httpd_base.dart',
      );

      var srcFile = File(srcPath);

      print(srcFile);

      var src = srcFile.readAsStringSync();

      var versionMatch = RegExp(r"VERSION\s*=\s*'(.*?)'").firstMatch(src)!;

      var srcVersion = versionMatch.group(1);

      print('srcVersion: $srcVersion');

      expect(
        pubSpec.version.toString(),
        equals(srcVersion),
        reason:
            'PetitHTTPD.VERSION[$srcVersion] != PubSpec.version[${pubSpec.version}]',
      );

      expect(PetitHTTPD.VERSION, equals(pubSpec.version.toString()));
    });
  });
}
