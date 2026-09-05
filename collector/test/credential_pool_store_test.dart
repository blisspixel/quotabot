import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/credential_pool_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late CredentialPoolStore store;
  const now = 1788600000000000;

  String identity(String value) => opaqueCredentialIdentity('claude', value);

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_pool_store_');
    store = CredentialPoolStore(
      'claude',
      directory: temp,
      clockMicros: () => now,
    );
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('a new isolate recovers only the exact previous generation', () async {
    final credential = identity('host generation');
    final pool = identity('provider account and organization');
    expect(store.remember(credential, pool, observedAtMicros: now), isTrue);
    final directory = temp.path;
    final restored = await Isolate.run(() {
      return CredentialPoolStore(
        'claude',
        directory: Directory(directory),
        clockMicros: () => now,
      ).lookup(credential)?.pool;
    });
    expect(restored, pool);
    expect(store.lookup(identity('replacement generation')), isNull);
    expect(store.lookup(credential)?.observedAtMicros, now);
    final body = File('${temp.path}/claude.json').readAsStringSync();
    expect(body, isNot(contains('host generation')));
    expect(body, isNot(contains('provider account and organization')));
  });

  test('late evidence cannot change the association of a newer profile', () {
    final credential = identity('credential');
    final oldPool = identity('old pool');
    final newPool = identity('new pool');
    expect(
        store.remember(credential, oldPool, observedAtMicros: now - 2), isTrue);
    expect(store.remember(credential, newPool, observedAtMicros: now), isTrue);
    expect(store.remember(credential, oldPool, observedAtMicros: now - 1),
        isFalse);
    expect(store.lookup(credential)?.pool, newPool);
  });

  test('equal-generation disagreement remains unresolved until a newer read',
      () {
    final credential = identity('credential');
    final pool = identity('pool');
    expect(store.remember(credential, pool, observedAtMicros: now - 1), isTrue);
    expect(store.remember(credential, pool, observedAtMicros: now - 1), isTrue);
    expect(
        store.remember(credential, identity('other'),
            observedAtMicros: now - 1),
        isFalse);
    expect(store.lookup(credential), isNull);
    expect(
        store.remember(credential, pool, observedAtMicros: now - 1), isFalse);
    expect(store.lookup(credential), isNull);
    expect(store.remember(credential, pool, observedAtMicros: now), isTrue);
    expect(store.lookup(credential)?.pool, pool);
  });

  test('stores at most 32 most recent opaque associations', () {
    final pool = identity('pool');
    for (var i = 0; i < 35; i++) {
      expect(
          store.remember(identity('credential $i'), pool,
              observedAtMicros: now - 35 + i),
          isTrue);
    }
    expect(store.lookup(identity('credential 0')), isNull);
    expect(store.lookup(identity('credential 2')), isNull);
    expect(store.lookup(identity('credential 3'))?.pool, pool);
    expect(store.lookup(identity('credential 34'))?.pool, pool);
    final file = File('${temp.path}/claude.json');
    final decoded = jsonDecode(file.readAsStringSync()) as Map;
    expect(decoded['associations'], hasLength(32));
    expect(file.lengthSync(), lessThan(CredentialPoolStore.maxBytes));
    expect(
        store.remember(identity('late old credential'), pool,
            observedAtMicros: now - 100),
        isFalse);
    expect(store.lookup(identity('late old credential')), isNull);
    expect(store.lookup(identity('credential 34'))?.pool, pool);
  });

  test('invalid identities and unsupported providers cannot write metadata',
      () {
    expect(store.lookup('someone@example.test'), isNull);
    expect(
        store.remember('raw credential', identity('pool'),
            observedAtMicros: now),
        isFalse);
    expect(
        store.remember(identity('credential'), 'raw account',
            observedAtMicros: now),
        isFalse);
    expect(
        CredentialPoolStore('../other', directory: temp).remember(
            identity('credential'), identity('pool'),
            observedAtMicros: now),
        isFalse);
    expect(temp.listSync(), isEmpty);
  });

  test('future and backward-clock evidence does not become an association', () {
    final credential = identity('credential');
    final pool = identity('pool');
    expect(store.remember(credential, pool, observedAtMicros: now + 301000000),
        isFalse);
    expect(store.remember(credential, pool, observedAtMicros: 0), isFalse);
    expect(store.remember(credential, pool, observedAtMicros: now), isTrue);
    final earlierClock = CredentialPoolStore('claude',
        directory: temp, clockMicros: () => now - 301000000);
    expect(earlierClock.lookup(credential), isNull);
  });

  test(
      'bounded corrupt evidence fails closed and a fresh profile can repair it',
      () {
    final credential = identity('credential');
    final pool = identity('pool');
    final file = File('${temp.path}/claude.json');
    for (final body in [
      '{',
      ' ' * (CredentialPoolStore.maxBytes + 1),
      jsonEncode({
        'schema': CredentialPoolStore.schema,
        'provider': 'codex',
        'associations': <Object?>[]
      }),
      jsonEncode({
        'schema': CredentialPoolStore.schema,
        'provider': 'claude',
        'associations': [
          {'credential': credential, 'pool': 'raw', 'observed_at_micros': now}
        ]
      }),
    ]) {
      file.writeAsStringSync(body);
      expect(store.lookup(credential), isNull);
      expect(store.remember(credential, pool, observedAtMicros: now), isTrue);
      expect(store.lookup(credential)?.pool, pool);
    }
  });

  test('duplicate identity rows and unknown schemas do not lend a pool', () {
    final credential = identity('credential');
    final row = {
      'credential': credential,
      'pool': identity('pool'),
      'observed_at_micros': now
    };
    final file = File('${temp.path}/claude.json');
    file.writeAsStringSync(jsonEncode({
      'schema': CredentialPoolStore.schema,
      'provider': 'claude',
      'associations': [row, row]
    }));
    expect(store.lookup(credential), isNull);
    file.writeAsStringSync(jsonEncode({
      'schema': 'future',
      'provider': 'claude',
      'associations': [row]
    }));
    expect(store.lookup(credential), isNull);
  });

  test('a persistent directory at the file or lock is never overwritten', () {
    final credential = identity('credential');
    final pool = identity('pool');
    final target = Directory('${temp.path}/claude.json')..createSync();
    expect(store.lookup(credential), isNull);
    expect(store.remember(credential, pool, observedAtMicros: now), isFalse);
    expect(target.existsSync(), isTrue);
    target.deleteSync();
    final lock = File('${temp.path}/claude.json.lock');
    if (lock.existsSync()) lock.deleteSync();
    final lockDirectory = Directory(lock.path)..createSync();
    expect(store.remember(credential, pool, observedAtMicros: now), isFalse);
    expect(lockDirectory.existsSync(), isTrue);
  });
}
