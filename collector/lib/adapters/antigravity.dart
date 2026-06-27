import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

import '../auth/google_auth.dart';
import '../models.dart';
import '../parsing.dart';
import '../sqlite_loader.dart';
import '../util.dart';

/// Antigravity (Google) adapter.
///
/// Antigravity is a VS Code fork that stores its account and Google OAuth token
/// in a globalStorage SQLite database. We read the email and plan from the
/// `antigravityAuthStatus` protobuf and query live model quota from the Cloud
/// Code API. After `quotabot login antigravity` the adapter uses its own grant
/// (see [GoogleAuth]); otherwise it falls back to the access token the IDE
/// currently holds. These quota calls are metadata lookups and cost no tokens.
/// Primary account from disk; additional from cross-platform profile scan (win/mac/linux)
/// and per-account caches for full multi support.
class AntigravityAdapter {
  static const id = 'antigravity';
  static const name = 'Antigravity';
  static bool _sqliteReady = false;

  /// Returns the set of emails for currently active Antigravity profiles.
  /// Scans IDE DBs (most recent) + ~/.gemini/google_accounts.json (only the "active", never "old").
  /// Used to filter stale caches to only currently "detected" active accounts (auto-hides previous logins).
  static Set<String> get currentAccounts {
    final accts = <String>{};
    // Prefer active account from Gemini/Antigravity CLI (~/.gemini)
    try {
      final af = File(_geminiAccountsPath());
      if (af.existsSync()) {
        final aj = jsonDecode(af.readAsStringSync()) as Map<String, dynamic>;
        final act = aj['active']?.toString();
        if (act != null && act.isNotEmpty) accts.add(act);
        // Only the "active" account is collected; the IDE's "old" list is
        // deliberately ignored so previously signed-in accounts stay hidden.
      }
    } catch (_) {}
    // Fallback or supplement from most-recent IDE DBs
    if (accts.isEmpty) {
      for (final p in _findAllDbPaths()) {
        if (File(p).existsSync()) {
          final email = _readEmail(p);
          if (email != null && email.isNotEmpty) accts.add(email);
          break; // only the newest profile
        }
      }
    }
    return accts;
  }

  static String? _readEmail(String dbPath) {
    _ensureSqlite();
    final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    try {
      final rows = db.select(
        "SELECT value FROM ItemTable WHERE key = 'antigravityAuthStatus';",
      );
      if (rows.isEmpty) return null;
      final raw = rows.first['value'];
      final s = raw is List<int>
          ? utf8.decode(raw, allowMalformed: true)
          : raw.toString();
      final parsed = jsonDecode(s) as Map<String, dynamic>;
      return parsed['email']?.toString();
    } catch (_) {
      return null;
    } finally {
      db.dispose();
    }
  }

  static const _api = 'https://cloudcode-pa.googleapis.com/v1internal';

  /// Platform-aware path to the Antigravity globalStorage SQLite. Falls back
  /// gracefully if the file is absent (no install or different platform layout).
  static String _antigravityDbPath() {
    if (Platform.isWindows) {
      final appData =
          Platform.environment['APPDATA'] ?? '${home()}/AppData/Roaming';
      return '$appData/Antigravity/User/globalStorage/state.vscdb';
    } else if (Platform.isMacOS) {
      return '${home()}/Library/Application Support/Antigravity/User/globalStorage/state.vscdb';
    } else {
      final dataHome =
          Platform.environment['XDG_DATA_HOME'] ?? '${home()}/.local/share';
      return '$dataHome/Antigravity/User/globalStorage/state.vscdb';
    }
  }

