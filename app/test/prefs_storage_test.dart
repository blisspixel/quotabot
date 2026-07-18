import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/prefs.dart';
import 'package:quotabot_collector/util.dart';

void main() {
  late Directory tempConfig;

  setUp(() {
    tempConfig = Directory.systemTemp.createTempSync('quotabot_prefs_test_');
    setQuotabotDirOverrideForTesting(tempConfig);
    setPrefsPermissionHardeningForTesting();
  });

  tearDown(() {
    setPrefsPermissionHardeningForTesting();
    setQuotabotDirOverrideForTesting(null);
    if (tempConfig.existsSync()) tempConfig.deleteSync(recursive: true);
  });

  test(
    'permission failure prevents a webhook secret from being written',
    () async {
      setPrefsPermissionHardeningForTesting(
        directoryHardener: (_, _) async =>
            throw const FileSystemException('simulated permission failure'),
      );

      await expectLater(
        const Prefs(
          webhookUrl: 'https://example.com/QB_PREFS_SECRET_SENTINEL',
          webhookAllowExternal: true,
        ).save(),
        throwsA(isA<PrefsStorageException>()),
      );

      final appDirectory = quotabotDir('app');
      expect(File('${appDirectory.path}/prefs.json').existsSync(), isFalse);
      expect(appDirectory.listSync().whereType<File>(), isEmpty);
    },
  );

  test(
    'permission failure prevents an existing webhook secret from loading',
    () async {
      final file = File('${quotabotDir('app').path}/prefs.json')
        ..writeAsStringSync(
          jsonEncode({
            'webhook_url': 'https://example.com/QB_PREFS_SECRET_SENTINEL',
            'webhook_allow_external': true,
          }),
        );
      setPrefsPermissionHardeningForTesting(
        fileHardener: (_, _) async =>
            throw const FileSystemException('simulated permission failure'),
      );

      final result = await Prefs.load();

      expect(file.existsSync(), isTrue);
      expect(result.failure, PrefsLoadFailure.protection);
      expect(result.retainedExistingFile, isTrue);
      expect(result.prefs.webhookUrl, isNull);
      expect(result.prefs.webhookAllowExternal, isFalse);
    },
  );

  test('protected preferences round-trip with owner-only storage', () async {
    const expected = Prefs(
      webhookUrl: 'https://example.com/alerts/token',
      webhookAllowExternal: true,
      setupDone: true,
    );

    await expected.save();
    final result = await Prefs.load();
    final loaded = result.prefs;

    expect(result.failure, isNull);
    expect(loaded.webhookUrl, expected.webhookUrl);
    expect(loaded.webhookAllowExternal, isTrue);
    expect(loaded.setupDone, isTrue);
    final directory = quotabotDir('app');
    final file = File('${directory.path}/prefs.json');
    if (Platform.isWindows) {
      final directoryAcl = Process.runSync('icacls', [directory.path]);
      final fileAcl = Process.runSync('icacls', [file.path]);
      expect(directoryAcl.exitCode, 0);
      expect(fileAcl.exitCode, 0);
      expect(directoryAcl.stdout.toString(), isNot(contains('(R)')));
      expect(fileAcl.stdout.toString(), isNot(contains('(R)')));
    } else {
      expect(directory.statSync().mode & 0x3f, 0);
      expect(file.statSync().mode & 0x3f, 0);
    }
  });

  test('window position persists only as a finite coordinate pair', () {
    expect(const Prefs(windowX: 120).toJson(), isNot(contains('window_x')));
    expect(const Prefs(windowY: 80).toJson(), isNot(contains('window_y')));

    final partial = Prefs.fromJson({'window_x': 120});
    expect(partial.windowX, isNull);
    expect(partial.windowY, isNull);

    final invalid = Prefs.fromJson({
      'window_x': double.infinity,
      'window_y': 80,
    });
    expect(invalid.windowX, isNull);
    expect(invalid.windowY, isNull);

    final valid = Prefs.fromJson({'window_x': -1600, 'window_y': 120});
    expect(valid.windowX, -1600);
    expect(valid.windowY, 120);
  });

  test('concurrent saves serialize and retain the newest settings', () async {
    final first = const Prefs(
      webhookUrl: 'http://127.0.0.1:9000/first',
      cadence: Cadence.m15,
    ).save();
    final second = const Prefs(
      webhookUrl: 'http://127.0.0.1:9000/second',
      cadence: Cadence.h1,
    ).save();

    await Future.wait([first, second]);
    final loaded = await Prefs.load();

    expect(loaded.failure, isNull);
    expect(loaded.prefs.webhookUrl, 'http://127.0.0.1:9000/second');
    expect(loaded.prefs.cadence, Cadence.h1);
  });

  test('malformed protected preferences report invalid data', () async {
    File(
      '${quotabotDir('app').path}/prefs.json',
    ).writeAsStringSync('{not-json');

    final loaded = await Prefs.load();

    expect(loaded.failure, PrefsLoadFailure.invalidData);
    expect(loaded.retainedExistingFile, isTrue);
    expect(loaded.prefs.webhookUrl, isNull);
    expect(loaded.prefs.cadence, Cadence.smart);
  });

  test('wrong preference field types report invalid data', () async {
    File('${quotabotDir('app').path}/prefs.json').writeAsStringSync(
      jsonEncode({'compact': 'yes', 'enable_notifications': 1}),
    );

    final loaded = await Prefs.load();

    expect(loaded.failure, PrefsLoadFailure.invalidData);
    expect(loaded.prefs.compact, isFalse);
    expect(loaded.prefs.enableNotifications, isTrue);
  });

  test('malformed UTF-8 preferences report invalid data', () async {
    File(
      '${quotabotDir('app').path}/prefs.json',
    ).writeAsBytesSync(const [0xff, 0xfe, 0xfd]);

    final loaded = await Prefs.load();

    expect(loaded.failure, PrefsLoadFailure.invalidData);
    expect(loaded.prefs.webhookUrl, isNull);
  });

  test('oversized protected preferences are rejected before reading', () async {
    File(
      '${quotabotDir('app').path}/prefs.json',
    ).writeAsBytesSync(List<int>.filled(64 * 1024 + 1, 0x20));

    final loaded = await Prefs.load();

    expect(loaded.failure, PrefsLoadFailure.unsupportedFile);
    expect(loaded.retainedExistingFile, isTrue);
  });

  test(
    'linked preferences are rejected before changing the target mode',
    () async {
      final target = File('${tempConfig.path}/outside.json')
        ..writeAsStringSync('{}');
      final mode = Process.runSync('chmod', ['644', target.path]);
      expect(mode.exitCode, 0);
      final prefsPath = '${quotabotDir('app').path}/prefs.json';
      Link(prefsPath).createSync(target.path);

      final loaded = await Prefs.load();

      expect(loaded.failure, PrefsLoadFailure.unsupportedFile);
      expect(target.statSync().mode & 0x3f, 0x24);
    },
    skip: Platform.isWindows
        ? 'ordinary Windows test accounts cannot create symbolic links'
        : false,
  );

  test('save bursts coalesce to one active and one latest write', () async {
    final releaseFirstWrite = Completer<void>();
    var directoryChecks = 0;
    var fileChecks = 0;
    setPrefsPermissionHardeningForTesting(
      directoryHardener: (_, _) async {
        directoryChecks++;
        if (directoryChecks == 1) await releaseFirstWrite.future;
      },
      fileHardener: (_, _) async => fileChecks++,
    );

    final saves = [
      for (var i = 0; i < 40; i++)
        Prefs(webhookUrl: 'http://127.0.0.1:9000/$i').save(),
    ];
    await Future<void>.delayed(Duration.zero);
    expect(directoryChecks, 1);

    var flushed = false;
    final flush = Prefs.flush().then((_) => flushed = true);
    await Future<void>.delayed(Duration.zero);
    expect(flushed, isFalse);

    releaseFirstWrite.complete();
    await Future.wait([...saves, flush]);
    final loaded = await Prefs.load();

    expect(fileChecks, 2);
    expect(loaded.prefs.webhookUrl, 'http://127.0.0.1:9000/39');
    expect(flushed, isTrue);
  });
}
