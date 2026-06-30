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

  // The Gemini CLI's public installed-app OAuth client (shipped in the
  // open-source google-gemini/gemini-cli). quotabot uses it only to refresh the
  // user's own Gemini/Antigravity token from the refresh token the CLI already
  // stored, exactly as the CLI itself does. No new grant is created.
  static const _geminiClientId =
      '681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com';
  static const _geminiClientSecret = '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';

  // In-process cache of a freshly refreshed CLI access token.
  static String? _cliTokenCache;
  static int _cliTokenExpMs = 0;

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

      // A network or timeout error here must not hard-fail the adapter: fall
      // through to the passive CLI/IDE token instead of throwing.
      try {
        final auth = GoogleAuth();
        access = await auth.freshAccessToken(account: account) ??
            await auth.freshAccessToken();
      } catch (_) {
        access = null;
      }
      if (access != null) {
        usingQuotabot = true;
      }

      if (access == null) {
        // Fallback to passive CLI gemini or IDE DB
        final antigravityMtime = dbPath != null ? _getPathMtime(dbPath) : null;
        final cliMtime = _getDevinCredMtime();
        if (cliMtime != null &&
            (antigravityMtime == null || cliMtime.isAfter(antigravityMtime))) {
          access = await _getCliAccess();
          usingCli = access != null;
        }
        if (access == null) {
          access = ideAccessToken;
        }
      }
      final load = access == null ? null : await _loadCodeAssist(access);
      if (access == null || load == null) {
        return offline(
          'no live quota - run: quotabot login antigravity (then sign in with this account)',
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
          final userEmail = await GoogleAuth().emailForAccessToken(access);
          if (userEmail != null) {
            account = userEmail;
          }
        } catch (_) {}
      }

      // Also try to extract email from the load response. Only accept a
      // string-valued key: `user` is often an object, and stringifying it would
      // assign a "{email: ...}" blob as the account.
      if (account == 'default' || account == (email ?? 'default')) {
        final loadEmail = findKey(load, 'email') ?? findKey(load, 'userEmail');
        if (loadEmail is String && loadEmail.isNotEmpty) {
          account = loadEmail;
        }
      }

      // Resolve a Cloud Code project that can read model quota. The project
      // from loadCodeAssist is not enough on its own; the account must be
      // onboarded for the tier first (the IDE/CLI does this). Onboarding is
      // cached per account so it only runs when needed.
      var project = _extractProjectId(findKey(load, 'cloudaicompanionProject'));
      final onboarded = _projectCache[account];
      if (onboarded != null) {
        project = onboarded;
      } else {
        final tier = _pickOnboardTier(
          load['allowedTiers'],
          (load['currentTier'] is Map)
              ? (load['currentTier'] as Map)['id']?.toString()
              : null,
        );
        final p = await _onboardUser(access, tier);
        if (p != null) {
          project = p;
          _projectCache[account] = p;
        }
      }

      final models = await _post(access, 'fetchAvailableModels', {
        if (project != null) 'project': project,
      });
      final windows = antigravityWindows(models, asOf);

      // Tier name from the load response (do not surface the raw `free-tier`
      // id as a plan: the Code Assist tier field does not reflect the user's
      // actual Antigravity entitlement, so it would mislabel paid accounts).
      final tierObj = findKey(load, 'currentTier');
      final tierName = tierObj is Map ? tierObj['name']?.toString() : null;

      if (windows.isEmpty) {
        // The token authenticated (account resolved) but the per-model quota
        // endpoint returned nothing. Be honest rather than calling it "free".
        return offline(
            'connected; Antigravity is not returning live quota here yet');
      }

      return ProviderQuota(
        provider: id,
        displayName: name,
        account: account,
        plan: plan ?? tierName,
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

  // Cached onboarded project id per account, so onboarding runs at most once
  // per process instead of on every refresh.
  static final Map<String, String> _projectCache = {};

  static const _metadata = {
    'ideType': 'ANTIGRAVITY',
    'platform': 'PLATFORM_UNSPECIFIED',
    'pluginType': 'GEMINI',
  };

  static Future<Map<String, dynamic>?> _loadCodeAssist(String access) =>
      _post(access, 'loadCodeAssist', {'metadata': _metadata});

  /// Reads a Cloud Code project id from a `cloudaicompanionProject` value that
  /// may be a bare string or a `{id: ...}` object.
  static String? _extractProjectId(dynamic v) {
    if (v is String && v.isNotEmpty) return v;
    if (v is Map && v['id'] is String && (v['id'] as String).isNotEmpty) {
      return v['id'] as String;
    }
    return null;
  }

  /// Chooses the tier to onboard with: the default tier, else the first with an
  /// id, else LEGACY, else whatever the load response reported.
  static String? _pickOnboardTier(dynamic allowedTiers, String? fromLoad) {
    if (allowedTiers is! List || allowedTiers.isEmpty) return fromLoad;
    bool hasId(dynamic t) =>
        t is Map && t['id'] is String && (t['id'] as String).isNotEmpty;
    for (final t in allowedTiers) {
      if (hasId(t) && (t as Map)['isDefault'] == true) return t['id'] as String;
    }
    for (final t in allowedTiers) {
      if (hasId(t)) return (t as Map)['id'] as String;
    }
    return 'LEGACY';
  }

  /// Onboards the account for [tier] so the model-quota endpoint is permitted,
  /// returning the provisioned project id. Retries while provisioning settles.
  static Future<String?> _onboardUser(String access, String? tier) async {
    final payload = {if (tier != null) 'tierId': tier, 'metadata': _metadata};
    for (var attempt = 0; attempt < 5; attempt++) {
      final resp = await _post(access, 'onboardUser', payload);
      if (resp == null) return null; // 401/403 or error: do not spin
      if (resp['done'] == true) {
        final proj = _extractProjectId(
          (resp['response'] is Map)
              ? (resp['response'] as Map)['cloudaicompanionProject']
              : null,
        );
        if (proj != null) return proj;
        return null;
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    return null;
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

  static Future<String?> _getCliAccess() => _getGeminiAccessFresh();

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

  /// Returns a usable Gemini/Antigravity access token, refreshing it when the
  /// one the CLI stored has expired. Access tokens live ~1 hour, so reading the
  /// file verbatim returns a dead token most of the time; we mint a fresh one
  /// from the stored refresh token (the CLI's own flow) when needed.
  static Future<String?> _getGeminiAccessFresh() async {
    try {
      final f = File(_geminiOauthPath());
      if (!f.existsSync()) return null;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final stored = j['access_token']?.toString();
      final exp = j['expiry_date'];
      final nowMs = DateTime.now().millisecondsSinceEpoch;

      // Stored token still valid (60s safety margin).
      if (stored != null &&
          stored.isNotEmpty &&
          exp is int &&
          nowMs < exp - 60000) {
        return stored;
      }
      // A token we refreshed earlier this session is still good.
      if (_cliTokenCache != null && nowMs < _cliTokenExpMs - 60000) {
        return _cliTokenCache;
      }
      final refresh = j['refresh_token']?.toString();
      if (refresh == null || refresh.isEmpty) return stored;

      final resp = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': refresh,
          'client_id': _geminiClientId,
          'client_secret': _geminiClientSecret,
        },
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return stored; // best effort
      final fresh = jsonDecode(resp.body) as Map<String, dynamic>;
      final tok = fresh['access_token']?.toString();
      if (tok == null || tok.isEmpty) return stored;
      final expiresIn = (fresh['expires_in'] as num?)?.toInt() ?? 3600;
      _cliTokenCache = tok;
      _cliTokenExpMs = nowMs + expiresIn * 1000;
      return tok;
    } catch (_) {
      return null;
    }
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
    return GoogleAuth().emailForAccessToken(access);
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
