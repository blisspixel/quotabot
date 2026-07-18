import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/profiles.dart';
import 'package:quotabot_collector/util.dart';

typedef PrefsDirectoryHardener =
    Future<void> Function(Directory directory, Duration timeout);
typedef PrefsFileHardener = Future<void> Function(File file, Duration timeout);

Future<void> _defaultPrefsDirectoryHardener(
  Directory directory,
  Duration timeout,
) => enforceOwnerOnlyDirectoryAsync(directory, timeout: timeout);

Future<void> _defaultPrefsFileHardener(File file, Duration timeout) =>
    enforceOwnerOnlyFileAsync(file, timeout: timeout);

PrefsDirectoryHardener _hardenPrefsDirectory = _defaultPrefsDirectoryHardener;
PrefsFileHardener _hardenPrefsFile = _defaultPrefsFileHardener;
String? _hardenedPrefsDirectoryPath;
String? _hardenedPrefsFilePath;
String? _pendingPrefsJson;
Completer<void>? _pendingPrefsWaiter;
Future<void>? _prefsDrain;

const _prefsProtectionTimeout = Duration(seconds: 3);
const _prefsReadTimeout = Duration(seconds: 1);
const _maxPrefsBytes = 64 * 1024;

enum PrefsLoadFailure { protection, invalidData, unsupportedFile, readFailure }

class PrefsStorageException implements Exception {
  const PrefsStorageException();

  @override
  String toString() => 'preferences storage unavailable';
}

class PrefsLoadResult {
  final Prefs prefs;
  final PrefsLoadFailure? failure;
  final bool retainedExistingFile;

  const PrefsLoadResult({
    required this.prefs,
    this.failure,
    this.retainedExistingFile = false,
  });
}

class _UnsupportedPrefsFile implements Exception {
  const _UnsupportedPrefsFile();
}

/// Overrides preferences permission enforcement for deterministic tests.
/// Production code must leave this unset.
void setPrefsPermissionHardeningForTesting({
  PrefsDirectoryHardener? directoryHardener,
  PrefsFileHardener? fileHardener,
}) {
  var assertsEnabled = false;
  assert(() {
    assertsEnabled = true;
    return true;
  }());
  if (!assertsEnabled) {
    throw UnsupportedError(
      'test preference permission override is unavailable in release',
    );
  }
  _hardenPrefsDirectory = directoryHardener ?? _defaultPrefsDirectoryHardener;
  _hardenPrefsFile = fileHardener ?? _defaultPrefsFileHardener;
  _hardenedPrefsDirectoryPath = null;
  _hardenedPrefsFilePath = null;
  assert(
    _prefsDrain == null,
    'preference writes must finish before test reset',
  );
  _pendingPrefsJson = null;
  _pendingPrefsWaiter = null;
}

Duration _remainingPrefsProtection(Stopwatch elapsed, Duration timeout) {
  final remaining = timeout - elapsed.elapsed;
  if (remaining.inMicroseconds <= 0) throw const PrefsStorageException();
  return remaining;
}

Future<bool> _ensurePrefsStorage(File file, Duration timeout) async {
  final elapsed = Stopwatch()..start();
  if (_hardenedPrefsDirectoryPath != file.parent.path) {
    await _hardenPrefsDirectory(
      file.parent,
      _remainingPrefsProtection(elapsed, timeout),
    );
    _hardenedPrefsDirectoryPath = file.parent.path;
  }
  final type = await FileSystemEntity.type(
    file.path,
    followLinks: false,
  ).timeout(_remainingPrefsProtection(elapsed, timeout));
  if (type == FileSystemEntityType.notFound) {
    _hardenedPrefsFilePath = null;
    return false;
  }
  if (type != FileSystemEntityType.file) {
    throw const _UnsupportedPrefsFile();
  }
  if (_hardenedPrefsFilePath != file.path) {
    await _hardenPrefsFile(file, _remainingPrefsProtection(elapsed, timeout));
    _hardenedPrefsFilePath = file.path;
  }
  return true;
}

Duration _remainingPrefsRead(Stopwatch elapsed) {
  final remaining = _prefsReadTimeout - elapsed.elapsed;
  if (remaining.inMicroseconds <= 0) throw TimeoutException('preferences');
  return remaining;
}

Future<List<int>> _readPrefsBytes(File file) async {
  final elapsed = Stopwatch()..start();
  final type = await FileSystemEntity.type(
    file.path,
    followLinks: false,
  ).timeout(_remainingPrefsRead(elapsed));
  if (type != FileSystemEntityType.file) {
    throw const _UnsupportedPrefsFile();
  }

  RandomAccessFile? opened;
  try {
    opened = await file
        .open(mode: FileMode.read)
        .timeout(_remainingPrefsRead(elapsed));
    final length = await opened.length().timeout(_remainingPrefsRead(elapsed));
    if (length > _maxPrefsBytes) throw const _UnsupportedPrefsFile();
    final bytes = await opened
        .read(_maxPrefsBytes + 1)
        .timeout(_remainingPrefsRead(elapsed));
    if (bytes.length > _maxPrefsBytes) throw const _UnsupportedPrefsFile();
    return bytes;
  } finally {
    try {
      await opened?.close().timeout(const Duration(milliseconds: 100));
    } catch (_) {}
  }
}

