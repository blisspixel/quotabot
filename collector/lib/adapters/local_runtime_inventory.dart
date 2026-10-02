import 'dart:convert';

import 'package:http/http.dart' as http;

/// Sanitized evidence from one collection's model-inventory fallback probes.
///
/// Request deadlines, cancellation, response limits, and ownership stay with
/// the caller. Failed compatibility paths must not erase a more informative
/// authentication or malformed-metadata response from a supported path.
class LocalRuntimeInventoryDiagnostics {
  String _error = 'not running';
  int? _httpStatus;
  int _priority = 0;

  String get error => _error;
  int? get httpStatus => _httpStatus;

  Future<T?> read<T>(
    Future<http.Response> Function() fetch,
    T? Function(Object?) parse,
  ) async {
    final http.Response response;
    try {
      response = await fetch();
    } catch (_) {
      return null;
    }
    final status = response.statusCode;
    if (status != 200) {
      if (status == 401) {
        _record('runtime metadata authentication required (HTTP 401)', 401, 4);
      } else if (status == 403) {
        _record('runtime metadata access denied (HTTP 403)', 403, 4);
      } else {
        final boundedStatus = status >= 100 && status <= 599 ? status : null;
        _record(
          boundedStatus == null
              ? 'runtime metadata unavailable'
              : 'runtime metadata unavailable (HTTP $boundedStatus)',
          boundedStatus,
          status == 404 || status == 405 ? 1 : 2,
        );
      }
      return null;
    }
    try {
      final Object? data = jsonDecode(response.body);
      final parsed = parse(data);
      if (parsed != null) return parsed;
    } catch (_) {
      // Neither body text nor parser exceptions are safe diagnostic content.
    }
    _record('invalid runtime model metadata', 200, 3);
    return null;
  }

  void _record(String error, int? httpStatus, int priority) {
    if (priority <= _priority) return;
    _error = error;
    _httpStatus = httpStatus;
    _priority = priority;
  }
}
