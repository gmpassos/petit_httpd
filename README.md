# petit_httpd

[![pub package](https://img.shields.io/pub/v/petit_httpd.svg?logo=dart&logoColor=00b9fc)](https://pub.dev/packages/petit_httpd)
[![Null Safety](https://img.shields.io/badge/null-safety-brightgreen)](https://dart.dev/null-safety)
[![Codecov](https://img.shields.io/codecov/c/github/gmpassos/petit_httpd)](https://app.codecov.io/gh/gmpassos/petit_httpd)
[![CI](https://img.shields.io/github/workflow/status/gmpassos/petit_httpd/Dart%20CI/master?logo=github-actions&logoColor=white)](https://github.com/gmpassos/petit_httpd/actions)
[![GitHub Tag](https://img.shields.io/github/v/tag/gmpassos/petit_httpd?logo=git&logoColor=white)](https://github.com/gmpassos/petit_httpd/releases)
[![New Commits](https://img.shields.io/github/commits-since/gmpassos/petit_httpd/latest?logo=git&logoColor=white)](https://github.com/gmpassos/petit_httpd/network)
[![Last Commits](https://img.shields.io/github/last-commit/gmpassos/petit_httpd?logo=git&logoColor=white)](https://github.com/gmpassos/petit_httpd/commits/master)
[![Pull Requests](https://img.shields.io/github/issues-pr/gmpassos/petit_httpd?logo=github&logoColor=white)](https://github.com/gmpassos/petit_httpd/pulls)
[![Code size](https://img.shields.io/github/languages/code-size/gmpassos/petit_httpd?logo=github&logoColor=white)](https://github.com/gmpassos/petit_httpd)
[![License](https://img.shields.io/github/license/gmpassos/petit_httpd?logo=open-source-initiative&logoColor=green)](https://github.com/gmpassos/petit_httpd/blob/master/LICENSE)

This is a simple HTTP file server integrated with [Let's Encrypt][shelf_letsencrypt], [gzip][shelf_gzip] and CORS.

[shelf_gzip]: https://pub.dev/packages/shelf_gzip
[shelf_letsencrypt]: https://pub.dev/packages/shelf_letsencrypt

## Motivation

Since [Dart][dart_overview_platforms] can run in many native platforms (Linux/x64, macOS/x64/arm64, Windows/x86),
it can be an awesome way to have a HTTP Server running in any place,
including all the basic features needed today.

[dart_overview_platforms]: https://dart.dev/overview#platform

## API Documentation

See the [API Documentation][api_doc] for a full list of functions, classes and extension.

[api_doc]: https://pub.dev/documentation/petit_httpd/latest/

## Usage

```dart
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
```

## CLI Tools

### petit_httpd

The `petit_httpd` is a **CLI** for the [PetitHTTPD class][PetitHTTPD_class].

[PetitHTTPD_class]: https://pub.dev/documentation/petit_httpd/latest/petit_httpd/PetitHTTPD-class.html

First activate the `petit_httpd` command:
```shell
$> dart pub global activate petit_httpd
```

To run an HTTP Daemon:

```shell
$> petit_httpd ./www --port 8080 --securePort 443 --address 0.0.0.0 --letsencrypt-path /etc/letsencrypt --domain mydomain.com
```

## Source

The official source code is [hosted @ GitHub][github_petit_httpd]:

- https://github.com/gmpassos/petit_httpd

[github_petit_httpd]: https://github.com/gmpassos/petit_httpd

# Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

# Contribution

Any help from the open-source community is always welcome and needed:
- Found an issue?
    - Please fill a bug report with details.
- Wish a feature?
    - Open a feature request with use cases.
- Are you using and liking the project?
    - Promote the project: create an article, do a post or make a donation.
- Are you a developer?
    - Fix a bug and send a pull request.
    - Implement a new feature, like other training algorithms and activation functions.
    - Improve the Unit Tests.
- Have you already helped in any way?
    - **Many thanks from me, the contributors and everybody that uses this project!**

*If you donate 1 hour of your time, you can contribute a lot,
because others will do the same, just be part and start with your 1 hour.*

[tracker]: https://github.com/gmpassos/petit_httpd/issues

# Author

Graciliano M. Passos: [gmpassos@GitHub][github].

[github]: https://github.com/gmpassos

## License

[Apache License - Version 2.0][apache_license]

[apache_license]: https://www.apache.org/licenses/LICENSE-2.0.txt
