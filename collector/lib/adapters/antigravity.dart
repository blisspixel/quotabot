import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

import '../auth/google_auth.dart';
import '../models.dart';
import '../parsing.dart';
import '../provider_ids.dart';
import '../util.dart';

typedef AntigravityAccountCandidate = ({
  String account,
  String? plan,
  String? ideAccessToken,
  String? localModel,
  String? localNote,
  List<ModelQuota> modelQuotas,
  bool useCliToken,
});

typedef AntigravityLocalState = ({
  String? email,
  String? plan,
  String? ideAccessToken,
  String? ideRefreshToken,
  String? localModel,
  String? localNote,
  List<ModelQuota> modelQuotas,
});

typedef AntigravityAccountSource = List<AntigravityAccountCandidate> Function();
typedef AntigravityTokenResolver = Future<String?> Function(
  String account,
  bool allowDefaultGrant,
);
typedef AntigravityEmailResolver = Future<String?> Function(
  String access,
  bool usingCli,
  bool usingQuotabot,
);
typedef AntigravityLoadCodeAssist = Future<Map<String, dynamic>?> Function(
  String access,
);
typedef AntigravityOnboardUser = Future<String?> Function(
  String access,
  String? tier,
);
typedef AntigravityFetchModels = Future<Map<String, dynamic>?> Function(
  String access,
  String? project,
);

/// Antigravity (Google) adapter.
///
/// Antigravity is a VS Code fork that stores its account and Google OAuth token
/// in a globalStorage SQLite database. We read the email and plan from the
/// `antigravityAuthStatus` protobuf and query live model quota from the Cloud
/// Code API. After `quotabot login antigravity` the adapter uses its own grant
/// (see [GoogleAuth]); otherwise it falls back to the access token the IDE
/// currently holds. These quota calls are metadata lookups and cost no tokens.
/// Primary account from disk; additional accounts come from the cross-platform
/// profile scan and per-account caches.
class AntigravityAdapter {
  static const id = antigravityProviderId;
  static const name = antigravityProviderName;
  final AntigravityAccountSource? _accountSource;
  final AntigravityTokenResolver? _tokenResolver;
  final AntigravityEmailResolver? _emailResolver;
  final AntigravityLoadCodeAssist? _loadCodeAssistFn;
  final AntigravityOnboardUser? _onboardUserFn;
  final AntigravityFetchModels? _fetchModelsFn;
  final http.Client? _http;
  final List<String> Function()? _dbPathSource;
  final String? Function()? _activeAccountSource;
  final bool Function()? _hasGeminiCredsSource;

  AntigravityAdapter({
    AntigravityAccountSource? accountSource,
    AntigravityTokenResolver? tokenResolver,
    AntigravityEmailResolver? emailResolver,
    AntigravityLoadCodeAssist? loadCodeAssist,
    AntigravityOnboardUser? onboardUser,
    AntigravityFetchModels? fetchModels,
    http.Client? client,
    List<String> Function()? dbPathSource,
    String? Function()? activeAccountSource,
    bool Function()? hasGeminiCreds,
  })  : _accountSource = accountSource,
        _tokenResolver = tokenResolver,
        _emailResolver = emailResolver,
        _loadCodeAssistFn = loadCodeAssist,
        _onboardUserFn = onboardUser,
        _fetchModelsFn = fetchModels,
        _http = client,
        _dbPathSource = dbPathSource,
        _activeAccountSource = activeAccountSource,
        _hasGeminiCredsSource = hasGeminiCreds;

