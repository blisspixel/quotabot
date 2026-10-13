import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

const quotabotUpdateSchema = 'quotabot.update.v1';
const quotabotReleaseRepository = 'blisspixel/quotabot';
const _maxReleaseResponseBytes = 512 * 1024;
const _maxReleaseDiscoveryBytes = 2 * 1024 * 1024;
const _releasePageSize = 5;
const _maxReleasePages = 4;

enum UpdateChannel { stable, preview }

final class QuotabotVersion implements Comparable<QuotabotVersion> {
  static final _pattern = RegExp(
    r'^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-rc\.(0|[1-9][0-9]*))?$',
  );

  final int major;
  final int minor;
  final int patch;
  final int? releaseCandidate;

  const QuotabotVersion(
    this.major,
    this.minor,
    this.patch, {
    this.releaseCandidate,
  });

  bool get isPrerelease => releaseCandidate != null;

  String get tag => 'v$this';

  static QuotabotVersion? tryParse(String value) {
    final match = _pattern.firstMatch(value);
    if (match == null) return null;
    try {
      return QuotabotVersion(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
        releaseCandidate:
            match.group(4) == null ? null : int.parse(match.group(4)!),
      );
    } on FormatException {
      return null;
    }
  }

  @override
  int compareTo(QuotabotVersion other) {
    for (final difference in [
      major.compareTo(other.major),
      minor.compareTo(other.minor),
      patch.compareTo(other.patch),
    ]) {
      if (difference != 0) return difference;
    }
    if (releaseCandidate == null && other.releaseCandidate == null) return 0;
    if (releaseCandidate == null) return 1;
    if (other.releaseCandidate == null) return -1;
    return releaseCandidate!.compareTo(other.releaseCandidate!);
  }

  @override
  bool operator ==(Object other) =>
      other is QuotabotVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, releaseCandidate);

  @override
  String toString() =>
      '$major.$minor.$patch${releaseCandidate == null ? '' : '-rc.$releaseCandidate'}';
}

final class QuotabotRelease {
  final String tag;
  final QuotabotVersion version;
  final bool prerelease;

  const QuotabotRelease({
    required this.tag,
    required this.version,
    required this.prerelease,
  });
}

final class QuotabotUpdateCheck {
  final QuotabotVersion current;
  final UpdateChannel? channel;
  final QuotabotRelease target;

  const QuotabotUpdateCheck({
    required this.current,
    required this.channel,
    required this.target,
  });

  bool get updateAvailable => target.version.compareTo(current) > 0;

  Map<String, Object?> toJson({bool installed = false, bool forced = false}) =>
      {
        'schema': quotabotUpdateSchema,
        'current_version': current.toString(),
        'selection': channel == null ? 'exact' : 'channel',
        if (channel != null) 'channel': channel!.name,
        'target_version': target.version.toString(),
        'target_tag': target.tag,
        'update_available': updateAvailable,
        'forced': forced,
        'installed': installed,
      };
}

final class QuotabotUpdateException implements Exception {
  final String message;

  const QuotabotUpdateException(this.message);

  @override
  String toString() => message;
}

Duration _remaining(Stopwatch clock, Duration timeout) {
  final remaining = timeout - clock.elapsed;
  if (remaining <= Duration.zero) {
    throw TimeoutException('release discovery deadline');
  }
  return remaining;
}

