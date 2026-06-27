import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// PKCE verifier/challenge pair (RFC 7636, S256).
typedef Pkce = ({String verifier, String challenge});

/// A bound one-shot loopback capture and the port it is listening on.
typedef LoopbackCodeCapture = ({int port, Future<String> code});

final _rng = Random.secure();

String _randomUrlSafe(int bytes) {
  final b = List<int>.generate(bytes, (_) => _rng.nextInt(256));
  return base64Url.encode(b).replaceAll('=', '');
}

/// A random opaque string for the OAuth `state` parameter.
String randomState() => _randomUrlSafe(16);

/// Generates a PKCE verifier and its S256 challenge.
Pkce pkcePair() {
  final verifier = _randomUrlSafe(32);
  final challenge = base64Url
      .encode(sha256.convert(ascii.encode(verifier)).bytes)
      .replaceAll('=', '');
  return (verifier: verifier, challenge: challenge);
}

/// Binds an ephemeral port, returns it, and releases it for the OAuth server.
Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

/// Opens [url] in the user's default browser (best effort).
Future<void> openInBrowser(String url) async {
  try {
    if (Platform.isWindows) {
      // Use rundll32 to avoid cmd.exe parsing issues with & and other chars in OAuth URLs.
      // This is more reliable than `start` for long query strings.
      await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [url]);
    } else {
      await Process.run('xdg-open', [url]);
    }
  } catch (_) {
    // The caller prints the URL as fallback.
  }
}

/// Runs a one-shot loopback server on [port], waits for the OAuth redirect,
/// validates `state`, and returns the authorization `code`. Times out after
/// five minutes.
Future<String> captureLoopbackCode({
  required int port,
  required String path,
  required String expectedState,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  return _captureFromServer(server, path: path, expectedState: expectedState);
}

/// Binds a one-shot loopback capture on an OS-selected port and keeps it bound.
/// Use this for OAuth login flows so another local process cannot win the port
/// between choosing it and opening the browser.
Future<LoopbackCodeCapture> startLoopbackCodeCapture({
  required String path,
  required String expectedState,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  return (
    port: server.port,
    code: _captureFromServer(server, path: path, expectedState: expectedState),
  );
}

Future<String> _captureFromServer(
  HttpServer server, {
  required String path,
  required String expectedState,
}) async {
  final completer = Completer<String>();
  late final StreamSubscription<HttpRequest> sub;
  var closed = false;

  Future<void> closeOnce() async {
    if (closed) return;
    closed = true;
    await sub.cancel();
    await server.close(force: true);
  }

  sub = server.listen((req) async {
    if (req.uri.path != path) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    final code = req.uri.queryParameters['code'];
    final state = req.uri.queryParameters['state'];
    final ok = code != null && state == expectedState;
    req.response
      ..statusCode = ok ? 200 : 400
      ..headers.contentType = ContentType.html
      ..write(
        ok
            ? '<html><body style="font-family:sans-serif;padding:40px">'
                '<h2>quotabot is connected.</h2>'
                'You can close this tab and return to the terminal.</body></html>'
            : '<html><body>Authorization failed. You can close this tab.</body></html>',
      );
    await req.response.close();
    if (ok && !completer.isCompleted) {
      completer.complete(code);
    }
  });

  return completer.future
      .timeout(const Duration(minutes: 5))
      .whenComplete(closeOnce);
}
