## 1.2.0

- `PetitHTTPD`:
  - Use `LetsEncrypt.startServer` (`shelf_letsencrypt` 2.x): ports and binding address are passed to the `LetsEncrypt` constructor.
  - Let's Encrypt now uses all the `domains`, not only the first one.
  - Fix the HTTPS redirect keeping the HTTP port: it now points to `securePort`, preserving path and query. Domains match case-insensitively.
  - `getRemoteAddress`: returns `null` if the connection is already gone (`shelf` 1.4.3 throws a `StateError`).
  - Added `stop`, `isStarted`, `boundPort`, `boundSecurePort`, `createHandler`, `httpsRedirectUri` and `letsEncryptDomains`.
  - `start`: throws a `StateError` if already started.
- CLI `petit_httpd`:
  - Logic moved to `lib/src/petit_httpd_cli.dart` (`runPetitHTTPD`, `petitHTTPDFromArgs`).
  - Invalid `--port`/`--secure-port` values exit with code `64`; a missing document root or a start error exits with `1`.
  - Fixed the usage line: `--cache-control` is an option, `--secure-port`.
- `README.md`: CLI options.
- Tests: integration tests on an ephemeral port (files, 404, 304, gzip, CORS, `Cache-Control`, path traversal, symbolic links), handler and CLI tests. Line coverage: 45.2% -> 96.5%.
- GitHub CI: `actions/checkout@v7`, `codecov/codecov-action@v7`; tests run on SDK 3.13.0 and stable.

- sdk: ^3.13.0
- args_simple: ^1.2.0
- shelf: ^1.4.3
- shelf_static: ^1.2.0
- shelf_gzip: ^4.1.0
- shelf_letsencrypt: ^2.0.8
- lints: ^6.1.0
- test: ^1.33.0
- dependency_validator: ^5.1.0
- coverage: ^1.16.0
- path: ^1.9.1
- mercury_client: ^2.4.0
- pubspec_parse: ^1.7.0 (replaces the discontinued `pubspec`)

## 1.1.0

- sdk: '>=3.0.0 <4.0.0'
- shelf_letsencrypt: ^1.2.0
- lints: ^2.1.0

## 1.0.6

- Fix call to `LetsEncrypt.startSecureServer`.
- shelf: ^1.4.1
- shelf_static: ^1.1.2
- shelf_gzip: ^4.0.1
- shelf_letsencrypt: ^1.1.1
- lints: ^2.0.1
- test: ^1.24.1
- dependency_validator: ^3.2.2
- coverage: ^1.6.3
- pubspec: ^2.3.0
- path: ^1.8.3
- mercury_client: ^2.1.8

## 1.0.5

- Added `-cache-control` parameter.
- shelf: ^1.4.0
- shelf_static: ^1.1.1
- sdk: '>=2.17.0 <3.0.0' 

## 1.0.4

- mercury_client: ^2.1.5

## 1.0.3

- `petit_httpd` new option:
  - `-force-https`: to automatically redirect to HTTPS when possible.
  - `-version`: just show the current CLI version. 

## 1.0.2

- Added server name in headers.

## 1.0.1

- Added `CORS` and `cache-control` headers.

## 1.0.0

- Initial version.