Future<({Object? decoded, int bytes})> _readReleaseDocument({
  required http.Client client,
  required Uri uri,
  required Map<String, String> headers,
  required Stopwatch clock,
  required Duration timeout,
  required int remainingByteBudget,
  String? notFoundMessage,
}) async {
  final request = http.Request('GET', uri)
    ..followRedirects = false
    ..headers.addAll(headers);
  final response =
      await client.send(request).timeout(_remaining(clock, timeout));
  if (response.statusCode != 200) {
    final subscription = response.stream.listen((_) {});
    await subscription.cancel();
    if (response.statusCode == 404 && notFoundMessage != null) {
      throw QuotabotUpdateException(notFoundMessage);
    }
    throw QuotabotUpdateException(
      'GitHub release discovery returned HTTP ${response.statusCode}',
    );
  }
  final declaredLength = response.contentLength;
  if (declaredLength != null &&
      (declaredLength > _maxReleaseResponseBytes ||
          declaredLength > remainingByteBudget)) {
    final subscription = response.stream.listen((_) {});
    await subscription.cancel();
    throw const QuotabotUpdateException(
      'GitHub release discovery exceeded the response size limit',
    );
  }
  final builder = await response.stream.fold<BytesBuilder>(
    BytesBuilder(copy: false),
    (bytes, chunk) {
      if (bytes.length + chunk.length > _maxReleaseResponseBytes ||
          bytes.length + chunk.length > remainingByteBudget) {
        throw const QuotabotUpdateException(
          'GitHub release discovery exceeded the response size limit',
        );
      }
      bytes.add(chunk);
      return bytes;
    },
  ).timeout(_remaining(clock, timeout));
  final body = builder.takeBytes();
  try {
    return (
      decoded: jsonDecode(utf8.decode(body, allowMalformed: false)),
      bytes: body.length,
    );
  } on FormatException {
    throw const QuotabotUpdateException(
      'GitHub release discovery returned invalid JSON',
    );
  }
}

Future<QuotabotUpdateCheck> checkForQuotabotUpdate({
  required String currentVersion,
  required UpdateChannel channel,
  String? targetTag,
  String? githubToken,
  http.Client? client,
  Duration timeout = const Duration(seconds: 15),
  String repository = quotabotReleaseRepository,
}) async {
  final current = QuotabotVersion.tryParse(currentVersion);
  if (current == null) {
    throw const QuotabotUpdateException(
      'the installed quotabot version is not a supported release version',
    );
  }
  if (!RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository)) {
    throw const QuotabotUpdateException('the release repository is invalid');
  }
  final requested =
      targetTag == null ? null : QuotabotVersion.tryParse(targetTag);
  if (targetTag != null && (requested == null || requested.tag != targetTag)) {
    throw const QuotabotUpdateException(
      '--target must be vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-rc.N',
    );
  }

  final ownClient = client == null;
  final httpClient = client ?? http.Client();
  final clock = Stopwatch()..start();
  try {
    final headers = {
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'quotabot/$currentVersion',
      'X-GitHub-Api-Version': '2022-11-28',
    };
    final token = githubToken?.trim();
    if (token != null && token.isNotEmpty) {
      if (token.length > 4096 ||
          token.codeUnits.any((unit) => unit < 32 || unit == 127)) {
        throw const QuotabotUpdateException(
          'the GitHub release token is invalid',
        );
      }
      headers['Authorization'] = 'Bearer $token';
    }
    final rows = <Object?>[];
    var bytesRead = 0;
    if (requested != null) {
      final result = await _readReleaseDocument(
        client: httpClient,
        uri: Uri.https(
          'api.github.com',
          '/repos/$repository/releases/tags/${requested.tag}',
        ),
        headers: headers,
        clock: clock,
        timeout: timeout,
        remainingByteBudget: _maxReleaseDiscoveryBytes,
        notFoundMessage:
            'GitHub has no published quotabot release for ${requested.tag}',
      );
      if (result.decoded is! Map) {
        throw const QuotabotUpdateException(
          'GitHub release discovery returned an unexpected document',
        );
      }
      rows.add(result.decoded);
    } else if (channel == UpdateChannel.stable) {
      final result = await _readReleaseDocument(
        client: httpClient,
        uri: Uri.https(
          'api.github.com',
          '/repos/$repository/releases/latest',
        ),
        headers: headers,
        clock: clock,
        timeout: timeout,
        remainingByteBudget: _maxReleaseDiscoveryBytes,
        notFoundMessage:
            'GitHub has no published quotabot release on the stable channel',
      );
      if (result.decoded is! Map) {
        throw const QuotabotUpdateException(
          'GitHub release discovery returned an unexpected document',
        );
      }
      rows.add(result.decoded);
    } else {
      for (var page = 1; page <= _maxReleasePages; page++) {
        final result = await _readReleaseDocument(
          client: httpClient,
          uri: Uri.https('api.github.com', '/repos/$repository/releases', {
            'per_page': '$_releasePageSize',
            'page': '$page',
          }),
          headers: headers,
          clock: clock,
          timeout: timeout,
          remainingByteBudget: _maxReleaseDiscoveryBytes - bytesRead,
        );
        if (result.decoded is! List) {
          throw const QuotabotUpdateException(
            'GitHub release discovery returned an unexpected document',
          );
        }
        final pageRows = result.decoded as List;
        rows.addAll(pageRows);
        bytesRead += result.bytes;
        if (pageRows.length < _releasePageSize) break;
      }
    }
    final releases = <QuotabotRelease>[];
    for (final item in rows) {
      if (item is! Map ||
          item['draft'] != false ||
          item['prerelease'] is! bool) {
        continue;
      }
      final tag = item['tag_name'];
      if (tag is! String) continue;
      final version = QuotabotVersion.tryParse(tag);
      if (version == null || version.tag != tag) continue;
      final prerelease = item['prerelease'] as bool;
      if (prerelease != version.isPrerelease) continue;
      releases.add(
        QuotabotRelease(
          tag: tag,
          version: version,
          prerelease: prerelease,
        ),
      );
    }

    QuotabotRelease? selected;
    if (requested != null) {
      for (final release in releases) {
        if (release.version == requested && release.tag == requested.tag) {
          selected = release;
          break;
        }
      }
      if (selected == null) {
        throw QuotabotUpdateException(
          'GitHub has no published quotabot release for ${requested.tag}',
        );
      }
    } else {
      final eligible = releases.where(
        (release) => channel == UpdateChannel.preview || !release.prerelease,
      );
      for (final release in eligible) {
        if (selected == null ||
            release.version.compareTo(selected.version) > 0) {
          selected = release;
        }
      }
      if (selected == null) {
        throw QuotabotUpdateException(
          'GitHub has no published quotabot release on the ${channel.name} channel',
        );
      }
    }
    return QuotabotUpdateCheck(
      current: current,
      channel: requested == null ? channel : null,
      target: selected,
    );
  } on TimeoutException {
    throw const QuotabotUpdateException('GitHub release discovery timed out');
  } on http.ClientException {
    throw const QuotabotUpdateException('GitHub release discovery failed');
  } finally {
    if (ownClient) httpClient.close();
  }
}

