import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/update_check.dart';

Map<String, Object?> release(
  String tag, {
  bool prerelease = false,
  bool draft = false,
  String? url,
}) => {
  'tag_name': tag,
  'html_url': url ?? 'https://github.com/blisspixel/quotabot/releases/tag/$tag',
  'prerelease': prerelease,
  'draft': draft,
};

void main() {
  test('SemVer comparison orders stable and release candidates', () {
    expect(compareQuotabotVersions('0.10.0', '0.10.0-rc.6'), greaterThan(0));
    expect(
      compareQuotabotVersions('0.10.0-rc.10', '0.10.0-rc.6'),
      greaterThan(0),
    );
    expect(compareQuotabotVersions('v0.9.9', '0.9.9+37'), 0);
    expect(compareQuotabotVersions('0.10.0-rc.6', '0.9.9'), greaterThan(0));
  });

  test('release parser keeps latest candidate and latest stable distinct', () {
    final status = parseQuotabotReleases([
      release('v0.9.9'),
      release('v0.10.0-rc.5', prerelease: true),
      release('v0.10.0-rc.6', prerelease: true),
    ], currentVersion: '0.9.8');

    expect(status.latest.version, '0.10.0-rc.6');
    expect(status.latest.prerelease, isTrue);
    expect(status.stable?.version, '0.9.9');
    expect(status.updateAvailable, isTrue);
  });

  test('stable installs do not treat a preview as a recommended update', () {
    final status = parseQuotabotReleases([
      release('v0.9.9'),
      release('v0.10.0-rc.6', prerelease: true),
    ], currentVersion: '0.9.9');

    expect(status.currentIsPrerelease, isFalse);
    expect(status.recommended?.version, '0.9.9');
    expect(status.updateAvailable, isFalse);
    expect(status.previewAvailable, isTrue);
  });

  test('preview installs follow the newest release channel', () {
    final status = parseQuotabotReleases([
      release('v0.9.9'),
      release('v0.10.0-rc.7', prerelease: true),
    ], currentVersion: '0.10.0-rc.6');

    expect(status.currentIsPrerelease, isTrue);
    expect(status.recommended?.version, '0.10.0-rc.7');
    expect(status.updateAvailable, isTrue);
  });

  test('stable installs do not fall back to an unpaired preview', () {
    final status = parseQuotabotReleases([
      release('v0.10.0-rc.7', prerelease: true),
    ], currentVersion: '0.9.9');

    expect(status.recommended, isNull);
    expect(status.updateAvailable, isFalse);
    expect(status.previewAvailable, isTrue);
  });

  test('SemVer comparison handles unbounded numeric identifiers', () {
    expect(
      compareQuotabotVersions(
        '184467440737095516160.0.0',
        '184467440737095516159.999.999',
      ),
      greaterThan(0),
    );
    expect(
      compareQuotabotVersions(
        '1.0.0-rc.184467440737095516160',
        '1.0.0-rc.184467440737095516159',
      ),
      greaterThan(0),
    );
  });

  test('release parser reports a matching current preview as current', () {
    final status = parseQuotabotReleases([
      release('v0.10.0-rc.6', prerelease: true),
      release('v0.9.9'),
    ], currentVersion: '0.10.0-rc.6');

    expect(status.updateAvailable, isFalse);
  });

  test('release parser ignores drafts, malformed rows, and external URLs', () {
    final status = parseQuotabotReleases([
      release('v9.0.0', draft: true),
      {
        'tag_name': 'v8.0.0',
        'html_url':
            'https://github.com/blisspixel/quotabot/releases/tag/v8.0.0',
        'prerelease': false,
      },
      {...release('v7.0.0'), 'draft': 'false'},
      release('not-a-version'),
      release(
        'v8.0.0',
        url: 'https://example.com/blisspixel/quotabot/releases/tag/v8.0.0',
      ),
      release('v0.9.9'),
    ], currentVersion: '0.9.9');

    expect(status.latest.version, '0.9.9');
    expect(status.stable?.version, '0.9.9');
  });

  test('release parser rejects malformed and contradictory SemVer rows', () {
    final status = parseQuotabotReleases([
      release('v01.2.3'),
      release('v1.2.3-rc.01', prerelease: true),
      release(
        'v1.2.3-rc.00000000000000000000000000000000000000001',
        prerelease: true,
      ),
      release('v1.2.3-rc.1'),
      release('v1.2.3', prerelease: true),
      release('1.2.3'),
      release(
        'v2.0.0',
        url: 'https://github.com/blisspixel/quotabot/releases/tag/v0.9.9',
      ),
      release('v0.9.9'),
    ]);

    expect(status.latest.version, '0.9.9');
  });

  test('release parser fails closed when no valid release remains', () {
    expect(
      () => parseQuotabotReleases([
        release('v9.0.0', draft: true),
        release('not-a-version'),
      ]),
      throwsA(isA<UpdateCheckException>()),
    );
  });

  test('live checker reads a bounded valid GitHub-shaped response', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode([
          release('v0.10.0-rc.6', prerelease: true),
          release('v0.9.9'),
        ]),
      );
      await request.response.close();
    });

    final status = await checkQuotabotUpdates(
      releasesApi: Uri.parse('http://127.0.0.1:${server.port}/releases'),
      timeout: const Duration(seconds: 2),
    );

    expect(status.latest.version, '0.10.0-rc.6');
    expect(status.stable?.version, '0.9.9');
    expect(status.currentBuild, quotabotAppBuild);
  });

  test(
    'custom comparison version does not inherit this app build number',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode([release('v0.9.9')]));
        await request.response.close();
      });

      final status = await checkQuotabotUpdates(
        currentVersion: '0.9.8',
        releasesApi: Uri.parse('http://127.0.0.1:${server.port}/releases'),
        timeout: const Duration(seconds: 2),
      );

      expect(status.currentBuild, '0.9.8');
    },
  );

  test('release endpoint requests enough history for the stable channel', () {
    final uri = Uri.parse(quotabotReleasesApi);

    expect(uri.queryParameters['per_page'], '100');
  });

  test('live checker does not follow release endpoint redirects', () async {
    final redirectTarget = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => redirectTarget.close(force: true));
    var targetWasRead = false;
    redirectTarget.listen((request) async {
      targetWasRead = true;
      request.response.write(jsonEncode([release('v9.9.9')]));
      await request.response.close();
    });

    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => source.close(force: true));
    source.listen((request) async {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'http://127.0.0.1:${redirectTarget.port}/releases',
      );
      await request.response.close();
    });

    await expectLater(
      checkQuotabotUpdates(
        releasesApi: Uri.parse('http://127.0.0.1:${source.port}/redirect'),
        timeout: const Duration(seconds: 2),
      ),
      throwsA(
        isA<UpdateCheckException>().having(
          (error) => error.message,
          'message',
          'GitHub release check returned HTTP 302',
        ),
      ),
    );
    expect(targetWasRead, isFalse);
  });

  test('live checker reports a GitHub HTTP failure clearly', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.statusCode = HttpStatus.tooManyRequests;
      request.response.write('rate limited');
      await request.response.close();
    });

    await expectLater(
      checkQuotabotUpdates(
        releasesApi: Uri.parse('http://127.0.0.1:${server.port}/rate-limited'),
        timeout: const Duration(seconds: 2),
      ),
      throwsA(
        isA<UpdateCheckException>().having(
          (error) => error.message,
          'message',
          'GitHub release check returned HTTP 429',
        ),
      ),
    );
  });

  test('live checker enforces one whole-response deadline', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.write('[');
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      try {
        request.response.write(']');
        await request.response.close();
      } catch (_) {
        // The checker deliberately cancels the response at its deadline.
      }
    });

    await expectLater(
      checkQuotabotUpdates(
        releasesApi: Uri.parse('http://127.0.0.1:${server.port}/slow'),
        timeout: const Duration(milliseconds: 60),
      ),
      throwsA(
        isA<UpdateCheckException>().having(
          (error) => error.message,
          'message',
          'GitHub release check timed out',
        ),
      ),
    );
  });

  test('live checker rejects an oversized response before decoding', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.add(List<int>.filled(513 * 1024, 0));
      await request.response.close();
    });

    await expectLater(
      checkQuotabotUpdates(
        releasesApi: Uri.parse('http://127.0.0.1:${server.port}/large'),
        timeout: const Duration(seconds: 2),
      ),
      throwsA(
        isA<UpdateCheckException>().having(
          (error) => error.message,
          'message',
          'GitHub release response was too large',
        ),
      ),
    );
  });
}
