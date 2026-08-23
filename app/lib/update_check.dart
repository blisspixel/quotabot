import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const String quotabotAppVersion = '0.10.0-rc.8';
const String quotabotAppBuild = '0.10.0-rc.8+39';
const String quotabotReleasesUrl =
    'https://github.com/blisspixel/quotabot/releases';
const String quotabotReleasesApi =
    'https://api.github.com/repos/blisspixel/quotabot/releases?per_page=100';
const int _maxReleaseResponseBytes = 512 * 1024;

class QuotabotRelease {
  final String tag;
  final String version;
  final String url;
  final bool prerelease;

  const QuotabotRelease({
    required this.tag,
    required this.version,
    required this.url,
    required this.prerelease,
  });
}

class QuotabotUpdateStatus {
  final String currentVersion;
  final String currentBuild;
  final QuotabotRelease? stable;
  final QuotabotRelease latest;

  const QuotabotUpdateStatus({
    required this.currentVersion,
    String? currentBuild,
    required this.stable,
    required this.latest,
  }) : currentBuild = currentBuild ?? currentVersion;

  bool get currentIsPrerelease =>
      _parseVersion(currentVersion)?.prerelease.isNotEmpty ?? false;

  /// Stable installs follow stable releases. Preview installs follow the
  /// newest release so an explicit check never nudges a stable user onto a
  /// prerelease channel.
  QuotabotRelease? get recommended => currentIsPrerelease ? latest : stable;

  bool get updateAvailable {
    final target = recommended;
    return target != null &&
        compareQuotabotVersions(target.version, currentVersion) > 0;
  }

  bool get previewAvailable =>
      latest.prerelease &&
      compareQuotabotVersions(latest.version, currentVersion) > 0;
}

class UpdateCheckException implements Exception {
  final String message;

  const UpdateCheckException(this.message);

  @override
  String toString() => message;
}

/// Compares release versions using SemVer precedence. Build metadata is ignored.
int compareQuotabotVersions(String left, String right) {
  final a = _parseVersion(left);
  final b = _parseVersion(right);
  if (a == null || b == null) return left.compareTo(right);
  for (var i = 0; i < 3; i++) {
    final compared = a.core[i].compareTo(b.core[i]);
    if (compared != 0) return compared;
  }
  if (a.prerelease.isEmpty && b.prerelease.isEmpty) return 0;
  if (a.prerelease.isEmpty) return 1;
  if (b.prerelease.isEmpty) return -1;
  final count = a.prerelease.length < b.prerelease.length
      ? a.prerelease.length
      : b.prerelease.length;
  for (var i = 0; i < count; i++) {
    final leftPart = a.prerelease[i];
    final rightPart = b.prerelease[i];
    final leftNumeric = RegExp(r'^[0-9]+$').hasMatch(leftPart);
    final rightNumeric = RegExp(r'^[0-9]+$').hasMatch(rightPart);
    if (leftNumeric && rightNumeric) {
      final compared = BigInt.parse(
        leftPart,
      ).compareTo(BigInt.parse(rightPart));
      if (compared != 0) return compared;
    } else if (leftNumeric) {
      return -1;
    } else if (rightNumeric) {
      return 1;
    } else {
      final compared = leftPart.compareTo(rightPart);
      if (compared != 0) return compared;
    }
  }
  return a.prerelease.length.compareTo(b.prerelease.length);
}

({List<BigInt> core, List<String> prerelease})? _parseVersion(String raw) {
  final match = RegExp(
    r'^v?([0-9]+)\.([0-9]+)\.([0-9]+)'
    r'(?:-([0-9A-Za-z.-]+))?'
    r'(?:\+([0-9A-Za-z.-]+))?$',
  ).firstMatch(raw.trim());
  if (match == null) return null;
  final coreParts = [match.group(1)!, match.group(2)!, match.group(3)!];
  if (coreParts.any((part) => part.length > 1 && part.startsWith('0'))) {
    return null;
  }
  final prereleaseText = match.group(4);
  final prerelease = prereleaseText == null
      ? const <String>[]
      : prereleaseText.split('.');
  if (prerelease.any(
    (part) =>
        part.isEmpty ||
        (RegExp(r'^[0-9]+$').hasMatch(part) &&
            part.length > 1 &&
            part.startsWith('0')),
  )) {
    return null;
  }
  final build = match.group(5);
  if (build != null && build.split('.').any((part) => part.isEmpty)) {
    return null;
  }
  return (
    core: coreParts.map(BigInt.parse).toList(growable: false),
    prerelease: prerelease,
  );
}

