import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Upper bound for a token-endpoint body. Larger payloads are rejected without
/// buffering the remainder, so a hostile response cannot grow without limit.
const oAuthTokenResponseMaxBytes = 128 * 1024;

/// POSTs one OAuth token-endpoint request and waits for original settlement.
///
/// [timeout] is a publication deadline: it cooperatively aborts, but this
/// future does not complete until the original send and body finish. A 200 body
/// that arrives after that deadline is still returned so a rotating refresh
/// token can be persisted. Injected [client]s stay caller-owned; otherwise the
/// short-lived client is closed here.
Future<http.Response> postOAuthTokenRequest({
  required Uri uri,
  required Map<String, String> headers,
  String? body,
  Map<String, String>? bodyFields,
  required Duration timeout,
  http.Client? client,
}) async {
  if (timeout.inMicroseconds <= 0) {
    throw ArgumentError.value(timeout, 'timeout', 'must be positive');
  }
  if ((body == null) == (bodyFields == null)) {
    throw ArgumentError(
      'exactly one of body or bodyFields is required',
    );
  }
  final owned = client ?? http.Client();
  final abort = Completer<void>();
  var expired = false;
  final timer = Timer(timeout, () {
    expired = true;
    if (!abort.isCompleted) abort.complete();
  });
  void cancel() {
    if (!abort.isCompleted) abort.complete();
  }

  try {
    final request = http.AbortableRequest(
      'POST',
      uri,
      abortTrigger: abort.future,
    )
      ..followRedirects = false
      ..headers.addAll(headers);
    if (bodyFields != null) {
      request.bodyFields = bodyFields;
    } else {
      request.body = body!;
    }
    // Await the original request and body, including cancellation. A refresh
    // transaction keeps its native guard until this work settles.
    final response = await owned.send(request);
    if ((response.contentLength ?? 0) > oAuthTokenResponseMaxBytes) {
      cancel();
      await response.stream.listen(null).cancel();
      throw const FormatException('token response exceeds size limit');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > oAuthTokenResponseMaxBytes) {
        cancel();
        throw const FormatException('token response exceeds size limit');
      }
      bytes.add(chunk);
    }
    final settled = http.Response.bytes(
      bytes.takeBytes(),
      response.statusCode,
      headers: response.headers,
    );
    if (expired && settled.statusCode != 200) {
      throw TimeoutException('token metadata deadline');
    }
    return settled;
  } on http.RequestAbortedException {
    if (expired) throw TimeoutException('token metadata deadline');
    rethrow;
  } finally {
    timer.cancel();
    if (client == null) owned.close();
  }
}
