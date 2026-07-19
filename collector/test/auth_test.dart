import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/auth/anthropic_auth.dart';
import 'package:quotabot_collector/auth/google_auth.dart';
import 'package:quotabot_collector/auth/oauth_util.dart';
import 'package:quotabot_collector/auth/openai_auth.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/auth/xai_auth.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

const _refreshSerializationTestTimeout = Timeout(Duration(seconds: 60));

void _useDeterministicTokenHardening() {
  setTokenPermissionHardeningForTesting(
    directoryHardener: (_) {},
    fileHardener: (_) {},
  );
}

void _holdTokenFileOpen(List<Object> arguments) {
  final handle = File(arguments[0] as String).openSync(mode: FileMode.read);
  final events = arguments[1] as SendPort;
  events.send('ready');
  sleep(const Duration(milliseconds: 75));
  handle.closeSync();
  events.send('done');
}

Future<void> _replaceTokenGenerationInIsolate(List<Object> arguments) async {
  final id = arguments[0] as String;
  final configPath = arguments[1] as String;
  final provider = arguments[2] as String;
  final peerStartedPath = arguments[3] as String;
  final pauseBeforeFirstWrite = arguments[4] as bool;
  final events = arguments[5] as SendPort;
  final commands = ReceivePort();

  setQuotabotDirOverrideForTesting(Directory(configPath));
  setTokenPermissionHardeningForTesting(
    fileHardener: (file) {
      enforceOwnerOnlyFile(file);
      if (!pauseBeforeFirstWrite || !file.path.endsWith('.tmp')) return;
      events.send(<Object>[id, 'inside']);
      final peerStarted = File(peerStartedPath);
      while (!peerStarted.existsSync()) {
        sleep(const Duration(milliseconds: 2));
      }
      // On POSIX the old process-scoped FileLock allowed the peer isolate to
      // pass its revision check and publish during this deterministic window.
      sleep(const Duration(milliseconds: 250));
    },
  );

  final record = TokenStore.loadRecord(provider)!;
  events.send(<Object>[id, 'ready', commands.sendPort]);
  await commands.first;
  if (!pauseBeforeFirstWrite) {
    File(peerStartedPath).createSync();
  }
  final replaced = TokenStore.replaceIfCurrent(
    record,
    Tokens(accessToken: '$id-access', refreshToken: '$id-refresh'),
  );
  events.send(<Object>[id, 'result', replaced]);
  commands.close();
}

Future<List<T>> _runSerializedRefreshPair<T>({
  required Future<T> Function() call,
  required Completer<void> requestStarted,
  required Completer<void> releaseRequest,
  required int Function() requestCount,
}) async {
  const assertionDeadline = Duration(seconds: 15);
  const cleanupDeadline = Duration(seconds: 15);
  final calls = <Future<T>>[call(), call()];
  final completion = Future.wait(calls);
  try {
    await requestStarted.future.timeout(assertionDeadline);
    await Future<void>.delayed(const Duration(milliseconds: 75));
    expect(requestCount(), 1);
    releaseRequest.complete();
    return await completion.timeout(assertionDeadline);
  } finally {
    if (!releaseRequest.isCompleted) releaseRequest.complete();
    try {
      await completion.timeout(cleanupDeadline);
    } catch (_) {
      // Preserve the original assertion or refresh failure. The bounded drain
      // gives in-flight token-store work a cleanup window before tearDown.
    }
  }
}

