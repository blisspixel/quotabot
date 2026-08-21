import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../file_guard.dart';
import '../provider_ids.dart';
import '../util.dart';

const _disconnectableProviders = {
  grokProviderId,
  antigravityProviderId,
  claudeProviderId,
  codexProviderId,
};

String providerDisconnectedMessage(String provider) =>
    'disconnected in quotabot (run quotabot login $provider to reconnect)';

/// Provider-wide opt-out owned by quotabot.
///
/// Host credentials remain untouched. A marker blocks both host and quotabot
/// grants until an explicit provider login succeeds and clears it.
class ProviderDisconnectStore {
  static Directory _defaultDir() => quotabotDir('auth');

  static File markerFile(
    String provider, {
    Directory Function()? dirFactory,
  }) {
    final name = _providerName(provider);
    final dir = (dirFactory ?? _defaultDir)();
    return File('${dir.path}/$name.disconnected');
  }

  static bool isDisconnected(
    String provider, {
    Directory Function()? dirFactory,
  }) {
    final marker = markerFile(provider, dirFactory: dirFactory);
    try {
      // Any entry at the exact marker path is a disconnect. A malformed link,
      // directory, device, or unreadable path must never fail open into host
      // credentials. Mutation paths remain stricter and never follow links.
      return FileSystemEntity.typeSync(marker.path, followLinks: false) !=
          FileSystemEntityType.notFound;
    } on FileSystemException {
      return true;
    }
  }

  static void markDisconnected(
    String provider, {
    Directory Function()? dirFactory,
    void Function()? afterMark,
  }) {
    final marker = markerFile(provider, dirFactory: dirFactory);
    enforceOwnerOnlyDirectory(marker.parent);
    _withMarkerLock(marker, () {
      _markUnlocked(marker);
      afterMark?.call();
    });
  }

  /// Publishes one successful explicit login against logout as one operation.
  ///
  /// The grant writer runs before the marker is cleared. Both steps share the
  /// provider marker lock with logout, so concurrent commands cannot leave a
  /// successful logout with host credentials unexpectedly enabled.
  static T publishSuccessfulLogin<T>(
    String provider,
    T Function() saveGrant, {
    Directory Function()? dirFactory,
  }) {
    final marker = markerFile(provider, dirFactory: dirFactory);
    enforceOwnerOnlyDirectory(marker.parent);
    return _withMarkerLock(marker, () {
      final result = saveGrant();
      _clearUnlocked(marker);
      return result;
    });
  }

  static void clearDisconnected(
    String provider, {
    Directory Function()? dirFactory,
  }) {
    final marker = markerFile(provider, dirFactory: dirFactory);
    enforceOwnerOnlyDirectory(marker.parent);
    _withMarkerLock(marker, () => _clearUnlocked(marker));
  }

  static void _markUnlocked(File marker) {
    final type = FileSystemEntity.typeSync(marker.path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      return;
    }
    if (type != FileSystemEntityType.notFound) {
      throw FileSystemException(
        'invalid provider disconnect marker',
        marker.path,
      );
    }
    final temporary = _createTemporaryMarker(marker);
    try {
      enforceOwnerOnlyFile(temporary);
      temporary.renameSync(marker.path);
    } finally {
      try {
        if (temporary.existsSync()) temporary.deleteSync();
      } catch (_) {}
    }
  }

  static void _clearUnlocked(File marker) {
    final type = FileSystemEntity.typeSync(marker.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type == FileSystemEntityType.file) {
      marker.deleteSync();
      return;
    }
    if (type == FileSystemEntityType.link) {
      Link(marker.path).deleteSync();
      return;
    }
    throw FileSystemException(
      'invalid provider disconnect marker',
      marker.path,
    );
  }

  static String _providerName(String provider) {
    if (!_disconnectableProviders.contains(provider)) {
      throw ArgumentError.value(provider, 'provider', 'cannot be disconnected');
    }
    return provider;
  }

  static T _withMarkerLock<T>(File marker, T Function() run) {
    final lockFile = File('${marker.path}.lock');
    var created = false;
    if (!lockFile.existsSync()) {
      try {
        lockFile.createSync(recursive: true, exclusive: true);
        created = true;
      } on FileSystemException {
        if (!lockFile.existsSync()) rethrow;
      }
    }
    try {
      if (FileSystemEntity.typeSync(lockFile.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw FileSystemException(
          'invalid provider disconnect lock',
          lockFile.path,
        );
      }
      if (created) enforceOwnerOnlyFile(lockFile);
    } catch (_) {
      if (created) {
        try {
          lockFile.deleteSync();
        } catch (_) {}
      }
      rethrow;
    }
    final guard = acquireInterprocessFileGuardSync(
      lockFile,
      hardenClaim: enforceOwnerOnlyFile,
    );
    try {
      return run();
    } finally {
      guard.release();
    }
  }

  static File _createTemporaryMarker(File marker) {
    final random = Random.secure();
    for (var attempt = 0; attempt < 16; attempt++) {
      final suffix = base64UrlEncode(
        List<int>.generate(12, (_) => random.nextInt(256)),
      ).replaceAll('=', '');
      final temporary = File('${marker.path}.$pid.$suffix.tmp');
      try {
        temporary.createSync(exclusive: true);
        return temporary;
      } on FileSystemException {
        if (!temporary.existsSync()) rethrow;
      }
    }
    throw FileSystemException(
      'could not create provider disconnect marker',
      marker.path,
    );
  }
}