Future<bool> _prefsPathExists(File? file) async {
  if (file == null) return false;
  try {
    final type = await FileSystemEntity.type(
      file.path,
      followLinks: false,
    ).timeout(const Duration(milliseconds: 100));
    return type != FileSystemEntityType.notFound;
  } catch (_) {
    return false;
  }
}

/// Refresh cadence: smart (adaptive) or a fixed interval.
enum Cadence { smart, m15, h1 }

/// Sort order for displayed providers (affects compact icons order and expanded cards).
enum ProviderSort { defaultOrder, alphabetical, mostAvailable, mostUsed }

/// Overall text size. Medium is the design default; the others scale all text.
enum TextSize {
  small(0.9),
  medium(1.0),
  large(1.15);

  const TextSize(this.scale);
  final double scale;
}

/// User interface preferences, persisted across restarts under the per-user
/// config directory.
class Prefs {
  final Set<String> hidden;
  final bool compact;
  final Cadence cadence;
  final bool alwaysOnTop;
  final bool showInTaskbar;
  final bool enableNotifications;
  final ProviderSort sort;
  final String activeProfile;
  final bool showAccounts;
  final TextSize textSize;

  /// Optional webhook that low-quota alerts are POSTed to (quotabot.alert.v1).
  /// Null disables it. Empty or whitespace is treated as disabled.
  final String? webhookUrl;

  /// Whether [webhookUrl] may point at a non-loopback host. Off by default, so
  /// an alert can never reach an external service without an explicit opt-in.
  final bool webhookAllowExternal;

  /// True once the first-run setup walkthrough has been completed or dismissed.
  final bool setupDone;
  final double? windowX;
  final double? windowY;

  const Prefs({
    this.hidden = const {},
    this.compact = false,
    this.cadence = Cadence.smart,
    this.alwaysOnTop = false,
    this.showInTaskbar = true,
    this.enableNotifications = true,
    this.sort = ProviderSort.defaultOrder,
    this.activeProfile = defaultProfileName,
    this.showAccounts = false,
    this.textSize = TextSize.medium,
    this.webhookUrl,
    this.webhookAllowExternal = false,
    this.setupDone = false,
    this.windowX,
    this.windowY,
  });

  Prefs copyWith({
    Set<String>? hidden,
    bool? compact,
    Cadence? cadence,
    bool? alwaysOnTop,
    bool? showInTaskbar,
    bool? enableNotifications,
    ProviderSort? sort,
    String? activeProfile,
    bool? showAccounts,
    TextSize? textSize,
    String? webhookUrl,
    bool? webhookAllowExternal,
    bool clearWebhook = false,
    bool? setupDone,
    double? windowX,
    double? windowY,
    bool clearWindowPosition = false,
  }) => Prefs(
    hidden: hidden ?? this.hidden,
    compact: compact ?? this.compact,
    cadence: cadence ?? this.cadence,
    alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
    showInTaskbar: showInTaskbar ?? this.showInTaskbar,
    enableNotifications: enableNotifications ?? this.enableNotifications,
    sort: sort ?? this.sort,
    activeProfile: activeProfile ?? this.activeProfile,
    showAccounts: showAccounts ?? this.showAccounts,
    textSize: textSize ?? this.textSize,
    webhookUrl: clearWebhook ? null : webhookUrl ?? this.webhookUrl,
    webhookAllowExternal: webhookAllowExternal ?? this.webhookAllowExternal,
    setupDone: setupDone ?? this.setupDone,
    windowX: clearWindowPosition ? null : windowX ?? this.windowX,
    windowY: clearWindowPosition ? null : windowY ?? this.windowY,
  );

  Map<String, dynamic> toJson() => {
    'hidden': hidden.toList(),
    'compact': compact,
    'cadence': cadence.name,
    'always_on_top': alwaysOnTop,
    'show_in_taskbar': showInTaskbar,
    'enable_notifications': enableNotifications,
    'sort': sort.name,
    'active_profile': activeProfile,
    'show_accounts': showAccounts,
    'text_size': textSize.name,
    if (webhookUrl != null) 'webhook_url': webhookUrl,
    'webhook_allow_external': webhookAllowExternal,
    'setup_done': setupDone,
    if (windowX != null && windowY != null) 'window_x': windowX,
    if (windowX != null && windowY != null) 'window_y': windowY,
  };