void main() {
  late Directory tempConfig;

  setUp(() {
    tempConfig = Directory.systemTemp.createTempSync('quotabot_auth_test_');
    setQuotabotDirOverrideForTesting(tempConfig);
    setTokenPermissionHardeningForTesting();
  });

  tearDown(() {
    setTokenPermissionHardeningForTesting();
    setQuotabotDirOverrideForTesting(null);
    if (tempConfig.existsSync()) tempConfig.deleteSync(recursive: true);
  });

  group('Tokens', () {
    test('opaque credential identities are domain-separated and irreversible',
        () {
      final claude = opaqueCredentialIdentity('claude', 'secret-material');
      final codex = opaqueCredentialIdentity('codex', 'secret-material');

      expect(isOpaqueCredentialIdentity(claude), isTrue);
      expect(claude, isNot(codex));
      expect(claude, hasLength(opaqueCredentialIdentityPrefix.length + 64));
      expect(claude, isNot(contains('secret-material')));
      expect(
        quotaAccountDisplayLabel(claude),
        'account ${claude.substring(opaqueCredentialIdentityPrefix.length, opaqueCredentialIdentityPrefix.length + 8)}',
      );
      expect(quotaAccountDisplayLabel(claude), isNot(contains(claude)));
      expect(quotaAccountDisplayLabel('work@example.com'), 'work@example.com');
      expect(isOpaqueCredentialIdentity('credential:abcd'), isFalse);
      expect(
        () => opaqueCredentialIdentity('claude', ''),
        throwsArgumentError,
      );
    });

    test('isFresh respects the expiry margin', () {
      expect(
        Tokens(accessToken: 'a', expiresAt: nowEpoch() + 3600).isFresh,
        isTrue,
      );
      expect(
        Tokens(accessToken: 'a', expiresAt: nowEpoch() + 10).isFresh,
        isFalse,
      );
      expect(Tokens(accessToken: 'a').isFresh, isFalse);
    });

    test('fromOAuth carries the prior refresh token forward', () {
      final t = Tokens.fromOAuth({
        'access_token': 'AT',
        'expires_in': 3600,
      }, priorRefresh: 'R0');
      expect(t.accessToken, 'AT');
      expect(t.refreshToken, 'R0');
      expect(t.expiresAt, greaterThan(nowEpoch()));
    });

    test('fromOAuth prefers a rotated refresh token', () {
      final t = Tokens.fromOAuth({
        'access_token': 'AT',
        'refresh_token': 'R1',
        'expires_in': 3600,
      }, priorRefresh: 'R0');
      expect(t.refreshToken, 'R1');
    });

    test('fromOAuth treats an empty refresh token as absent', () {
      // A blank refresh_token must not overwrite a still-valid prior one.
      final t = Tokens.fromOAuth({
        'access_token': 'AT',
        'refresh_token': '',
        'expires_in': 3600,
      }, priorRefresh: 'R0');
      expect(t.refreshToken, 'R0');
    });

    test('round-trips through json', () {
      final t = Tokens(accessToken: 'a', refreshToken: 'r', expiresAt: 123);
      final back = Tokens.fromJson(t.toJson());
      expect(back.accessToken, 'a');
      expect(back.refreshToken, 'r');
      expect(back.expiresAt, 123);
    });
  });

  group('TokenStore', () {
    const provider = '__test_auth__';
    tearDown(() {
      TokenStore.clear(provider);
      TokenStore.clearAccounts(provider);
    });

    test('save, load, exists, clear', () {
      expect(TokenStore.exists(provider), isFalse);
      TokenStore.save(provider, Tokens(accessToken: 'a', refreshToken: 'r'));
      expect(TokenStore.exists(provider), isTrue);
      expect(TokenStore.load(provider)!.refreshToken, 'r');
      TokenStore.clear(provider);
      expect(TokenStore.load(provider), isNull);
    });

    test('clear serializes an absent slot', () {
      expect(TokenStore.exists(provider), isFalse);

      TokenStore.clear(provider);

      expect(TokenStore.exists(provider), isFalse);
      expect(
        File('${quotabotDir('auth').path}/$provider.json.lock').existsSync(),
        isTrue,
      );
    });

    test('loadRecord keeps tokens and owner in one immutable snapshot', () {
      TokenStore.saveDefaultOwnedBy(
        provider,
        const Tokens(accessToken: 'first', refreshToken: 'r1'),
        'first@example.com',
      );

      final first = TokenStore.loadRecord(provider)!;
      TokenStore.saveDefaultOwnedBy(
        provider,
        const Tokens(accessToken: 'second', refreshToken: 'r2'),
        'second@example.com',
      );

      expect(first.tokens.accessToken, 'first');
      expect(first.tokens.refreshToken, 'r1');
      expect(first.owner, 'first@example.com');
      final second = TokenStore.loadRecord(provider)!;
      expect(second.tokens.accessToken, 'second');
      expect(second.owner, 'second@example.com');
    });

    test('conditional replacement rejects stale generations', () {
      TokenStore.saveDefaultOwnedBy(
        provider,
        const Tokens(accessToken: 'old', refreshToken: 'r0'),
        'old@example.com',
      );
      final stale = TokenStore.loadRecord(provider)!;

      TokenStore.saveDefaultOwnedBy(
        provider,
        const Tokens(accessToken: 'login', refreshToken: 'login-refresh'),
        'new@example.com',
      );
      expect(
        TokenStore.replaceIfCurrent(
          stale,
          const Tokens(accessToken: 'late-refresh', refreshToken: 'r1'),
        ),
        isFalse,
      );
      expect(TokenStore.load(provider)!.accessToken, 'login');
      expect(TokenStore.defaultOwner(provider), 'new@example.com');

      final current = TokenStore.loadRecord(provider)!;
      expect(
        TokenStore.replaceIfCurrent(
          current,
          const Tokens(accessToken: 'sequential', refreshToken: 'r2'),
        ),
        isTrue,
      );
      expect(TokenStore.load(provider)!.accessToken, 'sequential');
      expect(TokenStore.defaultOwner(provider), 'new@example.com');
    });

    test('concurrent isolates admit exactly one CAS generation', () async {
      const barrierTimeout = Duration(seconds: 15);
      TokenStore.save(
        provider,
        const Tokens(accessToken: 'old', refreshToken: 'old-refresh'),
      );
      final peerStarted = File('${tempConfig.path}/peer-started');
      final events = ReceivePort();
      final ready = <String, Completer<SendPort>>{
        'first': Completer<SendPort>(),
        'second': Completer<SendPort>(),
      };
      final results = <String, Completer<bool>>{
        'first': Completer<bool>(),
        'second': Completer<bool>(),
      };
      final firstInside = Completer<void>();
      final subscription = events.listen((message) {
        final event = (message as List<Object>).cast<Object>();
        final id = event[0] as String;
        final kind = event[1] as String;
        if (kind == 'ready') ready[id]!.complete(event[2] as SendPort);
        if (kind == 'inside') firstInside.complete();
        if (kind == 'result') results[id]!.complete(event[2] as bool);
      });
      Isolate? first;
      Isolate? second;
      try {
        first = await Isolate.spawn<List<Object>>(
          _replaceTokenGenerationInIsolate,
          <Object>[
            'first',
            tempConfig.path,
            provider,
            peerStarted.path,
            true,
            events.sendPort,
          ],
        );
        second = await Isolate.spawn<List<Object>>(
          _replaceTokenGenerationInIsolate,
          <Object>[
            'second',
            tempConfig.path,
            provider,
            peerStarted.path,
            false,
            events.sendPort,
          ],
        );
        final firstCommands =
            await ready['first']!.future.timeout(barrierTimeout);
        final secondCommands =
            await ready['second']!.future.timeout(barrierTimeout);

        firstCommands.send('start');
        await firstInside.future.timeout(barrierTimeout);
        secondCommands.send('start');

        final admitted = await Future.wait([
          results['first']!.future,
          results['second']!.future,
        ]).timeout(barrierTimeout);
        expect(admitted, [isTrue, isFalse]);
        expect(TokenStore.load(provider)!.accessToken, 'first-access');
      } finally {
        first?.kill(priority: Isolate.immediate);
        second?.kill(priority: Isolate.immediate);
        await subscription.cancel();
        events.close();
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('refresh transactions do not block unrelated account slots', () async {
      const account = 'work@example.com';
      TokenStore.save(provider, const Tokens(accessToken: 'default'));
      TokenStore.save(
        provider,
        const Tokens(accessToken: 'work'),
        account: account,
      );
      final defaultEntered = Completer<void>();
      final releaseDefault = Completer<void>();
      final defaultTransaction = TokenStore.refreshTransaction(
        provider,
        (record) async {
          expect(record?.tokens.accessToken, 'default');
          defaultEntered.complete();
          await releaseDefault.future;
          return 'default-done';
        },
      );
      await defaultEntered.future;

      final accountResult = await TokenStore.refreshTransaction(
        provider,
        (record) async => record?.tokens.accessToken,
        account: account,
      ).timeout(const Duration(seconds: 1));
      expect(accountResult, 'work');
      releaseDefault.complete();
      expect(await defaultTransaction, 'default-done');
    });

    test('refresh transaction releases its guard after callback failure',
        () async {
      TokenStore.save(provider, const Tokens(accessToken: 'old'));
      await expectLater(
        TokenStore.refreshTransaction<void>(
          provider,
          (_) async => throw StateError('simulated callback failure'),
        ),
        throwsStateError,
      );
      expect(
        await TokenStore.refreshTransaction(
          provider,
          (record) async => record?.tokens.accessToken,
        ),
        'old',
      );
    });

    test('an abandoned same-process claim is reclaimed after its bound', () {
      TokenStore.clear(provider);
      final claim = File(
        '${quotabotDir('auth').path}/$provider.json.lock.claim',
      )..writeAsStringSync(
          jsonEncode({'pid': pid, 'owner': '$pid.abandoned-test-claim'}),
        );
      enforceOwnerOnlyFile(claim);
      claim.setLastModifiedSync(
        DateTime.now().subtract(const Duration(minutes: 3)),
      );

      TokenStore.save(provider, const Tokens(accessToken: 'recovered'));

      expect(TokenStore.load(provider)?.accessToken, 'recovered');
      expect(claim.existsSync(), isFalse);
    });

    test('save is atomic and leaves no temp file behind', () {
      TokenStore.save(provider, Tokens(accessToken: 'a', refreshToken: 'r'));
      final leftover = quotabotDir('auth')
          .listSync()
          .whereType<File>()
          .where((f) => f.uri.pathSegments.last.startsWith(provider))
          .where((f) => f.path.endsWith('.tmp'))
          .toList();
      expect(leftover, isEmpty);
      // The rename must have produced a readable grant.
      expect(TokenStore.load(provider)!.refreshToken, 'r');
    });

    test(
      'load rejects a symbolic-link credential record',
      () {
        final linkedTarget = File('${tempConfig.path}/linked-token-target.json')
          ..writeAsStringSync(
            jsonEncode({
              'access_token': 'linked-secret',
              'refresh_token': 'linked-refresh',
              'expires_at': nowEpoch() + 3600,
            }),
            flush: true,
          );
        final recordPath = '${quotabotDir('auth').path}/$provider.json';
        Link(recordPath).createSync(linkedTarget.path);

        expect(TokenStore.loadRecord(provider), isNull);
        expect(TokenStore.load(provider), isNull);
        expect(linkedTarget.readAsStringSync(), contains('linked-secret'));
      },
      skip: Platform.isWindows
          ? 'ordinary Windows test accounts cannot create symbolic links'
          : false,
    );

    test('save tolerates a reader during atomic replacement', () async {
      TokenStore.save(
        provider,
        const Tokens(accessToken: 'old', refreshToken: 'old-refresh'),
      );
      final tokenPath = '${quotabotDir('auth').path}/$provider.json';
      final events = ReceivePort();
      final ready = Completer<void>();
      final done = Completer<void>();
      final subscription = events.listen((event) {
        if (event == 'ready') ready.complete();
        if (event == 'done') done.complete();
      });
      try {
        await Isolate.spawn<List<Object>>(
          _holdTokenFileOpen,
          [tokenPath, events.sendPort],
        );
        await ready.future.timeout(const Duration(seconds: 2));

        TokenStore.save(
          provider,
          const Tokens(accessToken: 'new', refreshToken: 'new-refresh'),
        );

        await done.future.timeout(const Duration(seconds: 2));
      } finally {
        await subscription.cancel();
        events.close();
      }
      expect(TokenStore.load(provider)!.accessToken, 'new');
      expect(TokenStore.load(provider)!.refreshToken, 'new-refresh');
    });

    test('save fails before writing when file hardening fails', () {
      setTokenPermissionHardeningForTesting(
        fileHardener: (_) => throw const FileSystemException(
          'simulated permission failure',
        ),
      );
      try {
        expect(
          () => TokenStore.save(
            provider,
            Tokens(accessToken: 'access', refreshToken: 'refresh'),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(TokenStore.exists(provider), isFalse);
        expect(quotabotDir('auth').listSync().whereType<File>(), isEmpty);
      } finally {
        // The group cleanup now takes the same lock as every writer, so restore
        // the production hardener before that cleanup runs.
        setTokenPermissionHardeningForTesting();
      }
    });

    test('saved token and directory are owner-only', () {
      final directory = quotabotDir('auth');
      if (Platform.isWindows) {
        final seeded = Process.runSync(
          'icacls',
          [directory.path, '/grant', '*S-1-1-0:(R)'],
        );
        expect(seeded.exitCode, 0);
      }

      TokenStore.save(provider, Tokens(accessToken: 'a', refreshToken: 'r'));
      final file = File('${directory.path}/$provider.json');
      final lockFile = File('${file.path}.lock');
      expect(lockFile.existsSync(), isTrue);
      if (Platform.isWindows) {
        final seededLock = Process.runSync(
          'icacls',
          [lockFile.path, '/grant', '*S-1-1-0:(R)'],
        );
        expect(seededLock.exitCode, 0);
      } else {
        final seededLock = Process.runSync('chmod', ['0666', lockFile.path]);
        expect(seededLock.exitCode, 0);
      }
      // An existing lock can come from an older install. Every operation
      // rechecks it before trusting the cross-process serialization boundary.
      TokenStore.save(provider, Tokens(accessToken: 'b', refreshToken: 'r2'));
      if (Platform.isWindows) {
        final directoryAcl = Process.runSync('icacls', [directory.path]);
        final fileAcl = Process.runSync('icacls', [file.path]);
        final lockAcl = Process.runSync('icacls', [lockFile.path]);
        expect(directoryAcl.exitCode, 0);
        expect(fileAcl.exitCode, 0);
        expect(lockAcl.exitCode, 0);
        expect(directoryAcl.stdout.toString(), isNot(contains('(R)')));
        expect(fileAcl.stdout.toString(), isNot(contains('(R)')));
        expect(lockAcl.stdout.toString(), isNot(contains('(R)')));
      } else {
        expect(directory.statSync().mode & 0x3f, 0);
        expect(file.statSync().mode & 0x3f, 0);
        expect(lockFile.statSync().mode & 0x3f, 0);
      }
    });

    test('rejects path-like provider ids', () {
      expect(
        () => TokenStore.save('../escape', Tokens(accessToken: 'a')),
        throwsArgumentError,
      );
      expect(() => TokenStore.exists('../escape'), throwsArgumentError);
      expect(() => TokenStore.clear('../escape'), throwsArgumentError);
      expect(() => TokenStore.load('../escape'), throwsArgumentError);
    });

    test('keeps account-scoped grants isolated from the default grant', () {
      TokenStore.save(provider, Tokens(accessToken: 'default'));
      TokenStore.save(
        provider,
        Tokens(accessToken: 'work', refreshToken: 'rw'),
        account: 'work@example.com',
      );
      TokenStore.save(
        provider,
        Tokens(accessToken: 'home', refreshToken: 'rh'),
        account: 'home@example.com',
      );

      expect(TokenStore.load(provider)!.accessToken, 'default');
      expect(
        TokenStore.load(provider, account: 'work@example.com')!.refreshToken,
        'rw',
      );
      expect(
        TokenStore.load(provider, account: 'home@example.com')!.refreshToken,
        'rh',
      );
      expect(TokenStore.accounts(provider), [
        'home@example.com',
        'work@example.com',
      ]);
    });

    test('does not put account names in auth filenames', () {
      const account = 'private.person@example.com';
      TokenStore.save(provider, Tokens(accessToken: 'a'), account: account);

      final names = quotabotDir('auth')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((name) => name.startsWith(provider))
          .toList();

      expect(names, isNotEmpty);
      expect(names.any((name) => name.contains('private.person')), isFalse);
      expect(TokenStore.exists(provider, account: account), isTrue);
    });

    test('rejects empty or control-character account ids', () {
      expect(
        () => TokenStore.save(provider, Tokens(accessToken: 'a'), account: ' '),
        throwsArgumentError,
      );
      expect(
        () => TokenStore.exists(provider, account: 'bad\nid'),
        throwsArgumentError,
      );
    });
  });

  group('PKCE', () {
    test('challenge is the S256 hash of the verifier', () {
      final p = pkcePair();
      final expected = base64Url
          .encode(sha256.convert(ascii.encode(p.verifier)).bytes)
          .replaceAll('=', '');
      expect(p.challenge, expected);
      expect(p.verifier.length, greaterThanOrEqualTo(43));
    });

    test('randomState is unique and url-safe', () {
      final a = randomState(), b = randomState();
      expect(a, isNot(b));
      expect(a, matches(RegExp(r'^[A-Za-z0-9_\-]+$')));
    });
  });

  group('refresh', () {
    test('auth helpers leave an injected client open for its owner', () async {
      final client = _CloseTrackingClient();

      await AnthropicAuth(client: client).refresh('anthropic-refresh');
      await OpenAiAuth(client: client).refresh('openai-refresh');
      await GoogleAuth(client: client).refresh('google-refresh');
      await XaiAuth(client: client).refresh('xai-refresh');

      expect(client.requestCount, 4);
      expect(client.closed, isFalse);
      client.close();
      expect(client.closed, isTrue);
    });

    test(
      'XaiAuth.refresh maps the token response and keeps rotation',
      () async {
        final mock = MockClient((req) async {
          expect(req.url.toString(), contains('auth.x.ai/oauth2/token'));
          expect(req.body, contains('grant_type=refresh_token'));
          return http.Response(
            jsonEncode({'access_token': 'AT', 'expires_in': 21600}),
            200,
          );
        });
        final t = await XaiAuth(client: mock).refresh('R1');
        expect(t!.accessToken, 'AT');
        expect(t.refreshToken, 'R1'); // carried forward
        expect(t.isFresh, isTrue);
      },
    );

    test('GoogleAuth.refresh returns null on a non-200', () async {
      final mock = MockClient((req) async => http.Response('nope', 400));
      expect(await GoogleAuth(client: mock).refresh('R1'), isNull);
    });

    test('GoogleAuth.refresh maps a successful response', () async {
      final mock = MockClient(
        (req) async => http.Response(
          jsonEncode({'access_token': 'GA', 'expires_in': 3600}),
          200,
        ),
      );
      final t = await GoogleAuth(client: mock).refresh('R1');
      expect(t!.accessToken, 'GA');
      expect(t.refreshToken, 'R1');
    });

    test('GoogleAuth.freshAccessToken returns a fresh account grant', () async {
      const provider = GoogleAuth.provider;
      const account = 'work@example.com';
      addTearDown(() {
        TokenStore.clear(provider);
        TokenStore.clearAccounts(provider);
      });
      TokenStore.save(
        provider,
        Tokens(
            accessToken: 'GA',
            refreshToken: 'GR',
            expiresAt: nowEpoch() + 3600),
        account: account,
      );
      final auth = GoogleAuth(
        client: MockClient((_) async => throw StateError('unexpected network')),
      );

      expect(await auth.freshAccessToken(account: account), 'GA');
    });

    test('GoogleAuth.freshAccessToken refreshes only the account slot',
        () async {
      const provider = GoogleAuth.provider;
      const account = 'work@example.com';
      addTearDown(() {
        TokenStore.clear(provider);
        TokenStore.clearAccounts(provider);
      });
      // A different account already holds the provider-default slot.
      TokenStore.save(
        provider,
        Tokens(accessToken: 'home-token', refreshToken: 'HR', expiresAt: 1),
      );
      TokenStore.save(
        provider,
        Tokens(accessToken: 'old', refreshToken: 'GR', expiresAt: 1),
        account: account,
      );
      final auth = GoogleAuth(
        client: MockClient((req) async {
          expect(req.body, contains('refresh_token=GR'));
          return http.Response(
            jsonEncode({'access_token': 'fresh', 'expires_in': 3600}),
            200,
          );
        }),
      );

      expect(await auth.freshAccessToken(account: account), 'fresh');
      expect(
        TokenStore.load(provider, account: account)!.accessToken,
        'fresh',
      );
      // The default slot must not be clobbered by the account refresh.
      expect(TokenStore.load(provider)!.accessToken, 'home-token');
    });

    test('GoogleAuth.freshAccessToken refreshes the default slot in place',
        () async {
      const provider = GoogleAuth.provider;
      addTearDown(() {
        TokenStore.clear(provider);
        TokenStore.clearAccounts(provider);
      });
      TokenStore.save(
        provider,
        Tokens(accessToken: 'old', refreshToken: 'DR', expiresAt: 1),
      );
      final auth = GoogleAuth(
        client: MockClient((req) async {
          expect(req.body, contains('refresh_token=DR'));
          return http.Response(
            jsonEncode({'access_token': 'fresh', 'expires_in': 3600}),
            200,
          );
        }),
      );

      expect(await auth.freshAccessToken(), 'fresh');
      expect(TokenStore.load(provider)!.accessToken, 'fresh');
      expect(TokenStore.accounts(provider), isEmpty);
    });

    test('GoogleAuth serializes concurrent refreshes for one account',
        () async {
      _useDeterministicTokenHardening();
      const provider = GoogleAuth.provider;
      const account = 'work@example.com';
      addTearDown(() {
        TokenStore.clear(provider);
        TokenStore.clearAccounts(provider);
      });
      TokenStore.save(
        provider,
        const Tokens(accessToken: 'old', refreshToken: 'GR', expiresAt: 1),
        account: account,
      );
      var requests = 0;
      final requestStarted = Completer<void>();
      final releaseRequest = Completer<void>();
      final auth = GoogleAuth(
        client: MockClient((_) async {
          requests++;
          if (!requestStarted.isCompleted) requestStarted.complete();
          await releaseRequest.future;
          return http.Response(
            jsonEncode({'access_token': 'fresh', 'expires_in': 3600}),
            200,
          );
        }),
      );

      final results = await _runSerializedRefreshPair<String?>(
        call: () => auth.freshAccessToken(account: account),
        requestStarted: requestStarted,
        releaseRequest: releaseRequest,
        requestCount: () => requests,
      );
      expect(results, ['fresh', 'fresh']);
      expect(requests, 1);
      expect(
        TokenStore.load(provider, account: account)?.accessToken,
        'fresh',
      );
    }, timeout: _refreshSerializationTestTimeout);

    test('GoogleAuth does not overwrite a replacement login after refresh',
        () async {
      const provider = GoogleAuth.provider;
      const account = 'work@example.com';
      addTearDown(() {
        TokenStore.clear(provider);
        TokenStore.clearAccounts(provider);
      });
      TokenStore.save(
        provider,
        const Tokens(accessToken: 'old', refreshToken: 'GR', expiresAt: 1),
        account: account,
      );
      final auth = GoogleAuth(
        client: MockClient((_) async {
          TokenStore.save(
            provider,
            Tokens(
              accessToken: 'replacement',
              refreshToken: 'replacement-refresh',
              expiresAt: nowEpoch() + 3600,
            ),
            account: account,
          );
          return http.Response(
            jsonEncode({'access_token': 'late', 'expires_in': 3600}),
            200,
          );
        }),
      );

      expect(await auth.freshAccessToken(account: account), isNull);
      expect(
        TokenStore.load(provider, account: account)!.accessToken,
        'replacement',
      );
    });

    test('XaiAuth.refresh returns null on a non-200', () async {
      final mock = MockClient((req) async => http.Response('no', 400));
      expect(await XaiAuth(client: mock).refresh('R'), isNull);
    });

    test('XaiAuth.freshAccessToken refreshes the selected account grant',
        () async {
      const provider = XaiAuth.provider;
      const account = 'work@example.com';
      TokenStore.save(
        provider,
        Tokens(accessToken: 'default-old', refreshToken: 'DR', expiresAt: 1),
      );
      TokenStore.save(
        provider,
        Tokens(accessToken: 'old', refreshToken: 'RW', expiresAt: 1),
        account: account,
      );
      addTearDown(() {
        TokenStore.clear(provider);
        TokenStore.clearAccounts(provider);
      });

      final mock = MockClient((req) async {
        expect(req.body, contains('refresh_token=RW'));
        return http.Response(
          jsonEncode({'access_token': 'fresh', 'expires_in': 21600}),
          200,
        );
      });

      expect(
        await XaiAuth(client: mock).freshAccessToken(account: account),
        'fresh',
      );
      expect(
        TokenStore.load(provider, account: account)!.accessToken,
        'fresh',
      );
      // The account refresh must not overwrite the provider-default grant.
      expect(TokenStore.load(provider)!.accessToken, 'default-old');
    });

    test('XaiAuth.freshAccessToken keeps the default slot owner on refresh',
        () async {
      const provider = XaiAuth.provider;
      addTearDown(() {
        TokenStore.clear(provider);
        TokenStore.clearAccounts(provider);
      });
      TokenStore.saveDefaultOwnedBy(
        provider,
        Tokens(accessToken: 'old', refreshToken: 'DR', expiresAt: 1),
        'a@example.com',
      );
      final mock = MockClient((req) async {
        expect(req.body, contains('refresh_token=DR'));
        return http.Response(
          jsonEncode({'access_token': 'fresh', 'expires_in': 21600}),
          200,
        );
      });

      expect(await XaiAuth(client: mock).freshAccessToken(), 'fresh');
      // The owner stamp must survive the in-place default refresh, or the
      // adapter's cross-account lending guard silently reopens.
      expect(TokenStore.defaultOwner(provider), 'a@example.com');
      expect(TokenStore.load(provider)!.accessToken, 'fresh');
    });

    test('XaiAuth rejects an unowned default grant before refresh', () async {
      const provider = XaiAuth.provider;
      const requiredOwner = 'work@example.com';
      addTearDown(() => TokenStore.clear(provider));
      TokenStore.save(
        provider,
        const Tokens(
          accessToken: 'legacy-old',
          refreshToken: 'legacy-refresh',
          expiresAt: 1,
        ),
      );
      var requests = 0;
      final auth = XaiAuth(
        client: MockClient((_) async {
          requests++;
          return http.Response(
            jsonEncode({'access_token': 'wrong-account', 'expires_in': 21600}),
            200,
          );
        }),
      );

      expect(
        await auth.freshAccessToken(requiredDefaultOwner: requiredOwner),
        isNull,
      );
      expect(requests, 0);
      expect(TokenStore.load(provider)!.accessToken, 'legacy-old');
      expect(TokenStore.defaultOwner(provider), isNull);
    });

    test('XaiAuth serializes concurrent refreshes for one default owner',
        () async {
      _useDeterministicTokenHardening();
      const provider = XaiAuth.provider;
      const owner = 'work@example.com';
      addTearDown(() => TokenStore.clear(provider));
      TokenStore.saveDefaultOwnedBy(
        provider,
        const Tokens(accessToken: 'old', refreshToken: 'XR', expiresAt: 1),
        owner,
      );
      var requests = 0;
      final requestStarted = Completer<void>();
      final releaseRequest = Completer<void>();
      final auth = XaiAuth(
        client: MockClient((_) async {
          requests++;
          if (!requestStarted.isCompleted) requestStarted.complete();
          await releaseRequest.future;
          return http.Response(
            jsonEncode({'access_token': 'fresh', 'expires_in': 21600}),
            200,
          );
        }),
      );

      final results = await _runSerializedRefreshPair<String?>(
        call: () => auth.freshAccessToken(requiredDefaultOwner: owner),
        requestStarted: requestStarted,
        releaseRequest: releaseRequest,
        requestCount: () => requests,
      );
      expect(results, ['fresh', 'fresh']);
      expect(requests, 1);
      expect(TokenStore.defaultOwner(provider), owner);
    }, timeout: _refreshSerializationTestTimeout);

    test('XaiAuth does not overwrite a replacement login after refresh',
        () async {
      const provider = XaiAuth.provider;
      addTearDown(() {
        TokenStore.clear(provider);
        TokenStore.clearAccounts(provider);
      });
      TokenStore.saveDefaultOwnedBy(
        provider,
        const Tokens(accessToken: 'old', refreshToken: 'DR', expiresAt: 1),
        'old@example.com',
      );
      final auth = XaiAuth(
        client: MockClient((_) async {
          TokenStore.saveDefaultOwnedBy(
            provider,
            Tokens(
              accessToken: 'replacement',
              refreshToken: 'replacement-refresh',
              expiresAt: nowEpoch() + 3600,
            ),
            'new@example.com',
          );
          return http.Response(
            jsonEncode({'access_token': 'late', 'expires_in': 3600}),
            200,
          );
        }),
      );

      expect(await auth.freshAccessToken(), isNull);
      expect(TokenStore.load(provider)!.accessToken, 'replacement');
      expect(TokenStore.defaultOwner(provider), 'new@example.com');
    });
  });

  group('AnthropicAuth', () {
    test('refresh maps the token response and posts the client id', () async {
      final mock = MockClient((req) async {
        expect(req.url.toString(), contains('console.anthropic.com'));
        expect(req.body, contains('grant_type=refresh_token'));
        expect(req.headers['anthropic-beta'], 'oauth-2025-04-20');
        return http.Response(
          jsonEncode({'access_token': 'AT', 'expires_in': 3600}),
          200,
        );
      });
      final t = await AnthropicAuth(client: mock).refresh('R1');
      expect(t!.accessToken, 'AT');
      expect(t.refreshToken, 'R1'); // carried forward
    });

    test('freshAccessToken returns a still-fresh grant without network',
        () async {
      const provider = AnthropicAuth.provider;
      addTearDown(() => TokenStore.clear(provider));
      TokenStore.save(
        provider,
        Tokens(
            accessToken: 'AT',
            refreshToken: 'RT',
            expiresAt: nowEpoch() + 3600),
      );
      final auth = AnthropicAuth(
        client: MockClient((_) async => throw StateError('unexpected network')),
      );
      expect(await auth.freshAccessToken(), 'AT');
      expect(
        TokenStore.defaultOwner(provider),
        opaqueCredentialIdentity(provider, 'RT'),
      );
    });

    test('refresh preserves identity while persisting the rotated token',
        () async {
      const provider = AnthropicAuth.provider;
      addTearDown(() => TokenStore.clear(provider));
      TokenStore.save(
        provider,
        Tokens(accessToken: 'old', refreshToken: 'R0', expiresAt: 1),
      );
      final mock = MockClient((req) async {
        expect(req.body, contains('refresh_token=R0'));
        return http.Response(
          jsonEncode({
            'access_token': 'new',
            'refresh_token': 'R1',
            'expires_in': 3600
          }),
          200,
        );
      });
      final credential = await AnthropicAuth(client: mock).freshCredential();
      final expectedIdentity = opaqueCredentialIdentity(provider, 'R0');
      expect(credential?.accessToken, 'new');
      expect(credential?.identity, expectedIdentity);
      // The rotated single-use refresh token must be persisted or the next
      // refresh fails.
      expect(TokenStore.load(provider)!.refreshToken, 'R1');
      expect(TokenStore.defaultOwner(provider), expectedIdentity);
      expect(AnthropicAuth.currentCredentialIdentity(), expectedIdentity);
    });

    test('AnthropicAuth serializes concurrent rotating-token refreshes',
        () async {
      _useDeterministicTokenHardening();
      const provider = AnthropicAuth.provider;
      addTearDown(() => TokenStore.clear(provider));
      TokenStore.save(
        provider,
        const Tokens(accessToken: 'old', refreshToken: 'R0', expiresAt: 1),
      );
      var requests = 0;
      final requestStarted = Completer<void>();
      final releaseRequest = Completer<void>();
      final auth = AnthropicAuth(
        client: MockClient((_) async {
          requests++;
          if (!requestStarted.isCompleted) requestStarted.complete();
          await releaseRequest.future;
          return http.Response(
            jsonEncode({
              'access_token': 'new',
              'refresh_token': 'R1',
              'expires_in': 3600,
            }),
            200,
          );
        }),
      );

      final results = await _runSerializedRefreshPair<AnthropicCredential?>(
        call: auth.freshCredential,
        requestStarted: requestStarted,
        releaseRequest: releaseRequest,
        requestCount: () => requests,
      );
      expect(results.map((value) => value?.accessToken), ['new', 'new']);
      expect(results[0]?.identity, results[1]?.identity);
      expect(requests, 1);
      expect(TokenStore.load(provider)?.refreshToken, 'R1');
    }, timeout: _refreshSerializationTestTimeout);

    test('replacement login wins an in-flight refresh', () async {
      const provider = AnthropicAuth.provider;
      addTearDown(() => TokenStore.clear(provider));
      final oldIdentity = opaqueCredentialIdentity(provider, 'R0');
      TokenStore.saveDefaultOwnedBy(
        provider,
        const Tokens(accessToken: 'old', refreshToken: 'R0', expiresAt: 1),
        oldIdentity,
      );
      final auth = AnthropicAuth(
        client: MockClient((_) async {
          final replacementIdentity =
              opaqueCredentialIdentity(provider, 'replacement-refresh');
          TokenStore.saveDefaultOwnedBy(
            provider,
            Tokens(
              accessToken: 'replacement',
              refreshToken: 'replacement-refresh',
              expiresAt: nowEpoch() + 3600,
            ),
            replacementIdentity,
          );
          return http.Response(
            jsonEncode({
              'access_token': 'late',
              'refresh_token': 'R1',
              'expires_in': 3600,
            }),
            200,
          );
        }),
      );

      expect(await auth.freshCredential(), isNull);
      expect(TokenStore.load(provider)!.accessToken, 'replacement');
      expect(
        TokenStore.defaultOwner(provider),
        opaqueCredentialIdentity(provider, 'replacement-refresh'),
      );
    });

    test('refresh-lock hardening failure spends no rotating token', () async {
      const provider = AnthropicAuth.provider;
      TokenStore.saveDefaultOwnedBy(
        provider,
        const Tokens(accessToken: 'old', refreshToken: 'R0', expiresAt: 1),
        opaqueCredentialIdentity(provider, 'R0'),
      );
      var requests = 0;
      final auth = AnthropicAuth(
        client: MockClient((_) async {
          requests++;
          return http.Response(
            jsonEncode({
              'access_token': 'new',
              'refresh_token': 'R1',
              'expires_in': 3600,
            }),
            200,
          );
        }),
      );
      setTokenPermissionHardeningForTesting(
        directoryHardener: (_) => throw const FileSystemException(
          'simulated persistence failure',
        ),
      );

      try {
        await expectLater(
          auth.freshCredential(),
          throwsA(isA<FileSystemException>()),
        );
        expect(requests, 0);
        expect(TokenStore.load(provider)!.refreshToken, 'R0');
      } finally {
        setTokenPermissionHardeningForTesting();
        TokenStore.clear(provider);
      }
    });

    test('replacement default grants do not share an identity', () async {
      const provider = AnthropicAuth.provider;
      addTearDown(() => TokenStore.clear(provider));
      final auth = AnthropicAuth(
        client: MockClient((_) async => throw StateError('unexpected network')),
      );
      TokenStore.save(
        provider,
        Tokens(
          accessToken: 'first-access',
          refreshToken: 'first-refresh',
          expiresAt: nowEpoch() + 3600,
        ),
      );
      final first = await auth.freshCredential();

      TokenStore.save(
        provider,
        Tokens(
          accessToken: 'second-access',
          refreshToken: 'second-refresh',
          expiresAt: nowEpoch() + 3600,
        ),
      );
      final second = await auth.freshCredential();

      expect(first?.identity, isNot(second?.identity));
      expect(
        second?.identity,
        opaqueCredentialIdentity(provider, 'second-refresh'),
      );
    });
  });

  group('OpenAiAuth', () {
    test('login reports a busy callback port before showing the URL', () async {
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        1455,
      );
      addTearDown(() => server.close(force: true));
      var showedUrl = false;

      await expectLater(
        OpenAiAuth(clientId: 'test-client').loginLoopback(
          showUrl: (_) => showedUrl = true,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('port 1455 is busy'),
          ),
        ),
      );
      expect(showedUrl, isFalse);
    });

    test('login releases the callback port when URL display fails', () async {
      await expectLater(
        OpenAiAuth(clientId: 'test-client').loginLoopback(
          showUrl: (_) => throw StateError('display failed'),
        ),
        throwsA(isA<StateError>()),
      );

      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        1455,
      );
      await server.close(force: true);
    });

    test('refresh maps the token response and keeps rotation', () async {
      final mock = MockClient((req) async {
        expect(req.url.toString(), contains('auth.openai.com/oauth/token'));
        expect(req.body, contains('grant_type=refresh_token'));
        return http.Response(
          jsonEncode({'access_token': 'AT', 'expires_in': 3600}),
          200,
        );
      });
      final t = await OpenAiAuth(client: mock).refresh('R1');
      expect(t!.accessToken, 'AT');
      expect(t.refreshToken, 'R1');
    });

    test('refresh preserves identity while persisting the rotated token',
        () async {
      const provider = OpenAiAuth.provider;
      addTearDown(() => TokenStore.clear(provider));
      TokenStore.save(
        provider,
        Tokens(accessToken: 'old', refreshToken: 'R0', expiresAt: 1),
      );
      final mock = MockClient((req) async => http.Response(
            jsonEncode({
              'access_token': 'new',
              'refresh_token': 'R1',
              'expires_in': 3600
            }),
            200,
          ));
      final credential = await OpenAiAuth(client: mock).freshCredential();
      final expectedIdentity = opaqueCredentialIdentity(provider, 'R0');
      expect(credential?.accessToken, 'new');
      expect(credential?.identity, expectedIdentity);
      expect(TokenStore.load(provider)!.refreshToken, 'R1');
      expect(TokenStore.defaultOwner(provider), expectedIdentity);
      expect(OpenAiAuth.currentCredentialIdentity(), expectedIdentity);
    });

    test('OpenAiAuth serializes concurrent rotating-token refreshes', () async {
      _useDeterministicTokenHardening();
      const provider = OpenAiAuth.provider;
      addTearDown(() => TokenStore.clear(provider));
      TokenStore.save(
        provider,
        const Tokens(accessToken: 'old', refreshToken: 'R0', expiresAt: 1),
      );
      var requests = 0;
      final requestStarted = Completer<void>();
      final releaseRequest = Completer<void>();
      final auth = OpenAiAuth(
        client: MockClient((_) async {
          requests++;
          if (!requestStarted.isCompleted) requestStarted.complete();
          await releaseRequest.future;
          return http.Response(
            jsonEncode({
              'access_token': 'new',
              'refresh_token': 'R1',
              'expires_in': 3600,
            }),
            200,
          );
        }),
      );

      final results = await _runSerializedRefreshPair<OpenAiCredential?>(
        call: auth.freshCredential,
        requestStarted: requestStarted,
        releaseRequest: releaseRequest,
        requestCount: () => requests,
      );
      expect(results.map((value) => value?.accessToken), ['new', 'new']);
      expect(results[0]?.identity, results[1]?.identity);
      expect(requests, 1);
      expect(TokenStore.load(provider)?.refreshToken, 'R1');
    }, timeout: _refreshSerializationTestTimeout);

    test('OpenAiAuth normalizes an access-token account claim', () async {
      const provider = OpenAiAuth.provider;
      const accountId = 'acct-stable';
      addTearDown(() => TokenStore.clear(provider));
      final accessToken = _unsignedJwt({
        'https://api.openai.com/auth': {
          'chatgpt_account_id': accountId,
        },
      });
      TokenStore.save(
        provider,
        Tokens(
          accessToken: accessToken,
          refreshToken: 'R0',
          expiresAt: nowEpoch() + 3600,
        ),
      );

      final credential = await OpenAiAuth(
        client: MockClient((_) async => throw StateError('unexpected network')),
      ).freshCredential();
      final expected =
          opaqueCredentialIdentity(provider, 'account-id:$accountId');
      expect(credential?.identity, expected);
      expect(OpenAiAuth.currentCredentialIdentity(), expected);
      expect(TokenStore.defaultOwner(provider), expected);
    });

    test('OpenAiAuth adopts an id-token account claim after refresh', () async {
      const provider = OpenAiAuth.provider;
      const accountId = 'acct-from-id-token';
      addTearDown(() => TokenStore.clear(provider));
      TokenStore.save(
        provider,
        const Tokens(accessToken: 'old', refreshToken: 'R0', expiresAt: 1),
      );
      final auth = OpenAiAuth(
        client: MockClient((_) async => http.Response(
              jsonEncode({
                'access_token': 'new',
                'refresh_token': 'R1',
                'expires_in': 3600,
                'id_token': _unsignedJwt({
                  'chatgpt_account_id': accountId,
                }),
              }),
              200,
            )),
      );

      final credential = await auth.freshCredential();
      final expected =
          opaqueCredentialIdentity(provider, 'account-id:$accountId');
      expect(credential?.accessToken, 'new');
      expect(credential?.identity, expected);
      expect(TokenStore.defaultOwner(provider), expected);
    });

    test('OpenAiAuth rejects an oversized account claim', () async {
      const provider = OpenAiAuth.provider;
      addTearDown(() => TokenStore.clear(provider));
      final oversized = List<String>.filled(513, 'a').join();
      TokenStore.save(
        provider,
        Tokens(
          accessToken: _unsignedJwt({'chatgpt_account_id': oversized}),
          refreshToken: 'R0',
          expiresAt: nowEpoch() + 3600,
        ),
      );

      final credential = await OpenAiAuth(
        client: MockClient((_) async => throw StateError('unexpected network')),
      ).freshCredential();
      expect(
        credential?.identity,
        opaqueCredentialIdentity(provider, 'R0'),
      );
    });

    test('replacement login wins an in-flight refresh', () async {
      const provider = OpenAiAuth.provider;
      addTearDown(() => TokenStore.clear(provider));
      final oldIdentity = opaqueCredentialIdentity(provider, 'R0');
      TokenStore.saveDefaultOwnedBy(
        provider,
        const Tokens(accessToken: 'old', refreshToken: 'R0', expiresAt: 1),
        oldIdentity,
      );
      final auth = OpenAiAuth(
        client: MockClient((_) async {
          final replacementIdentity =
              opaqueCredentialIdentity(provider, 'replacement-refresh');
          TokenStore.saveDefaultOwnedBy(
            provider,
            Tokens(
              accessToken: 'replacement',
              refreshToken: 'replacement-refresh',
              expiresAt: nowEpoch() + 3600,
            ),
            replacementIdentity,
          );
          return http.Response(
            jsonEncode({
              'access_token': 'late',
              'refresh_token': 'R1',
              'expires_in': 3600,
            }),
            200,
          );
        }),
      );

      expect(await auth.freshCredential(), isNull);
      expect(TokenStore.load(provider)!.accessToken, 'replacement');
      expect(
        TokenStore.defaultOwner(provider),
        opaqueCredentialIdentity(provider, 'replacement-refresh'),
      );
    });

    test('replacement default grants do not share an identity', () async {
      const provider = OpenAiAuth.provider;
      addTearDown(() => TokenStore.clear(provider));
      final auth = OpenAiAuth(
        client: MockClient((_) async => throw StateError('unexpected network')),
      );
      TokenStore.save(
        provider,
        Tokens(
          accessToken: 'first-access',
          refreshToken: 'first-refresh',
          expiresAt: nowEpoch() + 3600,
        ),
      );
      final first = await auth.freshCredential();

      TokenStore.save(
        provider,
        Tokens(
          accessToken: 'second-access',
          refreshToken: 'second-refresh',
          expiresAt: nowEpoch() + 3600,
        ),
      );
      final second = await auth.freshCredential();

      expect(first?.identity, isNot(second?.identity));
      expect(
        second?.identity,
        opaqueCredentialIdentity(provider, 'second-refresh'),
      );
    });

    test('freshAccessToken returns null with no stored grant', () async {
      const provider = OpenAiAuth.provider;
      addTearDown(() => TokenStore.clear(provider));
      expect(await OpenAiAuth().freshAccessToken(), isNull);
    });
  });

  group('GoogleAuth client', () {
    test('defaults to the bundled public client when nothing is set', () {
      final g = GoogleAuth();
      expect(g.clientId, isNotEmpty);
      expect(g.clientSecret, isNotEmpty);
    });

    test('honors an explicitly provided client', () {
      final g = GoogleAuth(clientId: 'X', clientSecret: 'Y');
      expect(g.clientId, 'X');
      expect(g.clientSecret, 'Y');
    });

    test('emailForAccessToken reads a plain userinfo email', () async {
      final mock = MockClient((req) async {
        expect(req.url.toString(), contains('/oauth2/v2/userinfo'));
        expect(req.headers['Authorization'], 'Bearer GA');
        return http.Response(jsonEncode({'email': 'work@example.com'}), 200);
      });

      expect(
        await GoogleAuth(client: mock).emailForAccessToken('GA'),
        'work@example.com',
      );
    });

    test('emailForAccessToken fails closed on bad userinfo', () async {
      final badStatus = GoogleAuth(
        client: MockClient((_) async => http.Response('no', 401)),
      );
      expect(await badStatus.emailForAccessToken('GA'), isNull);

      final badJson = GoogleAuth(
        client: MockClient((_) async => http.Response('{', 200)),
      );
      expect(await badJson.emailForAccessToken('GA'), isNull);

      final noEmail = GoogleAuth(
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      expect(await noEmail.emailForAccessToken('GA'), isNull);
    });
  });

  group('XaiAuth.deviceLogin', () {
    test('prompts, polls past pending, and reports a terminal error', () async {
      var tokenCalls = 0;
      final mock = MockClient((req) async {
        if (req.url.toString().contains('device/code')) {
          return http.Response(
            jsonEncode({
              'device_code': 'DC',
              'interval': 0,
              'verification_uri_complete': 'https://x.ai/activate',
              'user_code': 'ABCD',
            }),
            200,
          );
        }
        tokenCalls++;
        final err = tokenCalls == 1 ? 'authorization_pending' : 'access_denied';
        return http.Response(jsonEncode({'error': err}), 400);
      });
      String? shownUrl, shownCode;
      await expectLater(
        XaiAuth(client: mock).deviceLogin(
          prompt: (url, code) {
            shownUrl = url;
            shownCode = code;
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(shownUrl, 'https://x.ai/activate');
      expect(shownCode, 'ABCD');
      expect(tokenCalls, greaterThanOrEqualTo(2));
    });

    test('throws when device authorization fails to start', () async {
      final mock = MockClient((req) async => http.Response('no', 400));
      await expectLater(
        XaiAuth(client: mock).deviceLogin(prompt: (_, __) {}),
        throwsA(isA<StateError>()),
      );
    });

    test('throws instead of crashing on a 200 with no device_code', () async {
      // A malformed 200 (missing device_code) must be a clean StateError, not
      // an uncaught cast TypeError.
      final mock = MockClient(
        (req) async => http.Response(jsonEncode({'interval': 5}), 200),
      );
      await expectLater(
        XaiAuth(client: mock).deviceLogin(prompt: (_, __) {}),
        throwsA(isA<StateError>()),
      );
    });

    test('stores a successful device login under the id-token email', () async {
      const provider = XaiAuth.provider;
      const account = 'work@example.com';
      addTearDown(() {
        TokenStore.clear(provider);
        TokenStore.clearAccounts(provider);
      });
      final idToken = _unsignedJwt({'email': account});
      final mock = MockClient((req) async {
        if (req.url.toString().contains('device/code')) {
          return http.Response(
            jsonEncode({
              'device_code': 'DC',
              'interval': 0,
              'verification_uri_complete': 'https://x.ai/activate',
              'user_code': 'ABCD',
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'access_token': 'AT',
            'refresh_token': 'RT',
            'expires_in': 21600,
            'id_token': idToken,
          }),
          200,
        );
      });

      await XaiAuth(client: mock).deviceLogin(prompt: (_, __) {});

      expect(TokenStore.load(provider)!.refreshToken, 'RT');
      expect(
        TokenStore.load(provider, account: account)!.accessToken,
        'AT',
      );
      expect(TokenStore.accounts(provider), contains(account));
    });
  });
}

String _unsignedJwt(Map<String, dynamic> payload) {
  String enc(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${enc({})}.${enc(payload)}.sig';
}

class _CloseTrackingClient extends MockClient {
  _CloseTrackingClient()
      : super(
          (_) async => http.Response(
            jsonEncode({'access_token': 'fresh', 'expires_in': 3600}),
            200,
          ),
        );

  int requestCount = 0;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requestCount++;
    return super.send(request);
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}
