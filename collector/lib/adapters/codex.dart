import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../auth/openai_auth.dart';
import '../models.dart';
import '../parsing.dart';
import '../provider_ids.dart';
import '../util.dart';

typedef CodexUsageFetcher = Future<Map<String, dynamic>?> Function();

/// Fetches a fresh access token from quotabot's own Codex grant, or null when
/// no grant is connected. Injectable for tests.
typedef CodexGrantToken = Future<String?> Function();

/// Reads Codex (OpenAI) usage. Prefers the authoritative live usage endpoint
/// (`/backend-api/wham/usage`, the same data the CLI's own status view polls),
/// which is cross-device. It resolves auth in priority order:
///   1. the access token Codex stores in ~/.codex/auth.json (zero-setup path);
///   2. quotabot's own refreshable grant from `quotabot login codex` - the
///      idle-machine path that keeps the account-wide read live when the CLI
///      has not refreshed its token here.
/// Falls back to the rate_limits events Codex writes to its local session
/// rollout files - a this-machine-only view that undercounts when the account
/// is used on another device - only when every live read is unavailable.
///
/// Codex meters different models against separate limit buckets, and each
/// session only records the bucket it used, so the session fallback reads the
/// latest snapshot of each bucket across recent sessions and keeps the binding
/// (most-constrained) window per slot.
class CodexAdapter {
  static const id = codexProviderId;
  static const name = codexProviderName;
  static const _usageEndpoint = 'https://chatgpt.com/backend-api/wham/usage';
  final Directory? _sessionsDir;
  final CodexUsageFetcher? _usageFetcher;
  final http.Client? _http;
  final CodexGrantToken _grantToken;

  CodexAdapter({
    Directory? sessionsDir,
    CodexUsageFetcher? usageFetcher,
    http.Client? client,
    CodexGrantToken? grantToken,
  })  : _sessionsDir = sessionsDir,
        _usageFetcher = usageFetcher,
        _http = client,
        _grantToken =
            grantToken ?? (() => OpenAiAuth(client: client).freshAccessToken());

