import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/ansi.dart';
import 'package:quotabot_collector/auth/google_auth.dart';
import 'package:quotabot_collector/auth/xai_auth.dart';
import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/demo.dart' as cli_demo;
import 'package:quotabot_collector/drift.dart';
import 'package:quotabot_collector/top.dart';
import 'package:quotabot_collector/util.dart';
import 'package:quotabot_collector/webhook.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'chrome_controls.dart';
import 'demo.dart';
import 'desktop_readiness.dart';
import 'fleet.dart';
import 'headroom_colors.dart';
import 'logos.dart';
import 'prefs.dart';
import 'profile_editor.dart';
import 'profile_ui.dart';
import 'provider_display.dart';
import 'quota_labels.dart';
import 'quota_loading_indicator.dart';
import 'single_instance.dart';
import 'termshot.dart';
import 'theme_spec.dart';
import 'typography.dart';
import 'window_geometry.dart';

String _joinedCredentialProviderNames(List<String> providers) {
  final names = providers
      .map(
        (provider) => switch (provider) {
          'claude' => 'Claude',
          'codex' => 'Codex',
          _ => provider,
        },
      )
      .toList(growable: false);
  if (names.length < 2) return names.single;
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

const Size _compactMinimumWindowSize = Size(120, 40);
const Size _expandedMinimumWindowSize = Size(320, 120);

@visibleForTesting
Size desktopMinimumWindowSize({required bool compact}) =>
    compact ? _compactMinimumWindowSize : _expandedMinimumWindowSize;

const Color _quotaGreen = Color(0xFF3FB950);
const String _windowsAppUserModelId = 'io.quotabot.app';
const String _windowsNotificationGuid = 'f3063433-3b97-5b9f-9448-2f70cbbf4ad1';

/// Screenshot-export mode (`QUOTABOT_SHOTS=1`): the app loads demo data, captures
/// the widget and analytics views to PNGs (in `QUOTABOT_SHOTS_DIR`, default the
/// current directory), then exits. It reuses the real widget tree so the README
/// images stay pixel-faithful. Shots mode implies demo data; both are no-ops on a
/// normal run.
final bool _shotsMode = Platform.environment['QUOTABOT_SHOTS'] == '1';
final bool _gifFramesMode = Platform.environment['QUOTABOT_GIF_FRAMES'] == '1';
final bool _demoMode =
    _shotsMode || Platform.environment['QUOTABOT_DEMO'] == '1';
final DesktopReadinessProbe _desktopReadiness =
    DesktopReadinessProbe.fromEnvironment();

/// Boundary around the live route, captured for screenshots.
final GlobalKey _shotBoundaryKey = GlobalKey();

/// Boundary around the rendered CLI `top` frame, captured for the README.
final GlobalKey _termShotKey = GlobalKey();

/// Global text-scale, applied to every route (strip and analytics) via the
/// MaterialApp builder. Driven by the TextSize preference.
final ValueNotifier<double> textScale = ValueNotifier<double>(1.0);

/// Driven by the active profile. The default profile follows the OS theme.
final ValueNotifier<String> appThemeSpec = ValueNotifier<String>(
  appThemeSystem,
);

@visibleForTesting
String? preferenceLoadWarning(PrefsLoadResult result) =>
    switch (result.failure) {
      null => null,
      PrefsLoadFailure.protection =>
        result.retainedExistingFile
            ? 'Saved settings ignored (prefs.json unprotected)'
            : 'Saved settings unavailable (storage not ready)',
      PrefsLoadFailure.invalidData => 'Saved settings invalid; using defaults',
      PrefsLoadFailure.unsupportedFile =>
        'Saved settings file unsupported; using defaults',
      PrefsLoadFailure.readFailure =>
        'Saved settings unreadable; using defaults',
    };

@visibleForTesting
bool hasSuccessfulRefreshEvidence(Iterable<ProviderQuota> providers, int now) =>
    providers.any((quota) {
      if (!quota.ok ||
          quota.stale ||
          quota.suspect != null ||
          quota.driftReason != null ||
          quota.asOf <= 0 ||
          quota.asOf > now + kQuotaEvidenceClockSkewSeconds) {
        return false;
      }
      if (quota.windows.isNotEmpty) {
        return isTrustedQuotaEvidenceAt(quota, now);
      }
      if (quota.isLocal) return isLocalRuntimeAvailableAt(quota, now);
      if (quota.sourceClass != ProviderSourceClass.statusOnly) return false;
      final status = quota.status?.trim().toLowerCase();
      return status != null &&
          status.isNotEmpty &&
          !status.startsWith('not configured');
    });

final SingleInstanceGuard _singleInstance = SingleInstanceGuard();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final prefsResult = await Prefs.load();
  final prefs = prefsResult.prefs;

  // Enforce a single instance so a second launch surfaces the existing window
  // instead of spawning another process and a duplicate tray icon.
  final isPrimary = await _singleInstance.tryBecomePrimary(
    onShowRequested: () async {
      // Preserve the running instance's current taskbar preference. The startup
      // value captured here can be stale after the user changes settings.
      await windowManager.show();
      await windowManager.focus();
    },
  );
  if (!isPrimary) {
    // Another instance is already running and has been asked to surface. Exit
    // before creating any window or tray icon.
    await _singleInstance.dispose();
    exit(0);
  }

  final startupStorageWarning = preferenceLoadWarning(prefsResult);
  if (startupStorageWarning != null) {
    stderr.writeln(
      'quotabot: preference load failed (${prefsResult.failure!.name}); '
      'safe defaults active',
    );
  }
  textScale.value = prefs.textSize.scale;

  // Keep startup resilient when a platform notification backend is unavailable.
  try {
    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
      macOS: DarwinInitializationSettings(),
      linux: LinuxInitializationSettings(defaultActionName: 'Open'),
      windows: WindowsInitializationSettings(
        appName: 'quotabot',
        appUserModelId: _windowsAppUserModelId,
        guid: _windowsNotificationGuid,
      ),
    );
    await flutterLocalNotificationsPlugin.initialize(settings: initSettings);
    tz.initializeTimeZones();
    tz.setLocalLocation(tz.local);
  } catch (_) {
    // notifications init failed, app will continue without them
  }

  const initialWindowSize = Size(340, 760);
  final options = WindowOptions(
    size: initialWindowSize,
    minimumSize: desktopMinimumWindowSize(compact: prefs.compact),
    center: false,
    backgroundColor: Colors.transparent,
    titleBarStyle: TitleBarStyle.hidden,
    alwaysOnTop: prefs.alwaysOnTop,
    skipTaskbar: !prefs.showInTaskbar,
    title: 'quotabot',
  );
  unawaited(
    windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setAsFrameless();
      if (prefs.windowX != null && prefs.windowY != null) {
        final position = restoredWindowPosition(
          savedPosition: Offset(prefs.windowX!, prefs.windowY!),
          windowSize: initialWindowSize,
          workAreas: await desktopWorkAreas(),
        );
        if (position != null) {
          await windowManager.setPosition(position);
        } else {
          await windowManager.center();
        }
      } else {
        await windowManager.center();
      }
      await windowManager.setTitle('quotabot');
      await windowManager.show();
      await windowManager.focus();
      await windowManager.setMinimumSize(
        desktopMinimumWindowSize(compact: prefs.compact),
      );
      // Gentle bring-to-front for launcher contexts (was aggressive loop causing issues)
      await windowManager.setAlwaysOnTop(true);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await windowManager.setAlwaysOnTop(prefs.alwaysOnTop);
      await windowManager.focus();
      _desktopReadiness.recordWindowReady();
    }),
  );

  runApp(
    QuotaBotApp(prefs: prefs, startupStorageWarning: startupStorageWarning),
  );
}

class QuotaBotApp extends StatelessWidget {
  final Prefs prefs;
  final String? startupStorageWarning;
  @visibleForTesting
  final Widget? testHome;

  const QuotaBotApp({
    super.key,
    required this.prefs,
    this.startupStorageWarning,
  }) : testHome = null;

  @visibleForTesting
  const QuotaBotApp.test({
    super.key,
    required this.prefs,
    this.startupStorageWarning,
    this.testHome = const SizedBox(),
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: appThemeSpec,
      builder: (context, spec, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        themeMode: themeModeForAppTheme(spec),
        theme: _theme(Brightness.light, spec),
        darkTheme: _theme(Brightness.dark, spec),
        builder: (context, child) => RepaintBoundary(
          key: _shotBoundaryKey,
          child: ValueListenableBuilder<double>(
            valueListenable: textScale,
            builder: (context, scale, _) {
              final media = MediaQuery.of(context);
              return MediaQuery(
                data: media.copyWith(
                  textScaler: _PreferenceTextScaler(media.textScaler, scale),
                ),
                child: child!,
              );
            },
          ),
        ),
        home:
            testHome ??
            Dashboard(
              prefs: prefs,
              startupStorageWarning: startupStorageWarning,
            ),
      ),
    );
  }

  ThemeData _theme(Brightness b, String spec) {
    final chrome = AppChromeTheme.forSpec(b, spec);
    final base = ThemeData(
      brightness: b,
      scaffoldBackgroundColor: chrome.scaffold,
      fontFamily: 'Segoe UI',
      colorScheme: ColorScheme.fromSeed(seedColor: chrome.accent, brightness: b)
          .copyWith(
            primary: chrome.accent,
            surface: chrome.scaffold,
            onSurface: chrome.foreground,
          ),
    );
    // Use tabular (monospaced) figures everywhere so digits line up and the main
    // quota view and the analytics screen render numbers identically. Text styles
    // inherit and merge onto these defaults without setting fontFeatures
    // themselves, so this one setting carries across both screens.
    return base.copyWith(
      textTheme: _tabularFigures(base.textTheme),
      extensions: [chrome],
    );
  }
}

/// Composes the app's explicit text-size preference with the operating system
/// accessibility scaler. Keeping the platform scaler intact also preserves any
/// nonlinear large-text policy supplied by newer Flutter embedders.
class _PreferenceTextScaler extends TextScaler {
  final TextScaler platformScaler;
  final double preferenceScale;

  const _PreferenceTextScaler(this.platformScaler, this.preferenceScale);

  @override
  double scale(double fontSize) =>
      platformScaler.scale(fontSize) * preferenceScale;

  @override
  double get textScaleFactor => scale(1);

  @override
  bool operator ==(Object other) =>
      other is _PreferenceTextScaler &&
      other.platformScaler == platformScaler &&
      other.preferenceScale == preferenceScale;

  @override
  int get hashCode => Object.hash(platformScaler, preferenceScale);
}

/// Returns [t] with tabular (fixed-width) figures applied to every text style, so
/// numbers align and render consistently across the whole app.
TextTheme _tabularFigures(TextTheme t) {
  const feats = [FontFeature.tabularFigures()];
  TextStyle? f(TextStyle? s) => s?.copyWith(fontFeatures: feats);
  return TextTheme(
    displayLarge: f(t.displayLarge),
    displayMedium: f(t.displayMedium),
    displaySmall: f(t.displaySmall),
    headlineLarge: f(t.headlineLarge),
    headlineMedium: f(t.headlineMedium),
    headlineSmall: f(t.headlineSmall),
    titleLarge: f(t.titleLarge),
    titleMedium: f(t.titleMedium),
    titleSmall: f(t.titleSmall),
    bodyLarge: f(t.bodyLarge),
    bodyMedium: f(t.bodyMedium),
    bodySmall: f(t.bodySmall),
    labelLarge: f(t.labelLarge),
    labelMedium: f(t.labelMedium),
    labelSmall: f(t.labelSmall),
  );
}

typedef AlertPoster =
    Future<WebhookResult> Function(
      String url,
      Map<String, dynamic> payload, {
      required bool allowExternal,
    });

typedef PrefsSaver = Future<void> Function(Prefs prefs);

typedef ProviderConnector = Future<void> Function(String provider);

typedef ProfileDeleter = void Function(String name);

typedef ProfileSaver = void Function(QuotaProfile profile);

class Dashboard extends StatefulWidget {
  final Prefs prefs;
  final String? startupStorageWarning;
  final bool _hostIntegration;
  final bool? _demoModeOverride;
  @visibleForTesting
  final Future<List<ProviderQuota>> Function()? collector;
  @visibleForTesting
  final List<QuotaProfile>? testProfiles;
  @visibleForTesting
  final AlertPoster? alertPoster;
  @visibleForTesting
  final PrefsSaver? prefsSaver;
  @visibleForTesting
  final ProviderConnector? providerConnector;
  @visibleForTesting
  final ProfileDeleter? profileDeleter;
  @visibleForTesting
  final ProfileSaver? profileSaver;
  final RouteLeaseStore leaseStore;

  const Dashboard({super.key, required this.prefs, this.startupStorageWarning})
    : _hostIntegration = true,
      _demoModeOverride = null,
      collector = null,
      testProfiles = null,
      alertPoster = null,
      prefsSaver = null,
      providerConnector = null,
      profileDeleter = null,
      profileSaver = null,
      leaseStore = const FileRouteLeaseStore();

