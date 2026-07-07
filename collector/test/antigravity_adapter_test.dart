import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/antigravity.dart';
import 'package:quotabot_collector/auth/google_auth.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/util.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'ag_proto_builder.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_antigravity_adapter_');
    setQuotabotDirOverrideForTesting(temp);
  });

  tearDown(() {
    setQuotabotDirOverrideForTesting(null);
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  AntigravityAccountCandidate candidate(
    String account, {
    String? plan,
    String? ideAccessToken,
    String? localModel,
    String? localNote,
    List<ModelQuota> modelQuotas = const [],
    bool useCliToken = false,
  }) =>
      (
        account: account,
        plan: plan,
        ideAccessToken: ideAccessToken,
        localModel: localModel,
        localNote: localNote,
        modelQuotas: modelQuotas,
        useCliToken: useCliToken,
      );

  List<int> fieldString(String value) {
    final bytes = utf8.encode(value);
    final out = <int>[0x0a];
    var len = bytes.length;
    while (true) {
      final b = len & 0x7f;
      len >>= 7;
      if (len == 0) {
        out.add(b);
        break;
      }
      out.add(b | 0x80);
    }
    out.addAll(bytes);
    return out;
  }

  String localStatus({
    required String email,
    required String plan,
    required String model,
  }) {
    final nested = fieldString(
      '$email $model $plan subscribers get higher rate limits',
    );
    return base64Encode(fieldString(base64Encode(nested)));
  }

  File writeDb(
    String name, {
    String? email,
    String? token,
    String? userStatus,
  }) {
    final file = File('${temp.path}/$name.vscdb');
    final db = sqlite3.open(file.path);
    try {
      db.execute('CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)');
      if (email != null) {
        db.execute(
          'INSERT INTO ItemTable (key, value) VALUES (?, ?)',
          [
            'antigravityAuthStatus',
            jsonEncode({'email': email}),
          ],
        );
      }
      if (token != null) {
        db.execute(
          'INSERT INTO ItemTable (key, value) VALUES (?, ?)',
          [
            'antigravityUnifiedStateSync.oauthToken',
            base64Encode(utf8.encode('wrapped $token')),
          ],
        );
      }
      if (userStatus != null) {
        db.execute(
          'INSERT INTO ItemTable (key, value) VALUES (?, ?)',
          [
            'antigravityUnifiedStateSync.userStatus',
            userStatus,
          ],
        );
      }
    } finally {
      db.close();
    }
    return file;
  }

  String tokenSuffix(String char) => List.filled(31, char).join();

  Map<String, dynamic> load({
    String? project,
    String? email,
    String tierId = 'PRO',
    String tierName = 'AI Pro',
  }) =>
      {
        if (project != null) 'cloudaicompanionProject': {'id': project},
        if (email != null) 'userEmail': email,
        'allowedTiers': [
          {'id': tierId, 'isDefault': true}
        ],
        'currentTier': {'id': tierId, 'name': tierName},
      };

  Map<String, dynamic> models(double remainingFraction) => {
        'models': {
          'gemini': {
            'quotaInfo': {
              'remainingFraction': remainingFraction,
              'resetTime': DateTime.now()
                  .add(const Duration(hours: 2))
                  .toUtc()
                  .toIso8601String(),
            }
          }
        }
      };

  test('collectAccounts reads every active account in order', () async {
    final tokenCalls = <String>[];
    final loadTokens = <String>[];
    final onboardCalls = <String>[];
    final fetchCalls = <String>[];

    final q = await AntigravityAdapter(
      accountSource: () => [
        candidate('a@example.com'),
        candidate('b@example.com', ideAccessToken: 'ide-b'),
        candidate('c@example.com', ideAccessToken: 'ide-c'),
      ],
      tokenResolver: (account, allowDefault) async {
        tokenCalls.add('$account:$allowDefault');
        if (account == 'b@example.com') return 'grant-b';
        return allowDefault ? 'default-token' : null;
      },
      emailResolver: (_, __, ___) async => null,
      loadCodeAssist: (access) async {
        loadTokens.add(access);
        return load(project: 'load-$access');
      },
      onboardUser: (access, tier) async {
        onboardCalls.add('$access:$tier');
        return 'onboard-$access';
      },
      fetchModels: (access, project) async {
        fetchCalls.add('$access:$project');
        return models(access == 'ide-c' ? 0.25 : 0.75);
      },
    ).collectAccounts();

    expect(q.map((p) => p.account).toList(), [
      'a@example.com',
      'b@example.com',
      'c@example.com',
    ]);
    expect(q.map((p) => p.windows.single.usedPercent).toList(), [25, 25, 75]);
    expect(q.every((p) => !p.perMachine), isTrue);
    expect(tokenCalls, [
      'a@example.com:true',
      'b@example.com:false',
      'c@example.com:false',
    ]);
    expect(loadTokens, ['default-token', 'grant-b', 'ide-c']);
    expect(onboardCalls, [
      'default-token:PRO',
      'grant-b:PRO',
      'ide-c:PRO',
    ]);
    expect(fetchCalls, [
      'default-token:onboard-default-token',
      'grant-b:onboard-grant-b',
      'ide-c:onboard-ide-c',
    ]);
  });

  test('injected empty account discovery is fail-soft', () async {
    final q = await AntigravityAdapter(
      activeAccountSource: () => null,
      dbPathSource: () => const [],
      hasGeminiCreds: () => false,
    ).collectAccounts();

    expect(q.single.error, 'Antigravity not installed');
  });

  test('stored Antigravity grants are resolved by account and default scope',
      () async {
    TokenStore.clear(GoogleAuth.provider);
    TokenStore.clearAccounts(GoogleAuth.provider);
    addTearDown(() {
      TokenStore.clear(GoogleAuth.provider);
      TokenStore.clearAccounts(GoogleAuth.provider);
    });
    final expiry = nowEpoch() + 3600;
    TokenStore.save(
      GoogleAuth.provider,
      Tokens(accessToken: 'default-token', expiresAt: expiry),
    );
    TokenStore.save(
      GoogleAuth.provider,
      Tokens(accessToken: 'work-token', expiresAt: expiry),
      account: 'work-grant@example.com',
    );
    final loaded = <String>[];

    final q = await AntigravityAdapter(
      accountSource: () => [
        candidate('primary-grant@example.com'),
        candidate('work-grant@example.com'),
        candidate('missing-grant@example.com'),
      ],
      emailResolver: (_, __, ___) async => null,
      loadCodeAssist: (access) async {
        loaded.add(access);
        return load();
      },
      onboardUser: (_, __) async => 'project',
      fetchModels: (_, __) async => models(0.7),
    ).collectAccounts();

    expect(loaded, ['default-token', 'work-token']);
    expect(q.last.account, 'missing-grant@example.com');
    expect(q.last.error, contains('quotabot login antigravity'));
  });

  test('discovers active CLI and every profile database account', () async {
    final workDb = writeDb(
      'work',
      email: 'work@example.com',
      token: 'ya29.${tokenSuffix('A')}',
    );
    final homeDb = writeDb(
      'home',
      email: 'home@example.com',
      token: 'ya29.${tokenSuffix('B')}',
    );
    final tokenCalls = <String>[];

    final q = await AntigravityAdapter(
      dbPathSource: () => [workDb.path, homeDb.path],
      activeAccountSource: () => 'active@example.com',
      hasGeminiCreds: () => false,
      tokenResolver: (account, allowDefault) async {
        tokenCalls.add('$account:$allowDefault');
        return 'grant-$account';
      },
      emailResolver: (_, __, ___) async => null,
      loadCodeAssist: (_) async => load(),
      onboardUser: (_, __) async => 'project',
      fetchModels: (_, __) async => models(0.7),
    ).collectAccounts();

    expect(q.map((p) => p.account).toList(), [
      'active@example.com',
      'work@example.com',
      'home@example.com',
    ]);
    expect(tokenCalls, [
      'active@example.com:false',
      'work@example.com:false',
      'home@example.com:false',
    ]);
  });

  test('active CLI account is not replaced by a default grant', () async {
    final loaded = <String>[];

    final q = await AntigravityAdapter(
      accountSource: () => [
        candidate(
          'active-cli@example.com',
          ideAccessToken: 'cli-session-token',
          useCliToken: true,
        ),
      ],
      tokenResolver: (_, allowDefault) async =>
          allowDefault ? 'wrong-default-grant' : null,
      emailResolver: (_, __, ___) async => null,
      loadCodeAssist: (access) async {
        loaded.add(access);
        return load();
      },
      onboardUser: (_, __) async => 'project',
      fetchModels: (_, __) async => models(0.7),
    ).collectAccounts();

    expect(loaded, ['cli-session-token']);
    expect(q.single.account, 'active-cli@example.com');
    expect(q.single.windows.single.usedPercent, closeTo(30, 0.001));
  });

  test('discovers Antigravity IDE local status without authStatus', () async {
    final db = writeDb(
      'antigravity-ide',
      userStatus: localStatus(
        email: 'blisspixel@gmail.com',
        plan: 'Google AI Pro',
        model: 'Gemini 3.1 Pro (High)',
      ),
    );

    final q = await AntigravityAdapter(
      dbPathSource: () => [db.path],
      activeAccountSource: () => null,
      hasGeminiCreds: () => false,
      tokenResolver: (_, __) async => null,
      emailResolver: (_, __, ___) async => null,
      loadCodeAssist: (_) async => load(),
    ).collectAccounts();

    expect(q.single.account, 'blisspixel@gmail.com');
    expect(q.single.plan, 'Google AI Pro');
    expect(q.single.status, 'Gemini 3.1 Pro (High)');
    expect(q.single.details,
        contains('Local Antigravity status reports higher rate limits'));
    expect(
      q.single.error,
      'no live quota (this machine only) - run: quotabot login antigravity (then sign in with this account)',
    );
    expect(q.single.perMachine, isTrue);
  });

  test('explicit local status is not overwritten by a mismatched token',
      () async {
    final q = await AntigravityAdapter(
      accountSource: () => [
        candidate(
          'blisspixel@gmail.com',
          plan: 'Google AI Pro',
          localModel: 'Gemini 3.1 Pro (High)',
        ),
      ],
      tokenResolver: (_, allowDefault) async =>
          allowDefault ? 'stale-default-token' : null,
      emailResolver: (_, __, ___) async => 'other@example.com',
      loadCodeAssist: (_) async => load(),
    ).collectAccounts();

    expect(q.single.account, 'blisspixel@gmail.com');
    expect(q.single.plan, 'Google AI Pro');
    expect(q.single.status, 'Gemini 3.1 Pro (High)');
    expect(
      q.single.error,
      'local Antigravity status found (this machine only); live quota token is signed in to another account',
    );
    expect(q.single.windows, isEmpty);
    expect(q.single.perMachine, isTrue);
  });

  test('discovery keeps a default database account when no email exists',
      () async {
    final db = writeDb('default', token: 'ya29.${tokenSuffix('C')}');

    final q = await AntigravityAdapter(
      dbPathSource: () => [db.path],
      activeAccountSource: () => null,
      hasGeminiCreds: () => false,
      tokenResolver: (_, __) async => null,
      emailResolver: (_, __, ___) async => null,
      loadCodeAssist: (_) async => load(email: 'from-db-token@example.com'),
      onboardUser: (_, __) async => 'project',
      fetchModels: (_, __) async => models(0.65),
    ).collectAccounts();

    expect(q.single.account, 'from-db-token@example.com');
    expect(q.single.windows.single.usedPercent, closeTo(35, 0.001));
  });

  test('discovery falls back to a default CLI account with only credentials',
      () async {
    final q = await AntigravityAdapter(
      dbPathSource: () => const [],
      activeAccountSource: () => null,
      hasGeminiCreds: () => true,
      tokenResolver: (_, allowDefault) async =>
          allowDefault ? 'default-grant' : null,
      emailResolver: (_, __, ___) async => null,
      loadCodeAssist: (_) async => load(email: 'default@example.com'),
      onboardUser: (_, __) async => 'project',
      fetchModels: (_, __) async => models(0.55),
    ).collectAccounts();

    expect(q.single.account, 'default@example.com');
    expect(q.single.windows.single.usedPercent, closeTo(45, 0.001));
  });

  test('default Cloud Code flow posts load, onboard, and model requests',
      () async {
    final methods = <String>[];
    final projects = <String?>[];
    final client = MockClient((req) async {
      expect(req.headers['Authorization'], 'Bearer api-token');
      expect(req.headers['Content-Type'], 'application/json');
      expect(req.headers['User-Agent'], 'antigravity');
      final method = req.url.toString().split(':').last;
      methods.add(method);
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      switch (method) {
        case 'loadCodeAssist':
          expect(body['metadata'], isA<Map>());
          return http.Response(jsonEncode(load()), 200);
        case 'onboardUser':
          expect(body['tierId'], 'PRO');
          return http.Response(
            jsonEncode({
              'done': true,
              'response': {
                'cloudaicompanionProject': {'id': 'project-api'}
              }
            }),
            200,
          );
        case 'fetchAvailableModels':
          projects.add(body['project']?.toString());
          return http.Response(jsonEncode(models(0.4)), 200);
      }
      return http.Response('bad method', 404);
    });

    final q = await AntigravityAdapter(
      accountSource: () => [candidate('api@example.com')],
      tokenResolver: (_, __) async => 'api-token',
      emailResolver: (_, __, ___) async => null,
      client: client,
    ).collectAccounts();

    expect(methods, ['loadCodeAssist', 'onboardUser', 'fetchAvailableModels']);
    expect(projects, ['project-api']);
    expect(q.single.windows.single.usedPercent, 60);
  });

  test('onboarding picks the first tier when none is marked default', () async {
    final tiers = <String?>[];

    final q = await AntigravityAdapter(
      accountSource: () => [candidate('tier@example.com')],
      tokenResolver: (_, __) async => 'tier-token',
      emailResolver: (_, __, ___) async => null,
      loadCodeAssist: (_) async => {
        'allowedTiers': [
          {'id': 'FIRST'}
        ],
        'currentTier': {'id': 'CURRENT', 'name': 'AI Pro'},
      },
      onboardUser: (_, tier) async {
        tiers.add(tier);
        return 'project';
      },
      fetchModels: (_, __) async => models(0.8),
    ).collectAccounts();

    expect(tiers, ['FIRST']);
    expect(q.single.windows.single.usedPercent, closeTo(20, 0.001));
  });

  test('default Cloud Code flow fails soft on non-200 load', () async {
    final q = await AntigravityAdapter(
      accountSource: () => [candidate('api-fail@example.com')],
      tokenResolver: (_, __) async => 'api-token',
      emailResolver: (_, __, ___) async => null,
      client: MockClient((_) async => http.Response('denied', 403)),
    ).collectAccounts();

    expect(q.single.account, 'api-fail@example.com');
    expect(q.single.ok, isTrue);
    expect(q.single.windows, isEmpty);
    expect(q.single.error, contains('quotabot login antigravity'));
  });

  test('connected account with no model quota gets an honest note', () async {
    final q = await AntigravityAdapter(
      accountSource: () => [candidate('empty-models@example.com')],
      tokenResolver: (_, __) async => 'token',
      emailResolver: (_, __, ___) async => null,
      loadCodeAssist: (_) async => load(),
      onboardUser: (_, __) async => 'project',
      fetchModels: (_, __) async => {'models': {}},
    ).collectAccounts();

    expect(q.single.ok, isTrue);
    expect(q.single.windows, isEmpty);
    expect(q.single.error,
        'connected (this machine only); Antigravity is not returning live quota here yet');
    expect(q.single.perMachine, isTrue);
  });

  test('collect returns the first account snapshot', () async {
    final q = await AntigravityAdapter(
      accountSource: () => [
        candidate('primary@example.com', ideAccessToken: 'token-primary'),
        candidate('other@example.com', ideAccessToken: 'token-other'),
      ],
      tokenResolver: (_, __) async => null,
      emailResolver: (_, __, ___) async => null,
      loadCodeAssist: (_) async => load(),
      onboardUser: (_, __) async => 'project',
      fetchModels: (_, __) async => models(0.9),
    ).collect();

    expect(q.account, 'primary@example.com');
    expect(q.windows.single.usedPercent, closeTo(10, 0.001));
  });

  test('account failures do not hide later account snapshots', () async {
    final q = await AntigravityAdapter(
      accountSource: () => [
        candidate('signed-out@example.com'),
        candidate('live@example.com', ideAccessToken: 'live-token'),
      ],
      tokenResolver: (_, __) async => null,
      emailResolver: (_, __, ___) async => null,
      loadCodeAssist: (access) async => access == 'live-token' ? load() : null,
      onboardUser: (_, __) async => 'project',
      fetchModels: (_, __) async => models(0.6),
    ).collectAccounts();

    expect(q, hasLength(2));
    expect(q.first.account, 'signed-out@example.com');
    expect(q.first.ok, isTrue);
    expect(q.first.windows, isEmpty);
    expect(q.first.error, contains('quotabot login antigravity'));
    expect(q.last.account, 'live@example.com');
    expect(q.last.windows.single.usedPercent, 40);
  });

  test('duplicate account candidates are merged without duplicate cards',
      () async {
    final loaded = <String>[];

    final q = await AntigravityAdapter(
      accountSource: () => [
        candidate('dup@example.com', plan: 'Pro'),
        candidate('dup@example.com', ideAccessToken: 'ide-token'),
      ],
      tokenResolver: (_, __) async => null,
      emailResolver: (_, __, ___) async => null,
      loadCodeAssist: (access) async {
        loaded.add(access);
        return load();
      },
      onboardUser: (_, __) async => 'project',
      fetchModels: (_, __) async => models(0.5),
    ).collectAccounts();

    expect(q, hasLength(1));
    expect(q.single.account, 'dup@example.com');
    expect(q.single.plan, 'Pro');
    expect(loaded, ['ide-token']);
  });

  test('load response can identify a default account', () async {
    final q = await AntigravityAdapter(
      accountSource: () => [
        candidate('default', ideAccessToken: 'token'),
      ],
      tokenResolver: (_, __) async => null,
      emailResolver: (_, __, ___) async => null,
      loadCodeAssist: (_) async => load(email: 'resolved@example.com'),
      onboardUser: (_, __) async => 'project',
      fetchModels: (_, __) async => models(0.8),
    ).collectAccounts();

    expect(q.single.account, 'resolved@example.com');
  });

  test('per-model quota is read from local state even when offline', () async {
    final db = writeDb(
      'ide-models',
      email: 'me@example.com',
      userStatus: agUserStatusValue([
        agModelEntry('Gemini 3.5 Flash (Medium)',
            remaining: 0.985, reset: 1782098301, category: 'Fast'),
        agModelEntry('Gemini 3.5 Flash (High)',
            remaining: 0.985, reset: 1782098301),
        agModelEntry('Claude Opus 4.6 (Thinking)',
            remaining: 1.0, reset: 1782098733),
      ]),
    );

    final q = await AntigravityAdapter(
      dbPathSource: () => [db.path],
      activeAccountSource: () => null,
      hasGeminiCreds: () => false,
      tokenResolver: (_, __) async => null, // no live quota: offline path
      emailResolver: (_, __, ___) async => null,
      loadCodeAssist: (_) async => null,
    ).collectAccounts();

    expect(q.single.account, 'me@example.com');
    // Offline for live quota, yet the per-model table is present from local
    // state (network-free), rolled up to base models.
    expect(q.single.error, contains('quotabot login antigravity'));
    expect(
      q.single.modelQuotas.map((m) => m.model),
      ['Gemini 3.5 Flash', 'Claude Opus 4.6'],
    );
    expect(q.single.modelQuotas.first.usedPercent, closeTo(1.5, 1e-9));
    expect(q.single.modelQuotas.first.category, 'Fast');
    expect(q.single.perMachine, isTrue);
  });

  test('a live read overrides the stale local per-model cache', () async {
    // The account was used on another machine, so this machine's local cache is
    // stale (shows 0% used). The authoritative live read must win.
    final q = await AntigravityAdapter(
      accountSource: () => [
        candidate('me@example.com', modelQuotas: const [
          ModelQuota(model: 'Gemini 3.5 Flash', usedPercent: 0),
        ]),
      ],
      tokenResolver: (_, __) async => 'token',
      emailResolver: (_, __, ___) async => null,
      loadCodeAssist: (_) async => load(),
      onboardUser: (_, __) async => 'project',
      fetchModels: (_, __) async => models(0.4), // live: 60% used
    ).collectAccounts();

    expect(q.single.modelQuotas.single.model, 'gemini');
    expect(q.single.modelQuotas.single.usedPercent, closeTo(60, 1e-9));
    expect(q.single.perMachine, isFalse);
  });

  test('a live read does not merge this-machine local cache', () async {
    final q = await AntigravityAdapter(
      accountSource: () => [
        candidate('me@example.com', modelQuotas: const [
          ModelQuota(model: 'gemini', usedPercent: 90),
        ]),
      ],
      tokenResolver: (_, __) async => 'token',
      emailResolver: (_, __, ___) async => null,
      loadCodeAssist: (_) async => load(),
      onboardUser: (_, __) async => 'project',
      fetchModels: (_, __) async => models(0.4), // live: 60% used
    ).collectAccounts();

    expect(q.single.modelQuotas.single.model, 'gemini');
    expect(q.single.modelQuotas.single.usedPercent, closeTo(60, 1e-9));
    expect(q.single.windows.single.usedPercent, closeTo(60, 1e-9));
    expect(q.single.perMachine, isFalse);
  });

  test('empty or throwing account sources fail softly', () async {
    final empty = await AntigravityAdapter(
      accountSource: () => const [],
    ).collectAccounts();
    expect(empty.single.ok, isFalse);
    expect(empty.single.error, 'Antigravity not installed');

    final thrown = await AntigravityAdapter(
      accountSource: () => throw StateError('boom'),
    ).collectAccounts();
    expect(thrown.single.ok, isFalse);
    expect(thrown.single.error, 'unable to read Antigravity state');
  });
}