final class InstallerInvocation {
  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final String installedExecutable;

  const InstallerInvocation({
    required this.executable,
    required this.arguments,
    required this.environment,
    required this.installedExecutable,
  });
}

InstallerInvocation packagedInstallerInvocation({
  required String currentExecutable,
  required String operatingSystem,
  required String targetTag,
  required Map<String, String> environment,
}) {
  final target = QuotabotVersion.tryParse(targetTag);
  if (target == null || target.tag != targetTag) {
    throw const QuotabotUpdateException('the selected release tag is invalid');
  }
  final bundleRoot = File(currentExecutable).parent.parent;
  final lib = Directory(
    '${bundleRoot.path}${Platform.pathSeparator}lib',
  );
  final childEnvironment = Map<String, String>.from(environment)
    ..['QUOTABOT_REPO'] = quotabotReleaseRepository
    ..['QUOTABOT_VERSION'] = targetTag;

  if (operatingSystem == 'windows') {
    final installer = File(
      '${lib.path}${Platform.pathSeparator}install.ps1',
    );
    if (!installer.existsSync()) {
      throw const QuotabotUpdateException(
        'the packaged Windows updater is missing; reinstall quotabot once with the official installer',
      );
    }
    final systemRoot = environment['SystemRoot'] ?? environment['SYSTEMROOT'];
    if (systemRoot == null || systemRoot.trim().isEmpty) {
      throw const QuotabotUpdateException(
          'Windows PowerShell could not be located');
    }
    final powershell = File(
      '$systemRoot${Platform.pathSeparator}System32${Platform.pathSeparator}'
      'WindowsPowerShell${Platform.pathSeparator}v1.0${Platform.pathSeparator}'
      'powershell.exe',
    );
    if (!powershell.existsSync()) {
      throw const QuotabotUpdateException(
          'Windows PowerShell could not be located');
    }
    final localAppData = environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.trim().isEmpty) {
      throw const QuotabotUpdateException('LOCALAPPDATA is unavailable');
    }
    return InstallerInvocation(
      executable: powershell.path,
      arguments: [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        installer.path,
      ],
      environment: childEnvironment,
      installedExecutable:
          '$localAppData${Platform.pathSeparator}quotabot${Platform.pathSeparator}'
          'bin${Platform.pathSeparator}quotabot.exe',
    );
  }

  if (operatingSystem != 'linux' && operatingSystem != 'macos') {
    throw QuotabotUpdateException(
      'self-update is not supported on $operatingSystem',
    );
  }
  final installer = File('${lib.path}${Platform.pathSeparator}install.sh');
  if (!installer.existsSync()) {
    throw const QuotabotUpdateException(
      'the packaged POSIX updater is missing; reinstall quotabot once with the official installer',
    );
  }
  File? bash;
  for (final candidate in [File('/bin/bash'), File('/usr/bin/bash')]) {
    if (candidate.existsSync()) {
      bash = candidate;
      break;
    }
  }
  if (bash == null) {
    throw const QuotabotUpdateException('bash could not be located');
  }
  final home = environment['HOME'];
  if (home == null || home.trim().isEmpty) {
    throw const QuotabotUpdateException('HOME is unavailable');
  }
  return InstallerInvocation(
    executable: bash.path,
    arguments: [installer.path],
    environment: childEnvironment,
    installedExecutable:
        '$home${Platform.pathSeparator}.local${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}quotabot',
  );
}