  factory Prefs.fromJson(Map<String, dynamic> j) {
    final windowX = (j['window_x'] as num?)?.toDouble();
    final windowY = (j['window_y'] as num?)?.toDouble();
    final validWindowPosition =
        windowX != null &&
        windowY != null &&
        windowX.isFinite &&
        windowY.isFinite;
    return Prefs(
      hidden: ((j['hidden'] as List?) ?? const []).map((e) => '$e').toSet(),
      compact: j['compact'] as bool? ?? false,
      cadence: Cadence.values.firstWhere(
        (c) => c.name == j['cadence'],
        orElse: () => Cadence.smart,
      ),
      alwaysOnTop: j['always_on_top'] as bool? ?? false,
      showInTaskbar: j['show_in_taskbar'] as bool? ?? true,
      enableNotifications: j['enable_notifications'] as bool? ?? true,
      sort: ProviderSort.values.firstWhere(
        (s) => s.name == j['sort'],
        orElse: () => ProviderSort.defaultOrder,
      ),
      activeProfile:
          normalizeProfileName(j['active_profile'] as String?) ??
          defaultProfileName,
      showAccounts: j['show_accounts'] as bool? ?? false,
      textSize: TextSize.values.firstWhere(
        (t) => t.name == j['text_size'],
        orElse: () => TextSize.medium,
      ),
      webhookUrl: (j['webhook_url'] as String?)?.trim().isEmpty ?? true
          ? null
          : (j['webhook_url'] as String).trim(),
      webhookAllowExternal: j['webhook_allow_external'] as bool? ?? false,
      setupDone: j['setup_done'] as bool? ?? false,
      windowX: validWindowPosition ? windowX : null,
      windowY: validWindowPosition ? windowY : null,
    );
  }

  static File _file() => File('${quotabotDir('app').path}/prefs.json');

  static Future<PrefsLoadResult> load() async {
    File? file;
    bool exists;
    try {
      file = _file();
      exists = await _ensurePrefsStorage(file, _prefsProtectionTimeout);
    } on _UnsupportedPrefsFile {
      return const PrefsLoadResult(
        prefs: Prefs(),
        failure: PrefsLoadFailure.unsupportedFile,
        retainedExistingFile: true,
      );
    } catch (_) {
      return PrefsLoadResult(
        prefs: Prefs(),
        failure: PrefsLoadFailure.protection,
        retainedExistingFile: await _prefsPathExists(file),
      );
    }
    if (!exists) return const PrefsLoadResult(prefs: Prefs());

    late final List<int> encoded;
    try {
      encoded = await _readPrefsBytes(file);
    } on _UnsupportedPrefsFile {
      return const PrefsLoadResult(
        prefs: Prefs(),
        failure: PrefsLoadFailure.unsupportedFile,
        retainedExistingFile: true,
      );
    } catch (_) {
      return const PrefsLoadResult(
        prefs: Prefs(),
        failure: PrefsLoadFailure.readFailure,
        retainedExistingFile: true,
      );
    }

    try {
      final decoded = jsonDecode(utf8.decode(encoded));
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      return PrefsLoadResult(prefs: Prefs.fromJson(decoded));
    } catch (_) {
      return const PrefsLoadResult(
        prefs: Prefs(),
        failure: PrefsLoadFailure.invalidData,
        retainedExistingFile: true,
      );
    }
  }

  Future<void> save() {
    final encoded = jsonEncode(toJson());
    _pendingPrefsJson = encoded;
    final waiter = _pendingPrefsWaiter ??= Completer<void>();
    _prefsDrain ??= _drainPrefsWrites();
    return waiter.future;
  }

  static Future<void> flush() async {
    while (_prefsDrain != null) {
      await _prefsDrain;
    }
  }
}

Future<void> _drainPrefsWrites() async {
  while (_pendingPrefsJson != null) {
    final encoded = _pendingPrefsJson!;
    final waiter = _pendingPrefsWaiter!;
    _pendingPrefsJson = null;
    _pendingPrefsWaiter = null;
    try {
      await _savePrefsEncoded(encoded);
      if (!waiter.isCompleted) waiter.complete();
    } catch (error, stackTrace) {
      if (!waiter.isCompleted) waiter.completeError(error, stackTrace);
    }
  }
  _prefsDrain = null;
}

Future<void> _savePrefsEncoded(String encoded) async {
  File? tmp;
  try {
    // prefs.json can hold a webhook URL (a secret-bearing capability for chat
    // webhooks), so fail closed unless its storage is owner-only.
    final f = Prefs._file();
    final elapsed = Stopwatch()..start();
    await _ensurePrefsStorage(f, _prefsProtectionTimeout);
    tmp = File('${f.path}.$pid.tmp');
    if (tmp.existsSync()) tmp.deleteSync();
    tmp.createSync(recursive: true);
    await _hardenPrefsFile(
      tmp,
      _remainingPrefsProtection(elapsed, _prefsProtectionTimeout),
    );
    tmp.writeAsStringSync(encoded);
    tmp.renameSync(f.path);
    _hardenedPrefsFilePath = f.path;
  } catch (_) {
    try {
      if (tmp?.existsSync() ?? false) tmp!.deleteSync();
    } catch (_) {}
    throw const PrefsStorageException();
  }
}
