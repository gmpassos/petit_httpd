## 1.3.0

- **Security fix — default behaviour change: hidden files are no longer served.**
  - Until `1.2.2` any file in the document root was served, including hidden ones such as `/.env` or `/.git/config`.
  - Now a request with any path segment starting with `.` (file or directory, at any depth) gets a `404 Not Found`, the same response as a missing file (existence is not revealed). For example: `/.env`, `/.git/config`, `/sub/.secret`, `/.hidden/x.txt`, `/.hidden/` (its index document is not served either).
  - The segments are checked after URL-decoding, as the file is resolved: `/%2eenv`, `/%2Egit/config`, and encoded separators (`/sub%2f.secret`, `/%5c.env`) are also blocked. Any method, `HEAD` and range requests included.
  - Allowed: `/.well-known/` ([RFC 8615](https://www.rfc-editor.org/rfc/rfc8615)), for Let's Encrypt challenges, `security.txt` and others. Only as the first segment, case-sensitive; hidden entries inside it (`/.well-known/.secret`) are still blocked. See `PetitHTTPD.allowedHiddenDirectories`.
  - **Opt-in to the previous behaviour**: `PetitHTTPD(..., serveHiddenFiles: true)`, or the CLI flag `-serve-hidden-files`.
- `PetitHTTPD`:
  - Added `serveHiddenFiles` (default: `false`), `allowedHiddenDirectories` and `isHiddenPath`.
  - `toString` shows `serveHiddenFiles: true` when enabled.
- CLI `petit_httpd`:
  - New flag `-serve-hidden-files` (shown with `-verbose`). The double-dash form `--serve-hidden-files` is rejected (exit code `64`): as an option it would take the next argument (such as the document root) as its value.
- `README.md`: the hidden files section and the `-serve-hidden-files` option.
- Tests: hidden paths (plain, nested, `%2e`/`%2E`-encoded, encoded separators, trailing slash, query strings, dot segments, `HEAD`, range and conditional requests, any method) on the real server, `/.well-known/` served, `serveHiddenFiles: true`, path traversal with and without it, and the CLI flag on a real process.

## 1.2.2

- args_simple: ^1.2.1
  - Typed option accessors (e.g. `optionAsInt`) no longer throw a `TypeError` on an unparseable
    value (such as `--port abc`); they return the default.

## 1.2.1

- Tests (55 -> 88; no library changes):
  - Let's Encrypt integration tests without network access: self-signed certificates installed in the Let's Encrypt directory, all connections routed to the loopback (any other host is refused). Covers HTTPS serving, the HTTP -> HTTPS redirect, multiple domains (one certificate each, via SNI), `redirectToHTTPS: false`, stop/restart of both servers, and a failed start releasing the ports.
  - Server integration tests: range requests (`206`, suffix/open ranges, `416`), `HEAD` headers matching `GET`, a large binary file, concurrent requests, MIME types, URL-encoded file names (unicode, `%`, `+`), index files in nested directories, modified/deleted files, stop/start cycles and idle keep-alive connections closed on `stop`.
  - CLI as a real process: usage, missing document root, serving files until killed.
  - Pinned current behaviour (unchanged, to be reviewed): hidden files (`.env`, `.git/`) are served; any `Origin` is echoed with `Access-Control-Allow-Credentials: true`; the HTTPS redirect is a `303` without the `Server` header; any method (`POST`, `PUT`, `DELETE`, `OPTIONS`...) is answered as a read-only `GET`; unknown file types are sent as `text/plain`.
  - Line coverage: 96.5% -> 99.4% (the only uncovered line is unreachable: `start` never returns `false`).
- GitHub CI: the Codecov upload uses `CODECOV_TOKEN` and fails the build on error (`fail_ci_if_error: true`).
- dev_dependencies: basic_utils: ^5.8.2 (test certificates).

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