const portableDesktopVersionBytes = 4096;
const portableDesktopPlistBytes = 64 * 1024;
const portableDesktopScanLimit = 32;
const portableDesktopNoticeLimit = 8;

enum PortableDesktopLocation { handExtracted, managed }

/// One installed desktop bundle whose embedded version differs from the CLI.
///
/// Discovery is read-only. A hand-extracted copy is never replaced or deleted.
final class PortableDesktopBundle {
  final PortableDesktopLocation location;
  final QuotabotVersion version;
  final String path;
  final String asset;
  final String releasesUrl;

  const PortableDesktopBundle({
    required this.location,
    required this.version,
    required this.path,
    required this.asset,
    required this.releasesUrl,
  });

  String get locationName => switch (location) {
        PortableDesktopLocation.handExtracted => 'hand_extracted',
        PortableDesktopLocation.managed => 'managed',
      };

  Map<String, Object?> toJson() => {
        'location': locationName,
        'version': version.toString(),
        'path': path,
        if (asset.isNotEmpty) 'asset': asset,
        'releases_url': releasesUrl,
      };

  String notice(QuotabotVersion cliVersion) {
    final download = asset.isEmpty
        ? 'the desktop archive for this operating system from $releasesUrl'
        : '$asset from $releasesUrl';
    final cli = cliVersion.toString();
    final found = version.toString();
    if (location == PortableDesktopLocation.managed) {
      return 'Managed desktop $found at $path differs from CLI $cli. '
          'Run "quotabot update --force" to replace that managed install. '
          'Download $download, verify the .sha256 sidecar, and replace only '
          'that managed copy.';
    }
    return 'Hand-extracted desktop $found at $path differs from CLI $cli '
        'and was left in place. Download $download, verify the .sha256 '
        'sidecar, extract it into a new directory, quit the old copy, and '
        'launch the new executable.';
  }
}

final class PortableDesktopSkew {
  final QuotabotVersion referenceVersion;
  final List<PortableDesktopBundle> bundles;
  final int omittedCount;

