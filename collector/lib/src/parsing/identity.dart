part of '../../parsing.dart';

/// Recovers a token matching [patternSource] from nested base64/protobuf layers
/// (the stored blob is base64 wrapping protobufs that embed base64-encoded
/// tokens).
String? findEmbeddedToken(String storedB64, String patternSource) {
  final pattern = RegExp(patternSource);
  final seen = <String>{};
  String? result;

  void scan(List<int> bytes, int depth) {
    if (result != null || depth > 6) return;
    final txt = String.fromCharCodes(bytes);
    final m = pattern.firstMatch(txt);
    if (m != null) {
      result = m.group(0);
      return;
    }
    for (final chunk in RegExp(
      r'[A-Za-z0-9+/_\-]{24,}={0,2}',
    ).allMatches(txt)) {
      final c = chunk.group(0)!;
      if (!seen.add(c)) continue;
      for (final variant in [c, c.replaceAll('-', '+').replaceAll('_', '/')]) {
        try {
          final pad = variant + '=' * ((4 - variant.length % 4) % 4);
          final dec = base64Decode(pad);
          if (dec.length > 4) scan(dec, depth + 1);
        } catch (_) {}
        if (result != null) return;
      }
    }
  }

  try {
    final pad = storedB64 + '=' * ((4 - storedB64.length % 4) % 4);
    scan(base64Decode(pad), 0);
  } catch (_) {}
  return result;
}

/// Finds the plan tier display string inside the Antigravity userStatus
/// protobuf.
String? planFromProto(List<int> bytes) {
  const known = {'Free', 'Pro', 'Ultra', 'AI Pro', 'AI Ultra', 'Enterprise'};
  for (final s in protoStrings(bytes)) {
    if (known.contains(s)) return s;
  }
  return null;
}

({String? email, String? plan, String? model, String? note})?
    antigravityUserStatusFromProto(List<int> bytes) {
  String? email;
  String? plan;
  String? model;
  String? note;
  final seenChunks = <String>{};

  late void Function(List<int> value, int depth) scanBytes;
  late void Function(String s, int depth) scanText;

  scanBytes = (List<int> value, int depth) {
    if (depth > 5) return;
    final direct = asciiString(value);
    if (direct != null) scanText(direct, depth);
    for (final s in protoStrings(value)) {
      scanText(s, depth);
    }
  };

  scanText = (String s, int depth) {
    email ??= _firstEmail(s);
    final candidatePlan = _firstKnownPlan(s);
    if (_preferPlan(candidatePlan, plan)) plan = candidatePlan;
    final candidateModel = _bestModelName(s);
    if (_preferModel(candidateModel, model)) model = candidateModel;
    if (note == null && s.contains('higher rate limits')) {
      note = 'Local Antigravity status reports higher rate limits';
    }
    if (depth >= 5) return;
    for (final chunk in RegExp(
      r'[A-Za-z0-9+/_\-]{24,}={0,2}',
    ).allMatches(s)) {
      final raw = chunk.group(0)!;
      if (!seenChunks.add(raw)) continue;
      final decoded = _tryDecodeBase64(raw);
      if (decoded == null || decoded.length < 4) continue;
      scanBytes(decoded, depth + 1);
    }
  };

  scanBytes(bytes, 0);
  if (email == null && plan == null && model == null && note == null) {
    return null;
  }
  return (email: email, plan: plan, model: model, note: note);
}

String? _firstEmail(String s) {
  final m =
      RegExp(r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', caseSensitive: false)
          .firstMatch(s);
  return m?.group(0);
}

List<int>? _tryDecodeBase64(String raw) {
  final compact = raw.trim().replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty) return null;
  for (final candidate in [
    compact,
    compact.replaceAll('-', '+').replaceAll('_', '/'),
    if (compact.length % 4 == 1) compact.substring(1),
    if (compact.length % 4 == 1) compact.substring(0, compact.length - 1),
  ]) {
    try {
      final padded = candidate + '=' * ((4 - candidate.length % 4) % 4);
      return base64Decode(padded);
    } catch (_) {}
  }
  return null;
}

String? _firstKnownPlan(String s) {
  final trimmed = s.trim();
  if (const {'Enterprise', 'Ultra', 'Pro', 'Free'}.contains(trimmed)) {
    return trimmed;
  }
  String? best;
  int? bestIndex;
  for (final plan in const [
    'Google AI Ultra',
    'Google AI Pro',
    'AI Ultra',
    'AI Pro',
    'Enterprise',
  ]) {
    final index = s.indexOf(plan);
    if (index < 0) continue;
    if (bestIndex == null || index < bestIndex) {
      best = plan;
      bestIndex = index;
    }
  }
  return best;
}

bool _preferPlan(String? candidate, String? current) {
  if (candidate == null) return false;
  if (current == null) return true;
  return _planSpecificity(candidate) > _planSpecificity(current);
}

int _planSpecificity(String plan) {
  if (plan.startsWith('Google AI ') || plan.startsWith('AI ')) return 3;
  if (plan == 'Enterprise') return 3;
  return 1;
}

String? _bestModelName(String s) {
  String? best;
  for (final pattern in _modelPatterns) {
    for (final m in pattern.allMatches(s)) {
      final candidate = m.group(0)?.trim();
      if (_preferModel(candidate, best)) best = candidate;
    }
  }
  return best;
}

final _modelPatterns = [
  RegExp(
    r'Gemini\s+[0-9]+(?:\.[0-9]+)?(?:\s+[A-Za-z0-9]+)*(?:\s+\([^)]+\))?',
  ),
  RegExp(
    r'Claude\s+[0-9]+(?:\.[0-9]+)?(?:\s+[A-Za-z0-9]+)*(?:\s+\([^)]+\))?',
  ),
  RegExp(
    r'GPT-OSS\s+[0-9]+(?:\.[0-9]+)?(?:\s+[A-Za-z0-9]+)*(?:\s+\([^)]+\))?',
  ),
];

bool _preferModel(String? candidate, String? current) {
  if (candidate == null) return false;
  if (current == null) return true;
  return _modelScore(candidate) > _modelScore(current);
}

int _modelScore(String model) {
  var score = 0;
  if (model.contains('(High)')) score += 100;
  if (model.contains('(Medium)')) score += 50;
  if (model.contains('(Low)')) score += 10;
  if (model.contains(' Pro')) score += 40;
  if (model.contains(' Flash')) score += 20;
  return score;
}