  /// Returns the set of emails for currently active Antigravity profiles.
  /// Scans IDE DBs plus the active ~/.gemini account. The "old" account list is
  /// deliberately ignored so explicitly signed-out accounts stay hidden.
  static Set<String> get currentAccounts {
    try {
      return AntigravityAdapter()
          ._discoverAccounts()
          .map((a) => a.account)
          .toSet();
    } catch (_) {
      return const {};
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

  // In-process cache of a freshly refreshed CLI access token, keyed by the
  // refresh token it was minted from so a switched ~/.gemini account (a
  // different refresh token) never receives the previous account's token.
  static String? _cliTokenCache;
  static String? _cliTokenCacheKey;
  static int _cliTokenExpMs = 0;

  // Default path discovery uses real per-user application directories; tests
  // exercise the same account-discovery logic through injected paths.
  // coverage:ignore-start
  /// Platform-aware paths to Antigravity globalStorage SQLite databases. Recent
  /// builds use "Antigravity IDE"; older installs used "Antigravity".
  static List<String> _antigravityDbPaths() {
    if (Platform.isWindows) {
      final appData =
          Platform.environment['APPDATA'] ?? '${home()}/AppData/Roaming';
      return [
        '$appData/Antigravity IDE/User/globalStorage/state.vscdb',
        '$appData/Antigravity/User/globalStorage/state.vscdb',
      ];
    } else if (Platform.isMacOS) {
      final base = '${home()}/Library/Application Support';
      return [
        '$base/Antigravity IDE/User/globalStorage/state.vscdb',
        '$base/Antigravity/User/globalStorage/state.vscdb',
      ];
    } else {
      final dataHome =
          Platform.environment['XDG_DATA_HOME'] ?? '${home()}/.local/share';
      return [
        '$dataHome/Antigravity IDE/User/globalStorage/state.vscdb',
        '$dataHome/Antigravity/User/globalStorage/state.vscdb',
      ];
    }
  }

  static List<String> _profileBases() {
    if (Platform.isWindows) {
      final appData =
          Platform.environment['APPDATA'] ?? '${home()}/AppData/Roaming';
      return [
        '$appData/Antigravity IDE/Profiles',
        '$appData/Antigravity/Profiles',
      ];
    } else if (Platform.isMacOS) {
      final base = '${home()}/Library/Application Support';
      return [
        '$base/Antigravity IDE/Profiles',
        '$base/Antigravity/Profiles',
      ];
    } else {
      final dataHome =
          Platform.environment['XDG_DATA_HOME'] ?? '${home()}/.local/share';
      return [
        '$dataHome/Antigravity IDE/Profiles',
        '$dataHome/Antigravity/Profiles',
      ];
    }
  }

  static List<String> _findAllDbPaths() {
    final rootPaths = _antigravityDbPaths();
    final hasModernRoot = rootPaths.any(
      (p) => p.contains('Antigravity IDE') && File(p).existsSync(),
    );
    final paths = <String>[
      for (final p in rootPaths)
        if (!hasModernRoot || p.contains('Antigravity IDE')) p,
    ];
    final profileBases = _profileBases();
    final hasModernProfiles = profileBases.any(
      (p) => p.contains('Antigravity IDE') && Directory(p).existsSync(),
    );
    for (final profilesBase in profileBases) {
      if (hasModernProfiles && !profilesBase.contains('Antigravity IDE')) {
        continue;
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
    }
    final seen = <String>{};
    paths.retainWhere(seen.add);
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
  // coverage:ignore-end

  List<AntigravityAccountCandidate> _discoverAccounts() {
    final byAccount = <String, AntigravityAccountCandidate>{};
    final order = <String>[];
    AntigravityAccountCandidate? defaultDb;

    void add(AntigravityAccountCandidate candidate) {
      final account = candidate.account.trim();
      if (account.isEmpty) return;
      final normalized = (
        account: account,
        plan: candidate.plan,
        ideAccessToken: candidate.ideAccessToken,
        localModel: candidate.localModel,
        localNote: candidate.localNote,
        modelQuotas: candidate.modelQuotas,
        useCliToken: candidate.useCliToken,
      );
      final existing = byAccount[account];
      if (existing == null) {
        order.add(account);
        byAccount[account] = normalized;
        return;
      }
      byAccount[account] = (
        account: account,
        plan: existing.plan ?? normalized.plan,
        ideAccessToken: existing.ideAccessToken ?? normalized.ideAccessToken,
        localModel: existing.localModel ?? normalized.localModel,
        localNote: existing.localNote ?? normalized.localNote,
        modelQuotas: existing.modelQuotas.isNotEmpty
            ? existing.modelQuotas
            : normalized.modelQuotas,
        useCliToken: existing.useCliToken || normalized.useCliToken,
      );
    }

    AntigravityLocalState? activeLocalState;
    final active = _activeAccountSource != null
        ? _activeAccountSource()
        : () {
            activeLocalState = _readActiveAntigravityState();
            return activeLocalState?.email ?? _readActiveGeminiAccount();
          }();
    if (active != null) {
      add((
        account: active,
        plan: activeLocalState?.plan,
        ideAccessToken: activeLocalState?.ideAccessToken,
        localModel: activeLocalState?.localModel,
        localNote: activeLocalState?.localNote,
        modelQuotas: activeLocalState?.modelQuotas ?? const [],
        useCliToken: activeLocalState == null,
      ));
      if (activeLocalState?.ideRefreshToken != null) {
        // coverage:ignore-line
        _ideRefreshByAccount[active] = activeLocalState!.ideRefreshToken!;
      }
    }

    for (final dbPath in (_dbPathSource ?? _findAllDbPaths)()) {
      final f = File(dbPath);
      if (!f.existsSync()) continue;
      try {
        final state = _readLocalState(dbPath);
        final email = state.email;
        if (state.ideRefreshToken != null) {
          // coverage:ignore-line
          _ideRefreshByAccount[email ?? 'default'] = state.ideRefreshToken!;
        }
        if (email != null && email.isNotEmpty) {
          add((
            account: email,
            plan: state.plan,
            ideAccessToken: state.ideAccessToken,
            localModel: state.localModel,
            localNote: state.localNote,
            modelQuotas: state.modelQuotas,
            useCliToken: false,
          ));
        } else {
          defaultDb ??= (
            account: 'default',
            plan: state.plan,
            ideAccessToken: state.ideAccessToken,
            localModel: state.localModel,
            localNote: state.localNote,
            modelQuotas: state.modelQuotas,
            useCliToken: false,
          );
        }
      } catch (_) {}
    }

    if (byAccount.isEmpty && defaultDb != null) add(defaultDb);
    if (byAccount.isEmpty && (_hasGeminiCredsSource ?? _hasGeminiCreds)()) {
      add((
        account: 'default',
        plan: null,
        ideAccessToken: null,
        localModel: null,
        localNote: null,
        modelQuotas: const [],
        useCliToken: true,
      ));
    }
    return order.map((account) => byAccount[account]!).toList();
  }

  static List<AntigravityAccountCandidate> _dedupeAccounts(
    List<AntigravityAccountCandidate> accounts,
  ) {
    final byAccount = <String, AntigravityAccountCandidate>{};
    final order = <String>[];
    for (final account in accounts) {
      final key = account.account.trim();
      if (key.isEmpty) continue;
      if (!byAccount.containsKey(key)) order.add(key);
      final existing = byAccount[key];
      byAccount[key] = existing == null
          ? (
              account: key,
              plan: account.plan,
              ideAccessToken: account.ideAccessToken,
              localModel: account.localModel,
              localNote: account.localNote,
              modelQuotas: account.modelQuotas,
              useCliToken: account.useCliToken,
            )
          : (
              account: key,
              plan: existing.plan ?? account.plan,
              ideAccessToken: existing.ideAccessToken ?? account.ideAccessToken,
              localModel: existing.localModel ?? account.localModel,
              localNote: existing.localNote ?? account.localNote,
              modelQuotas: existing.modelQuotas.isNotEmpty
                  ? existing.modelQuotas
                  : account.modelQuotas,
              useCliToken: existing.useCliToken || account.useCliToken,
            );
    }
    return order.map((account) => byAccount[account]!).toList();
  }

  // Default credential probing reads real per-user files; tests exercise this
  // branch through an injected credential-presence source.
  // coverage:ignore-start
  static bool _hasGeminiCreds() =>
      File(_geminiOauthPath()).existsSync() ||
      File(_geminiAccountsPath()).existsSync();
  // coverage:ignore-end

  Future<ProviderQuota> collect() async {
    final results = await collectAccounts();
    return results.first;
  }

  Future<List<ProviderQuota>> collectAccounts() async {
    final asOf = nowEpoch();
    try {
      final accounts =
          _dedupeAccounts(_accountSource?.call() ?? _discoverAccounts());
      if (accounts.isEmpty) {
        return [
          ProviderQuota.error(id, name, 'Antigravity not installed', asOf)
        ];
      }
      final out = <ProviderQuota>[];
      for (var i = 0; i < accounts.length; i++) {
        out.add(
          await _collectAccount(
            accounts[i],
            asOf,
            allowDefaultGrant: i == 0,
          ),
        );
      }
      return out;
    } catch (_) {
      return [
        ProviderQuota.error(
          id,
          name,
          'unable to read Antigravity state',
          asOf,
        )
      ];
    }
  }

  Future<ProviderQuota> _collectAccount(
    AntigravityAccountCandidate source,
    int asOf, {
    required bool allowDefaultGrant,
  }) async {
    var account = source.account;
    final plan = source.plan;

    ProviderQuota offline(String note) => ProviderQuota(
          provider: id,
          displayName: name,
          account: account,
          plan: plan,
          asOf: asOf,
          ok: true,
          error: note,
          status: source.localModel,
          details: [
            if (source.localNote != null) source.localNote!,
          ],
          windows: const [],
          modelQuotas: source.modelQuotas,
          perMachine: true,
        );

    try {
      String? access;
      var usingQuotabot = false;
      var usingCli = false;
      // True only when the token is the provider-default grant, not one stored
      // for this specific account. The default slot is not owner-stamped, so it
      // can belong to a different account; the email cross-check below must
      // verify a default-grant token and fail closed if it cannot. An
      // account-specific grant is trusted for its account without that check.
      var usedDefaultGrant = false;

      // Account-specific grant first; only fall back to the default grant when
      // it is allowed (the first discovered account) and this account has none,
      // and remember that the fallback was used. Matches the prior behavior of
      // `_resolveGrant(account, useCliToken ? false : allowDefaultGrant)` while
      // exposing whether the default was used.
      access = await _resolveGrant(account, false);
      if (access != null) {
        usingQuotabot = true;
      } else if (!source.useCliToken && allowDefaultGrant) {
        access = await _resolveGrant(account, true);
        if (access != null) {
          usingQuotabot = true;
          usedDefaultGrant = true;
        }
      }

      // Mint a fresh token from the IDE's own stored refresh token (Antigravity's
      // client, which the quota endpoint accepts) before falling back to the
      // possibly-expired IDE access token, so a live read works without login.
      if (access == null) {
        final ideRefresh = _ideRefreshByAccount[account];
        if (ideRefresh != null) {
          // coverage:ignore-start
          access = (await GoogleAuth().refresh(ideRefresh))?.accessToken;
          if (access != null) usingQuotabot = true;
          // coverage:ignore-end
        }
      }

      if (access == null && source.useCliToken) {
        access = source.ideAccessToken ?? await _getCliAccess();
        usingCli = access != null;
      }
      if (access == null && source.useCliToken && account == 'default') {
        access = await _resolveGrant(account, allowDefaultGrant);
        usingQuotabot = access != null;
      }
      if (!source.useCliToken) {
        access ??= source.ideAccessToken;
      }

      final load = access == null
          ? null
          : await (_loadCodeAssistFn ?? _loadCodeAssist)(access);
      if (access == null || load == null) {
        return offline(
          'no live quota (this machine only) - run: quotabot login antigravity (then sign in with this account)',
        );
      }

      final tokenEmail = await _resolveTokenEmail(
        access,
        usingCli: usingCli,
        usingQuotabot: usingQuotabot,
      );
      if (tokenEmail != null) {
        if (account != 'default' &&
            tokenEmail.toLowerCase() != account.toLowerCase()) {
          return offline(
            'local Antigravity status found (this machine only); live quota token is signed in to another account',
          );
        }
        account = tokenEmail;
      } else if (usedDefaultGrant && account != 'default') {
        // The token is the provider-default grant, which may belong to a
        // different account, and we could not resolve its email to confirm it is
        // this account's. Fail closed rather than risk labeling another account's
        // quota as this one. An account-specific grant is not affected (it is
        // this account's by construction), so a transient userinfo failure only
        // hides a default-grant-backed first account, and self-heals next read.
        return offline(
          'local Antigravity status found (this machine only); could not verify '
          'the live quota token belongs to this account',
        );
      }

      // Also try to extract email from the load response. Only accept a
      // string-valued key: `user` is often an object, and stringifying it would
      // assign a "{email: ...}" blob as the account.
      if (account == 'default' || account == source.account) {
        final loadEmail = findKey(load, 'email') ?? findKey(load, 'userEmail');
        if (loadEmail is String && loadEmail.isNotEmpty) {
          account = loadEmail;
        }
      }

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
        final p = await (_onboardUserFn ?? _onboardUser)(access, tier);
        if (p != null) {
          project = p;
          _projectCache[account] = p;
        }
      }

      final models = await (_fetchModelsFn ?? _fetchAvailableModels)(
        access,
        project,
      );
      final windows = antigravityWindows(models, asOf);
      // Authoritative live quota from the Cloud Code endpoint. The local
      // userStatus cache is this-machine state, so it is only used by the
      // offline path and must not override a successful live read.
      final liveModelQuotas = antigravityModelQuotasFromLive(models);

      // Tier name from the load response (do not surface the raw `free-tier`
      // id as a plan: the Code Assist tier field does not reflect the user's
      // actual Antigravity entitlement, so it would mislabel paid accounts).
      final tierObj = findKey(load, 'currentTier');
      final tierName = tierObj is Map ? tierObj['name']?.toString() : null;

      if (windows.isEmpty) {
        return offline(source.localModel != null
            ? 'connected (this machine only); Antigravity local status is available, but live quota windows are not exposed here yet'
            : 'connected (this machine only); Antigravity is not returning live quota here yet');
      }

      return ProviderQuota(
        provider: id,
        displayName: name,
        account: account,
        plan: plan ?? tierName,
        asOf: asOf,
        status: source.localModel,
        details: [
          if (source.localNote != null) source.localNote!,
        ],
        windows: windows,
        modelQuotas: liveModelQuotas,
      );
    } catch (e) {
      final health = providerPipeHealthForReadError(e);
      return ProviderQuota(
        provider: id,
        displayName: name,
        account: account,
        plan: plan,
        asOf: asOf,
        ok: false,
        error: health == providerPipeHealthThrottled
            ? 'Antigravity read timed out'
            : 'unable to read Antigravity state',
        pipeHealth: health,
      );
    }
  }

  Future<String?> _resolveGrant(String account, bool allowDefaultGrant) async {
    try {
      if (_tokenResolver != null) {
        return await _tokenResolver(account, allowDefaultGrant);
      }
      final auth = GoogleAuth();
      return await auth.freshAccessToken(account: account) ??
          (allowDefaultGrant ? await auth.freshAccessToken() : null);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _resolveTokenEmail(
    String access, {
    required bool usingCli,
    required bool usingQuotabot,
  }) async {
    try {
      if (_emailResolver != null) {
        return await _emailResolver(access, usingCli, usingQuotabot);
      }
      if (usingCli && !usingQuotabot) {
        return await _getCliEmail(access);
      }
      return await GoogleAuth().emailForAccessToken(access);
    } catch (_) {
      return null;
    }
  }

  // --- Cloud Code API ---------------------------------------------------------

  // Cached onboarded project id per account, so onboarding runs at most once
  // per process instead of on every refresh.
  static final Map<String, String> _projectCache = {};

  // The IDE's own stored refresh token (Antigravity's OAuth client), captured
  // per account from state.vscdb during this instance's discovery. Refreshing
  // it mints a token the quota endpoint accepts, so a live read works without an
  // explicit `login antigravity` even after the IDE's short-lived access token
  // expired. Instance-scoped, so it never leaks between collects.
  final Map<String, String> _ideRefreshByAccount = {};

  static const _metadata = {
    'ideType': 'ANTIGRAVITY',
    'platform': 'PLATFORM_UNSPECIFIED',
    'pluginType': 'GEMINI',
  };

  Future<Map<String, dynamic>?> _loadCodeAssist(String access) =>
      _post(access, 'loadCodeAssist', {'metadata': _metadata});

  Future<Map<String, dynamic>?> _fetchAvailableModels(
    String access,
    String? project,
  ) =>
      _post(access, 'fetchAvailableModels', {
        if (project != null) 'project': project,
      });

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
  Future<String?> _onboardUser(String access, String? tier) async {
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
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return null;
  }

  Future<Map<String, dynamic>?> _post(
    String access,
    String method,
    Map<String, dynamic> body,
  ) async {
    final post = _http?.post ?? http.post;
    final resp = await post(
      Uri.parse('$_api:$method'),
      headers: {
        'Authorization': 'Bearer $access',
        'Content-Type': 'application/json',
        'User-Agent': 'antigravity',
      },
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return null;
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // --- Local state ------------------------------------------------------------

  /// Returns account metadata from the SQLite DB. The IDE access token is a
  /// fallback used only when quotabot has no grant of its own.
  static AntigravityLocalState _readLocalState(String dbPath) {
    final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    try {
      String? authRaw = _value(db, 'antigravityAuthStatus');
      String? tokenRaw = _value(db, 'antigravityUnifiedStateSync.oauthToken');
      String? userStatusRaw =
          _value(db, 'antigravityUnifiedStateSync.userStatus');

      String? email, plan, localModel, localNote;
      List<int>? authProtoBytes;
      if (authRaw != null) {
        final status = jsonDecode(authRaw) as Map<String, dynamic>;
        email = status['email']?.toString();
        final b64 = status['userStatusProtoBinaryBase64'];
        if (b64 is String) {
          final bytes = _decodeBase64Bytes(b64);
          if (bytes != null) {
            authProtoBytes = bytes;
            final parsed = antigravityUserStatusFromProto(bytes);
            plan = planFromProto(bytes) ?? parsed?.plan;
            localModel = parsed?.model;
            localNote = parsed?.note;
          }
        }
      }
      final localStatus = userStatusRaw == null
          ? null
          : _userStatusFromStoredValue(userStatusRaw);
      if (localStatus != null) {
        email ??= localStatus.email;
        plan ??= localStatus.plan;
        localModel ??= localStatus.model;
        localNote ??= localStatus.note;
      }
      // Per-model quota lives in the unified userStatus blob (the richer
      // source); fall back to the proto embedded in antigravityAuthStatus.
      var modelQuotas = const <ModelQuota>[];
      final userStatusBytes =
          userStatusRaw == null ? null : _decodeBase64Bytes(userStatusRaw);
      for (final src in [userStatusBytes, authProtoBytes]) {
        if (src == null) continue;
        final q = antigravityModelQuotas(src);
        if (q.isNotEmpty) {
          modelQuotas = q;
          break;
        }
      }

      final access = tokenRaw == null
          ? null
          : findEmbeddedToken(tokenRaw, r'ya29\.[A-Za-z0-9._\-]{30,}');
      // Capture the IDE's refresh token (Antigravity's client) so a live read
      // can mint a fresh, endpoint-accepted token without an explicit login.
      final ideRefresh = tokenRaw == null
          ? null
          : findEmbeddedToken(tokenRaw, r'1//[A-Za-z0-9._\-]{20,}');
      return (
        email: email,
        plan: plan,
        ideAccessToken: access,
        ideRefreshToken: ideRefresh,
        localModel: localModel,
        localNote: localNote,
        modelQuotas: modelQuotas,
      );
    } finally {
      db.close();
    }
  }

  static ({String? email, String? plan, String? model, String? note})?
      _userStatusFromStoredValue(String raw) {
    final bytes = _decodeBase64Bytes(raw);
    if (bytes == null) return null;
    return antigravityUserStatusFromProto(bytes);
  }

  static List<int>? _decodeBase64Bytes(String raw) {
    final compact = raw.trim().replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty) return null;
    for (final candidate in [
      compact,
      compact.replaceAll('-', '+').replaceAll('_', '/'),
    ]) {
      try {
        final padded = candidate + '=' * ((4 - candidate.length % 4) % 4);
        return base64Decode(padded);
      } catch (_) {}
    }
    return null;
  }

  static String? _value(Database db, String key) {
    final rows = db.select('SELECT value FROM ItemTable WHERE key=?', [key]);
    if (rows.isEmpty) return null;
    return _asString(rows.first['value']);
  }

  static String? _asString(Object? v) {
    if (v is String) return v;
    if (v is List<int>) return utf8.decode(v, allowMalformed: true);
    return v?.toString();
  }

  // --- Gemini / Antigravity CLI auth ( ~/.gemini ) ---------------------------
  // The active login (after CLI `agy` or antigravity login, or account switch) lives here.
  // IDE state.vscdb may be stale after browser/CLI switches. Prefer by mtime.

  // Gemini CLI helpers are tied to the user's real home directory and Google's
  // token endpoint; adapter behavior is tested through injected account sources
  // and mocked Cloud Code calls.
  // coverage:ignore-start
  static String _geminiDir() => '${home()}/.gemini';
  static String _geminiOauthPath() => '${_geminiDir()}/oauth_creds.json';
  static String _geminiAccountsPath() => '${_geminiDir()}/google_accounts.json';

  static Future<String?> _getCliAccess() => _getGeminiAccessFresh();

  static Future<String?> _getCliEmail(String access) => _getGeminiEmail(access);

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
      final refresh = j['refresh_token']?.toString();
      // A token we refreshed earlier this session from this same refresh token
      // is still good. Keying on the refresh token keeps a switched account
      // from getting the previous account's cached token.
      if (_cliTokenCache != null &&
          refresh != null &&
          _cliTokenCacheKey == refresh &&
          nowMs < _cliTokenExpMs - 60000) {
        return _cliTokenCache;
      }
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
      _cliTokenCacheKey = refresh;
      _cliTokenExpMs = nowMs + expiresIn * 1000;
      return tok;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _getGeminiEmail(String access) async {
    // The current Antigravity CLI can update oauth_creds.json without updating
    // the legacy google_accounts.json active pointer. Prefer the signed id-token
    // claim when present, then fall back to the older account file.
    final fromIdToken = _emailFromGeminiOauthIdToken();
    if (fromIdToken != null) return fromIdToken;
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

  static String? _readActiveGeminiAccount() {
    final fromIdToken = _emailFromGeminiOauthIdToken();
    if (fromIdToken != null) return fromIdToken;
    try {
      final af = File(_geminiAccountsPath());
      if (!af.existsSync()) return null;
      final aj = jsonDecode(af.readAsStringSync()) as Map<String, dynamic>;
      final act = aj['active']?.toString();
      return act != null && act.isNotEmpty ? act : null;
    } catch (_) {
      return null;
    }
  }

  static AntigravityLocalState? _readActiveAntigravityState() {
    for (final dbPath in _findAllDbPaths()) {
      final f = File(dbPath);
      if (!f.existsSync()) continue;
      try {
        final state = _readLocalState(dbPath);
        if (state.email != null && state.email!.isNotEmpty) return state;
      } catch (_) {}
    }
    return null;
  }

  static String? _emailFromGeminiOauthIdToken() {
    try {
      final f = File(_geminiOauthPath());
      if (!f.existsSync()) return null;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final idToken = j['id_token']?.toString();
      return _emailFromJwt(idToken);
    } catch (_) {
      return null;
    }
  }

  static String? _emailFromJwt(String? token) {
    if (token == null || token.isEmpty) return null;
    final parts = token.split('.');
    if (parts.length < 2) return null;
    try {
      final payload =
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      final email = decoded['email'];
      return email is String && email.isNotEmpty ? email : null;
    } catch (_) {
      return null;
    }
  }

  // coverage:ignore-end
}