  const PortableDesktopSkew({
    required this.referenceVersion,
    required this.bundles,
    required this.omittedCount,
  });

  bool get hasNotices => bundles.isNotEmpty || omittedCount > 0;

  List<String> get lines {
    final result = [
      for (final bundle in bundles) bundle.notice(referenceVersion),
    ];
    if (omittedCount == 1) {
      result.add(
        '1 more desktop copy differs from CLI $referenceVersion and was left '
        'in place.',
      );
    } else if (omittedCount > 1) {
      result.add(
        '$omittedCount more desktop copies differ from CLI $referenceVersion '
        'and were left in place.',
      );
    }
    return result;
  }

  Map<String, Object?> toJson() => {
        'reference_version': referenceVersion.toString(),
        'omitted_count': omittedCount,
        'bundles': [for (final bundle in bundles) bundle.toJson()],
      };
}

String portableDesktopAssetName({
  required String operatingSystem,
  required String architecture,
}) {
  if (operatingSystem == 'linux' &&
      (architecture == 'x64' || architecture == 'arm64')) {
    return 'quotabot-linux-$architecture-desktop.tar.gz';
  }
  if (operatingSystem == 'macos' &&
      (architecture == 'x64' || architecture == 'arm64')) {
    return 'quotabot-darwin-$architecture-desktop.zip';
  }
  if (operatingSystem == 'windows' && architecture == 'x64') {
    return 'quotabot-windows-x64-desktop.zip';
  }
  return '';
}

String portableDesktopReleasesUrl(QuotabotVersion version) =>
    'https://github.com/$quotabotReleaseRepository/releases/tag/${version.tag}';

String currentPortableDesktopArchitecture() {
  final marker = Platform.version;
  if (marker.contains('arm64')) return 'arm64';
  if (marker.contains('x64')) return 'x64';
  return '';
}

QuotabotVersion? _parseBundleVersion(String raw) {
  final withoutBuild = raw.trim().split('+').first.trim();
  return QuotabotVersion.tryParse(withoutBuild);
}

bool _safePortablePath(String path) {
  if (path.isEmpty || path.length > 4096) return false;
  for (final unit in path.codeUnits) {
    if (unit < 32 || unit == 127) return false;
  }
  return true;
}