  static List<String> _findAllDbPaths() {
    final paths = <String>[_antigravityDbPath()];
    String profilesBase;
    if (Platform.isWindows) {
      final appData =
          Platform.environment['APPDATA'] ?? '${home()}/AppData/Roaming';
      profilesBase = '$appData/Antigravity/Profiles';
    } else if (Platform.isMacOS) {
      profilesBase =
          '${home()}/Library/Application Support/Antigravity/Profiles';
    } else {
      final dataHome =
          Platform.environment['XDG_DATA_HOME'] ?? '${home()}/.local/share';
      profilesBase = '$dataHome/Antigravity/Profiles';
    }
    final profilesDir = Directory(profilesBase);
    if (profilesDir.existsSync()) {
      for (final e in profilesDir.listSync()) {
        if (e is Directory) {
          final p = '${e.path}/globalStorage/state.vscdb';
          if (File(p).existsSync()) paths.add(p);
          final p2 = '${e.path}/User/globalStorage/state.vscdb';
          if (File(p2).existsSync()) paths.add(p2);
        }
      }
    }
    // Sort by last modified time descending so the most recently used profile
    // (e.g. after signing in with a different account) is tried first as primary.
    paths.sort((a, b) {
      try {
        final ta = File(a).statSync().modified;
        final tb = File(b).statSync().modified;
        return tb.compareTo(ta);
      } catch (_) {
        return 0;
      }
    });
    return paths;
  }

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
    try {
      final dbPaths = _findAllDbPaths();
      String? dbPath;
      for (final p in dbPaths) {
        if (File(p).existsSync()) {
          dbPath = p;
          break;
        }
      }
      final hasGeminiCreds = File(_geminiOauthPath()).existsSync() ||
          File(_geminiAccountsPath()).existsSync();
      if (dbPath == null && !hasGeminiCreds) {
        return ProviderQuota.error(id, name, 'Antigravity not installed', asOf);
      }

      (String?, String?, String?) local = (null, null, null);
      if (dbPath != null && File(dbPath).existsSync()) {
        local = _readLocalState(dbPath);
      }
      final (email, plan, ideAccessToken) = local;

      // Determine current account from the freshest source (gemini CLI active preferred over stale IDE DB)
      var account = _readActiveAccount() ?? email ?? 'default';

      // Account/plan-only result, used as a graceful fallback.
      ProviderQuota offline(String note) => ProviderQuota(
            provider: id,
            displayName: name,
            account: account,
            plan: plan,
            asOf: asOf,
            ok: true,
            error: note,
            windows: const [],
          );

      // Choose access token.
      // Prefer the explicit grant from `quotabot login antigravity` so live quota works
      // with the account the user just signed in with, even if ~/.gemini has a different active account.
      String? access;
      bool usingQuotabot = false;
      bool usingCli = false;

      access = await GoogleAuth().freshAccessToken();
      if (access != null) {
        usingQuotabot = true;
      }

      if (access == null) {
        // Fallback to passive CLI gemini or IDE DB
        final antigravityMtime = dbPath != null ? _getPathMtime(dbPath) : null;
        final cliMtime = _getDevinCredMtime();
        if (cliMtime != null &&
            (antigravityMtime == null || cliMtime.isAfter(antigravityMtime))) {
          access = _getCliAccess();
          usingCli = access != null;
        }
        if (access == null) {
          access = ideAccessToken;
        }
      }
      final load = access == null ? null : await _loadCodeAssist(access);
      if (access == null || load == null) {
        return offline(
          'no live quota - reopen Antigravity, or configure QUOTABOT_GOOGLE_CLIENT_ID/SECRET and run: quotabot login antigravity',
        );
      }

      // Override account with email from the actual token / google_accounts (handles CLI logins or stale local DB)
      // When using quotabot grant, always try userinfo so we show the account from the login the user just performed.
      if (usingCli && !usingQuotabot) {
        final dEmail = await _getCliEmail(access);
        if (dEmail != null) {
          account = dEmail;
        }
      } else {
        try {
          final userInfo = await _getUserInfo(access);
          if (userInfo != null && userInfo['email'] != null) {
            account = userInfo['email'].toString();
          }
        } catch (_) {}
      }

      // Also try to extract email from the load response
      if (account == 'default' || account == (email ?? 'default')) {
        final loadEmail = findKey(load, 'email')?.toString() ??
            findKey(load, 'userEmail')?.toString() ??
            findKey(load, 'user')?.toString();
        if (loadEmail != null && loadEmail.isNotEmpty) {
          account = loadEmail;
        }
      }

      final project = findKey(load, 'cloudaicompanionProject')?.toString();
      final models = await _post(access, 'fetchAvailableModels', {
        if (project != null) 'project': project,
      });
      final windows = antigravityWindows(models, asOf);

      // Try to surface tier/individual quota info if present in the load response
      String? tier = plan ?? findKey(load, 'currentTier')?.toString();
      final quotaInfo = findKey(load, 'quotaInfo');
      if (quotaInfo is Map && tier == null) {
        tier = quotaInfo['tier']?.toString() ?? quotaInfo['plan']?.toString();
      }
      if (windows.isEmpty) return offline('no live quota - account/plan only');

      return ProviderQuota(
        provider: id,
        displayName: name,
        account: account,
        plan: tier,
        asOf: asOf,
        windows: windows,
      );
    } catch (_) {
      return ProviderQuota.error(
        id,
        name,
        'unable to read Antigravity state',
        asOf,
      );
    }
  }

  // --- Cloud Code API ---------------------------------------------------------

  static Future<Map<String, dynamic>?> _loadCodeAssist(String access) =>
      _post(access, 'loadCodeAssist', {
        'metadata': {
          'ideType': 'ANTIGRAVITY',
          'platform': 'PLATFORM_UNSPECIFIED',
          'pluginType': 'GEMINI',
        },
      });

  static Future<Map<String, dynamic>?> _getUserInfo(String access) async {
    final resp = await http.get(
      Uri.parse('https://www.googleapis.com/oauth2/v2/userinfo'),
      headers: {'Authorization': 'Bearer $access'},
    ).timeout(const Duration(seconds: 5));
    if (resp.statusCode != 200) return null;
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>?> _post(
    String access,
    String method,
    Map<String, dynamic> body,
  ) async {
    final resp = await http
        .post(
          Uri.parse('$_api:$method'),
          headers: {
            'Authorization': 'Bearer $access',
            'Content-Type': 'application/json',
            'User-Agent': 'antigravity',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return null;
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // --- Local state ------------------------------------------------------------

  /// Returns (email, plan, ideAccessToken) from the SQLite DB. The IDE access
  /// token is a fallback used only when quotabot has no grant of its own.
  (String?, String?, String?) _readLocalState(String dbPath) {
    _ensureSqlite();
    final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    try {
      String? authRaw = _value(db, 'antigravityAuthStatus');
      String? tokenRaw = _value(db, 'antigravityUnifiedStateSync.oauthToken');

      String? email, plan;
      if (authRaw != null) {
        final status = jsonDecode(authRaw) as Map<String, dynamic>;
        email = status['email']?.toString();
        final b64 = status['userStatusProtoBinaryBase64'];
        if (b64 is String) plan = planFromProto(base64.decode(b64));
      }
      final access = tokenRaw == null
          ? null
          : findEmbeddedToken(tokenRaw, r'ya29\.[A-Za-z0-9._\-]{30,}');
      return (email, plan, access);
    } finally {
      db.dispose();
    }
  }

  String? _value(Database db, String key) {
    final rows = db.select('SELECT value FROM ItemTable WHERE key=?', [key]);
    if (rows.isEmpty) return null;
    return _asString(rows.first['value']);
  }

  static void _ensureSqlite() {
    if (_sqliteReady) return;
    configureSqliteLibrary();
    _sqliteReady = true;
  }

  String? _asString(Object? v) {
    if (v is String) return v;
    if (v is List<int>) return utf8.decode(v, allowMalformed: true);
    return v?.toString();
  }

  // --- Gemini / Antigravity CLI auth ( ~/.gemini ) ---------------------------
  // The active login (after CLI `agy` or antigravity login, or account switch) lives here.
  // IDE state.vscdb may be stale after browser/CLI switches. Prefer by mtime.

  static String _geminiDir() => '${home()}/.gemini';
  static String _geminiOauthPath() => '${_geminiDir()}/oauth_creds.json';
  static String _geminiAccountsPath() => '${_geminiDir()}/google_accounts.json';

  static DateTime? _getPathMtime(String p) {
    try {
      final f = File(p);
      return f.existsSync() ? f.statSync().modified : null;
    } catch (_) {
      return null;
    }
  }

  static DateTime? _getDevinCredMtime() => _getGeminiCredMtime();

  static String? _getCliAccess() => _getGeminiAccess();

  static Future<String?> _getCliEmail(String access) => _getGeminiEmail(access);

  static DateTime? _getGeminiCredMtime() {
    try {
      DateTime? mt;
      final o = File(_geminiOauthPath());
      if (o.existsSync()) mt = o.statSync().modified;
      final a = File(_geminiAccountsPath());
      if (a.existsSync()) {
        final at = a.statSync().modified;
        if (mt == null || at.isAfter(mt)) mt = at;
      }
      return mt;
    } catch (_) {
      return null;
    }
  }

  static String? _getGeminiAccess() {
    try {
      final f = File(_geminiOauthPath());
      if (!f.existsSync()) return null;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final tok = j['access_token']?.toString();
      if (tok != null && tok.isNotEmpty) return tok;
    } catch (_) {}
    return null;
  }

  static Future<String?> _getGeminiEmail(String access) async {
    // Active from accounts file is authoritative for the current CLI session.
    try {
      final af = File(_geminiAccountsPath());
      if (af.existsSync()) {
        final aj = jsonDecode(af.readAsStringSync()) as Map<String, dynamic>;
        final act = aj['active']?.toString();
        if (act != null && act.isNotEmpty) return act;
      }
    } catch (_) {}
    // Fallback: ask Google with the token.
    try {
      final ui = await _getUserInfo(access);
      if (ui != null && ui['email'] != null) return ui['email'].toString();
    } catch (_) {}
    return null;
  }

  static String? _readActiveAccount() {
    // gemini active first (the account the user last selected in CLI / Antigravity login)
    try {
      final af = File(_geminiAccountsPath());
      if (af.existsSync()) {
        final aj = jsonDecode(af.readAsStringSync()) as Map<String, dynamic>;
        final act = aj['active']?.toString();
        if (act != null && act.isNotEmpty) return act;
      }
    } catch (_) {}
    // recent DB email
    for (final p in _findAllDbPaths()) {
      if (File(p).existsSync()) {
        final e = _readEmail(p);
        if (e != null && e.isNotEmpty) return e;
      }
    }
    return null;
  }
}