  /// How many recent rollout files to scan for per-bucket snapshots. Enough to
  /// catch buckets touched across a normal working window without reading the
  /// whole history.
  static const _scanFiles = 16;

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
    // Prefer the authoritative cross-device live read; fall back to the local
    // per-machine session snapshots only when it is unavailable.
    final live = await _tryLive(asOf);
    if (live != null) return live;
    return _fromSessions(asOf);
  }

  /// Reads the authoritative live usage endpoint. Returns null (so the caller
  /// falls back to sessions) when there is no token, the token is expired, or
  /// the network fails - it never throws.
  Future<ProviderQuota?> _tryLive(int asOf) async {
    try {
      final resp =
          _usageFetcher != null ? await _usageFetcher() : await _fetchUsage();
      if (resp == null) return null;
      final windows = codexUsageWindows(resp);
      if (windows.isEmpty) return null;
      final plan = resp['plan_type']?.toString();
      final email = resp['email']?.toString();
      final credits = codexResetCredits(resp);
      return ProviderQuota(
        provider: id,
        displayName: name,
        account:
            (email != null && email.isNotEmpty) ? email : (plan ?? 'default'),
        plan: plan,
        asOf: asOf,
        windows: windows,
        resetCreditsAvailable: credits ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  // A metadata GET that reuses the account-wide usage endpoint; it spends no
  // usage tokens. Tries the host token first, then quotabot's own grant so an
  // idle machine (where the CLI has not refreshed its token) still reads live.
  // The account id is read from auth.json regardless of which token is used - it
  // is a stable identifier that does not expire.
  Future<Map<String, dynamic>?> _fetchUsage() async {
    final base = _sessionsDir?.parent.path ?? '${home()}/.codex';
    final tokens = _readHostTokens(File('$base/auth.json'));
    final acct = tokens?.accountId;
    final grantToken = await _grantToken();
    final ordered = <String>[
      if (tokens?.accessToken != null && tokens!.accessToken!.isNotEmpty)
        tokens.accessToken!,
      if (grantToken != null && grantToken.isNotEmpty) grantToken,
    ];
    for (final token in ordered) {
      final body = await _usageWith(token, acct);
      if (body != null) return body;
    }
    return null;
  }

  Future<Map<String, dynamic>?> _usageWith(String token, String? acct) async {
    final get = _http?.get ?? http.get;
    final resp = await get(
      Uri.parse(_usageEndpoint),
      headers: {
        'Authorization': 'Bearer $token',
        if (acct != null) 'chatgpt-account-id': acct,
      },
    ).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return null;
    final body = jsonDecode(resp.body);
    return body is Map<String, dynamic> ? body : null;
  }

  _HostTokens? _readHostTokens(File authFile) {
    if (!authFile.existsSync()) return null;
    final auth = jsonDecode(authFile.readAsStringSync());
    if (auth is! Map) return null;
    final tokens = auth['tokens'];
    if (tokens is! Map) return null;
    return _HostTokens(
      accessToken: tokens['access_token'] as String?,
      accountId: tokens['account_id'] as String?,
    );
  }

  Future<ProviderQuota> _fromSessions(int asOf) async {
    try {
      final sessionsDir =
          _sessionsDir ?? Directory('${home()}/.codex/sessions');
      if (!sessionsDir.existsSync()) {
        return ProviderQuota.error(id, name, 'no ~/.codex/sessions', asOf);
      }

      final rollouts =
          sessionsDir.listSync(recursive: true).whereType<File>().where((f) {
        final n = f.uri.pathSegments.last;
        return n.startsWith('rollout-') && n.endsWith('.jsonl');
      }).toList()
            ..sort(
              (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
            );

      if (rollouts.isEmpty) {
        return ProviderQuota.error(id, name, 'no rollout files', asOf);
      }

      // Collect the latest snapshot of each distinct limit bucket. Files are
      // newest first, so the first snapshot seen for a bucket is its latest.
      final byBucket = <String, _Snapshot>{};
      for (final file in rollouts.take(_scanFiles)) {
        final snap = _lastRateLimits(file);
        if (snap == null) continue;
        final key = (snap.rl['limit_id'] ?? snap.rl['limit_name'] ?? 'default')
            .toString();
        byBucket.putIfAbsent(key, () => snap);
      }
      if (byBucket.isEmpty) {
        return ProviderQuota.error(
          id,
          name,
          'no rate_limits in recent sessions',
          asOf,
        );
      }
      return _toQuota(byBucket.values.toList());
    } catch (_) {
      return ProviderQuota.error(
        id,
        name,
        'unable to read Codex session data',
        asOf,
      );
    }
  }

  /// Returns the last `rate_limits` snapshot in a rollout file with the capture
  /// time (epoch seconds) from that same line's `timestamp`, or null. The
  /// capture time matters: Codex only rewrites rate_limits on a turn, so a file
  /// touched recently can still hold an hours-old snapshot. Falls back to the
  /// file mtime when the line carries no timestamp.
  _Snapshot? _lastRateLimits(File file) {
    if (file.lengthSync() > 10 * 1024 * 1024) return null;
    final lines = file.readAsLinesSync();
    for (final line in lines.reversed) {
      if (!line.contains('"rate_limits"')) continue;
      try {
        final obj = jsonDecode(line);
        final rl = findKey(obj, 'rate_limits');
        if (rl is! Map) continue;
        final ts = parseIsoToEpoch(findKey(obj, 'timestamp')) ??
            (file.statSync().modified.millisecondsSinceEpoch ~/ 1000);
        return _Snapshot(Map<String, dynamic>.from(rl), ts);
      } catch (_) {
        // skip malformed line
      }
    }
    return null;
  }

  ProviderQuota _toQuota(List<_Snapshot> snapshots) {
    final now = nowEpoch();
    // Freshness is governed by the most recently captured bucket.
    final capturedAt =
        snapshots.map((s) => s.capturedAt).reduce((a, b) => a > b ? a : b);
    final newest = snapshots.reduce(
      (a, b) => a.capturedAt >= b.capturedAt ? a : b,
    );
    final age = now - capturedAt;
    // Mark stale once the freshest snapshot is older than the shortest (primary)
    // window, since by then the numbers no longer reflect live usage. Defaults
    // to one hour when the primary window length is unknown.
    final primaryMinutes =
        (newest.rl['primary']?['window_minutes'] as num?)?.toInt();
    final staleAfter = primaryMinutes != null ? primaryMinutes * 60 : 3600;
    final stale = age > staleAfter;
    final base = ProviderQuota(
      provider: id,
      displayName: name,
      account: (newest.rl['plan_type'] ?? 'default').toString(),
      plan: newest.rl['plan_type']?.toString(),
      asOf: capturedAt,
      windows: codexBindingWindows(snapshots.map((s) => s.rl), now),
      // Session logs are this machine's view only; the live path is authoritative.
      perMachine: true,
    );
    return stale ? base.asStale('snapshot ${_ageLabel(age)} old') : base;
  }

  String _ageLabel(int seconds) {
    if (seconds < 3600) return '${seconds ~/ 60}m';
    if (seconds < 86400) return '${seconds ~/ 3600}h';
    return '${seconds ~/ 86400}d';
  }
}

/// One bucket's latest rate_limits map plus when it was captured.
class _Snapshot {
  final Map<String, dynamic> rl;
  final int capturedAt;
  _Snapshot(this.rl, this.capturedAt);
}

/// The host `auth.json` token fields quotabot reuses: the access token (may be
/// expired) and the stable ChatGPT account id used for the usage header.
class _HostTokens {
  final String? accessToken;
  final String? accountId;
  _HostTokens({this.accessToken, this.accountId});
}