  /// Builds a deterministic dashboard without desktop plugin or preference
  /// side effects. This exercises the production widget tree while keeping
  /// automated tests isolated from the user's host and account state.
  @visibleForTesting
  const Dashboard.test({
    super.key,
    required this.prefs,
    bool demoMode = true,
    this.collector,
    this.testProfiles,
    this.alertPoster,
    this.prefsSaver,
    this.providerConnector,
    this.profileDeleter,
    this.profileSaver,
    this.leaseStore = const NoopRouteLeaseStore(),
    this.startupStorageWarning,
  }) : _hostIntegration = false,
       _demoModeOverride = demoMode,
       assert(
         demoMode || collector != null,
         'A non-demo test dashboard requires an injected collector.',
       );

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard>
    with WindowListener, TrayListener, ScreenListener {
  List<ProviderQuota> _data = const [];
  List<ProviderQuota> _setupData = const [];
  bool _loading = true;
  late bool _compact = widget.prefs.compact;
  late Cadence _cadence = widget.prefs.cadence;
  late bool _alwaysOnTop = widget.prefs.alwaysOnTop;
  late bool _showInTaskbar = widget.prefs.showInTaskbar;
  late bool _enableNotifications = widget.prefs.enableNotifications;
  late bool _showAccounts = widget.prefs.showAccounts;
  late bool _setupDone = widget.prefs.setupDone;
  late TextSize _textSize = widget.prefs.textSize;
  late String? _webhookUrl = widget.prefs.webhookUrl;
  late bool _webhookAllowExternal = widget.prefs.webhookAllowExternal;
  late List<QuotaProfile> _profiles;
  late QuotaProfile _activeProfile;
  late Set<String> _defaultHidden;
  late ProviderSort _defaultSort;

  /// Providers currently in a red alert state, so a steady spent window is
  /// alerted once on the crossing and re-armed only after it recovers. Mirrors
  /// the edge-trigger state `quotabot watch` keeps. Not reset on a profile
  /// change: the alert engine already drops providers that leave the visible
  /// set and fires for newly-visible red ones, so clearing it here would
  /// re-fire a still-red provider that was already alerted.
  Set<String> _armed = {};
  Completer<void>? _alertCheckFlight;
  bool _alertCheckPending = false;
  bool _isRefreshing = false;
  Future<void>? _refreshInFlight;
  int _failStreak = 0; // consecutive refreshes with no live data at all
  late Set<String> _hidden;
  late ProviderSort _sort;
  Map<String, List<ProviderQuota>> _history = {};
  Map<String, Insights> _insights = {};
  Map<String, List<List<double?>>> _heatmaps = {};
  Map<String, List<HeadroomBucket>> _buckets = {};
  Map<String, BurnStat> _burnStats = {};
  RoutedRequestSummary _routeSummary = emptyRoutedRequestSummary;
  String? _lastRefreshError;
  String? _lastWebhookDeliveryStatus;
  bool? _lastWebhookDeliveryFailed;
  bool _notificationDeliveryFailed = false;
  late String? _settingsStorageWarning = widget.startupStorageWarning;
  String? _profileStorageWarning;
  String? get _preferenceStorageWarning =>
      _profileStorageWarning ?? _settingsStorageWarning;
  final Set<String> _expanded = {}; // providers whose insights panel is open
  bool _overflowing = false; // content taller than the capped window (scrolls)
  // Analytics renders as a body inside this dashboard (same header, same
  // menu), never as a separate route, so the chrome stays consistent.
  bool _showingAnalytics = false;
  FleetRange _analyticsRange = FleetRange.now;
  final Map<String, DateTime> _lastNotified =
      {}; // debounce key -> time for notif spam reduction
  // Providers currently notified about an available redeemable reset. Edge
  // triggered: fire once when a reset appears, re-arm only after it is gone, so
  // an available reset does not re-notify every poll.
  final Set<String> _resetArmed = <String>{};
  Offset? _windowPos;
  DateTime _updated = DateTime.now();
  Timer? _refreshTimer;
  Timer? _tick;
  Timer? _windowMovePersistTimer;
  int _windowMoveRevision = 0;
  final GlobalKey _contentKey = GlobalKey();
  final ScrollController _scroll = ScrollController();

  List<ProviderQuota> get _profiledData =>
      applyProfile(_data, profileWithoutUiPrefs(_activeProfile));

  List<ProviderQuota> get _visible =>
      _profiledData.where((q) => !hiddenTargetsQuota(_hidden, q)).toList();

  /// Display order, respecting user sort preference. Used for both compact
  /// icons and expanded cards. Computed fresh so headroom sorts stay current.
  List<ProviderQuota> get _displayed {
    final list = List<ProviderQuota>.from(_visible);
    if (list.length <= 1) return list;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    switch (_sort) {
      case ProviderSort.alphabetical:
        list.sort((a, b) => a.displayName.compareTo(b.displayName));
        break;
      case ProviderSort.mostAvailable:
        list.sort((a, b) {
          final ha = isTrustedQuotaEvidenceAt(a, now)
              ? providerHeadroom(a, now) ?? -1.0
              : -1.0;
          final hb = isTrustedQuotaEvidenceAt(b, now)
              ? providerHeadroom(b, now) ?? -1.0
              : -1.0;
          return hb.compareTo(ha); // highest headroom first
        });
        break;
      case ProviderSort.mostUsed:
        list.sort((a, b) {
          final ha = isTrustedQuotaEvidenceAt(a, now)
              ? providerHeadroom(a, now) ?? 101.0
              : 101.0;
          final hb = isTrustedQuotaEvidenceAt(b, now)
              ? providerHeadroom(b, now) ?? 101.0
              : 101.0;
          return ha.compareTo(hb); // lowest headroom (most used) first
        });
        break;
      case ProviderSort.defaultOrder:
        break;
    }
    // Local runtimes always sit below the cloud quota services, keeping their
    // relative order from the sort above. Local has no quota to rank against.
    return [...list.where((q) => !q.isLocal), ...list.where((q) => q.isLocal)];
  }

  bool get _showFirstRunPrompt =>
      !_setupDone && !(widget._demoModeOverride ?? _demoMode);

  List<String> get _activeProfileLegacyCredentialFilterProviders {
    final providers = <String>{};
    for (final entry in _activeProfile.accounts.entries) {
      if (entry.value.any(
        (account) => isLegacyCredentialProfileAccountFilter(entry.key, account),
      )) {
        providers.add(entry.key.trim().toLowerCase());
      }
    }
    return providers.toList()..sort();
  }

  Map<String, int> _providerCounts(Iterable<ProviderQuota> data) {
    final counts = <String, int>{};
    for (final q in data) {
      counts[q.provider] = (counts[q.provider] ?? 0) + 1;
    }
    return counts;
  }

  bool _shouldShowAccount(ProviderQuota q, Map<String, int> counts) =>
      _showAccounts && quotaShouldShowAccountLabel(q, counts);

  List<ProviderQuota> get _menuProviders {
    final seen = <String>{};
    final out = <ProviderQuota>[];
    final counts = _providerCounts(_profiledData);
    for (final q in _profiledData) {
      final target = _menuVisibilityTarget(q, counts);
      if (seen.add(target)) out.add(q);
    }
    return out;
  }

  String _menuVisibilityTarget(ProviderQuota quota, Map<String, int> counts) =>
      _showAccounts ? quotaHideTarget(quota, counts) : quota.provider;

  bool _menuProviderVisible(ProviderQuota quota) => _showAccounts
      ? !hiddenTargetsQuota(_hidden, quota)
      : _profiledData
            .where((candidate) => candidate.provider == quota.provider)
            .any((candidate) => !hiddenTargetsQuota(_hidden, candidate));

  List<QuotaProfile> _loadProfiles() {
    if (!widget._hostIntegration) {
      return widget.testProfiles ?? [QuotaProfile.defaultProfile()];
    }
    final loaded = listProfiles();
    return loaded.isEmpty ? [QuotaProfile.defaultProfile()] : loaded;
  }

  QuotaProfile _profileByName(String name) {
    final normalized = normalizeProfileName(name) ?? defaultProfileName;
    for (final profile in _profiles) {
      if (profile.name == normalized) return profile;
    }
    return _profiles.firstWhere(
      (profile) => profile.name == defaultProfileName,
      orElse: QuotaProfile.defaultProfile,
    );
  }

  void _upsertProfile(QuotaProfile profile) {
    final index = _profiles.indexWhere((item) => item.name == profile.name);
    if (index < 0) {
      _profiles = [..._profiles, profile];
    } else {
      _profiles = [..._profiles]..[index] = profile;
    }
  }

  void _applyProfileUiState(QuotaProfile profile) {
    appThemeSpec.value = normalizeAppTheme(profile.theme);
    if (profile.name == defaultProfileName) {
      _hidden = {..._defaultHidden};
      _sort = _defaultSort;
      return;
    }
    _hidden = {...profile.hiddenProviders};
    _sort = sortFromProfile(profile);
  }

  bool _saveActiveProfileUiState() {
    if (_activeProfile.name == defaultProfileName) {
      _defaultHidden = {..._hidden};
      _defaultSort = _sort;
      _setProfileStorageWarning(null);
      return true;
    }
    final updated = profileWithUiPrefs(
      _activeProfile,
      hiddenProviders: _hidden,
      sort: _sort,
    );
    try {
      final saver = widget.profileSaver;
      if (saver != null) {
        saver(updated);
      } else if (widget._hostIntegration) {
        saveProfile(updated);
      }
    } catch (_) {
      _setProfileStorageWarning(
        'Profile changes not saved (storage unavailable)',
      );
      return false;
    }
    _activeProfile = updated;
    _upsertProfile(updated);
    _setProfileStorageWarning(null);
    return true;
  }

  @override
  void initState() {
    super.initState();
    _defaultHidden = {...widget.prefs.hidden};
    _defaultSort = widget.prefs.sort;
    _profiles = _loadProfiles();
    _activeProfile = _profileByName(widget.prefs.activeProfile);
    _applyProfileUiState(_activeProfile);
    _windowPos = widget.prefs.windowX == null || widget.prefs.windowY == null
        ? null
        : Offset(widget.prefs.windowX!, widget.prefs.windowY!);
    if (widget._hostIntegration) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      screenRetriever.addListener(this);
      unawaited(_initTray());
      unawaited(windowManager.setAlwaysOnTop(_alwaysOnTop));
      unawaited(windowManager.setSkipTaskbar(!_showInTaskbar));
      unawaited(
        windowManager.setMinimumSize(
          desktopMinimumWindowSize(compact: _compact),
        ),
      );
    }
    _refresh();
    if (_shotsMode) unawaited(_exportShots());
    // Repaint periodically so the age label and reset countdowns stay current.
    // Thirty seconds is plenty when the labels are in minutes, and avoids the
    // distraction of a per-second ticking clock.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  /// Captures the current route under [_shotBoundaryKey] to a PNG. Used only by
  /// screenshot mode. The render object is read synchronously (callers settle the
  /// frame with a delay first), so no BuildContext crosses an async gap.
  Future<void> _captureBoundary(String filename, [GlobalKey? key]) async {
    final boundary =
        (key ?? _shotBoundaryKey).currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) return;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return;
    final dir = Platform.environment['QUOTABOT_SHOTS_DIR'] ?? '.';
    File('$dir/$filename').writeAsBytesSync(data.buffer.asUint8List());
  }

  Future<void> _setShotCompact(bool value) async {
    if (_compact != value) {
      setState(() => _compact = value);
      _applySize();
    }
    await Future<void>.delayed(const Duration(milliseconds: 650));
    await WidgetsBinding.instance.endOfFrame;
  }

