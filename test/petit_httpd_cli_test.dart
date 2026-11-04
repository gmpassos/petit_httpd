@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args_simple/args_simple.dart';
import 'package:path/path.dart' as p;
import 'package:petit_httpd/petit_httpd.dart';
import 'package:petit_httpd/src/petit_httpd_cli.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('petit_httpd_cli_');
    File(p.join(tempDir.path, 'hello.txt')).writeAsStringSync('Hello CLI!');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  PetitHTTPD parse(List<String> args) =>
      petitHTTPDFromArgs(ArgsSimple.parse(args));

  group('petitHTTPDFromArgs', () {
    test('defaults', () {
      var httpd = parse([tempDir.path]);

      expect(httpd.documentRoot.path, equals(tempDir.absolute.path));
      expect(httpd.port, equals(80));
      expect(httpd.securePort, equals(443));
      expect(httpd.bindingAddress, equals('localhost'));
      expect(httpd.setCORSHeaders, isFalse);
      expect(httpd.headerCacheControl, isNull);
      expect(httpd.redirectToHTTPS, isFalse);
      expect(httpd.domains, isEmpty);
      expect(httpd.letsEncryptDirectory?.path, equals('/etc/letsencrypt/live'));
      expect(httpd.isLetsEncryptEnabled, isFalse);
      expect(httpd.serveHiddenFiles, isFalse);
    });

    test('-serve-hidden-files', () {
      expect(
        parse([tempDir.path, '-serve-hidden-files']).serveHiddenFiles,
        isTrue,
      );
      // Flag keys are normalized, like the options:
      expect(
        parse([tempDir.path, '-serveHiddenFiles']).serveHiddenFiles,
        isTrue,
      );
      expect(
        parse(['-serve-hidden-files', tempDir.path]).documentRoot.path,
        equals(tempDir.absolute.path),
      );
    });

    test('`--serve-hidden-files` is rejected (would take a value)', () {
      for (var args in [
        ['--serve-hidden-files', tempDir.path],
        [tempDir.path, '--serve-hidden-files'],
        [tempDir.path, '--serve-hidden-files', 'true'],
      ]) {
        expect(
          () => parse(args),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('`-serve-hidden-files` is a flag'),
            ),
          ),
          reason: '$args',
        );
      }
    });

    test('all options', () {
      var httpd = parse([
        tempDir.path,
        '--port',
        '8080',
        '--secure-port',
        '8443',
        '--address',
        '0.0.0.0',
        '--letsencrypt-path',
        '/tmp/le',
        '--domain',
        'example.com',
        '--email',
        'admin@example.com',
        '--cache-control',
        'no-cache',
        '-cors',
        '-force-https',
        '-serve-hidden-files',
      ]);

      expect(httpd.serveHiddenFiles, isTrue);
      expect(httpd.port, equals(8080));
      expect(httpd.securePort, equals(8443));
      expect(httpd.bindingAddress, equals('0.0.0.0'));
      expect(httpd.setCORSHeaders, isTrue);
      expect(httpd.headerCacheControl, equals('no-cache'));
      expect(httpd.redirectToHTTPS, isTrue);
      expect(httpd.domains, equals({'example.com': 'admin@example.com'}));
      expect(httpd.letsEncryptDirectory?.path, equals('/tmp/le'));
      expect(httpd.isLetsEncryptEnabled, isTrue);
    });

    test('option keys are normalized (`--securePort`)', () {
      var httpd = parse([tempDir.path, '--securePort', '9443']);
      expect(httpd.securePort, equals(9443));
    });

    test('default e-mail and blank values', () {
      var httpd = parse([
        tempDir.path,
        '--domain',
        'example.com',
        '--cache-control',
        '  ',
      ]);
      expect(httpd.domains, equals({'example.com': 'contact@example.com'}));
      expect(httpd.headerCacheControl, isNull);

      httpd = parse([tempDir.path, '--domain', ' ', '--email', 'a@b.com']);
      expect(httpd.domains, isEmpty);
    });

    test('invalid ports', () {
      for (var port in ['abc', '-1', '65536', '80.5', '']) {
        expect(
          () => parse([tempDir.path, '--port', port]),
          throwsFormatException,
          reason: port,
        );
        expect(
          () => parse([tempDir.path, '--secure-port', port]),
          throwsFormatException,
          reason: port,
        );
      }

      expect(parse([tempDir.path, '--port', '0']).port, equals(0));
      expect(parse([tempDir.path, '--port', '65535']).port, equals(65535));
    });
  });

  group('runPetitHTTPD', () {
    Future<(int?, List<String>)> run(
      List<String> args, {
      void Function(PetitHTTPD)? onStart,
    }) async {
      var output = <String>[];
      var exitCode = await runPetitHTTPD(
        args,
        log: (o) => output.add('$o'),
        onStart: onStart,
      );
      return (exitCode, output);
    }

    test('-version', () async {
      var (exitCode, output) = await run(['-version']);
      expect(exitCode, equals(0));
      expect(output, equals(['petit_httpd/${PetitHTTPD.VERSION}']));
    });

    test('usage', () async {
      var (exitCode, output) = await run([]);
      expect(exitCode, equals(0));
      expect(output, contains('USAGE:'));
      expect(output.join('\n'), contains(petitHTTPDUsage));
    });

    test('invalid option', () async {
      var (exitCode, output) = await run([tempDir.path, '--port', 'x']);
      expect(exitCode, equals(64));
      expect(output.join('\n'), contains('Invalid `--port`: x'));
    });

    test('`--serve-hidden-files` exits with 64', () async {
      var (exitCode, output) = await run([
        tempDir.path,
        '--serve-hidden-files',
      ]);
      expect(exitCode, equals(64));
      expect(output.join('\n'), contains('`-serve-hidden-files` is a flag'));
    });

    test('missing document root', () async {
      var missing = p.join(tempDir.path, 'missing');
      var (exitCode, output) = await run([missing]);
      expect(exitCode, equals(1));
      expect(output.join('\n'), contains('document root not found'));
    });

    test('starts the server', () async {
      PetitHTTPD? started;

      // No `--domain`: Let's Encrypt is disabled.
      var (exitCode, output) = await run([
        tempDir.path,
        '--port',
        '0',
        '--address',
        '127.0.0.1',
        '--cache-control',
        'no-store',
        '-cors',
        '-verbose',
      ], onStart: (httpd) => started = httpd);

      expect(exitCode, isNull);
      expect(started, isNotNull);
      addTearDown(() => started!.stop(force: true));

      var log = output.join('\n');
      expect(log, contains('-- Port: 0'));
      expect(log, contains('-- CORS: true'));
      expect(log, contains('-- Serve hidden files: false'));
      expect(log, contains('-- Cache-Control: no-store'));
      expect(log, contains('-- STARTED: PetitHTTPD{'));

      var client = HttpClient();
      addTearDown(() => client.close(force: true));

      var request = await client.get(
        '127.0.0.1',
        started!.boundPort!,
        '/hello.txt',
      );
      request.headers.set('origin', 'https://example.com');
      var response = await request.close();
      var body = await response.transform(utf8.decoder).join();

      expect(response.statusCode, equals(200));
      expect(body, equals('Hello CLI!'));
      expect(response.headers.value('cache-control'), equals('no-store'));
      expect(
        response.headers.value('access-control-allow-origin'),
        equals('https://example.com'),
      );
    });

    test('start error (verbose, with a domain)', () async {
      var leDir = p.join(tempDir.path, 'le');

      // Invalid domain: Let's Encrypt fails before any network access.
      var (exitCode, output) = await run([
        tempDir.path,
        '--port',
        '0',
        '--secure-port',
        '0',
        '--address',
        '127.0.0.1',
        '--domain',
        'not a valid domain!',
        '--letsencrypt-path',
        leDir,
        '-force-https',
        '-verbose',
      ]);

      expect(exitCode, equals(1));

      var log = output.join('\n');
      expect(log, contains('-- Force HTTPS: true'));
      expect(
        log,
        contains(
          '-- Domain: not a valid domain! > contact@not a valid domain!',
        ),
      );
      expect(log, contains("-- Let's Encrypt directory: $leDir"));
      expect(log, contains('** ERROR Starting: PetitHTTPD{'));
    });
  });

  group('bin/petit_httpd.dart', () {
    test('-version', () async {
      var result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'bin/petit_httpd.dart',
        '-version',
      ]);

      expect(result.exitCode, equals(0), reason: '${result.stderr}');
      expect(
        '${result.stdout}'.trim(),
        endsWith('petit_httpd/${PetitHTTPD.VERSION}'),
      );
    });

    test('invalid port exits with 64', () async {
      var result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'bin/petit_httpd.dart',
        tempDir.path,
        '--port',
        'x',
      ]);

      expect(result.exitCode, equals(64), reason: '${result.stderr}');
    });

    test('usage', () async {
      var result = await Process.run(Platform.resolvedExecutable, [
        'bin/petit_httpd.dart',
      ]);

      expect(result.exitCode, equals(0), reason: '${result.stderr}');
      expect('${result.stdout}', contains('USAGE:'));
      expect('${result.stdout}', contains(petitHTTPDUsage));
    });

    test('missing document root exits with 1', () async {
      var result = await Process.run(Platform.resolvedExecutable, [
        'bin/petit_httpd.dart',
        p.join(tempDir.path, 'missing'),
      ]);

      expect(result.exitCode, equals(1), reason: '${result.stderr}');
      expect('${result.stdout}', contains('document root not found'));
    });

    test(
      'serves files until killed',
      () async {
        // The CLI logs the configured port, so it can't be `0`:
        var socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        var port = socket.port;
        await socket.close();

        var process = await Process.start(Platform.resolvedExecutable, [
          'bin/petit_httpd.dart',
          tempDir.path,
          '--port',
          '$port',
          '--address',
          '127.0.0.1',
          '--cache-control',
          'no-cache',
          '-cors',
        ]);
        addTearDown(() => process.kill(ProcessSignal.sigkill));

        var lines = <String>[];
        var newLine = StreamController<void>.broadcast();
        addTearDown(newLine.close);
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((l) {
              lines.add(l);
              newLine.add(null);
            });
        var stderr = StringBuffer();
        process.stderr.transform(utf8.decoder).listen(stderr.write);

        int? exitCode;
        unawaited(
          process.exitCode.then((c) {
            exitCode = c;
            if (!newLine.isClosed) newLine.add(null);
          }),
        );

        Future<String> waitLine(String s) async {
          while (true) {
            var line = lines.where((l) => l.contains(s)).firstOrNull;
            if (line != null) return line;
            if (exitCode != null) {
              fail('Process exited ($exitCode) before `$s`:\n$lines\n$stderr');
            }
            await newLine.stream.first;
          }
        }

        var started = await waitLine('-- STARTED:');
        expect(started, contains('port: $port'));

        var client = HttpClient();
        addTearDown(() => client.close(force: true));

        var request = await client.get('127.0.0.1', port, '/hello.txt');
        request.headers.set('origin', 'https://example.com');
        var response = await request.close();
        var body = await response.transform(utf8.decoder).join();

        expect(response.statusCode, equals(200));
        expect(body, equals('Hello CLI!'));
        expect(response.headers.value('cache-control'), equals('no-cache'));
        expect(
          response.headers.value('access-control-allow-origin'),
          equals('https://example.com'),
        );

        // Requests are logged to stdout:
        expect(await waitLine('/hello.txt'), contains('[200]'));

        expect(process.kill(), isTrue);
        expect(await process.exitCode, isNot(equals(0)));

        // The port is released:
        await expectLater(
          Socket.connect('127.0.0.1', port),
          throwsA(isA<SocketException>()),
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
      skip: Platform.isWindows ? 'Uses POSIX signals' : false,
    );

    for (var serveHiddenFiles in [false, true]) {
      test(
        'hidden files (-serve-hidden-files: $serveHiddenFiles)',
        () async {
          File(p.join(tempDir.path, '.env')).writeAsStringSync('KEY=value');
          var git = Directory(p.join(tempDir.path, '.git'))..createSync();
          File(p.join(git.path, 'config')).writeAsStringSync('[core]');
          var wellKnown = Directory(p.join(tempDir.path, '.well-known'))
            ..createSync();
          File(p.join(wellKnown.path, 'security.txt'))
              .writeAsStringSync('Contact: mailto:a@b.com');

          var socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
          var port = socket.port;
          await socket.close();

          var process = await Process.start(Platform.resolvedExecutable, [
            'bin/petit_httpd.dart',
            tempDir.path,
            '--port',
            '$port',
            '--address',
            '127.0.0.1',
            if (serveHiddenFiles) '-serve-hidden-files',
            '-verbose',
          ]);
          addTearDown(() => process.kill(ProcessSignal.sigkill));

          var stdout = StringBuffer();
          var started = Completer<void>();
          process.stdout.transform(utf8.decoder).listen((s) {
            stdout.write(s);
            if (!started.isCompleted &&
                stdout.toString().contains('-- STARTED:')) {
              started.complete();
            }
          });
          var stderr = StringBuffer();
          process.stderr.transform(utf8.decoder).listen(stderr.write);
          unawaited(
            process.exitCode.then((c) {
              if (!started.isCompleted) {
                started.completeError(
                  'Process exited ($c) before starting:\n$stdout\n$stderr',
                );
              }
            }),
          );

          await started.future;
          expect(
            '$stdout',
            contains('-- Serve hidden files: $serveHiddenFiles'),
          );

          var client = HttpClient();
          addTearDown(() => client.close(force: true));

          Future<(int, String)> get(String path) async {
            var request = await client.get('127.0.0.1', port, path);
            var response = await request.close();
            var body = await response.transform(utf8.decoder).join();
            return (response.statusCode, body);
          }

          var hidden = {
            '/.env': 'KEY=value',
            '/.git/config': '[core]',
            '/%2Eenv': 'KEY=value',
            '/%2egit/config': '[core]',
          };

          for (var e in hidden.entries) {
            var (status, body) = await get(e.key);
            if (serveHiddenFiles) {
              expect(status, equals(200), reason: e.key);
              expect(body, equals(e.value), reason: e.key);
            } else {
              expect(status, equals(404), reason: e.key);
              expect(body, isNot(contains(e.value)), reason: e.key);
            }
          }

          var (status, body) = await get('/.well-known/security.txt');
          expect(status, equals(200));
          expect(body, equals('Contact: mailto:a@b.com'));

          (status, body) = await get('/hello.txt');
          expect(status, equals(200));
          expect(body, equals('Hello CLI!'));

          expect(process.kill(), isTrue);
          expect(await process.exitCode, isNot(equals(0)));
        },
        timeout: const Timeout(Duration(seconds: 90)),
        skip: Platform.isWindows ? 'Uses POSIX signals' : false,
      );
    }
  });
}
