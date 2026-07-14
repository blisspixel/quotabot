import 'dart:convert';

import 'util.dart';

/// Upper bound on a VS Code-fork `state.vscdb` value blob before it is decoded.
/// The usage-state JSON quotabot reads is a few KB; this cap only exists so a
/// pathological or malicious same-user-written value cell (Cursor/Windsurf/Kiro
/// SQLite state is not quotabot's file) cannot exhaust memory when decoded. Every
/// other local file quotabot reads has a comparable byte cap.
const int _maxStateValueBytes = 8 * 1024 * 1024;

Map<String, dynamic>? decodeStateJsonObject(Object? raw) {
  try {
    if (raw is List<int> && raw.length > _maxStateValueBytes) return null;
    final text = raw is List<int>
        ? utf8.decode(raw, allowMalformed: true)
        : raw?.toString();
    if (text == null || text.trim().isEmpty) return null;
    if (text.length > _maxStateValueBytes) return null;
    final parsed = jsonDecode(text);
    return parsed is Map ? Map<String, dynamic>.from(parsed) : null;
  } catch (_) {
    // Also catches a StackOverflowError from decoding a deeply-nested blob.
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