  /// Loads demo data (via [_demoMode]), captures the widget then the analytics
  /// view, and exits. Reuses the real widgets so the README images stay faithful.
  Future<void> _exportShots() async {
    // The window show is gated behind windowManager.waitUntilReadyToShow, so wait
    // out that plus the first real paint before the first capture.
    await Future<void>.delayed(const Duration(seconds: 2));
    await WidgetsBinding.instance.endOfFrame;
    await _setShotCompact(false);
    await _captureBoundary('screenshot-widget.png');
    if (_gifFramesMode) {
      await _captureBoundary('demo-01-widget-expanded.png');
      await _setShotCompact(true);
      await _captureBoundary('demo-02-widget-collapsed.png');
      await _setShotCompact(false);
      await _captureBoundary('demo-03-widget-expanded.png');
    }
    _showFleet(initialRange: FleetRange.quarter);
    await Future<void>.delayed(
      const Duration(milliseconds: 1400),
    ); // route + charts
    await WidgetsBinding.instance.endOfFrame;
    await _captureBoundary('screenshot-analytics.png');
    if (_gifFramesMode) {
      await _captureBoundary('demo-04-analytics-90d.png');
    }
    _showTerminal(_demoTopFrame());
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await WidgetsBinding.instance.endOfFrame;
    await _captureBoundary('screenshot-top.png', _termShotKey);
    if (_gifFramesMode) {
      await _captureBoundary('demo-05-top.png', _termShotKey);
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
    exit(0);
  }

  /// Renders the `quotabot top` view over the demo fleet to ANSI lines, for the
  /// terminal screenshot. Truecolor so the gradient meters show.
  List<String> _demoTopFrame() {
    final now = nowEpoch();
    final demo = cli_demo.demoProviders(now);
    return renderTopFrame(
      providers: demo,
      suggestion: decide(
        demo,
        now,
        context: providerRouteDecisionContext(
          demo,
          now,
          burnStatsByProvider: cli_demo.demoBurnStats(),
          catalog: kModelCatalog,
        ),
      ).route,
      now: now,
      // Wide enough that the meters stay generous with the forecast column held
      // back, matching a typical 80-120 column terminal.
      width: 84,
      color: true,
      clock: '11:43:07',
      depth: ColorDepth.truecolor,
    );
  }

  /// Pushes a terminal panel showing [lines], wrapped in a boundary the exporter
  /// captures. A horizontal scroll view gives the panel unbounded width so the
  /// capture takes the frame's natural size instead of clipping to the (portrait)
  /// window. Screenshot mode only.
  void _showTerminal(List<String> lines) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: const Color(0xFF0D1117),
          body: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: RepaintBoundary(
              key: _termShotKey,
              child: TerminalShot(ansiLines: lines),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    if (widget._hostIntegration) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
      screenRetriever.removeListener(this);
    }
    _refreshTimer?.cancel();
    _tick?.cancel();
    _windowMovePersistTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void onWindowMoved() async {
    final revision = ++_windowMoveRevision;
    final position = await windowManager.getPosition();
    if (!mounted || revision != _windowMoveRevision) return;
    _windowPos = position;
    _windowMovePersistTimer?.cancel();
    _windowMovePersistTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_persistPrefs());
    });
  }

  @override
  void onScreenEvent(String eventName) {
    unawaited(_reconcileWindowGeometry());
  }

  Future<void> _reconcileWindowGeometry() async {
    try {
      final position = await windowManager.getPosition();
      final size = await windowManager.getSize();
      final workAreas = await desktopWorkAreas();
      if (!mounted || workAreas.isEmpty) return;
      final restored = restoredWindowPosition(
        savedPosition: position,
        windowSize: size,
        workAreas: workAreas,
      );
      if (restored != null && restored != position) {
        _windowMoveRevision++;
        _windowMovePersistTimer?.cancel();
        await windowManager.setPosition(restored);
        if (!mounted) return;
        _windowPos = restored;
        unawaited(_persistPrefs());
      }
      _applySize();
    } catch (_) {
      // Display discovery is optional. Keep the current reachable window when
      // the platform cannot provide updated monitor geometry.
    }
  }

  // System tray: keep quotabot one click away, and let the window close to the
  // tray instead of quitting so it can sit quietly in the background. The tray
  // menu is the way back and the only place that truly quits.
  Future<void> _initTray() async {
    try {
      await trayManager.setIcon(
        Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.png',
      );
      // tray_manager 0.5.3 does not implement setToolTip on Linux. Calling the
      // unsupported method aborts the rest of tray initialization there.
      if (!Platform.isLinux) {
        await trayManager.setToolTip('quotabot');
      }
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: 'Show quotabot'),
            MenuItem(key: 'refresh', label: 'Refresh now'),
            MenuItem(key: 'analytics', label: 'Quota analytics'),
            MenuItem.separator(),
            MenuItem(key: 'quit', label: 'Quit'),
          ],
        ),
      );
      if (_desktopReadiness.enabled && Platform.isMacOS) {
        final bounds = await trayManager.getBounds();
        if (bounds == null || bounds.isEmpty) {
          throw StateError('Native tray bounds are unavailable.');
        }
      }
      // Only now that the tray exists do we redirect close to hide: otherwise a
      // platform without a tray would have no way to reopen a hidden window.
      await windowManager.setPreventClose(true);
      _desktopReadiness.recordTrayReady(true);
    } catch (_) {
      // No tray on this platform/session; the window keeps normal close-to-quit.
      _desktopReadiness.recordTrayReady(false);
    }
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    _windowMoveRevision++;
    _windowMovePersistTimer?.cancel();
    await _persistPrefs();
    await Prefs.flush();
    await windowManager.setPreventClose(false);
    await trayManager.destroy();
    await windowManager.destroy();
  }

  @override
  void onTrayIconMouseDown() => unawaited(_showWindow());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(_showWindow());
      case 'refresh':
        unawaited(_showWindow());
        _refresh();
      case 'analytics':
        unawaited(_showWindow());
        _showFleet();
      case 'quit':
        unawaited(_quit());
    }
  }

  @override
  void onWindowClose() {
    // Closing hides to the tray (see [_initTray]); Quit lives in the tray menu.
    unawaited(windowManager.hide());
  }

  Future<bool> _persistPrefs({bool saveProfileUiState = false}) async {
    if (!widget._hostIntegration && widget.prefsSaver == null) {
      return !saveProfileUiState || _saveActiveProfileUiState();
    }
    final profileSaved = !saveProfileUiState || _saveActiveProfileUiState();
    final next = Prefs(
      hidden: _defaultHidden,
      compact: _compact,
      cadence: _cadence,
      alwaysOnTop: _alwaysOnTop,
      showInTaskbar: _showInTaskbar,
      enableNotifications: _enableNotifications,
      sort: _defaultSort,
      activeProfile: _activeProfile.name,
      textSize: _textSize,
      showAccounts: _showAccounts,
      webhookUrl: _webhookUrl,
      webhookAllowExternal: _webhookAllowExternal,
      setupDone: _setupDone,
      windowX: _windowPos?.dx,
      windowY: _windowPos?.dy,
    );
    try {
      await (widget.prefsSaver?.call(next) ?? next.save());
      _setPreferenceStorageWarning(null);
      return profileSaved;
    } catch (_) {
      _setPreferenceStorageWarning('Settings not saved (storage unavailable)');
      return false;
    }
  }

  void _setPreferenceStorageWarning(String? warning) {
    if (!mounted || _settingsStorageWarning == warning) return;
    setState(() => _settingsStorageWarning = warning);
    if (warning != null && widget._hostIntegration) {
      stderr.writeln(
        'quotabot: settings were not saved because secure storage is '
        'unavailable',
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _applySize());
  }

  void _setProfileStorageWarning(String? warning) {
    if (!mounted || _profileStorageWarning == warning) return;
    setState(() => _profileStorageWarning = warning);
    if (warning != null && widget._hostIntegration) {
      stderr.writeln(
        'quotabot: profile changes were not saved because secure storage is '
        'unavailable',
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _applySize());
  }

  /// Collects provider quota, off the UI isolate in production so the
  /// synchronous parts of a collect (SQLite reads, protobuf decode, JSON
  /// parsing) do not block the main isolate and stall the loading animation.
  ///
  /// Falls back to the main isolate if the background isolate cannot run the
  /// collector (for example a native-library initialization failure), so
  /// collection always works, just less smoothly. Test injection bypasses the
  /// isolate entirely.
  Future<List<ProviderQuota>> _collectProviders() async {
    if (widget.collector != null) return widget.collector!();
    try {
      return await Isolate.run(collectAll);
    } catch (_) {
      return collectAll();
    }
  }

  Future<void> _refresh() {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;

    late final Future<void> tracked;
    tracked = _performRefresh().whenComplete(() {
      if (identical(_refreshInFlight, tracked)) {
        _refreshInFlight = null;
      }
    });
    _refreshInFlight = tracked;
    return tracked;
  }

  Future<void> _performRefresh() async {
    if (widget._demoModeOverride ?? _demoMode) {
      _loadDemo();
      return;
    }
    setState(() => _isRefreshing = true);
    try {
      // A hard deadline over the whole collect: adapters carry their own
      // per-provider deadlines, but if anything ever hangs past them, the
      // refresh loop must recover rather than freeze all future refreshes.
      final results = await _collectProviders().timeout(
        const Duration(seconds: 45),
      );
      final routeSummary = widget._hostIntegration
          ? loadRoutedRequestSummary()
          : emptyRoutedRequestSummary;
      if (!mounted) return;
      final active = widget._hostIntegration
          ? visibleProviderRows(results, detectInstalledAgenticTools())
          : results;
      final setupRows = providerSetupRows(results);
      final profiles = _loadProfiles();
      final selectedProfile = _activeProfile.name;
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final burnStats = widget._hostIntegration
          ? recentBurnStatsByQuota(active, nowSec)
          : <String, BurnStat>{};
      // Track systemic failure...
      final anyLive = hasSuccessfulRefreshEvidence(active, nowSec);
      _failStreak = anyLive ? 0 : _failStreak + 1;
      setState(() {
        _profiles = profiles;
        _activeProfile = _profileByName(selectedProfile);
        _applyProfileUiState(_activeProfile);
        _data = active;
        _setupData = setupRows;
        _loading = false;
        _updated = DateTime.now();
        _history = {};
        _heatmaps = {};
        _buckets = {};
        _burnStats = burnStats;
        _routeSummary = routeSummary;
        _lastRefreshError = anyLive
            ? null
            : refreshNoCurrentDataMessage(hasRows: active.isNotEmpty);
        final tz = DateTime.now().timeZoneOffset;
        final rawInsights = <String, Insights>{};
        if (widget._hostIntegration) {
          for (final q in active) {
            final key = quotaDisplayKey(q);
            _history[key] = loadHistory(q.provider, account: q.account);
            if (!q.isLocal) {
              final buckets = loadBuckets(q.provider, account: q.account);
              _buckets[key] = buckets;
              rawInsights[key] = Insights.from(buckets, nowSec, tzOffset: tz);
              _heatmaps[key] = smoothedWeekHourHeatmap(buckets, tzOffset: tz);
            }
          }
        }
        _insights = shrinkInsightsReliability(rawInsights);
      });
      if (widget._hostIntegration || widget.alertPoster != null) {
        // Fire-and-forget: notification and webhook posting must not delay the
        // refresh completing or the post-frame resize; _checkAndNotify swallows
        // its own errors, so an unawaited failure cannot escape.
        unawaited(_checkAndNotify());
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _applySize());
    } catch (error) {
      // Catch Error as well as Exception: a latent adapter fault (a bad cast,
      // .first on empty) surfaces as an Error, and the isolate-failure fallback
      // rethrows it on the main isolate. Catching only Exception let it escape
      // as an unhandled async error every poll while the UI showed no failure.
      // A failed or timed-out refresh keeps the last data on screen as
      // explicitly stale evidence; the next poll (scheduled in finally)
      // retries. This prevents a previously live account-wide value from
      // remaining routable after the collector can no longer confirm it.
      _failStreak += 1;
      if (mounted) {
        final message = refreshFailureMessage(
          error,
          hasPreviousData: _data.isNotEmpty,
        );
        setState(() {
          _data = retainSnapshotAfterRefreshFailure(_data, note: message);
          _setupData = retainSnapshotAfterRefreshFailure(
            _setupData,
            note: message,
          );
          _loading = false;
          _updated = DateTime.now();
          _lastRefreshError = message;
        });
      }
    } finally {
      // Always reschedule, so one thrown refresh can never stop auto-polling.
      if (mounted) {
        _scheduleNext();
        setState(() => _isRefreshing = false);
      }
    }
  }

  /// Populates the dashboard with synthetic demo data (QUOTABOT_DEMO=1) so the
  /// app can be previewed or screenshotted without touching real accounts.
  void _loadDemo() {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final tz = DateTime.now().timeZoneOffset;
    final buckets = demoBuckets();
    final demo = demoData();
    setState(() {
      if (_shotsMode) {
        _compact = false;
        _hidden = {};
        _sort = ProviderSort.defaultOrder;
      }
      _showAccounts = true; // show demo account labels in screenshots
      _data = demo;
      _setupData = providerSetupRows(demo);
      _loading = false;
      _updated = DateTime.now();
      _history = {};
      _heatmaps = {};
      _buckets = {};
      _burnStats = cli_demo.demoBurnStats();
      _routeSummary = demoRoutedRequestSummary();
      final rawInsights = <String, Insights>{};
      for (final q in demo) {
        final b = buckets[q.provider];
        if (b == null) continue;
        final key = quotaDisplayKey(q);
        _buckets[key] = b;
        rawInsights[key] = Insights.from(b, nowSec, tzOffset: tz);
        _heatmaps[key] = smoothedWeekHourHeatmap(b, tzOffset: tz);
      }
      _insights = shrinkInsightsReliability(rawInsights);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _applySize());
    _scheduleNext(); // keep the "as of" label current even in demo mode
    if (Platform.environment['QUOTABOT_SHOT'] == '1') {
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) _showFleet();
      });
    }
  }

  /// Adaptive polling: fast only when a reset is imminent or a cap is nearly
  /// hit; slow when everything is healthy and resets are far away.
  void _scheduleNext() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(_nextInterval(), _refresh);
  }

  Duration _nextInterval() {
    // Fixed cadences override the smart logic.
    if (_cadence == Cadence.m15) return const Duration(minutes: 15);
    if (_cadence == Cadence.h1) return const Duration(hours: 1);
    // The adaptive cadence is shared with the CLI's `top` so both poll alike.
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return Duration(
      seconds: nextRefreshSeconds(_data, now, failStreak: _failStreak),
    );
  }

  /// Resize the window to hug the content. Live measurement of the rendered
  /// content proved unreliable here (the content is clamped to the window when
  /// it overflows, and window_manager's pixel units don't match Flutter's
  /// logical pixels under display scaling), so the height is derived
  /// deterministically from the provider and window counts instead. It is
  /// slightly generous so nothing is clipped, and the body is scrollable as a
  /// safety net. Capped at the screen height (see [_maxWindowHeight]).
  void _applySize() {
    if (!widget._hostIntegration) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Analytics keeps whatever size the window has (its body scrolls); the
      // quota view's content-hugging resize resumes when it closes.
      if (_showingAnalytics) return;
      final maxH = _maxWindowHeight();
      double w;
      double h;
      if (_compact) {
        final n = _displayed.length.clamp(1, _shotsMode ? 16 : 8);
        final maxCompactWidth = _shotsMode ? 680.0 : 400.0;
        w = (n * 46 + 96).clamp(140.0, maxCompactWidth).toDouble();
        h = 50;
      } else {
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        w = 340;
        // Estimates tuned to the real rendered heights so the frameless window
        // hugs the content (no translucent dead space below it). The body
        // scrolls, so a small undershoot is caught rather than clipped.
        h = _showFirstRunPrompt
            ? 112
            : 62; // header row, onboarding, and outer paddings
        if (_displayed.isEmpty) {
          h +=
              _activeProfileLegacyCredentialFilterProviders.isNotEmpty ||
                  _profiledData.isNotEmpty
              ? 72
              : 38;
        }
        for (final q in _displayed) {
          final key = quotaDisplayKey(q);
          final isExpanded = _expanded.contains(key);
          // The tight default hides the provenance line, model-specific quota,
          // and the "usually" line; they only add height once the card expands.
          final scopedRows = desktopScopedModelQuotas(q).length * 2;
          final rows =
              providerTileQuotaRowCount(q, now) - (isExpanded ? 0 : scopedRows);
          var card = 64.0 + rows * 14.0; // card chrome and data rows
          if (isExpanded && desktopScopedModelQuotas(q).isNotEmpty) {
            card += 18; // model-specific section heading
          }
          if (q.suspect != null && q.driftReason == null) card += 20;
          // The inline Connect button shows on a failed read for a provider that
          // supports quotabot's own login; budget its row so the first frame
          // before measured sizing does not clip it.
          if (_canConnectProvider(q.provider) &&
              !q.isLocal &&
              (q.stale || !isTrustedQuotaEvidenceAt(q, now))) {
            card += 28;
          }
          if (q.isLocal) card += q.details.length * 14; // detail lines
          if (isExpanded && (_history[key] ?? const []).isNotEmpty) {
            card += 20; // "usually ~X% free" line
          }
          // An expanded insights panel adds a sparkline, a couple of lines, and
          // (when there is enough data) a heatmap grid.
          if (_expanded.contains(key) && (_insights[key]?.samples ?? 0) > 0) {
            card += 96;
          }
          h += card;
        }
        h += (_displayed.length - 1).clamp(0, 20) * 8; // inter-card gaps
        // Prefer the real measured content height when available: the content
        // box lives inside a scroll view so its render box reports the full
        // intrinsic height, which the estimate above cannot do for wrapped
        // text (long "no live data" notes). The estimate is the fallback.
        final measured = _measuredContentHeight();
        final content = (measured != null && measured > 80) ? measured : h;
        h = content.clamp(120.0, maxH).toDouble();
        // Content taller than the capped window: it scrolls, so show the bar.
        final overflow = content > maxH + 1;
        if (mounted && overflow != _overflowing) {
          setState(() => _overflowing = overflow);
        }
      }
      try {
        await windowManager.setSize(Size(w, h));
      } catch (_) {}
    });
  }

  /// True total content height (viewport + any overflow), read from the scroll
  /// position. This reflects wrapped text exactly and, unlike measuring the
  /// content render box, never collapses to the viewport height. Null until the
  /// scroll view is laid out.
  double? _measuredContentHeight() {
    if (!_scroll.hasClients) return null;
    final pos = _scroll.position;
    if (!pos.hasViewportDimension) return null;
    return pos.viewportDimension + pos.maxScrollExtent;
  }

  /// Largest height we will give the window: the screen height (of the display
  /// the window is on) minus a margin for the taskbar. Beyond this the content
  /// scrolls rather than running off-screen. Falls back to a safe default if the
  /// display info is not available yet.
  double _maxWindowHeight() {
    try {
      final display = View.of(context).display;
      final screenH = display.size.height / display.devicePixelRatio;
      return (screenH - 80).clamp(200.0, 4000.0).toDouble();
    } catch (_) {
      return 900.0;
    }
  }

  void _toggleCompact() {
    setState(() {
      _compact = !_compact;
      // The compact strip is the quota view; leaving analytics keeps the
      // header's collapse button honest in both directions.
      if (_compact) _showingAnalytics = false;
    });
    if (widget._hostIntegration) {
      unawaited(
        windowManager.setMinimumSize(
          desktopMinimumWindowSize(compact: _compact),
        ),
      );
    }
    _applySize();
    unawaited(_persistPrefs());
  }

  void _toggleHidden(String target) {
    setState(() {
      if (!_hidden.remove(target)) _hidden.add(target);
    });
    _applySize();
    unawaited(_persistPrefs(saveProfileUiState: true));
  }

  void _toggleProviderHidden(String provider) {
    final quotas = _profiledData
        .where((quota) => quota.provider == provider)
        .toList(growable: false);
    final allHidden =
        quotas.isNotEmpty &&
        quotas.every((quota) => hiddenTargetsQuota(_hidden, quota));
    setState(() {
      _hidden.removeWhere(
        (target) => target == provider || target.startsWith('$provider|'),
      );
      if (!allHidden) _hidden.add(provider);
    });
    _applySize();
    unawaited(_persistPrefs(saveProfileUiState: true));
  }

  void _toggleQuotaHidden(ProviderQuota quota) {
    final counts = _providerCounts(_profiledData);
    final target = quotaHideTarget(quota, counts);
    setState(() {
      if (_hidden.contains(quota.provider) && target != quota.provider) {
        _hidden.remove(quota.provider);
        for (final other in _profiledData.where(
          (q) => q.provider == quota.provider && q != quota,
        )) {
          _hidden.add(quotaHideTarget(other, counts));
        }
        _hidden.remove(target);
      } else if (hiddenTargetsQuota(_hidden, quota)) {
        _hidden.remove(target);
      } else {
        _hidden.add(target);
      }
    });
    _applySize();
    unawaited(_persistPrefs(saveProfileUiState: true));
  }

  /// Right-click / long-press menu on a provider card: quick set-up help and
  /// hide, without opening the main menu.
  Future<void> _showCardMenu(ProviderQuota q, Offset globalPos) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPos.dx, globalPos.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(value: 'setup', child: Text('Set up ${q.displayName}')),
        PopupMenuItem(
          value: 'hide',
          child: Text(
            _shouldShowAccount(q, _providerCounts(_profiledData))
                ? 'Hide ${q.displayName} '
                      '(${quotaAccountDisplayLabel(q.account)})'
                : 'Hide ${q.displayName}',
          ),
        ),
      ],
    );
    if (choice == 'hide') {
      _toggleQuotaHidden(q);
    } else if (choice == 'setup') {
      _showProviderSetup(q);
    }
  }

  /// A setup-help dialog tailored to the provider, with an inline "Connect now"
  /// for the two providers that support quotabot's own login.
  void _showProviderSetup(ProviderQuota q) {
    final canConnect =
        widget._hostIntegration && _canConnectProvider(q.provider);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Set up ${q.displayName}'),
        content: Text(providerSetupText(q.provider)),
        actions: [
          if (canConnect)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _connectAndValidate(q.provider, account: q.account);
              },
              child: const Text('Connect now'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chrome = AppChromeTheme.of(context);

    if (_showingAnalytics && !_compact && !_loading) {
      // Analytics fills the window under the same header as the quota view
      // and scrolls internally, so the chrome never changes between views.
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: chrome.scaffold,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: chrome.border),
          ),
          child: Column(
            children: [
              _header(),
              const SizedBox(height: 2),
              Expanded(
                child: FleetScreen(
                  key: ValueKey(_analyticsRange),
                  data: _visible,
                  buckets: _buckets,
                  dark: Theme.of(context).brightness == Brightness.dark,
                  showAccounts: _showAccounts,
                  routedRequests: _routeSummary,
                  initialRange: _analyticsRange,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      // The scroll view is the body directly (not wrapped in Align) so it
      // receives the window's tight height as its viewport and reports overflow
      // via maxScrollExtent. _applySize reads that to size the window to hug the
      // content; when more providers than fit on screen exist the window caps at
      // the screen height and the rest scrolls instead of overflowing.
      body: Scrollbar(
        controller: _scroll,
        thumbVisibility: _overflowing,
        child: SingleChildScrollView(
          controller: _scroll,
          physics: const ClampingScrollPhysics(),
          child: _contentBox(chrome, _contentKey),
        ),
      ),
    );
  }

  Widget _contentBox(AppChromeTheme chrome, Key? key) {
    return Container(
      key: key,
      decoration: BoxDecoration(
        color: chrome.scaffold,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: chrome.border),
      ),
      child: _loading
          ? SizedBox(
              width: 220,
              height: 80,
              child: Center(
                child: QuotaLoadingIndicator(
                  size: 30,
                  color: _quotaGreen,
                  trackColor: chrome.gaugeTrack,
                ),
              ),
            )
          : _compact
          ? _compactView()
          : _expandedView(chrome.card),
    );
  }

  Widget _expandedView(Color card) {
    final displayed = _displayed;
    final counts = _providerCounts(displayed);
    final groups = displayed.isEmpty
        ? const <ProviderDisplayGroup>[]
        : _showAccounts
        ? groupProvidersForDisplay(displayed)
        : [ProviderDisplayGroup(account: null, quotas: displayed)];
    final showGroupHeaders = groups.length > 1;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        if (_showFirstRunPrompt) _firstRunPrompt(),
        const SizedBox(height: 2),
        if (groups.isEmpty)
          _emptyProfileState()
        else
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: widget._hostIntegration
                ? (_) => windowManager.startDragging()
                : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var g = 0; g < groups.length; g++) ...[
                    if (showGroupHeaders) ...[
                      if (g > 0) const SizedBox(height: 10),
                      _AccountGroupHeader(
                        account: groups[g].account,
                        count: groups[g].quotas.length,
                      ),
                      const SizedBox(height: 6),
                    ],
                    for (var i = 0; i < groups[g].quotas.length; i++) ...[
                      if (i > 0) const SizedBox(height: 8),
                      _providerTile(groups[g].quotas[i], card, counts),
                    ],
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _emptyProfileState() {
    final muted = AppChromeTheme.of(context).muted;
    final repairProviders = _activeProfileLegacyCredentialFilterProviders;
    final needsCredentialFilterRepair = repairProviders.isNotEmpty;
    final allProfileProvidersHidden =
        !needsCredentialFilterRepair && _profiledData.isNotEmpty;
    final providerNames = needsCredentialFilterRepair
        ? _joinedCredentialProviderNames(repairProviders)
        : '';
    final repairMessage = repairProviders.length > 1
        ? 'This profile uses older $providerNames account filters. '
              'Select the current credentials before routing.'
        : 'This profile uses an older $providerNames account filter. '
              'Select the current $providerNames credential before routing.';
    final message = needsCredentialFilterRepair
        ? repairMessage
        : allProfileProvidersHidden
        ? 'All providers in ${profileLabel(_activeProfile)} are hidden. '
              'Use the Providers menu to show one.'
        : 'No providers in ${profileLabel(_activeProfile)}';
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: widget._hostIntegration
          ? (_) => windowManager.startDragging()
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              label: message,
              child: ExcludeSemantics(
                child: Text(
                  message,
                  style: TextStyle(fontSize: AppType.caption, color: muted),
                ),
              ),
            ),
            if (needsCredentialFilterRepair)
              TextButton(
                onPressed: _showProfileEditor,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.only(top: 4),
                  minimumSize: const Size(0, 30),
                ),
                child: const Text('Edit profile'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _firstRunPrompt() {
    final chrome = AppChromeTheme.of(context);
    return Semantics(
      container: true,
      label:
          'Start here. Review provider connections and quota evidence before '
          'using recommendations.',
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 2, 12, 4),
        padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
        decoration: BoxDecoration(
          color: chrome.tileBorder.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: chrome.border),
        ),
        child: Row(
          children: [
            Icon(Icons.fact_check_outlined, size: 16, color: chrome.muted),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                'Start here: review provider connections',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppType.caption,
                  fontWeight: FontWeight.w600,
                  color: chrome.foreground,
                ),
              ),
            ),
            TextButton(
              onPressed: () => _finishFirstRunSetup(openProviders: true),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 7),
                minimumSize: const Size(0, 30),
              ),
              child: const Text('Review'),
            ),
            IconButton(
              tooltip: 'Dismiss getting started',
              onPressed: _finishFirstRunSetup,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              icon: Icon(Icons.close_rounded, size: 15, color: chrome.muted),
            ),
          ],
        ),
      ),
    );
  }

  void _finishFirstRunSetup({bool openProviders = false}) {
    if (_setupDone) return;
    setState(() => _setupDone = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _applySize());
    unawaited(_persistPrefs());
    if (openProviders) _showSetup();
  }

  Widget _providerTile(ProviderQuota q, Color card, Map<String, int> counts) {
    final key = quotaDisplayKey(q);
    return ProviderTile(
      key: ValueKey(key),
      quota: q,
      cardColor: card,
      history: _history[key] ?? const [],
      insights: _insights[key],
      heatmap: _heatmaps[key],
      expanded: _expanded.contains(key),
      onToggle: () => setState(() {
        if (!_expanded.remove(key)) _expanded.add(key);
        WidgetsBinding.instance.addPostFrameCallback((_) => _applySize());
      }),
      onContextMenu: (pos) => _showCardMenu(q, pos),
      onConnect: widget._hostIntegration && _canConnectProvider(q.provider)
          ? () => unawaited(_connectAndValidate(q.provider, account: q.account))
          : null,
      showAccounts: _shouldShowAccount(q, counts),
    );
  }

  /// Tiny strip: each visible provider as logo + status dot. Glanceable.
  Widget _compactView() {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final chrome = AppChromeTheme.of(context);
    final muted = chrome.muted;
    final fg = chrome.foreground;
    final displayed = _displayed;
    final counts = _providerCounts(displayed);
    return SizedBox(
      height: 46,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 6, 0),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: widget._hostIntegration
                    ? (_) => windowManager.startDragging()
                    : null,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: _shotsMode
                      ? const NeverScrollableScrollPhysics()
                      : const ClampingScrollPhysics(),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (displayed.isEmpty)
                        Text(
                          'No providers',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppType.caption,
                            color: muted,
                          ),
                        )
                      else
                        for (int i = 0; i < displayed.length; i++)
                          Padding(
                            padding: EdgeInsets.only(
                              right: i == displayed.length - 1 ? 0 : 10,
                            ),
                            child: _FocusableCompactProviderChip(
                              key: ValueKey(
                                'compact-provider-${quotaDisplayKey(displayed[i])}',
                              ),
                              message: _compactTooltip(
                                displayed[i],
                                counts,
                                now,
                              ),
                              child: _compactChip(displayed[i], now, fg),
                            ),
                          ),
                    ],
                  ),
                ),
              ),
            ),
            if (_preferenceStorageWarning != null)
              Tooltip(
                message: _preferenceStorageWarning!,
                child: Semantics(
                  label: _preferenceStorageWarning,
                  liveRegion: true,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: Color(0xFFD29922),
                    ),
                  ),
                ),
              ),
            _iconButton(
              Icons.open_in_full_rounded,
              muted,
              _toggleCompact,
              tooltip: 'Expand',
            ),
            _iconButton(
              Icons.close_rounded,
              muted,
              widget._hostIntegration ? windowManager.close : null,
              tooltip: 'Close',
            ),
          ],
        ),
      ),
    );
  }

  Widget _compactChip(ProviderQuota q, int now, Color fg) {
    final st = providerStatus(q, now);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ProviderLogo(q.provider, size: 18, color: fg),
        const SizedBox(width: 5),
        st.hasData
            ? _Dot(st.color, size: 8)
            : Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: st.color, width: 1.4),
                ),
              ),
      ],
    );
  }

  String _compactTooltip(ProviderQuota q, Map<String, int> counts, int now) {
    final base = _shouldShowAccount(q, counts)
        ? '${q.displayName} (${quotaAccountDisplayLabel(q.account)})'
        : q.displayName;
    return '$base - ${desktopProviderTrustLine(q, now)}';
  }

  RouteSuggestion _routeSuggestion(int now) => decide(
    _visible,
    now,
    context: providerRouteDecisionContext(
      _visible,
      now,
      burnStatsByProvider: _burnStats,
      activeLeases: widget.leaseStore.active(now),
      pipePenaltyByProvider: _routeSummary.pipePenaltyByProvider(now: now),
      catalog: kModelCatalog,
      preferenceOrder: _activeProfile.preferenceOrder,
    ),
  ).route;

  /// Average remaining headroom across visible providers that report quota,
  /// as a percent (0..100), or null when nothing has data. This is the "pool"
  /// the header gauge fills to.
  double? _poolHeadroom() {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return trustedPoolHeadroom(_visible, now);
  }

  Widget _header() {
    final chrome = AppChromeTheme.of(context);
    final muted = chrome.muted;
    const warning = Color(0xFFD29922);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final suggestion = _routeSuggestion(now);
    final routeLine = desktopRouteSignalLine(
      suggestion,
      _visible,
      now,
      showAccounts: _showAccounts,
    );
    final routeDetail = desktopRouteDetailLine(
      suggestion,
      _visible,
      now,
      showAccounts: _showAccounts,
    );
    final largeText = MediaQuery.textScalerOf(context).scale(10) > 14;
    final titleCluster = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        () {
          final pool = _poolHeadroom();
          final track = chrome.gaugeTrack;
          return Semantics(
            label: pool == null
                ? 'Trusted quota headroom unavailable'
                : 'Average trusted quota headroom ${pool.round()} percent',
            excludeSemantics: true,
            child: AppGauge(
              size: 17,
              value: (pool ?? 0) / 100.0,
              fillColor: pool == null ? track : _availColor(pool),
              trackColor: track,
            ),
          );
        }(),
        const SizedBox(width: 7),
        Text(
          _showingAnalytics ? 'Analytics' : 'Quota',
          style: TextStyle(
            fontSize: AppType.title,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
            color: chrome.foreground,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            checkedAtLabel(_updated),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: AppType.caption, color: muted),
          ),
        ),
        if (_activeProfile.name != defaultProfileName) ...[
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              profileLabel(_activeProfile),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.label,
                fontWeight: FontWeight.w600,
                color: muted,
              ),
            ),
          ),
        ],
      ],
    );
    final actions = <Widget>[
      _iconButton(
        _isRefreshing ? Icons.sync : Icons.refresh_rounded,
        muted,
        _isRefreshing ? null : _refresh,
        tooltip: _isRefreshing ? 'Refreshing quotas' : 'Refresh now',
      ),
      _iconButton(
        _showingAnalytics ? Icons.arrow_back_rounded : Icons.bar_chart_rounded,
        muted,
        _showingAnalytics ? _closeFleet : _showFleet,
        tooltip: _showingAnalytics ? 'Back to quotas' : 'Quota analytics',
      ),
      _iconButton(
        Icons.close_fullscreen_rounded,
        muted,
        _toggleCompact,
        tooltip: 'Collapse',
      ),
      _menuButton(muted),
      _iconButton(
        Icons.help_outline_rounded,
        muted,
        _showHelp,
        tooltip: 'Setup and help',
      ),
      _iconButton(
        Icons.close_rounded,
        muted,
        widget._hostIntegration ? windowManager.close : null,
        tooltip: 'Close',
      ),
    ];
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: widget._hostIntegration
          ? (_) => windowManager.startDragging()
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (largeText) ...[
              titleCluster,
              Align(
                alignment: Alignment.centerRight,
                child: Row(mainAxisSize: MainAxisSize.min, children: actions),
              ),
            ] else
              Row(
                children: [
                  Expanded(child: titleCluster),
                  ...actions,
                ],
              ),
            if (routeLine != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 4),
                child: Row(
                  children: [
                    Icon(Icons.alt_route_rounded, size: 12, color: muted),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Tooltip(
                        message: routeDetail ?? routeLine,
                        child: Text(
                          routeLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppType.caption,
                            fontWeight: FontWeight.w500,
                            color: muted,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (_preferenceStorageWarning != null)
              _warningLine(_preferenceStorageWarning!, warning),
            if (_lastRefreshError != null)
              _warningLine(_lastRefreshError!, warning),
          ],
        ),
      ),
    );
  }

  Widget _warningLine(String message, Color warning) => Padding(
    padding: const EdgeInsets.only(top: 4, right: 4),
    child: Row(
      children: [
        Icon(Icons.warning_amber_rounded, size: 12, color: warning),
        const SizedBox(width: 5),
        Expanded(
          child: Semantics(
            liveRegion: true,
            child: Tooltip(
              message: message,
              child: Text(
                message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppType.caption,
                  fontWeight: FontWeight.w500,
                  color: warning,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _menuButton(Color muted) {
    final counts = _providerCounts(_profiledData);
    return PopupMenuButton<String>(
      tooltip: 'Menu: profiles, providers, and settings',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      icon: Icon(Icons.more_vert_rounded, size: 16, color: muted),
      onSelected: _onMenu,
      itemBuilder: (_) => [
        const PopupMenuItem(
          enabled: false,
          height: 26,
          child: Text(
            'PROFILE',
            style: TextStyle(fontSize: AppType.label, letterSpacing: 0.6),
          ),
        ),
        for (final profile in _profiles)
          CheckedPopupMenuItem(
            value: 'profile:${profile.name}',
            checked: _activeProfile.name == profile.name,
            child: Text(
              profileLabel(profile),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: AppType.subtitle),
            ),
          ),
        PopupMenuItem(
          value: 'profiles:manage',
          child: Text(
            'Manage profiles...',
            style: const TextStyle(fontSize: AppType.subtitle),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          enabled: false,
          height: 26,
          child: Text(
            'PROVIDERS',
            style: TextStyle(fontSize: AppType.label, letterSpacing: 0.6),
          ),
        ),
        for (final q in _menuProviders)
          CheckedPopupMenuItem(
            value: 'show:${_menuVisibilityTarget(q, counts)}',
            checked: _menuProviderVisible(q),
            child: Text(
              !_showAccounts
                  ? q.displayName
                  : (counts[q.provider] ?? 0) > 1
                  ? _shouldShowAccount(q, counts)
                        ? '${q.displayName} '
                              '(${quotaAccountDisplayLabel(q.account)})'
                        : '${q.displayName} (${counts[q.provider]} accounts)'
                  : _shouldShowAccount(q, counts)
                  ? '${q.displayName} '
                        '(${quotaAccountDisplayLabel(q.account)})'
                  : q.displayName,
              style: const TextStyle(fontSize: AppType.subtitle),
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          enabled: false,
          height: 26,
          child: Text(
            'REFRESH',
            style: TextStyle(fontSize: AppType.label, letterSpacing: 0.6),
          ),
        ),
        _cadenceItem('cad:smart', Cadence.smart, 'Smart (default)'),
        _cadenceItem('cad:m15', Cadence.m15, 'Every 15 min'),
        _cadenceItem('cad:h1', Cadence.h1, 'Every hour'),
        const PopupMenuDivider(),
        const PopupMenuItem(
          enabled: false,
          height: 26,
          child: Text(
            'SORT',
            style: TextStyle(fontSize: AppType.label, letterSpacing: 0.6),
          ),
        ),
        _sortItem('sort:default', ProviderSort.defaultOrder, 'Default order'),
        _sortItem('sort:alpha', ProviderSort.alphabetical, 'Alphabetical'),
        _sortItem('sort:avail', ProviderSort.mostAvailable, 'Most available'),
        _sortItem('sort:used', ProviderSort.mostUsed, 'Most used'),
        const PopupMenuDivider(),
        const PopupMenuItem(
          enabled: false,
          height: 26,
          child: Text(
            'OPTIONS',
            style: TextStyle(fontSize: AppType.label, letterSpacing: 0.6),
          ),
        ),
        CheckedPopupMenuItem(
          value: 'always_on_top',
          checked: _alwaysOnTop,
          child: Text(
            'Always on top',
            style: const TextStyle(fontSize: AppType.subtitle),
          ),
        ),
        CheckedPopupMenuItem(
          value: 'show_in_taskbar',
          checked: _showInTaskbar,
          child: Text(
            'Show in taskbar',
            style: const TextStyle(fontSize: AppType.subtitle),
          ),
        ),
        CheckedPopupMenuItem(
          value: 'notifications',
          checked: _enableNotifications,
          child: Text(
            _notificationDeliveryFailed
                ? 'Notifications: delivery failed'
                : 'Notifications',
            style: const TextStyle(fontSize: AppType.subtitle),
          ),
        ),
        PopupMenuItem(
          value: 'webhook',
          child: Text(
            _webhookUrl == null
                ? 'Alert webhook...'
                : _lastWebhookDeliveryFailed ?? false
                ? 'Alert webhook: delivery failed'
                : 'Alert webhook: on',
            style: const TextStyle(fontSize: AppType.subtitle),
          ),
        ),
        CheckedPopupMenuItem(
          value: 'show_accounts',
          checked: _showAccounts,
          child: Text(
            'Show account names',
            style: const TextStyle(fontSize: AppType.subtitle),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          enabled: false,
          height: 26,
          child: Text(
            'TEXT SIZE',
            style: TextStyle(fontSize: AppType.label, letterSpacing: 0.6),
          ),
        ),
        _textSizeItem('text:small', TextSize.small, 'Small'),
        _textSizeItem('text:medium', TextSize.medium, 'Medium'),
        _textSizeItem('text:large', TextSize.large, 'Large'),
      ],
    );
  }

  PopupMenuItem<String> _textSizeItem(String value, TextSize t, String label) =>
      CheckedPopupMenuItem(
        value: value,
        checked: _textSize == t,
        child: Text(label, style: const TextStyle(fontSize: AppType.subtitle)),
      );

  PopupMenuItem<String> _cadenceItem(String value, Cadence c, String label) =>
      CheckedPopupMenuItem(
        value: value,
        checked: _cadence == c,
        child: Text(label, style: const TextStyle(fontSize: AppType.subtitle)),
      );

  PopupMenuItem<String> _sortItem(String value, ProviderSort s, String label) =>
      CheckedPopupMenuItem(
        value: value,
        checked: _sort == s,
        child: Text(label, style: const TextStyle(fontSize: AppType.subtitle)),
      );

  void _onMenu(String value) {
    if (value.startsWith('profile:')) {
      _setActiveProfile(value.substring(8));
    } else if (value == 'profiles:manage') {
      _showProfileEditor();
    } else if (value.startsWith('show:')) {
      final target = value.substring(5);
      if (!_showAccounts) {
        _toggleProviderHidden(target);
        return;
      }
      ProviderQuota? quota;
      final counts = _providerCounts(_profiledData);
      for (final q in _profiledData) {
        if (quotaHideTarget(q, counts) == target || q.provider == target) {
          quota = q;
          break;
        }
      }
      quota == null ? _toggleHidden(target) : _toggleQuotaHidden(quota);
    } else if (value == 'cad:smart') {
      _setCadence(Cadence.smart);
    } else if (value == 'cad:m15') {
      _setCadence(Cadence.m15);
    } else if (value == 'cad:h1') {
      _setCadence(Cadence.h1);
    } else if (value == 'sort:default') {
      _setSort(ProviderSort.defaultOrder);
    } else if (value == 'sort:alpha') {
      _setSort(ProviderSort.alphabetical);
    } else if (value == 'sort:avail') {
      _setSort(ProviderSort.mostAvailable);
    } else if (value == 'sort:used') {
      _setSort(ProviderSort.mostUsed);
    } else if (value == 'always_on_top') {
      _setAlwaysOnTop(!_alwaysOnTop);
    } else if (value == 'show_in_taskbar') {
      _setShowInTaskbar(!_showInTaskbar);
    } else if (value == 'notifications') {
      _toggleNotifications();
    } else if (value == 'show_accounts') {
      _setShowAccounts(!_showAccounts);
    } else if (value == 'webhook') {
      _showWebhookDialog();
    } else if (value == 'text:small') {
      _setTextSize(TextSize.small);
    } else if (value == 'text:medium') {
      _setTextSize(TextSize.medium);
    } else if (value == 'text:large') {
      _setTextSize(TextSize.large);
    }
  }

  void _setActiveProfile(String name) {
    final normalized = normalizeProfileName(name);
    if (normalized == null || normalized == _activeProfile.name) return;
    if (!_saveActiveProfileUiState()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save profile changes.')),
      );
      return;
    }
    if (widget._hostIntegration) _profiles = _loadProfiles();
    final next = _profileByName(normalized);
    setState(() {
      _activeProfile = next;
      _applyProfileUiState(next);
    });
    _applySize();
    unawaited(_persistPrefs());
  }

  Future<void> _showProfileEditor() async {
    if (!_saveActiveProfileUiState()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save profile changes.')),
      );
      return;
    }
    final result = await showDialog<ProfileEditorResult>(
      context: context,
      builder: (_) => ProfileEditorDialog(
        profiles: widget._hostIntegration ? _loadProfiles() : _profiles,
        providers: _data,
        activeProfile: _activeProfile.name,
        currentSort: _sort,
        currentHidden: _hidden,
      ),
    );
    if (!mounted || result == null) return;
    if (result.action == ProfileEditorAction.delete) {
      final name = result.deleteName;
      if (name == null) return;
      try {
        final deleter = widget.profileDeleter;
        if (deleter != null) {
          deleter(name);
        } else if (widget._hostIntegration) {
          deleteProfile(name);
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not delete profile.')),
          );
        }
        return;
      }
      final next = name == _activeProfile.name
          ? defaultProfileName
          : _activeProfile.name;
      _profiles = widget._hostIntegration
          ? _loadProfiles()
          : _profiles.where((profile) => profile.name != name).toList();
      final profile = _profileByName(next);
      setState(() {
        _activeProfile = profile;
        _applyProfileUiState(profile);
      });
      unawaited(_persistPrefs());
      _applySize();
      return;
    }
    final profile = result.profile;
    if (profile == null) return;
    if (widget._hostIntegration) {
      try {
        saveProfile(profile);
      } catch (_) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save profile.')),
        );
        return;
      }
      _profiles = _loadProfiles();
    } else {
      _upsertProfile(profile);
    }
    final saved = _profileByName(profile.name);
    setState(() {
      _activeProfile = saved;
      _applyProfileUiState(saved);
    });
    unawaited(_persistPrefs());
    _applySize();
  }

  void _setShowAccounts(bool value) {
    setState(() => _showAccounts = value);
    unawaited(_persistPrefs());
  }

  /// Prompts for the optional low-quota alert webhook. An empty URL clears it.
  /// A non-loopback host needs "allow external" on, so an alert never leaves the
  /// machine without an explicit opt-in.
  Future<void> _showWebhookDialog() async {
    final result = await showDialog<_WebhookSettings>(
      context: context,
      builder: (_) => _WebhookDialog(
        initialUrl: _webhookUrl ?? '',
        initialAllowExternal: _webhookAllowExternal,
        lastDeliveryStatus: _lastWebhookDeliveryStatus,
        lastDeliveryFailed: _lastWebhookDeliveryFailed,
      ),
    );
    if (!mounted || result == null) return;
    final nextUrl = result.url.isEmpty ? null : result.url;
    final configurationChanged =
        nextUrl != _webhookUrl || result.allowExternal != _webhookAllowExternal;
    setState(() {
      _webhookUrl = nextUrl;
      _webhookAllowExternal = result.allowExternal;
      if (configurationChanged) {
        _lastWebhookDeliveryStatus = null;
        _lastWebhookDeliveryFailed = null;
      }
    });
    final persisted = await _persistPrefs();
    if (!persisted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Webhook not saved (storage unavailable)'),
        ),
      );
    }
  }

  void _setTextSize(TextSize t) {
    setState(() => _textSize = t);
    textScale.value = t.scale; // applied app-wide by the MaterialApp builder
    unawaited(_persistPrefs());
    WidgetsBinding.instance.addPostFrameCallback((_) => _applySize());
  }

  void _setCadence(Cadence c) {
    setState(() => _cadence = c);
    _scheduleNext(); // apply the new cadence immediately
    unawaited(_persistPrefs());
  }

  void _setSort(ProviderSort s) {
    if (_sort == s) return;
    setState(() => _sort = s);
    _applySize();
    unawaited(_persistPrefs(saveProfileUiState: true));
  }

  void _setAlwaysOnTop(bool value) {
    setState(() => _alwaysOnTop = value);
    if (widget._hostIntegration) windowManager.setAlwaysOnTop(value);
    unawaited(_persistPrefs());
  }

  void _setShowInTaskbar(bool value) {
    setState(() => _showInTaskbar = value);
    if (widget._hostIntegration) windowManager.setSkipTaskbar(!value);
    unawaited(_persistPrefs());
  }

  /// Coalesces alert checks behind one delivery flight. The flight marker is
  /// installed synchronously before alert computation or any transport await,
  /// so a refresh that finishes while a webhook is slow cannot start a second
  /// notification or webhook batch against the same edge state.
  Future<void> _checkAndNotify() {
    final running = _alertCheckFlight;
    if (running != null) {
      _alertCheckPending = true;
      return running.future;
    }
    final flight = Completer<void>();
    _alertCheckFlight = flight;
    _alertCheckPending = false;
    unawaited(_drainAlertChecks(flight));
    return flight.future;
  }

  Future<void> _drainAlertChecks(Completer<void> flight) async {
    try {
      do {
        _alertCheckPending = false;
        await _checkAndNotifyOnce();
      } while (_alertCheckPending && mounted);
    } catch (_) {
      // Alert delivery is best effort and must never break the refresh loop.
    } finally {
      if (identical(_alertCheckFlight, flight)) {
        _alertCheckFlight = null;
      }
      if (!flight.isCompleted) flight.complete();
    }
  }

  Future<void> _checkAndNotifyOnce() async {
    final webhookUrl = _webhookUrl;
    // Local notifications and the alert webhook are independent transports; run
    // when either is active. Alerts are still computed and armed so the
    // edge-trigger stays correct even when only the webhook is on.
    if (!_enableNotifications && webhookUrl == null) return;
    try {
      final now = DateTime.now();
      final nowSec = now.millisecondsSinceEpoch ~/ 1000;
      final snapshot = _visible;
      // Compute the routing recommendation once so a low-quota alert can point
      // the user at where to send work instead.
      final suggestion = _routeSuggestion(nowSec);

      // Proactive low-quota alerts: fire once when a provider's binding window
      // crosses into red, naming where to route next, using the same
      // edge-triggered engine as `quotabot watch`.
      final alerts = computeAlerts(
        snapshot: snapshot,
        suggestion: suggestion,
        now: nowSec,
        armed: _armed,
      );
      _armed = alerts.armed;
      for (final a in alerts.fired) {
        // The notification and the webhook post independently: a notification
        // plugin failure (for example no Windows implementation) must not
        // suppress the webhook or skip the rest of the batch. Both keys carry
        // the account so two accounts of one provider do not collide.
        if (_enableNotifications) {
          final notificationBody = desktopQuotaAlertNotificationMessage(
            a,
            snapshot,
            showAccounts: _showAccounts,
          );
          final notificationQuota = snapshot.firstWhere(
            (quota) =>
                quota.provider == a.provider && quota.account == a.account,
          );
          final notificationLabel = desktopNotificationProviderLabel(
            notificationQuota,
            snapshot,
            showAccounts: _showAccounts,
          );
          final id = notificationId(
            '${quotaIdentityKey(a.provider, a.account)}:low',
          );
          try {
            await flutterLocalNotificationsPlugin.cancel(id: id);
            await flutterLocalNotificationsPlugin.show(
              id: id,
              title: 'Low quota',
              body: notificationBody,
              notificationDetails: _buildDetails(notificationLabel),
            );
            _setNotificationDeliveryFailed(false);
          } catch (_) {
            _setNotificationDeliveryFailed(true);
          }
        }
        if (webhookUrl != null) {
          final poster = widget.alertPoster;
          final result = poster == null
              ? await postAlert(
                  webhookUrl,
                  a.toJson(),
                  allowExternal: _webhookAllowExternal,
                )
              : await poster(
                  webhookUrl,
                  a.toJson(),
                  allowExternal: _webhookAllowExternal,
                );
          _setWebhookDeliveryStatus(result);
        }
      }

      // Scheduled "resets soon" reminders are local notifications only.
      if (_enableNotifications) {
        for (final q in snapshot) {
          if (!canScheduleQuotaResetAlert(q, nowSec)) continue;
          for (final w in q.windows) {
            if (w.resetsAt != null &&
                w.resetsAt! > nowSec &&
                w.percent != null &&
                w.percent! > 80) {
              final key = '${quotaIdentityKeyFor(q)}:${w.label}:reset';
              if (_shouldNotify(key, now)) {
                final notificationLabel = desktopNotificationProviderLabel(
                  q,
                  snapshot,
                  showAccounts: _showAccounts,
                );
                final resetDt = DateTime.fromMillisecondsSinceEpoch(
                  w.resetsAt! * 1000,
                );
                final tzReset = tz.TZDateTime.from(resetDt, tz.local);
                final id = notificationId(key);
                try {
                  await flutterLocalNotificationsPlugin.cancel(id: id);
                  await flutterLocalNotificationsPlugin.zonedSchedule(
                    id: id,
                    title: 'Quota reset soon',
                    body: '$notificationLabel ${w.label} resets soon',
                    scheduledDate: tzReset,
                    notificationDetails: _buildDetails(notificationLabel),
                    androidScheduleMode:
                        AndroidScheduleMode.exactAllowWhileIdle,
                  );
                  _setNotificationDeliveryFailed(false);
                } catch (_) {
                  _setNotificationDeliveryFailed(true);
                }
              }
            }
          }
        }
      }

      // Reset-available alerts: fire once when a provider offers a redeemable
      // off-cycle reset (Codex reset credits), so the user sees the escape hatch
      // the moment it appears instead of only in the card. The edge-trigger and
      // its flap-resistant re-arm rule live in the pure computeResetSignals.
      if (_enableNotifications) {
        final resets = computeResetSignals(
          snapshot: [
            for (final quota in snapshot)
              if (canScheduleQuotaResetAlert(quota, nowSec)) quota,
          ],
          armed: _resetArmed,
        );
        _resetArmed
          ..clear()
          ..addAll(resets.armed);
        for (final r in resets.fired) {
          final notificationQuota = snapshot.firstWhere(
            (quota) =>
                quota.provider == r.provider && quota.account == r.account,
          );
          final notificationLabel = desktopNotificationProviderLabel(
            notificationQuota,
            snapshot,
            showAccounts: _showAccounts,
          );
          final id = notificationId(
            '${quotaIdentityKey(r.provider, r.account)}:reset-available',
          );
          try {
            await flutterLocalNotificationsPlugin.cancel(id: id);
            await flutterLocalNotificationsPlugin.show(
              id: id,
              title: 'Reset available',
              body: desktopResetAvailableNotificationMessage(
                r,
                snapshot,
                showAccounts: _showAccounts,
              ),
              notificationDetails: _buildDetails(notificationLabel),
            );
            _setNotificationDeliveryFailed(false);
          } catch (_) {
            _setNotificationDeliveryFailed(true);
          }
        }
      }
    } catch (_) {
      // ignore notif errors
    }
  }

  void _setWebhookDeliveryStatus(WebhookResult result) {
    if (!mounted) return;
    setState(() {
      _lastWebhookDeliveryStatus = webhookDeliveryStatus(result);
      _lastWebhookDeliveryFailed = !result.ok;
    });
  }

  void _setNotificationDeliveryFailed(bool failed) {
    if (!mounted || _notificationDeliveryFailed == failed) return;
    setState(() => _notificationDeliveryFailed = failed);
  }

  bool _shouldNotify(String key, DateTime now) {
    final last = _lastNotified[key];
    if (last == null || now.difference(last).inSeconds > 300) {
      _lastNotified[key] = now;
      return true;
    }
    return false;
  }

  // Platform-aware details. Errors are caught by caller.
  NotificationDetails _buildDetails(String name) => NotificationDetails(
    android: const AndroidNotificationDetails(
      'quotabot_quota',
      'Quota Alerts',
      importance: Importance.high,
    ),
    macOS: const DarwinNotificationDetails(),
    linux: const LinuxNotificationDetails(defaultActionName: 'View'),
    windows: WindowsNotificationDetails(subtitle: name),
  );

  void _toggleNotifications() {
    setState(() => _enableNotifications = !_enableNotifications);
    unawaited(_persistPrefs());
  }

  void _showHelp() => _showSetup();

  /// Shows the analytics body in this window, under the same header and menu
  /// as the quota view. No resize, no move, no route push: only the body under
  /// the header changes, and it scrolls to fit whatever size the window has.
  void _showFleet({FleetRange initialRange = FleetRange.now}) {
    setState(() {
      _showingAnalytics = true;
      _analyticsRange = initialRange;
    });
  }

  void _closeFleet() {
    setState(() => _showingAnalytics = false);
    WidgetsBinding.instance.addPostFrameCallback((_) => _applySize());
  }

  /// Compact setup/help panel: a short intro, then every provider account from
  /// the latest snapshot with its live status and an inline Connect for
  /// Grok/Antigravity. Reachable from the help button; never pops up on its own.
  /// All path/state reads are portable, so it works the same on every OS.
  void _showSetup() {
    // Mid-connect providers; declared outside the builder so it survives the
    // StatefulBuilder rebuilds.
    final connecting = <String>{};
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final dark = Theme.of(ctx).brightness == Brightness.dark;
        final muted = dark ? const Color(0xFF8A91A0) : const Color(0xFF6B7280);
        final fg = dark ? Colors.white : const Color(0xFF111317);
        return StatefulBuilder(
          builder: (ctx, setDlg) {
            final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            final setupRows = _currentSetupRows(now);
            final setupCounts = _providerCounts(setupRows);
            return Dialog(
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 24,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 320,
                  maxHeight: 460,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Providers',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: AppType.title,
                                fontWeight: FontWeight.w700,
                                color: fg,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close providers',
                            icon: Icon(
                              Icons.close_rounded,
                              size: 18,
                              color: muted,
                            ),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 28,
                              minHeight: 28,
                            ),
                            onPressed: () => Navigator.of(ctx).pop(),
                          ),
                        ],
                      ),
                      Flexible(
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Quota reads use metadata only and spend no '
                                'model tokens. Cards distinguish account-wide, '
                                'this-machine, cached, and unavailable '
                                'evidence.',
                                style: TextStyle(
                                  fontSize: AppType.bodySmall,
                                  height: 1.3,
                                  color: muted,
                                ),
                              ),
                              const SizedBox(height: 8),
                              for (final q in setupRows)
                                _setupRow(
                                  ctx,
                                  q,
                                  muted,
                                  fg,
                                  connecting,
                                  setDlg,
                                  showAccount: quotaShouldShowAccountLabel(
                                    q,
                                    setupCounts,
                                  ),
                                ),
                              const SizedBox(height: 4),
                              Text(
                                'Tip: right-click any card to set it up or hide '
                                'it.',
                                style: TextStyle(
                                  fontSize: AppType.caption,
                                  color: muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  List<ProviderQuota> _currentSetupRows(int now) {
    final source = _setupData.isEmpty ? _data : _setupData;
    final rowsByAccount = <String, ProviderQuota>{};
    for (final quota in source) {
      final key = quotaDisplayKey(quota);
      final current = rowsByAccount[key];
      if (current == null ||
          _setupRowRank(quota, now) > _setupRowRank(current, now)) {
        rowsByAccount[key] = quota;
      }
    }
    return rowsByAccount.values.toList();
  }

  static int _setupRowRank(ProviderQuota quota, int now) {
    if (isTrustedQuotaEvidenceAt(quota, now)) return 5;
    if (isLocalRuntimeAvailableAt(quota, now)) return 4;
    if (quota.ok &&
        !quota.stale &&
        quota.suspect == null &&
        quota.driftReason == null &&
        quota.sourceClassViolation == null &&
        quota.asOf > 0 &&
        quota.asOf <= now + kQuotaEvidenceClockSkewSeconds &&
        quota.sourceClass == ProviderSourceClass.statusOnly &&
        (quota.status ?? '').isNotEmpty) {
      return 3;
    }
    if (quota.stale && quota.windows.isNotEmpty) return 2;
    if (quota.ok) return 1;
    return 0;
  }

  Widget _setupRow(
    BuildContext ctx,
    ProviderQuota q,
    Color muted,
    Color fg,
    Set<String> connecting,
    StateSetter setDlg, {
    required bool showAccount,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final (label, color) = _stateChip(
      q,
      now,
      errorColor: Theme.of(ctx).colorScheme.error,
    );
    final canConnect = widget.providerConnector != null
        ? q.provider == 'grok' || q.provider == 'antigravity'
        : widget._hostIntegration && _canConnectProvider(q.provider);
    final isLive = label == 'live' || label == 'in use';
    final busy = connecting.contains(q.provider);
    final displayLabel = showAccount
        ? '${q.displayName} (${quotaAccountDisplayLabel(q.account)})'
        : q.displayName;
    final state = Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        label: label,
        excludeSemantics: true,
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: AppType.caption, color: color),
        ),
      ),
    );
    final Widget action = busy
        ? Semantics(
            label: 'Connecting $displayLabel',
            liveRegion: true,
            child: const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        : canConnect && !isLive
        ? TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 30),
            ),
            onPressed: () async {
              setDlg(() => connecting.add(q.provider));
              await _connectAndValidate(q.provider, account: q.account);
              if (ctx.mounted) setDlg(() => connecting.remove(q.provider));
            },
            child: const Text(
              'Connect',
              style: TextStyle(fontSize: AppType.bodySmall),
            ),
          )
        : IconButton(
            tooltip: 'Set up $displayLabel',
            icon: Icon(Icons.help_outline_rounded, size: 16, color: muted),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            onPressed: () => _showProviderSetup(q),
          );
    final largeText = MediaQuery.textScalerOf(ctx).scale(10) > 14;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: largeText
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    ProviderLogo(q.provider, size: 18, color: fg),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        displayLabel,
                        style: TextStyle(fontSize: AppType.subtitle, color: fg),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 27),
                  child: Row(
                    children: [
                      Expanded(child: state),
                      const SizedBox(width: 8),
                      action,
                    ],
                  ),
                ),
              ],
            )
          : Row(
              children: [
                ProviderLogo(q.provider, size: 18, color: fg),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    displayLabel,
                    style: TextStyle(fontSize: AppType.subtitle, color: fg),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Flexible(child: state),
                const SizedBox(width: 8),
                action,
              ],
            ),
    );
  }

  /// Runs quotabot's own login for a provider, then re-collects so the setup
  /// row reflects the new state. When an account-specific row initiated the
  /// flow, only that same account identity can satisfy validation.
  Future<bool> _connectAndValidate(String provider, {String? account}) async {
    final messenger = ScaffoldMessenger.of(context);
    // The connect flow only handles these two, and their display names are
    // fixed, so the toast can use the same capitalized label as the dialog
    // title instead of the raw provider id.
    final label = provider == 'antigravity' ? 'Antigravity' : 'Grok';
    try {
      final connector = widget.providerConnector;
      if (connector != null) {
        if (provider != 'antigravity' && provider != 'grok') return false;
        await connector(provider);
      } else if (provider == 'antigravity') {
        await GoogleAuth().loginLoopback(
          showUrl: (url) {
            if (!mounted) return;
            showDialog<void>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('Connect Antigravity'),
                content: SelectableText(
                  'If the browser does not open, visit this URL:\n\n$url',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c),
                    child: const Text('OK'),
                  ),
                ],
              ),
            );
          },
        );
      } else if (provider == 'grok') {
        await XaiAuth().deviceLogin(
          prompt: (url, code) {
            if (!mounted) return;
            showDialog<void>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('Connect Grok'),
                content: SelectableText(
                  'Open this URL and confirm the code:\n\n$url\n\ncode: $code',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c),
                    child: const Text('OK'),
                  ),
                ],
              ),
            );
          },
        );
      } else {
        return false;
      }
      // A refresh already in progress may have started before login completed,
      // so wait for it and then force one collection that sees the new account.
      final priorRefresh = _refreshInFlight;
      if (priorRefresh != null) await priorRefresh;
      await _refresh();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final live = _data
          .where(
            (quota) =>
                quota.provider == provider &&
                isTrustedQuotaEvidenceAt(quota, now) &&
                providerHeadroom(quota, now) != null,
          )
          .toList(growable: false);
      final target = account?.trim();
      final hasSpecificTarget =
          target != null &&
          target.isNotEmpty &&
          !genericAccountLabels.contains(target.toLowerCase());
      final ok = !hasSpecificTarget
          ? live.isNotEmpty
          : live.any((quota) => quota.account == target);
      final message = ok
          ? '$label connected'
          : hasSpecificTarget && live.isNotEmpty
          ? '$label connected, but the selected account is still unconfirmed'
          : '$label not live yet';
      messenger.showSnackBar(SnackBar(content: Text(message)));
      return ok;
    } catch (_) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not connect $label')),
      );
      return false;
    }
  }

  static bool _canConnectProvider(String provider) {
    if (provider == 'grok') return true;
    if (provider != 'antigravity') return false;
    final auth = GoogleAuth();
    return auth.clientId.isNotEmpty && auth.clientSecret.isNotEmpty;
  }

  /// Short status label and color for the setup list.
  (String, Color) _stateChip(
    ProviderQuota q,
    int now, {
    required Color errorColor,
  }) {
    const green = Color(0xFF3FB950),
        amber = Color(0xFFD29922),
        grey = Color(0xFF8A91A0),
        blue = Color(0xFF58A6FF);
    if (q.sourceClassViolation != null) {
      return ('invalid evidence', errorColor);
    }
    if (q.isLocal) {
      if (!q.ok || q.error != null) {
        return ('error', errorColor);
      }
      if (q.stale) return ('cached', amber);
      if (q.asOf <= 0 || q.asOf > now + kQuotaEvidenceClockSkewSeconds) {
        return ('unverified', amber);
      }
      if (!isLocalRuntimeAvailableAt(q, now)) return ('unavailable', grey);
      return q.active ? ('in use', green) : ('idle', blue);
    }
    if (q.driftReason != null) return ('provider drift', errorColor);
    if (!q.ok) return ('no live data', grey);
    if (q.stale) return ('cached', amber);
    if (q.suspect != null) return ('review', amber);
    if (q.asOf <= 0 || q.asOf > now + kQuotaEvidenceClockSkewSeconds) {
      return ('unverified', amber);
    }
    if (q.windows.isEmpty && (q.status ?? '').isNotEmpty) {
      return q.sourceClass == ProviderSourceClass.statusOnly
          ? ('metadata', blue)
          : ('no live data', grey);
    }
    if (q.windows.isEmpty) return ('no live data', grey);
    if (!isTrustedQuotaEvidenceAt(q, now)) return ('unverified', amber);
    final h = providerHeadroom(q, now);
    if (h == null) return ('unverified', amber);
    if (h <= kSpentHeadroomFloor) return ('spent', errorColor);
    return ('live', green);
  }

  Widget _iconButton(
    IconData icon,
    Color color,
    VoidCallback? onTap, {
    required String tooltip,
  }) => AppChromeIconButton(
    icon: icon,
    color: color,
    onTap: onTap,
    tooltip: tooltip,
  );
}

