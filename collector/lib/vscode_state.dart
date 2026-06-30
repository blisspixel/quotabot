import 'dart:convert';

import 'util.dart';

Map<String, dynamic>? decodeStateJsonObject(Object? raw) {
  try {
    final text = raw is List<int>
        ? utf8.decode(raw, allowMalformed: true)
        : raw?.toString();
    if (text == null || text.trim().isEmpty) return null;
    final parsed = jsonDecode(text);
    return parsed is Map ? Map<String, dynamic>.from(parsed) : null;
  } catch (_) {
    return null;
  }
}

String? firstNestedString(Map<String, dynamic> data, List<String> keys) {
  for (final key in keys) {
    final found = findKey(data, key);
    if (found is String && found.trim().isNotEmpty) return found.trim();
  }
  return null;
}
