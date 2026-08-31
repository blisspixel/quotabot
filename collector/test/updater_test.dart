import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/updater.dart';
import 'package:test/test.dart';

Map<String, Object?> release(
  String tag, {
  bool? prerelease,
  bool draft = false,
}) =>
    {
      'tag_name': tag,
      'draft': draft,
      'prerelease': prerelease ?? tag.contains('-'),
    };

MockClient releasesClient(List<Object?> releases) =>
    MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.host, 'api.github.com');
      expect(request.headers['user-agent'], startsWith('quotabot/'));
      if (request.url.path.startsWith(
        '/repos/blisspixel/quotabot/releases/tags/',
      )) {
        final tag = request.url.pathSegments.last;
        final matching = releases.where(
          (row) => row is Map && row['tag_name'] == tag,
        );
        if (matching.isEmpty) return http.Response('', 404);
        return http.Response(jsonEncode(matching.first), 200);
      }
      expect(request.url.path, '/repos/blisspixel/quotabot/releases');
      expect(request.url.queryParameters['per_page'], '20');
      expect(request.url.queryParameters['page'], '1');
      return http.Response(jsonEncode(releases), 200);
    });

void main() {
  group('QuotabotVersion', () {
    test('parses and orders stable and release-candidate versions', () {
      final rc9 = QuotabotVersion.tryParse('v0.10.0-rc.9')!;
      final rc16 = QuotabotVersion.tryParse('0.10.0-rc.16')!;
      final stable = QuotabotVersion.tryParse('0.10.0')!;

      expect(rc9.tag, 'v0.10.0-rc.9');
      expect(rc16.compareTo(rc9), greaterThan(0));
      expect(stable.compareTo(rc16), greaterThan(0));
      expect(stable.isPrerelease, isFalse);
    });

    test('rejects loose, ambiguous, and unsupported versions', () {
      for (final value in [
        '',
        'version 1.0.0',
        '01.0.0',
        '1.0',
        '1.0.0-beta.1',
        'v1.0.0-rc.01',
        ' v1.0.0',
        'v${'9' * 100}.0.0',
      ]) {
        expect(QuotabotVersion.tryParse(value), isNull, reason: value);
      }
    });
  });

  group('release discovery', () {
    test('release candidates follow the newest preview by default', () async {
      final check = await checkForQuotabotUpdate(
        currentVersion: '0.10.0-rc.14',
        channel: UpdateChannel.preview,
        client: releasesClient([
          release('v0.9.9'),
          release('v0.10.0-rc.15'),
          release('v0.10.0-rc.16'),
          release('v0.10.0-rc.17', draft: true),
        ]),
      );

      expect(check.target.tag, 'v0.10.0-rc.16');
      expect(check.updateAvailable, isTrue);
      expect(check.toJson()['schema'], quotabotUpdateSchema);
      expect(check.toJson()['selection'], 'channel');
    });

    test('stable channel does not admit a preview', () async {
      final check = await checkForQuotabotUpdate(
        currentVersion: '0.9.8',
        channel: UpdateChannel.stable,
        client: releasesClient([
          release('v0.9.9'),
          release('v0.10.0-rc.16'),
        ]),
      );

      expect(check.target.tag, 'v0.9.9');
      expect(check.updateAvailable, isTrue);
    });

    test('stable discovery follows bounded release pagination', () async {
      final client = MockClient((request) async {
        final page = request.url.queryParameters['page'];
        if (page == '1') {
          return http.Response(
            jsonEncode([
              for (var rc = 40; rc >= 21; rc--) release('v0.10.0-rc.$rc'),
            ]),
            200,
          );
        }
        expect(page, '2');
        return http.Response(jsonEncode([release('v0.9.9')]), 200);
      });

      final check = await checkForQuotabotUpdate(
        currentVersion: '0.9.8',
        channel: UpdateChannel.stable,
        client: client,
      );

      expect(check.target.tag, 'v0.9.9');
    });

    test('exact target must be a published matching release', () async {
      final check = await checkForQuotabotUpdate(
        currentVersion: '0.10.0-rc.16',
        channel: UpdateChannel.preview,
        targetTag: 'v0.9.9',
        client: releasesClient([release('v0.9.9')]),
      );
      expect(check.target.tag, 'v0.9.9');
      expect(check.updateAvailable, isFalse);
      expect(check.channel, isNull);
      expect(check.toJson()['selection'], 'exact');
      expect(check.toJson(), isNot(contains('channel')));

      await expectLater(
        checkForQuotabotUpdate(
          currentVersion: '0.10.0-rc.16',
          channel: UpdateChannel.preview,
          targetTag: 'v0.9.8',
          client: releasesClient([release('v0.9.9')]),
        ),
        throwsA(
          isA<QuotabotUpdateException>().having(
            (error) => error.message,
            'message',
            contains('no published quotabot release'),
          ),
        ),
      );

      await expectLater(
        checkForQuotabotUpdate(
          currentVersion: '0.10.0-rc.16',
          channel: UpdateChannel.preview,
          targetTag: '0.9.9',
          client: releasesClient([release('v0.9.9')]),
        ),
        throwsA(
          isA<QuotabotUpdateException>().having(
            (error) => error.message,
            'message',
            contains('--target must be'),
          ),
        ),
      );
    });

    test('ignores malformed and inconsistently classified releases', () async {
      final check = await checkForQuotabotUpdate(
        currentVersion: '0.9.8',
        channel: UpdateChannel.preview,
        client: releasesClient([
          release('v0.10.0-rc.99', prerelease: false),
          release('not-a-version'),
          {'tag_name': 'v0.10.0-rc.98', 'draft': false},
          release('v0.9.9'),
        ]),
      );

      expect(check.target.tag, 'v0.9.9');
    });

    test('bounds status, structure, JSON, size, and timeout failures',
        () async {
      final cases = <({MockClient client, String message})>[
        (
          client: MockClient((_) async => http.Response('', 503)),
          message: 'HTTP 503',
        ),
        (
          client: MockClient((_) async => http.Response('{}', 200)),
          message: 'unexpected document',
        ),
        (
          client: MockClient((_) async => http.Response('{', 200)),
          message: 'invalid JSON',
        ),
        (
          client: MockClient(
            (_) async => http.Response.bytes(
              List<int>.filled(512 * 1024 + 1, 32),
              200,
            ),
          ),
          message: 'size limit',
        ),
        (
          client: MockClient((_) async {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            return http.Response('[]', 200);
          }),
          message: 'timed out',
        ),
      ];
      for (final item in cases) {
        await expectLater(
          checkForQuotabotUpdate(
            currentVersion: '0.9.9',
            channel: UpdateChannel.stable,
            client: item.client,
            timeout: const Duration(milliseconds: 5),
          ),
          throwsA(
            isA<QuotabotUpdateException>().having(
              (error) => error.message,
              'message',
              contains(item.message),
            ),
          ),
        );
      }
    });
  });

  test('Windows invocation uses only the bundled installer and exact tag',
      () async {
    if (!Platform.isWindows) return;
    final temp = Directory.systemTemp.createTempSync('quotabot_updater_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final bundle = Directory('${temp.path}${Platform.pathSeparator}bundle');
    final bin = Directory('${bundle.path}${Platform.pathSeparator}bin')
      ..createSync(recursive: true);
    final lib = Directory('${bundle.path}${Platform.pathSeparator}lib')
      ..createSync(recursive: true);
    final executable = File('${bin.path}${Platform.pathSeparator}quotabot.exe')
      ..writeAsBytesSync([1]);
    File('${lib.path}${Platform.pathSeparator}install.ps1')
        .writeAsStringSync('exit 0');
    final systemRoot = Directory(
      '${temp.path}${Platform.pathSeparator}Windows',
    );
    final powershell = File(
      '${systemRoot.path}${Platform.pathSeparator}System32'
      '${Platform.pathSeparator}WindowsPowerShell${Platform.pathSeparator}v1.0'
      '${Platform.pathSeparator}powershell.exe',
    )..createSync(recursive: true);
    final localAppData = '${temp.path}${Platform.pathSeparator}Local';

    final invocation = packagedInstallerInvocation(
      currentExecutable: executable.path,
      operatingSystem: 'windows',
      targetTag: 'v0.10.0-rc.16',
      environment: {
        'SystemRoot': systemRoot.path,
        'LOCALAPPDATA': localAppData,
      },
    );

    expect(invocation.executable, powershell.path);
    expect(invocation.arguments, containsAllInOrder(['-File', isA<String>()]));
    expect(invocation.arguments.last, endsWith('lib\\install.ps1'));
    expect(invocation.environment['QUOTABOT_VERSION'], 'v0.10.0-rc.16');
    expect(invocation.environment['QUOTABOT_REPO'], 'blisspixel/quotabot');
    expect(invocation.installedExecutable, endsWith('bin\\quotabot.exe'));
  });
}