typedef _WebhookSettings = ({String url, bool allowExternal});

class _WebhookDialog extends StatefulWidget {
  final String initialUrl;
  final bool initialAllowExternal;
  final String? lastDeliveryStatus;
  final bool? lastDeliveryFailed;

  const _WebhookDialog({
    required this.initialUrl,
    required this.initialAllowExternal,
    required this.lastDeliveryStatus,
    required this.lastDeliveryFailed,
  });

  @override
  State<_WebhookDialog> createState() => _WebhookDialogState();
}

class _WebhookDialogState extends State<_WebhookDialog> {
  late final TextEditingController _controller;
  late bool _allowExternal;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialUrl);
    _allowExternal = widget.initialAllowExternal;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final url = _controller.text.trim();
    final needsExternal = url.isNotEmpty && !isLoopbackUrl(url);
    final blocked = needsExternal && !_allowExternal;
    return AlertDialog(
      title: const Text('Alert webhook'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'POST low-quota alerts as quotabot.alert.v1 JSON (quota '
              'metadata only). Leave blank to disable.',
              style: TextStyle(fontSize: AppType.caption),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'http://127.0.0.1:9000/quota',
                isDense: true,
              ),
              style: const TextStyle(fontSize: AppType.body),
              onChanged: (_) => setState(() {}),
            ),
            CheckboxListTile(
              value: _allowExternal,
              onChanged: (value) =>
                  setState(() => _allowExternal = value ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text(
                'Allow an external (non-loopback) host',
                style: TextStyle(fontSize: AppType.caption),
              ),
            ),
            if (widget.lastDeliveryStatus != null) ...[
              const SizedBox(height: 4),
              Semantics(
                liveRegion: true,
                child: Text(
                  widget.lastDeliveryStatus!,
                  style: TextStyle(
                    fontSize: AppType.label,
                    color: widget.lastDeliveryFailed ?? false
                        ? const Color(0xFFDB6D28)
                        : null,
                  ),
                ),
              ),
            ],
            if (blocked)
              Semantics(
                liveRegion: true,
                child: const Text(
                  'This host is not loopback; enable the option above to use it.',
                  style: TextStyle(
                    fontSize: AppType.label,
                    color: Color(0xFFDB6D28),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: blocked
              ? null
              : () => Navigator.of(context).pop((
                  url: _controller.text.trim(),
                  allowExternal: _allowExternal,
                )),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _AccountGroupHeader extends StatelessWidget {
  final String? account;
  final int count;

  const _AccountGroupHeader({required this.account, required this.count});

  @override
  Widget build(BuildContext context) {
    final chrome = AppChromeTheme.of(context);
    final label = account == null
        ? 'default and local'
        : quotaAccountDisplayLabel(account!);
    return Row(
      children: [
        Icon(Icons.account_circle_outlined, size: 14, color: chrome.muted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppType.caption,
              fontWeight: FontWeight.w700,
              color: chrome.foreground,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Container(height: 1, width: 34, color: chrome.border),
        const SizedBox(width: 8),
        Text(
          '$count ${count == 1 ? 'provider' : 'providers'}',
          style: TextStyle(fontSize: AppType.label, color: chrome.muted),
        ),
      ],
    );
  }
}

/// Adds desktop keyboard activation and a visible focus ring to provider cards
/// that can reveal analytics. The card keeps its mouse and context-menu gestures
/// in [child]; this wrapper only handles focus, Enter, Space, and semantics.
class _FocusableProviderCard extends StatefulWidget {
  final bool enabled;
  final String label;
  final bool expanded;
  final VoidCallback? onActivate;
  final Widget child;

  const _FocusableProviderCard({
    required this.enabled,
    required this.label,
    required this.expanded,
    required this.onActivate,
    required this.child,
  });

  @override
  State<_FocusableProviderCard> createState() => _FocusableProviderCardState();
}

class _FocusableProviderCardState extends State<_FocusableProviderCard> {
  bool _showFocus = false;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || widget.onActivate == null) return widget.child;
    final primary = Theme.of(context).colorScheme.primary;
    // Focus wins with a full ring; a plain hover gets a quieter accent edge so
    // the card reads as interactive without competing with the keyboard focus.
    final borderColor = _showFocus
        ? primary
        : _hover
        ? primary.withValues(alpha: 0.45)
        : Colors.transparent;
    return Semantics(
      container: true,
      label: widget.label,
      hint: 'Press Enter or Space to toggle analytics',
      button: true,
      expanded: widget.expanded,
      onTap: widget.onActivate,
      child: FocusableActionDetector(
        enabled: true,
        mouseCursor: SystemMouseCursors.click,
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onActivate!();
              return null;
            },
          ),
        },
        onShowFocusHighlight: (show) {
          if (_showFocus != show) setState(() => _showFocus = show);
        },
        onShowHoverHighlight: (hover) {
          if (_hover != hover) setState(() => _hover = hover);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          curve: Curves.easeOut,
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: borderColor, width: _showFocus ? 2 : 1.5),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

String _providerPlanTitle(String raw) {
  final cleaned = raw.trim().replaceAll(RegExp(r'[_-]+'), ' ');
  final normalized = cleaned.toLowerCase();
  return switch (normalized) {
    'team premium' => 'Team Premium',
    'team standard' => 'Team Standard',
    'ai pro' => 'AI Pro',
    'chatgpt plus' => 'ChatGPT Plus',
    _ when cleaned == normalized =>
      cleaned
          .split(RegExp(r'\s+'))
          .where((word) => word.isNotEmpty)
          .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
          .join(' '),
    _ => cleaned,
  };
}

class ProviderTile extends StatelessWidget {
  final ProviderQuota quota;
  final Color cardColor;
  final List<ProviderQuota> history;
  final Insights? insights;
  final List<List<double?>>? heatmap;
  final bool expanded;
  final VoidCallback? onToggle;
  final void Function(Offset globalPosition)? onContextMenu;

  /// Starts an in-app login for providers that support quotabot's own grant
  /// (Grok, Antigravity). Null when the provider cannot be connected from the
  /// GUI, which hides the inline Reconnect affordance.
  final VoidCallback? onConnect;
  final bool showAccounts;
  final int? nowEpochSeconds;
  const ProviderTile({
    super.key,
    required this.quota,
    required this.cardColor,
    this.history = const [],
    this.insights,
    this.heatmap,
    this.expanded = false,
    this.onToggle,
    this.onContextMenu,
    this.onConnect,
    this.showAccounts = true,
    this.nowEpochSeconds,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final chrome = AppChromeTheme.of(context);
    final muted = chrome.muted;
    final fg = chrome.foreground;
    final now =
        nowEpochSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final views = quota.windows.map((w) => _view(quota, w, now)).toList();
    final scopedModelQuotas = desktopScopedModelQuotas(quota);
    final completeWindowEvidence = quota.windows.every((window) {
      final percent = window.percent;
      return percent != null &&
          percent.isFinite &&
          percent >= 0 &&
          percent <= 100;
    });

    // Binding constraint from pure analysis. A spent longer window overrides
    // shorter ones so the display never shows healthy when the binding cap is spent.
    final bindingWin = bindingWindow(quota, now);
    WinView? binding;
    if (bindingWin != null) {
      binding = _view(quota, bindingWin, now);
    }
    final trustedEvidence = isTrustedQuotaEvidenceAt(quota, now);
    final localAvailable = isLocalRuntimeAvailableAt(quota, now);
    final blocked = binding != null && binding.exhausted;
    // When a spent short window blocks the card, a longer window that still has
    // room is the constraint the user faces after the short one resets - show it
    // instead of hiding it behind the "spent" line.
    final secondaryWin = blocked ? secondaryVisibleWindow(quota, now) : null;
    final driftColor = _providerDriftForeground(cardColor);
    final statusColor = quota.isLocal
        ? !localAvailable
              ? muted
              : quota.active
              ? const Color(0xFF3FB950)
              : const Color(0xFF58A6FF)
        : quota.driftReason != null
        ? driftColor
        : quota.suspect != null
        ? const Color(0xFFD29922)
        : !trustedEvidence
        ? muted
        : binding == null
        ? muted
        : _availColor(binding.remaining);
    final hasInsights = insights != null && insights!.samples > 0;
    // The tight default shows only the binding windows. Any card can expand to
    // reveal its provenance line, model-specific quota, and analytics, so the
    // affordance is offered whenever a toggle is wired, not just for insights.
    final expandable = onToggle != null;
    // Detail is hidden only when there is a working toggle to bring it back. A
    // non-interactive tile (no toggle wired) shows everything so nothing becomes
    // permanently unreachable behind an affordance that is not there.
    final showDetail = expanded || !expandable;
    final trustLine = desktopProviderTrustLine(quota, now);
    final trustDetail = desktopProviderTrustDetail(quota, now);
    final rawPlan = quota.plan?.trim();
    final planLabel = rawPlan == null || rawPlan.isEmpty
        ? null
        : rawPlan.toLowerCase().replaceAll(RegExp(r'[_-]+'), ' ');
    final planDetail = planLabel == null
        ? null
        : 'Plan: ${_providerPlanTitle(rawPlan!)}';
    // A redeemable off-cycle reset is the most actionable thing on a tight card,
    // so it renders as a prominent green banner, not a muted detail line.
    final resetMessage = resetAvailableMessage(quota);
    final evidenceLabel = quota.driftReason != null
        ? 'last trusted'
        : quota.stale
        ? 'last known'
        : !trustedEvidence
        ? 'unverified'
        : null;

    // A glance-layer forward-looking note on the binding window, in plain
    // language backed by the calibrated forecast and matching what `quotabot
    // top` shows. Shown only when a real burn signal exists; quotabot never
    // invents one. The strand probability needs the burn standard error, so it
    // appears once there is enough history; otherwise the runway estimate does.
    final forecast =
        (quota.isLocal ||
            !trustedEvidence ||
            blocked ||
            binding == null ||
            !hasInsights)
        ? null
        : classifyForecast(
            strandProbability: strandProbability(
              binding.remaining,
              insights!.burnPerHour,
              insights!.burnSePerHour,
              binding.resetsAt,
              now,
            ),
            burnPerHour: insights!.burnPerHour,
            headroom: binding.remaining,
          );

    final cardLabel = showAccounts && quotaHasSpecificAccount(quota)
        ? '${quota.displayName} '
              '(${quotaAccountDisplayLabel(quota.account)}) quota card'
        : '${quota.displayName} quota card';
    return _FocusableProviderCard(
      enabled: expandable,
      label: cardLabel,
      expanded: expanded,
      onActivate: onToggle,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: expandable ? onToggle : null,
        onSecondaryTapDown: onContextMenu == null
            ? null
            : (d) => onContextMenu!(d.globalPosition),
        onLongPressStart: onContextMenu == null
            ? null
            : (d) => onContextMenu!(d.globalPosition),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: chrome.tileBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ProviderLogo(quota.provider, size: 20, color: fg),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: quota.displayName,
                            style: TextStyle(
                              fontSize: AppType.subtitle,
                              fontWeight: FontWeight.w600,
                              color: fg,
                            ),
                          ),
                          if (showAccounts && quotaHasSpecificAccount(quota))
                            TextSpan(
                              text:
                                  ' (${quotaAccountDisplayLabel(quota.account)})',
                              style: TextStyle(
                                fontSize: AppType.caption,
                                fontWeight: FontWeight.w500,
                                color: muted,
                              ),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (quota.isLocal)
                    _Dot(statusColor)
                  else if (quota.windows.isNotEmpty)
                    _Dot(statusColor),
                  if (planLabel != null) ...[
                    const SizedBox(width: 4),
                    Flexible(
                      child: Semantics(
                        label: planDetail,
                        excludeSemantics: true,
                        child: Tooltip(
                          message: planDetail!,
                          excludeFromSemantics: true,
                          child: Text(
                            planLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppType.caption,
                              fontWeight: FontWeight.w500,
                              color: muted,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (expandable) ...[
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      // One chevron that rotates, so expand and collapse read as
                      // the same control moving rather than two different icons.
                      turns: expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOut,
                      child: Icon(
                        Icons.expand_more_rounded,
                        size: 14,
                        color: muted,
                      ),
                    ),
                  ],
                ],
              ),
              if (showDetail)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Semantics(
                    label: trustDetail,
                    excludeSemantics: true,
                    child: Tooltip(
                      message: trustDetail,
                      excludeFromSemantics: true,
                      child: Text(
                        trustLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.small,
                          fontWeight: FontWeight.w500,
                          color: muted,
                        ),
                      ),
                    ),
                  ),
                ),
              if (quota.suspect != null && quota.driftReason == null)
                _providerSuspectRow(quota.suspect!, const Color(0xFFD29922)),
              if (resetMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.refresh_rounded,
                        size: 13,
                        color: Color(0xFF3FB950),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          resetMessage,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: AppType.small,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF3FB950),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (quota.driftReason != null)
                _providerDriftRow(
                  quota.driftReason!,
                  driftColor,
                  hasTrustedWindows: quota.hasWindows,
                ),
              if (!quota.isLocal &&
                  quota.hasWindows &&
                  quota.stale &&
                  quota.driftReason == null &&
                  quota.error?.isNotEmpty == true)
                _providerStaleFailureRow(
                  quota.error!,
                  driftColor,
                  throttled:
                      quota.pipeHealth == providerPipeHealthThrottled ||
                      quota.pipeHealth == providerPipeHealthDegraded,
                ),
              // Surface the in-app login right where the failure shows, so a
              // provider that supports quotabot's own grant (Grok, Antigravity)
              // can be reconnected without a terminal. Kept out of the tight/
              // expanded gate because a failed login is always actionable.
              if (onConnect != null &&
                  !quota.isLocal &&
                  (quota.stale || !trustedEvidence))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: onConnect,
                      icon: const Icon(Icons.login_rounded, size: 14),
                      label: const Text('Connect'),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF58A6FF),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(
                          fontSize: AppType.small,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              if (quota.isLocal)
                (localAvailable
                    ? _localRow(quota, muted, fg)
                    : _noData(
                        quota.error ?? 'local runtime unavailable',
                        muted,
                      ))
              else if (quota.windows.isEmpty)
                ((quota.status ?? '').isNotEmpty
                    ? _statusOnlyRow(quota, muted, fg)
                    : _noData(quota.error, muted))
              else if (!completeWindowEvidence)
                _noData(
                  'quota balance unavailable - not used for routing',
                  muted,
                )
              else if (blocked) ...[
                _blockedRow(
                  binding,
                  now,
                  muted,
                  evidenceLabel: evidenceLabel,
                  largeText: MediaQuery.textScalerOf(context).scale(10) > 14,
                ),
                if (secondaryWin != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: WindowBar(
                      view: _view(quota, secondaryWin, now),
                      muted: muted,
                      fg: fg,
                      evidenceLabel: evidenceLabel,
                    ),
                  ),
              ] else
                ...views.map(
                  (v) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: WindowBar(
                      view: v,
                      muted: muted,
                      fg: fg,
                      evidenceLabel: evidenceLabel,
                    ),
                  ),
                ),
              if (showDetail && scopedModelQuotas.isNotEmpty) ...[
                _scopedQuotaHeading(quota, muted),
                ...scopedModelQuotas.map((modelQuota) {
                  final spendEvidence = claudeFableSpendEvidenceAt(
                    quota,
                    modelQuota.model,
                    now,
                  );
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _scopedModelQuotaRow(
                      modelQuota,
                      muted: muted,
                      fg: fg,
                      spendEvidence: spendEvidence,
                      evidenceLabel: desktopScopedModelEvidenceLabel(
                        quota,
                        modelQuota,
                        now,
                      ),
                    ),
                  );
                }),
              ],
              if (showDetail && forecast != null) _forecastRow(forecast, muted),
              if (showDetail && history.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: () {
                    final avg = averageRecentHeadroom(history, now);
                    return Text(
                      avg == null
                          ? '${history.length} recent checks'
                          : 'usually ~${avg.toStringAsFixed(0)}% free (last ${history.length})',
                      style: TextStyle(
                        fontSize: AppType.caption,
                        fontWeight: FontWeight.w500,
                        color: muted,
                      ),
                    );
                  }(),
                ),
              if (showDetail && hasInsights)
                InsightsPanel(
                  insights: insights!,
                  history: history,
                  heatmap: heatmap,
                  bindingRemaining: binding?.remaining,
                  bindingResetsAt: binding?.resetsAt,
                  muted: muted,
                  fg: fg,
                  dark: dark,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _scopedQuotaHeading(ProviderQuota quota, Color muted) {
    final detail =
        'Model-specific quota. This allowance applies only to the named '
        '${quota.displayName} model and does not replace ${quota.displayName}\'s '
        'shared account limits. An expired allowance remains last observed '
        'until a new provider read.';
    return Padding(
      padding: const EdgeInsets.only(top: 1, bottom: 5),
      child: Semantics(
        container: true,
        label: detail,
        excludeSemantics: true,
        child: Tooltip(
          message: detail,
          excludeFromSemantics: true,
          child: Row(
            children: [
              Icon(Icons.filter_alt_outlined, size: 12, color: muted),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  'Model-specific quota (separate)',
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.small,
                    fontWeight: FontWeight.w600,
                    color: muted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _scopedModelQuotaRow(
    ModelQuota modelQuota, {
    required Color muted,
    required Color fg,
    required ScopedModelSpendEvidence? spendEvidence,
    required String? evidenceLabel,
  }) {
    final model = modelQuota.model.trim();
    final modelLabel = model.isEmpty ? 'Unnamed model' : model;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                label: modelLabel,
                excludeSemantics: true,
                child: Tooltip(
                  message: modelLabel,
                  excludeFromSemantics: true,
                  child: Text(
                    modelLabel,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.small,
                      fontWeight: FontWeight.w600,
                      color: muted,
                    ),
                  ),
                ),
              ),
            ),
            if (spendEvidence != null) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Semantics(
                  label: spendEvidence.detail,
                  excludeSemantics: true,
                  child: Tooltip(
                    message: spendEvidence.detail,
                    excludeFromSemantics: true,
                    child: Text(
                      spendEvidence.compactLabel,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: TextStyle(
                        fontSize: AppType.caption,
                        fontWeight: FontWeight.w600,
                        color: muted,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 3),
        WindowBar(
          view: _modelQuotaView(modelQuota),
          muted: muted,
          fg: fg,
          evidenceLabel: evidenceLabel,
        ),
      ],
    );
  }

  Widget _providerSuspectRow(String reason, Color color) {
    final detail =
        'Provider marked this reading for review. It is shown as unverified and '
        'is not used for routing or forecasts. Reason: $reason';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Semantics(
        container: true,
        liveRegion: true,
        label: detail,
        excludeSemantics: true,
        child: Tooltip(
          message: detail,
          excludeFromSemantics: true,
          child: Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 13, color: color),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  'reading needs review - not used for routing',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.caption,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _providerDriftRow(
    String reason,
    Color color, {
    required bool hasTrustedWindows,
  }) {
    // Keep the glance surface calm: one short label, with the full explanation
    // (and the reason) on hover and for screen readers. The drift diagnostic
    // clears itself on the next clean read, so there is no call to action here.
    final label = hasTrustedWindows
        ? 'provider drift - showing last trusted'
        : 'provider drift - quarantined';
    final detail = hasTrustedWindows
        ? 'Provider drift detected. Showing the last trusted quota; routing is '
              'disabled until a clean read recovers. Reason: $reason'
        : 'Provider drift detected. Legacy quota evidence is quarantined; no '
              'trusted snapshot is available. Reason: $reason';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Semantics(
        container: true,
        liveRegion: true,
        excludeSemantics: true,
        label: detail,
        child: Tooltip(
          message: detail,
          child: Row(
            children: [
              Icon(Icons.error_outline_rounded, size: 13, color: color),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.caption,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _providerStaleFailureRow(
    String reason,
    Color color, {
    bool throttled = false,
  }) {
    // A throttled or slow pipe is temporary and self-recovering, so it reads as
    // "throttled - retrying" in amber rather than a red "live read failed" that
    // implies a broken login or a bad response.
    const throttleColor = Color(0xFFD29922);
    final rowColor = throttled ? throttleColor : color;
    final detail = throttled
        ? 'The provider is responding slowly (throttled). Showing last-known '
              'quota and backing off; it retries automatically. Reason: $reason'
        : 'The latest live quota read failed. Showing last-known quota; routing '
              'is disabled until a clean read succeeds. Reason: $reason';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Semantics(
        container: true,
        liveRegion: true,
        label: detail,
        excludeSemantics: true,
        child: Tooltip(
          message: detail,
          excludeFromSemantics: true,
          child: Row(
            children: [
              Icon(
                throttled
                    ? Icons.hourglass_top_rounded
                    : Icons.cloud_off_rounded,
                size: 13,
                color: rowColor,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  throttled
                      ? 'throttled - retrying, showing last known'
                      : 'live read failed - showing last known',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.caption,
                    fontWeight: FontWeight.w600,
                    color: rowColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Warning foregrounds chosen for the actual tile surface rather than the
  /// ambient theme, because previews and tests may render a tile on a surface
  /// from the opposite brightness. Both official app surfaces exceed WCAG's
  /// 4.5:1 normal-text contrast threshold with their selected color.
  Color _providerDriftForeground(Color background) {
    return background.computeLuminance() > 0.5
        ? const Color(0xFFB42318)
        : const Color(0xFFFF7B72);
  }

  /// Glance-layer forward-looking note on the binding window, phrased in plain
  /// language from the shared [WindowForecast]. A strand risk is stated as words
  /// (the probability lives a layer down, in the analytics screen), a quieter
  /// drain as an estimated runway. Colored by urgency.
  Widget _forecastRow(WindowForecast f, Color muted) {
    const red = Color(0xFFF85149);
    const orange = Color(0xFFDB6D28);
    final (String text, Color color, IconData icon) = switch (f.kind) {
      ForecastKind.strand => (
        f.severity >= 2
            ? 'likely to run out before it resets'
            : 'may run out before it resets',
        f.severity >= 2 ? red : orange,
        Icons.warning_amber_rounded,
      ),
      ForecastKind.timeToEmpty => (
        _runwayPhrase(f.hoursToEmpty!),
        muted,
        Icons.schedule_rounded,
      ),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: AppType.caption,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Plain-language runway ("about an hour of usage left" and neighbors). The
  /// coarse buckets are deliberate: this is an estimate, and rounding to a day,
  /// an hour, or a handful of minutes avoids implying a precision it lacks.
  static String _runwayPhrase(double hours) {
    if (hours >= 36) return 'about ${(hours / 24).round()} days of usage left';
    if (hours >= 1.5) return 'about ${hours.round()} hours of usage left';
    if (hours >= 0.75) return 'about an hour of usage left';
    final mins = (hours * 60).round().clamp(1, 59);
    return mins == 1
        ? 'about a minute of usage left'
        : 'about $mins minutes of usage left';
  }

  /// Single collapsed line shown when the binding window is exhausted.
  Widget _blockedRow(
    WinView v,
    int now,
    Color muted, {
    String? evidenceLabel,
    required bool largeText,
  }) {
    const red = Color(0xFFF85149);
    final status = evidenceLabel == null
        ? '${v.label} spent'
        : '${v.label} was spent ($evidenceLabel)';
    final resetPassedWithoutCurrentEvidence =
        evidenceLabel != null && v.resetsAt != null && v.resetsAt! <= now;
    final availability = v.resetsAt == null
        ? ''
        : resetPassedWithoutCurrentEvidence
        ? 'refresh to confirm'
        : evidenceLabel == null
        ? 'available ${backLabel(v.resetsAt, now)}'
        : 'reset ${backLabel(v.resetsAt, now)}';
    final stateColor = evidenceLabel == null ? red : muted;
    final statusRow = Row(
      children: [
        _Dot(stateColor),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            status,
            style: TextStyle(
              fontSize: AppType.body,
              fontWeight: FontWeight.w600,
              color: stateColor,
            ),
          ),
        ),
      ],
    );
    final availabilityText = Semantics(
      label: availability,
      excludeSemantics: true,
      child: Tooltip(
        message: availability,
        excludeFromSemantics: true,
        child: Text(
          availability,
          maxLines: largeText ? 3 : 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppType.caption,
            fontWeight: FontWeight.w600,
            color: muted,
          ),
        ),
      ),
    );
    if (largeText) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          statusRow,
          if (availability.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3, left: 15),
              child: availabilityText,
            ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: statusRow),
        if (availability.isNotEmpty) ...[
          const SizedBox(width: 8),
          Flexible(child: availabilityText),
        ],
      ],
    );
  }

  Widget _noData(String? err, Color muted) {
    final trimmed = err?.trim();
    final msg = trimmed == null || trimmed.isEmpty ? 'no live data' : trimmed;
    return Tooltip(
      message: msg,
      excludeFromSemantics: true,
      child: Semantics(
        label: msg,
        excludeSemantics: true,
        child: Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: muted, width: 1.4),
              ),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                msg,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: AppType.caption, color: muted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusOnlyRow(ProviderQuota quota, Color muted, Color fg) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle_outline_rounded, size: 13, color: muted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                quota.status!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: AppType.caption, color: fg),
              ),
            ),
          ],
        ),
        for (final detail in quota.details)
          Padding(
            padding: const EdgeInsets.only(top: 3, left: 19),
            child: Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: AppType.small, color: muted),
            ),
          ),
      ],
    );
  }

  /// Status block for a local runtime: what is loaded or how many are installed,
  /// an in-use / idle label, and the detail lines (size, quantization, disk).
  /// Local runtimes have no quota to show.
  Widget _localRow(ProviderQuota quota, Color muted, Color fg) {
    final loaded = quota.active;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              loaded ? Icons.bolt_rounded : Icons.dns_rounded,
              size: 13,
              color: loaded ? const Color(0xFF3FB950) : muted,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                quota.status ?? 'running',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppType.caption,
                  fontWeight: FontWeight.w500,
                  color: fg,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              loaded ? 'in use' : 'idle',
              style: TextStyle(fontSize: AppType.small, color: muted),
            ),
          ],
        ),
        for (final d in quota.details)
          Padding(
            padding: const EdgeInsets.only(top: 3, left: 19),
            child: Text(
              d,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: AppType.small, color: muted),
            ),
          ),
      ],
    );
  }
}

/// Precomputed view of a rolling window.
class WinView {
  final String label;
  final double remaining; // headroom %, 0..100
  /// Legacy presentation state retained for deterministic demo/test views. Live
  /// quota reads never infer a fresh balance merely because a reset passed.
  final bool rolledOver;
  final int? resetsAt;
  const WinView(this.label, this.remaining, this.rolledOver, this.resetsAt);
  bool get exhausted => !rolledOver && remaining <= kSpentHeadroomFloor;
}

WinView _view(ProviderQuota quota, QuotaWindow w, int now) {
  final rolled = quotaWindowHasRolledOver(quota, w, now);
  final rem = quotaWindowHeadroom(quota, w, now);
  return WinView(w.label, rem, rolled, w.resetsAt);
}

WinView _modelQuotaView(ModelQuota modelQuota) {
  final providerLabel = modelQuota.windowLabel?.trim();
  return WinView(
    providerLabel == null || providerLabel.isEmpty ? 'quota' : providerLabel,
    modelQuota.remainingPercent!,
    false,
    modelQuota.resetsAt,
  );
}

/// Claude and Codex scoped pools are sparse and compact enough to show below
/// their shared account windows. Antigravity's model-quota list is exhaustive
/// and can be large, so it remains available only through model-routing detail
/// surfaces.
@visibleForTesting
List<ModelQuota> desktopScopedModelQuotas(ProviderQuota quota) =>
    (quota.provider == claudeProviderId || quota.provider == codexProviderId) &&
        quota.windows.isNotEmpty
    ? quota.modelQuotas
          .where((modelQuota) => modelQuota.remainingPercent != null)
          .toList(growable: false)
    : const [];

/// Evidence qualifier for a sparse Claude model-family allowance. A passed
/// scoped reset does not prove a fresh 100% pool, but it also does not make the
/// provider's shared account windows or unrelated models unavailable.
@visibleForTesting
String? desktopScopedModelEvidenceLabel(
  ProviderQuota quota,
  ModelQuota modelQuota,
  int now,
) {
  if (quota.driftReason != null) return 'last trusted';
  if (quota.stale) return 'last known';
  final reset = modelQuota.resetsAt;
  if (reset != null && reset <= now) return 'last observed';
  if (!isTrustedQuotaEvidenceAt(quota, now)) return 'unverified';
  return null;
}

/// Deterministic quota-row estimate used by the native window sizing fallback.
@visibleForTesting
int providerTileQuotaRowCount(ProviderQuota quota, int now) {
  final blocked = providerStatus(quota, now).blocked;
  final hasCompleteWindowEvidence = quota.windows.every((window) {
    final percent = window.percent;
    return percent != null &&
        percent.isFinite &&
        percent >= 0 &&
        percent <= 100;
  });
  final providerRows =
      (quota.windows.isEmpty || !hasCompleteWindowEvidence || blocked)
      ? 1
      : quota.windows.length;
  // A sparse scoped pool renders as two visual lines: its model identity and
  // its provider window meter. Count both so the native window-size fallback
  // does not clip the new dedicated row before measured sizing takes over.
  return providerRows + desktopScopedModelQuotas(quota).length * 2;
}

Color _availColor(num remaining) {
  return headroomColor(remaining);
}

/// One rolling window rendered as: [label] [availability bar] [reset / %].
class WindowBar extends StatelessWidget {
  final WinView view;
  final Color muted;
  final Color fg;
  final String? evidenceLabel;
  const WindowBar({
    super.key,
    required this.view,
    required this.muted,
    required this.fg,
    this.evidenceLabel,
  });

  @override
  Widget build(BuildContext context) {
    final remaining = view.remaining;
    final color = evidenceLabel == null ? _availColor(remaining) : muted;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final chrome = AppChromeTheme.of(context);
    final value = evidenceLabel != null
        ? view.rolledOver
              ? 'reset passed ($evidenceLabel)'
              : '${remaining.round()}% $evidenceLabel'
        : view.rolledOver
        ? 'ready'
        : view.resetsAt != null
        ? '${remaining.round()}% free  ${resetLabel(view.resetsAt, now)}'
        : '${remaining.round()}% free';

    return Row(
      children: [
        Expanded(
          flex: 2,
          child: _WindowBarText(
            text: view.label,
            style: TextStyle(
              fontSize: AppType.label,
              fontWeight: FontWeight.w600,
              color: muted,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          flex: 7,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4.5),
            child: TweenAnimationBuilder<double>(
              // Ease the fill to its new level on refresh so a jump reads as
              // motion, not a flicker.
              tween: Tween(begin: 0, end: (remaining / 100.0).clamp(0.0, 1.0)),
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => LinearProgressIndicator(
                value: v,
                minHeight: 8,
                backgroundColor: chrome.gaugeTrack,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 5,
          child: _WindowBarText(
            text: value,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontSize: AppType.small,
              fontWeight: FontWeight.w600,
              color: evidenceLabel != null
                  ? muted
                  : view.rolledOver
                  ? const Color(0xFF3FB950)
                  : fg,
            ),
          ),
        ),
      ],
    );
  }
}

class _WindowBarText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final TextAlign textAlign;

  const _WindowBarText({
    required this.text,
    required this.style,
    this.textAlign = TextAlign.start,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    label: text,
    excludeSemantics: true,
    child: Tooltip(
      message: text,
      excludeFromSemantics: true,
      child: Text(
        text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        textAlign: textAlign,
        style: style,
      ),
    ),
  );
}

/// Expandable per-provider analytics: a headroom sparkline from the recent raw
/// buffer plus distribution, reliability, trend, and tightest-hour stats from
/// the long-term bucket engine.
class InsightsPanel extends StatelessWidget {
  final Insights insights;
  final List<ProviderQuota> history;
  final List<List<double?>>? heatmap;
  final double? bindingRemaining;
  final int? bindingResetsAt;
  final Color muted;
  final Color fg;
  final bool dark;
  const InsightsPanel({
    super.key,
    required this.insights,
    required this.history,
    this.heatmap,
    this.bindingRemaining,
    this.bindingResetsAt,
    required this.muted,
    required this.fg,
    required this.dark,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final series = history
        .map((q) => providerHeadroom(q, now))
        .whereType<double>()
        .toList();
    final lineColor = _availColor(insights.mean ?? 0);

    // Plain-language headline: the usual free range (the p10..p90 band) rather
    // than raw percentiles. e.g. "usually 70-90% free".
    final headline = insights.p10 == null
        ? null
        : 'usually ${insights.p10!.round()}-${insights.p90!.round()}% free';

    // A qualitative read of how often it is spent, plus a trend in words.
    final sub = <String>[];
    final r = insights.reliability;
    if (r != null) {
      sub.add(
        r >= 0.98
            ? 'almost never runs out'
            : r >= 0.9
            ? 'rarely runs out'
            : r >= 0.7
            ? 'sometimes gets tight'
            : 'often maxed out',
      );
    }
    final showTrend =
        insights.trendPerDay != null &&
        (insights.trendConfidence ?? 0) >= 0.3 &&
        insights.trendPerDay!.abs() >= 0.15;
    if (showTrend) {
      sub.add(insights.trendPerDay! < 0 ? 'trending tighter' : 'easing up');
    }

    // Forward-looking pace for the current window (the actionable line).
    final pace = bindingRemaining == null
        ? null
        : computePace(
            headroom: bindingRemaining!,
            resetsAt: bindingResetsAt,
            burnPerHour: insights.burnPerHour,
            now: now,
          );
    final showPace = pace != null && pace.burnPerHour >= 0.2;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (series.length >= 2)
            Semantics(
              container: true,
              label: insightsSparklineSemantics(series),
              excludeSemantics: true,
              child: SizedBox(
                height: 26,
                width: double.infinity,
                child: CustomPaint(
                  painter: _SparklinePainter(
                    series,
                    lineColor,
                    dark ? const Color(0xFF2A2E36) : const Color(0xFFE9EBEF),
                  ),
                ),
              ),
            ),
          if (headline != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  if (showTrend)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(
                        insights.trendPerDay! < 0
                            ? Icons.trending_down_rounded
                            : Icons.trending_up_rounded,
                        size: 13,
                        color: insights.trendPerDay! < 0
                            ? const Color(0xFFDB6D28)
                            : const Color(0xFF3FB950),
                      ),
                    ),
                  Expanded(
                    child: Text(
                      headline,
                      style: TextStyle(
                        fontSize: AppType.caption,
                        fontWeight: FontWeight.w600,
                        color: fg,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (sub.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                sub.join(' . '),
                style: TextStyle(fontSize: AppType.label, color: muted),
              ),
            ),
          if (heatmap != null && _filledCells(heatmap!) >= 8) ...[
            const SizedBox(height: 6),
            Text(
              'free by hour x weekday (greener = freer)',
              style: TextStyle(fontSize: AppType.micro, color: muted),
            ),
            const SizedBox(height: 3),
            Semantics(
              container: true,
              label: insightsHeatmapSemantics(heatmap!),
              excludeSemantics: true,
              child: SizedBox(
                height: 30,
                width: double.infinity,
                child: CustomPaint(painter: _HeatmapPainter(heatmap!, dark)),
              ),
            ),
          ],
          if (showPace)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                pace.verdict,
                style: TextStyle(
                  fontSize: AppType.label,
                  fontWeight: FontWeight.w500,
                  color: pace.hoursEarlyExhaust != null
                      ? const Color(0xFFDB6D28)
                      : muted,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

@visibleForTesting
String insightsSparklineSemantics(List<double> values) {
  if (values.isEmpty) return 'Quota headroom history. No samples.';
  var low = values.first;
  var high = values.first;
  for (final value in values.skip(1)) {
    if (value < low) low = value;
    if (value > high) high = value;
  }
  final sampleLabel = values.length == 1
      ? '1 sample'
      : '${values.length} samples';
  return 'Quota headroom history, oldest to newest. $sampleLabel. '
      'Latest ${values.last.round()} percent free; range ${low.round()} to '
      '${high.round()} percent.';
}

String _insightsHourSemantics(int hour) {
  final normalized = hour % 24;
  if (normalized == 0) return 'midnight';
  if (normalized == 12) return 'noon';
  return normalized < 12 ? '$normalized AM' : '${normalized - 12} PM';
}

@visibleForTesting
String insightsHeatmapSemantics(List<List<double?>> grid) {
  const days = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  var count = 0;
  double? low;
  double? high;
  double? best;
  var bestDay = 0;
  var bestHour = 0;
  for (var day = 0; day < grid.length; day++) {
    for (var hour = 0; hour < grid[day].length; hour++) {
      final value = grid[day][hour];
      if (value == null || !value.isFinite) continue;
      count++;
      if (low == null || value < low) low = value;
      if (high == null || value > high) high = value;
      if (best == null || value > best) {
        best = value;
        bestDay = day;
        bestHour = hour;
      }
    }
  }
  if (count == 0) {
    return 'Quota headroom heatmap by weekday and hour. No sampled slots.';
  }
  final dayLabel = bestDay < days.length ? days[bestDay] : 'day ${bestDay + 1}';
  final slotLabel = count == 1 ? '1 sampled slot' : '$count sampled slots';
  return 'Quota headroom heatmap by weekday and hour. $slotLabel, ranging '
      'from ${low!.round()} to ${high!.round()} percent free. Best sampled '
      'slot $dayLabel at ${_insightsHourSemantics(bestHour)}, '
      '${best!.round()} percent free.';
}

/// Number of populated cells in a 7x24 heatmap.
int _filledCells(List<List<double?>> grid) {
  var n = 0;
  for (final row in grid) {
    for (final v in row) {
      if (v != null) n++;
    }
  }
  return n;
}

/// Draws the 7x24 (weekday x hour) headroom heatmap. Each cell is colored on the
/// same green-to-red scale as the bars; empty cells are a faint track.
class _HeatmapPainter extends CustomPainter {
  final List<List<double?>> grid; // [7][24] mean headroom, null = no data
  final bool dark;
  _HeatmapPainter(this.grid, this.dark);

  @override
  void paint(Canvas canvas, Size size) {
    const cols = 24, rows = 7;
    final cw = size.width / cols, ch = size.height / rows;
    final empty = dark ? const Color(0xFF24282F) : const Color(0xFFEDEEF1);
    final gap = cw > 5 ? 1.0 : 0.5;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final v = grid[r][c];
        final paint = Paint()..color = v == null ? empty : _availColor(v);
        canvas.drawRect(
          Rect.fromLTWH(c * cw, r * ch, cw - gap, ch - gap),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_HeatmapPainter old) => old.grid != grid;
}

/// Draws a headroom-over-time sparkline scaled to the widget, fixed to a 0..100
/// vertical range so providers are visually comparable.
class _SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;
  final Color baseline;
  _SparklinePainter(this.values, this.color, this.baseline);

  @override
  void paint(Canvas canvas, Size size) {
    final base = Paint()
      ..color = baseline
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height - 1),
      Offset(size.width, size.height - 1),
      base,
    );
    if (values.length < 2) return;
    final dx = size.width / (values.length - 1);
    Offset point(int i) => Offset(
      i * dx,
      size.height - (values[i].clamp(0, 100) / 100) * size.height,
    );
    final path = Path()..moveTo(point(0).dx, point(0).dy);
    for (var i = 1; i < values.length; i++) {
      path.lineTo(point(i).dx, point(i).dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.values != values || old.color != color;
}

/// A compact provider status is informative rather than actionable, but it
/// still participates in keyboard traversal so its full trust tooltip is
/// reachable. Focusing an off-screen chip scrolls it into view.
class _FocusableCompactProviderChip extends StatefulWidget {
  final String message;
  final Widget child;

  const _FocusableCompactProviderChip({
    super.key,
    required this.message,
    required this.child,
  });

  @override
  State<_FocusableCompactProviderChip> createState() =>
      _FocusableCompactProviderChipState();
}

class _FocusableCompactProviderChipState
    extends State<_FocusableCompactProviderChip> {
  bool _focused = false;

  void _handleFocusChange(bool focused) {
    if (_focused != focused) setState(() => _focused = focused);
    if (!focused) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final reduceMotion =
          MediaQuery.maybeOf(context)?.disableAnimations ?? false;
      unawaited(
        Scrollable.ensureVisible(
          context,
          alignment: 0.5,
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final chrome = AppChromeTheme.of(context);
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return Focus(
      onFocusChange: _handleFocusChange,
      child: Semantics(
        label: widget.message,
        focusable: true,
        focused: _focused,
        excludeSemantics: true,
        child: Tooltip(
          message: widget.message,
          child: AnimatedContainer(
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 100),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: _focused
                  ? chrome.accent.withValues(alpha: 0.10)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: _focused ? chrome.accent : Colors.transparent,
              ),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  final double size;
  const _Dot(this.color, {this.size = 7});
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// Overall provider status used by the header dot and compact chips.
class PStatus {
  final Color color;
  final bool hasData;
  final bool blocked;
  const PStatus(this.color, this.hasData, this.blocked);
}

PStatus providerStatus(ProviderQuota q, int now) {
  // A running local runtime is available, so it reads green like a healthy
  // provider. The in-use vs idle nuance is shown in the card body, not the dot.
  if (q.isLocal) {
    return isLocalRuntimeAvailableAt(q, now)
        ? const PStatus(Color(0xFF3FB950), true, false)
        : const PStatus(Color(0xFF8A91A0), false, false);
  }
  final h = providerHeadroom(q, now);
  if (h == null) {
    return const PStatus(Color(0xFF8A91A0), false, false);
  }
  if (!isTrustedQuotaEvidenceAt(q, now)) {
    if (q.suspect != null && q.driftReason == null) {
      return const PStatus(Color(0xFFD29922), true, false);
    }
    return const PStatus(Color(0xFF8A91A0), true, false);
  }
  return PStatus(_availColor(h), true, h <= kSpentHeadroomFloor);
}