/// Parses GitHub's releases response without trusting draft or malformed rows.
QuotabotUpdateStatus parseQuotabotReleases(
  Object? decoded, {
  String currentVersion = quotabotAppVersion,
  String? currentBuild,
}) {
  if (decoded is! List) {
    throw const UpdateCheckException('GitHub returned an invalid release list');
  }
  final releases = <QuotabotRelease>[];
  for (final row in decoded) {
    if (row is! Map) continue;
    final draft = row['draft'];
    final tag = row['tag_name'];
    final url = row['html_url'];
    final prerelease = row['prerelease'];
    if (draft is! bool ||
        draft ||
        tag is! String ||
        url is! String ||
        prerelease is! bool ||
        !tag.startsWith('v')) {
      continue;
    }
    final parsed = _parseVersion(tag);
    if (parsed == null || parsed.prerelease.isNotEmpty != prerelease) continue;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        uri.path != '/blisspixel/quotabot/releases/tag/$tag') {
      continue;
    }
    releases.add(
      QuotabotRelease(
        tag: tag,
        version: tag.replaceFirst(RegExp(r'^v'), ''),
        url: uri.toString(),
        prerelease: prerelease,
      ),
    );
  }
  if (releases.isEmpty) {
    throw const UpdateCheckException('No valid quotabot releases were found');
  }
  releases.sort((a, b) => compareQuotabotVersions(b.version, a.version));
  final stable = releases.where((release) => !release.prerelease).firstOrNull;
  return QuotabotUpdateStatus(
    currentVersion: currentVersion,
    currentBuild: currentBuild,
    stable: stable,
    latest: releases.first,
  );
}

Duration _remaining(Stopwatch clock, Duration timeout) {
  final remaining = timeout - clock.elapsed;
  if (remaining <= Duration.zero) throw TimeoutException('release deadline');
  return remaining;
}

Future<List<int>> _readReleaseBytes(
  HttpClientResponse response,
  Duration timeout,
) {
  final result = Completer<List<int>>();
  final bytes = BytesBuilder(copy: false);
  StreamSubscription<List<int>>? subscription;
  Timer? timer;

  void fail(Object error, [StackTrace? stackTrace]) {
    if (result.isCompleted) return;
    timer?.cancel();
    final active = subscription;
    if (active != null) unawaited(active.cancel());
    result.completeError(error, stackTrace);
  }

  subscription = response.listen(
    (chunk) {
      if (bytes.length + chunk.length > _maxReleaseResponseBytes) {
        fail(
          const UpdateCheckException('GitHub release response was too large'),
        );
        return;
      }
      bytes.add(chunk);
    },
    onError: fail,
    onDone: () {
      if (result.isCompleted) return;
      timer?.cancel();
      result.complete(bytes.takeBytes());
    },
    cancelOnError: true,
  );
  timer = Timer(
    timeout,
    () => fail(TimeoutException('release response deadline')),
  );
  return result.future;
}

Future<void> _cancelReleaseResponse(HttpClientResponse response) async {
  final subscription = response.listen((_) {});
  await subscription.cancel();
}

/// Checks GitHub only after a user explicitly invokes the update action.
Future<QuotabotUpdateStatus> checkQuotabotUpdates({
  String currentVersion = quotabotAppVersion,
  String? currentBuild,
  HttpClient? client,
  Uri? releasesApi,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final ownsClient = client == null;
  final http = client ?? HttpClient();
  final clock = Stopwatch()..start();
  try {
    final request = await http
        .getUrl(releasesApi ?? Uri.parse(quotabotReleasesApi))
        .timeout(_remaining(clock, timeout));
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'quotabot/$currentVersion',
    );
    request.followRedirects = false;
    late HttpClientResponse response;
    try {
      response = await request.close().timeout(_remaining(clock, timeout));
    } on TimeoutException {
      request.abort();
      rethrow;
    }
    if (response.statusCode != HttpStatus.ok) {
      await _cancelReleaseResponse(
        response,
      ).timeout(_remaining(clock, timeout));
      throw UpdateCheckException(
        'GitHub release check returned HTTP ${response.statusCode}',
      );
    }
    final declaredLength = response.contentLength;
    if (declaredLength > _maxReleaseResponseBytes) {
      await _cancelReleaseResponse(
        response,
      ).timeout(_remaining(clock, timeout));
      throw const UpdateCheckException('GitHub release response was too large');
    }
    final bytes = await _readReleaseBytes(response, _remaining(clock, timeout));
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } catch (_) {
      throw const UpdateCheckException(
        'GitHub returned an invalid release response',
      );
    }
    return parseQuotabotReleases(
      decoded,
      currentVersion: currentVersion,
      currentBuild:
          currentBuild ??
          (currentVersion == quotabotAppVersion
              ? quotabotAppBuild
              : currentVersion),
    );
  } on UpdateCheckException {
    rethrow;
  } on TimeoutException {
    throw const UpdateCheckException('GitHub release check timed out');
  } on IOException {
    throw const UpdateCheckException('Could not read GitHub releases');
  } finally {
    if (ownsClient) http.close(force: true);
  }
}