String _foldPortablePath(String path) {
  final separator = Platform.pathSeparator;
  final normalized =
      path.replaceAll('\\', separator).replaceAll('/', separator);
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

bool _portablePathWithin(String parent, String child) {
  final separator = Platform.pathSeparator;
  final left = _foldPortablePath(parent);
  final right = _foldPortablePath(child);
  final prefix = left.endsWith(separator) ? left : '$left$separator';
  return right.startsWith(prefix);
}

String _portableLeaf(String path) {
  final parts = path.split(RegExp(r'[\\/]'));
  return parts.isEmpty ? '' : parts.last;
}

String _portableChild(String parent, List<String> parts) {
  var path = parent;
  for (final part in parts) {
    path = '$path${Platform.pathSeparator}$part';
  }
  return path;
}

QuotabotVersion? _readFlutterVersionFile(File file) {
  RandomAccessFile? handle;
  try {
    final kind = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (kind != FileSystemEntityType.file) return null;
    handle = file.openSync();
    final bytes = handle.readSync(portableDesktopVersionBytes + 1);
    if (bytes.isEmpty || bytes.length > portableDesktopVersionBytes) {
      return null;
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) return null;
    final version = decoded['version'];
    if (version is! String) return null;
    return _parseBundleVersion(version);
  } catch (_) {
    return null;
  } finally {
    try {
      handle?.closeSync();
    } catch (_) {}
  }
}

QuotabotVersion? _readMacShortVersion(File plist) {
  RandomAccessFile? handle;
  try {
    final kind = FileSystemEntity.typeSync(plist.path, followLinks: false);
    if (kind != FileSystemEntityType.file) return null;
    handle = plist.openSync();
    final bytes = handle.readSync(portableDesktopPlistBytes);
    if (bytes.isEmpty) return null;
    final text = utf8.decode(bytes, allowMalformed: true).replaceAll('\n', '');
    final match = RegExp(
      r'<key>\s*CFBundleShortVersionString\s*</key>\s*<string>\s*([^<]{1,80})\s*</string>',
    ).firstMatch(text);
    final raw = match?.group(1);
    if (raw == null) return null;
    return _parseBundleVersion(raw);
  } catch (_) {
    return null;
  } finally {
    try {
      handle?.closeSync();
    } catch (_) {}
  }
}

QuotabotVersion? _readMacBundleVersion(String bundlePath) {
  for (final relative in [
    [
      'Contents',
      'Frameworks',
      'App.framework',
      'Versions',
      'A',
      'Resources',
      'flutter_assets',
      'version.json',
    ],
    [
      'Contents',
      'Frameworks',
      'App.framework',
      'Resources',
      'flutter_assets',
      'version.json',
    ],
  ]) {
    final version = _readFlutterVersionFile(
      File(_portableChild(bundlePath, relative)),
    );
    if (version != null) return version;
  }
  return _readMacShortVersion(
    File(_portableChild(bundlePath, ['Contents', 'Info.plist'])),
  );
}

QuotabotVersion? _readLinuxOrWindowsBundleVersion(String bundlePath) =>
    _readFlutterVersionFile(
      File(
        _portableChild(bundlePath, ['data', 'flutter_assets', 'version.json']),
      ),
    );

bool _isRegularFile(String path) {
  try {
    return FileSystemEntity.typeSync(path, followLinks: true) ==
        FileSystemEntityType.file;
  } catch (_) {
    return false;
  }
}

final _safePortableName = RegExp(r'^[A-Za-z0-9._-]{1,128}$');
final _versionedMacApp = RegExp(r'^quotabot-.+\.app$');

List<Directory> _portableChildDirectories(
  String parent, {
  required bool Function(String name) include,
}) {
  try {
    final kind = FileSystemEntity.typeSync(parent, followLinks: true);
    if (kind != FileSystemEntityType.directory) return const [];
    final entries = Directory(parent).listSync(followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    final matches = <Directory>[];
    var examined = 0;
    for (final entry in entries) {
      if (examined >= portableDesktopScanLimit) break;
      examined++;
      if (entry is! Directory) continue;
      if (!_portablePathWithin(parent, entry.path)) continue;
      final name = _portableLeaf(entry.path);
      if (!_safePortableName.hasMatch(name) || name.startsWith('.')) continue;
      if (!include(name)) continue;
      final childKind = FileSystemEntity.typeSync(
        entry.path,
        followLinks: false,
      );
      if (childKind != FileSystemEntityType.directory) continue;
      matches.add(entry);
    }
    return matches;
  } catch (_) {
    return const [];
  }
}

void _addSkewBundle({
  required List<PortableDesktopBundle> found,
  required PortableDesktopLocation location,
  required QuotabotVersion? installed,
  required QuotabotVersion cliVersion,
  required String path,
  required String asset,
  required String releasesUrl,
}) {
  if (installed == null || installed == cliVersion) return;
  if (!_safePortablePath(path)) return;
  found.add(
    PortableDesktopBundle(
      location: location,
      version: installed,
      path: path,
      asset: asset,
      releasesUrl: releasesUrl,
    ),
  );
}

/// Names desktop bundles whose embedded version differs from [cliVersion].
///
/// One directory level is examined, version files are capped at 4 KiB, and
/// nothing is replaced, stopped, or deleted. A matching version is omitted.
PortableDesktopSkew findPortableDesktopVersionSkew({
  required QuotabotVersion cliVersion,
  required String operatingSystem,
  String architecture = '',
  String? home,
  String? localAppData,
}) {
  final found = <PortableDesktopBundle>[];
  try {
    final asset = portableDesktopAssetName(
      operatingSystem: operatingSystem,
      architecture: architecture,
    );
    final releasesUrl = portableDesktopReleasesUrl(cliVersion);
    final homeRoot = home?.trim();
    final localRoot = localAppData?.trim();
    if (operatingSystem == 'linux' && homeRoot != null && homeRoot.isNotEmpty) {
      final root = _portableChild(homeRoot, [
        '.local',
        'share',
        'quotabot-desktop',
      ]);
      final executable = _portableChild(root, ['quotabot']);
      if (_isRegularFile(executable)) {
        _addSkewBundle(
          found: found,
          location: PortableDesktopLocation.managed,
          installed: _readLinuxOrWindowsBundleVersion(root),
          cliVersion: cliVersion,
          path: root,
          asset: asset,
          releasesUrl: releasesUrl,
        );
      }
      for (final child in _portableChildDirectories(
        root,
        include: (name) => name != 'data' && name != 'lib',
      )) {
        _addSkewBundle(
          found: found,
          location: PortableDesktopLocation.handExtracted,
          installed: _readLinuxOrWindowsBundleVersion(child.path),
          cliVersion: cliVersion,
          path: child.path,
          asset: asset,
          releasesUrl: releasesUrl,
        );
      }
    } else if (operatingSystem == 'macos' &&
        homeRoot != null &&
        homeRoot.isNotEmpty) {
      final applications = _portableChild(homeRoot, ['Applications']);
      final managed = _portableChild(applications, ['quotabot.app']);
      final executable = _portableChild(managed, [
        'Contents',
        'MacOS',
        'quotabot',
      ]);
      if (_isRegularFile(executable)) {
        _addSkewBundle(
          found: found,
          location: PortableDesktopLocation.managed,
          installed: _readMacBundleVersion(managed),
          cliVersion: cliVersion,
          path: managed,
          asset: asset,
          releasesUrl: releasesUrl,
        );
      }
      for (final child in _portableChildDirectories(
        applications,
        include: _versionedMacApp.hasMatch,
      )) {
        _addSkewBundle(
          found: found,
          location: PortableDesktopLocation.handExtracted,
          installed: _readMacBundleVersion(child.path),
          cliVersion: cliVersion,
          path: child.path,
          asset: asset,
          releasesUrl: releasesUrl,
        );
      }
    } else if (operatingSystem == 'windows' &&
        localRoot != null &&
        localRoot.isNotEmpty) {
      final managed = _portableChild(localRoot, ['quotabot', 'desktop']);
      final executable = _portableChild(managed, ['quotabot.exe']);
      if (_isRegularFile(executable)) {
        _addSkewBundle(
          found: found,
          location: PortableDesktopLocation.managed,
          installed: _readLinuxOrWindowsBundleVersion(managed),
          cliVersion: cliVersion,
          path: managed,
          asset: asset,
          releasesUrl: releasesUrl,
        );
      }
      final versioned = _portableChild(localRoot, ['quotabot-desktop']);
      for (final child in _portableChildDirectories(
        versioned,
        include: (_) => true,
      )) {
        _addSkewBundle(
          found: found,
          location: PortableDesktopLocation.handExtracted,
          installed: _readLinuxOrWindowsBundleVersion(child.path),
          cliVersion: cliVersion,
          path: child.path,
          asset: asset,
          releasesUrl: releasesUrl,
        );
      }
    }
  } catch (_) {
    return PortableDesktopSkew(
      referenceVersion: cliVersion,
      bundles: const [],
      omittedCount: 0,
    );
  }
  found.sort((a, b) => a.path.compareTo(b.path));
  if (found.length <= portableDesktopNoticeLimit) {
    return PortableDesktopSkew(
      referenceVersion: cliVersion,
      bundles: found,
      omittedCount: 0,
    );
  }
  return PortableDesktopSkew(
    referenceVersion: cliVersion,
    bundles: found.sublist(0, portableDesktopNoticeLimit),
    omittedCount: found.length - portableDesktopNoticeLimit,
  );
}
