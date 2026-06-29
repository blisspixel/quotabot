import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/ansi.dart';
import 'package:quotabot_collector/auth/google_auth.dart';
import 'package:quotabot_collector/auth/xai_auth.dart';
import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/demo.dart' as cli_demo;
import 'package:quotabot_collector/top.dart';
import 'package:quotabot_collector/util.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'demo.dart';
import 'fleet.dart';
import 'logos.dart';
import 'prefs.dart';
import 'termshot.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

/// Screenshot-export mode (`QUOTABOT_SHOTS=1`): the app loads demo data, captures
/// the widget and analytics views to PNGs (in `QUOTABOT_SHOTS_DIR`, default the
/// current directory), then exits. It reuses the real widget tree so the README
/// images stay pixel-faithful. Shots mode implies demo data; both are no-ops on a
/// normal run.
final bool _shotsMode = Platform.environment['QUOTABOT_SHOTS'] == '1';
final bool _demoMode =
    _shotsMode || Platform.environment['QUOTABOT_DEMO'] == '1';

/// Boundary around the live route, captured for screenshots.
final GlobalKey _shotBoundaryKey = GlobalKey();

/// Boundary around the rendered CLI `top` frame, captured for the README.
final GlobalKey _termShotKey = GlobalKey();

/// Global text-scale, applied to every route (strip and analytics) via the
/// MaterialApp builder. Driven by the TextSize preference.
final ValueNotifier<double> textScale = ValueNotifier<double>(1.0);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final prefs = Prefs.load();
  textScale.value = prefs.textSize.scale;

  // init notifications (cross platform) - wrapped to prevent crash on Windows if not fully supported
  try {
    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
      macOS: DarwinInitializationSettings(),
      linux: LinuxInitializationSettings(defaultActionName: 'Open'),
    );
    await flutterLocalNotificationsPlugin.initialize(initSettings);
    tz.initializeTimeZones();
    tz.setLocalLocation(tz.local);
  } catch (_) {
    // notifications init failed, app will continue without them
  }

  final options = WindowOptions(
    size: Size(340, 760),
    minimumSize: Size(120, 40),
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
        final x = prefs.windowX!;
        final y = prefs.windowY!;
        // Guard against offscreen/negative saved positions (e.g. multi-monitor drift) that can make window invisible.
        if (x > -200 && y > -100 && x < 6000 && y < 3000) {
          await windowManager.setPosition(Offset(x, y));
        } else {
          await windowManager.center();
        }
      }
      await windowManager.setTitle('quotabot');
      await windowManager.show();
      await windowManager.focus();
      await windowManager.setMinimumSize(const Size(120, 40));
      // Gentle bring-to-front for launcher contexts (was aggressive loop causing issues)
      await windowManager.setAlwaysOnTop(true);
      await Future.delayed(const Duration(milliseconds: 120));
      await windowManager.setAlwaysOnTop(prefs.alwaysOnTop);
      await windowManager.focus();
    }),
  );

  runApp(QuotaBotApp(prefs: prefs));
}

class QuotaBotApp extends StatelessWidget {
  final Prefs prefs;
  const QuotaBotApp({super.key, required this.prefs});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system, // follow OS light/dark
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      builder: (context, child) => RepaintBoundary(
        key: _shotBoundaryKey,
        child: ValueListenableBuilder<double>(
          valueListenable: textScale,
          builder: (context, scale, _) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
      ),
      home: Dashboard(prefs: prefs),
    );
  }

  ThemeData _theme(Brightness b) {
    final dark = b == Brightness.dark;
    final base = ThemeData(
      brightness: b,
      scaffoldBackgroundColor: dark
          ? const Color(0xFF14161A)
          : const Color(0xFFF4F5F7),
      fontFamily: 'Segoe UI',
    );
    // Use tabular (monospaced) figures everywhere so digits line up and the main
    // quota view and the analytics screen render numbers identically. Text styles
    // inherit and merge onto these defaults without setting fontFeatures
    // themselves, so this one setting carries across both screens.
    return base.copyWith(textTheme: _tabularFigures(base.textTheme));
  }
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

class Dashboard extends StatefulWidget {
  final Prefs prefs;
  const Dashboard({super.key, required this.prefs});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard>
    with WindowListener, TrayListener {
  List<ProviderQuota> _data = const [];
  bool _loading = true;
  late bool _compact = widget.prefs.compact;
  late Cadence _cadence = widget.prefs.cadence;
  late bool _alwaysOnTop = widget.prefs.alwaysOnTop;
  late bool _showInTaskbar = widget.prefs.showInTaskbar;
  late bool _enableNotifications = widget.prefs.enableNotifications;
  late bool _showAccounts = widget.prefs.showAccounts;
  late TextSize _textSize = widget.prefs.textSize;
  bool _isRefreshing = false;
  int _failStreak = 0; // consecutive refreshes with no live data at all
  late final Set<String> _hidden = {...widget.prefs.hidden};
  late ProviderSort _sort = widget.prefs.sort;
  Map<String, List<ProviderQuota>> _history = {};
  Map<String, Insights> _insights = {};
  Map<String, List<List<double?>>> _heatmaps = {};
  Map<String, List<HeadroomBucket>> _buckets = {};
  final Set<String> _expanded = {}; // providers whose insights panel is open
  bool _overflowing = false; // content taller than the capped window (scrolls)
  final Map<String, DateTime> _lastNotified =
      {}; // debounce key -> time for notif spam reduction
  Offset? _windowPos;
  DateTime _updated = DateTime.now();
  Timer? _refreshTimer;
  Timer? _tick;
  final GlobalKey _contentKey = GlobalKey();
  final ScrollController _scroll = ScrollController();

  List<ProviderQuota> get _visible =>
      _data.where((q) => !_hidden.contains(q.provider)).toList();

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
          final ha = providerHeadroom(a, now) ?? -1.0;
          final hb = providerHeadroom(b, now) ?? -1.0;
          return hb.compareTo(ha); // highest headroom first
        });
        break;
      case ProviderSort.mostUsed:
        list.sort((a, b) {
          final ha = providerHeadroom(a, now) ?? 101.0;
          final hb = providerHeadroom(b, now) ?? 101.0;
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

  @override
  void initState() {
    super.initState();
    _windowPos = widget.prefs.windowX == null
        ? null
        : Offset(widget.prefs.windowX!, widget.prefs.windowY ?? 0);
    windowManager.addListener(this);
    trayManager.addListener(this);
    unawaited(_initTray());
    unawaited(windowManager.setAlwaysOnTop(_alwaysOnTop));
    unawaited(windowManager.setSkipTaskbar(!_showInTaskbar));
    unawaited(windowManager.setMinimumSize(const Size(120, 40)));
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

  /// Loads demo data (via [_demoMode]), captures the widget then the analytics
  /// view, and exits. Reuses the real widgets so the README images stay faithful.
  Future<void> _exportShots() async {
    // The window show is gated behind windowManager.waitUntilReadyToShow, so wait
    // out that plus the first real paint before the first capture.
    await Future.delayed(const Duration(seconds: 2));
    await WidgetsBinding.instance.endOfFrame;
    await _captureBoundary('screenshot-widget.png');
    _showFleet();
    await Future.delayed(const Duration(milliseconds: 1400)); // route + charts
    await WidgetsBinding.instance.endOfFrame;
    await _captureBoundary('screenshot-analytics.png');
    _showTerminal(_demoTopFrame());
    await Future.delayed(const Duration(milliseconds: 700));
    await WidgetsBinding.instance.endOfFrame;
    await _captureBoundary('screenshot-top.png', _termShotKey);
    await Future.delayed(const Duration(milliseconds: 150));
    exit(0);
  }

  /// Renders the `quotabot top` view over the demo fleet to ANSI lines, for the
  /// terminal screenshot. Truecolor so the gradient meters show.
  List<String> _demoTopFrame() {
    final now = nowEpoch();
    final demo = cli_demo.demoProviders(now);
    return renderTopFrame(
      providers: demo,
      suggestion: suggestRoute(demo, now,
          burnStatsByProvider: cli_demo.demoBurnStats()),
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
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    _refreshTimer?.cancel();
    _tick?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void onWindowMoved() async {
    _windowPos = await windowManager.getPosition();
    _persistPrefs();
  }

  // System tray: keep quotabot one click away, and let the window close to the
  // tray instead of quitting so it can sit quietly in the background. The tray
  // menu is the way back and the only place that truly quits.
  Future<void> _initTray() async {
    try {
      await trayManager.setIcon(
        Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.png',
      );
      await trayManager.setToolTip('quotabot');
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
      // Only now that the tray exists do we redirect close to hide: otherwise a
      // platform without a tray would have no way to reopen a hidden window.
      await windowManager.setPreventClose(true);
    } catch (_) {
      // No tray on this platform/session; the window keeps normal close-to-quit.
    }
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
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

  void _persistPrefs() {
    Prefs(
      hidden: _hidden,
      compact: _compact,
      cadence: _cadence,
      alwaysOnTop: _alwaysOnTop,
      showInTaskbar: _showInTaskbar,
      enableNotifications: _enableNotifications,
      sort: _sort,
      textSize: _textSize,
      showAccounts: _showAccounts,
      setupDone: widget.prefs.setupDone,
      windowX: _windowPos?.dx,
      windowY: _windowPos?.dy,
    ).save();
  }

  Future<void> _refresh() async {
    if (_isRefreshing) return;
    if (_demoMode) {
      _loadDemo();
      return;
    }
    setState(() => _isRefreshing = true);
    try {
      final results = await collectAll();
      if (!mounted) return;
      final det = detectInstalledAgenticTools();
      // Only keep providers that have data or are detected as installed.
      // This hides e.g. Kiro/Cursor/Windsurf/Antigravity when not present and no data.
      // Core providers (codex etc.) are kept even if currently empty.
      final active = results.where((q) {
        if (q.windows.isNotEmpty || q.stale) return true;
        final err = (q.error ?? '').toLowerCase();
        final isPassiveStub =
            err.contains('installed') ||
            err.contains('no data') ||
            err.contains('free tier') ||
            err.contains('not installed');
        if (isPassiveStub) {
          return det.contains(q.provider);
        }
        return true;
      }).toList();
      // Track systemic failure...
      final anyLive = active.any(
        (q) => q.ok && q.windows.isNotEmpty && !q.stale,
      );
      _failStreak = anyLive ? 0 : _failStreak + 1;
      setState(() {
        _data = active;
        _loading = false;
        _updated = DateTime.now();
        _history = {};
        _insights = {};
        _heatmaps = {};
        _buckets = {};
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final tz = DateTime.now().timeZoneOffset;
        for (final q in active) {
          _history[q.provider] = loadHistory(q.provider);
          if (!q.isLocal) {
            final buckets = loadBuckets(q.provider);
            _buckets[q.provider] = buckets;
            _insights[q.provider] = Insights.from(
              buckets,
              nowSec,
              tzOffset: tz,
            );
            _heatmaps[q.provider] = weekHourHeatmap(buckets, tzOffset: tz);
          }
        }
      });
      _scheduleNext();
      _checkAndNotify();
      WidgetsBinding.instance.addPostFrameCallback((_) => _applySize());
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  /// Populates the dashboard with synthetic demo data (QUOTABOT_DEMO=1) so the
  /// app can be previewed or screenshotted without touching real accounts.
  void _loadDemo() {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final tz = DateTime.now().timeZoneOffset;
    final buckets = demoBuckets();
    setState(() {
      _showAccounts = true; // show the (fake) account names in the demo
      _data = demoData();
      _loading = false;
      _updated = DateTime.now();
      _history = {};
      _insights = {};
      _heatmaps = {};
      _buckets = buckets;
      buckets.forEach((id, b) {
        _insights[id] = Insights.from(b, nowSec, tzOffset: tz);
        _heatmaps[id] = weekHourHeatmap(b, tzOffset: tz);
      });
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
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final maxH = _maxWindowHeight();
      double w;
      double h;
      if (_compact) {
        final n = _displayed.length.clamp(1, 8);
        w = (n * 42 + 70).clamp(140.0, 400.0).toDouble();
        h = 50;
      } else {
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        w = 340;
        // Estimates tuned to the real rendered heights so the frameless window
        // hugs the content (no translucent dead space below it). The body
        // scrolls, so a small undershoot is caught rather than clipped.
        h = 62; // header row + outer paddings
        for (final q in _displayed) {
          final blocked = providerStatus(q, now).blocked;
          final rows = (q.windows.isEmpty || blocked) ? 1 : q.windows.length;
          var card = 50.0 + rows * 14.0; // card chrome + each window/status row
          if (q.isLocal) card += q.details.length * 14; // detail lines
          if ((_history[q.provider] ?? const []).isNotEmpty) {
            card += 20; // "usually ~X% free" line
          }
          // An expanded insights panel adds a sparkline, a couple of lines, and
          // (when there is enough data) a heatmap grid.
          if (_expanded.contains(q.provider) &&
              (_insights[q.provider]?.samples ?? 0) > 0) {
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
    setState(() => _compact = !_compact);
    _applySize();
    _persistPrefs();
  }

  void _toggleHidden(String provider) {
    setState(() {
      if (!_hidden.remove(provider)) _hidden.add(provider);
    });
    _applySize();
    _persistPrefs();
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
        PopupMenuItem(value: 'hide', child: Text('Hide ${q.displayName}')),
      ],
    );
    if (choice == 'hide') {
      _toggleHidden(q.provider);
    } else if (choice == 'setup') {
      _showProviderSetup(q);
    }
  }

  /// A setup-help dialog tailored to the provider, with an inline "Connect now"
  /// for the two providers that support quotabot's own login.
  void _showProviderSetup(ProviderQuota q) {
    final canConnect = _canConnectProvider(q.provider);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Set up ${q.displayName}'),
        content: Text(_setupText(q.provider)),
        actions: [
          if (canConnect)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _connectAndValidate(q.provider);
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

  static String _setupText(String provider) {
    switch (provider) {
      case 'codex':
        return 'Sign in to the Codex CLI (run codex once). quotabot reads its '
            'local rate-limit file automatically. No login needed here.';
      case 'claude':
        return 'Sign in to Claude Code. quotabot reads its usage automatically. '
            'No login needed here.';
      case 'grok':
        return 'Grok shows live while the Grok CLI token is fresh. To keep it '
            'live without reopening the CLI, connect quotabot once with a device '
            'code (works on Windows, macOS, and Linux).';
      case 'antigravity':
        return 'Antigravity shows live while the IDE token is fresh. To keep it '
            'live without reopening the IDE, provide QUOTABOT_GOOGLE_CLIENT_ID '
            'and QUOTABOT_GOOGLE_CLIENT_SECRET for your own Google OAuth client, '
            'then connect via your browser.';
      case 'kiro':
      case 'cursor':
      case 'windsurf':
        return 'Detected from the app\'s local data. If it shows no data, open '
            'the app once and sign in, then refresh.';
      case 'ollama':
      case 'lmstudio':
        return 'Local runtime. Start it and load a model; quotabot detects what '
            'is installed and loaded automatically. No login needed.';
      default:
        return 'quotabot reads this provider from local data; no setup needed.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final card = dark ? const Color(0xFF1C1F25) : Colors.white;

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
          child: _contentBox(dark, card, _contentKey),
        ),
      ),
    );
  }

  Widget _contentBox(bool dark, Color card, Key? key) {
    return Container(
      key: key,
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: dark ? const Color(0xFF2A2E36) : const Color(0xFFE2E4E8),
        ),
      ),
      child: _loading
          ? const SizedBox(
              width: 220,
              height: 80,
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          : _compact
          ? _compactView(dark)
          : _expandedView(dark, card),
    );
  }

  Widget _expandedView(bool dark, Color card) {
    // Only providers with more than one account on screen need their account
    // name shown to tell them apart (e.g. multiple Antigravity logins). For a
    // single-account provider like Grok the username is just noise, so hide it.
    final counts = <String, int>{};
    for (final q in _displayed) {
      counts[q.provider] = (counts[q.provider] ?? 0) + 1;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(dark),
        const SizedBox(height: 2),
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: (_) => windowManager.startDragging(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < _displayed.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  ProviderTile(
                    quota: _displayed[i],
                    cardColor: card,
                    history: _history[_displayed[i].provider] ?? const [],
                    insights: _insights[_displayed[i].provider],
                    heatmap: _heatmaps[_displayed[i].provider],
                    expanded: _expanded.contains(_displayed[i].provider),
                    onToggle: () => setState(() {
                      final p = _displayed[i].provider;
                      if (!_expanded.remove(p)) _expanded.add(p);
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _applySize(),
                      );
                    }),
                    onContextMenu: (pos) => _showCardMenu(_displayed[i], pos),
                    showAccounts:
                        _showAccounts &&
                        (counts[_displayed[i].provider] ?? 0) > 1,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Tiny strip: each visible provider as logo + status dot. Glanceable.
  Widget _compactView(bool dark) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final muted = dark ? const Color(0xFF8A91A0) : const Color(0xFF6B7280);
    final fg = dark ? Colors.white : const Color(0xFF111317);
    return SizedBox(
      height: 46,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 6, 0),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (_) => windowManager.startDragging(),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (int i = 0; i < _displayed.length; i++)
                      Padding(
                        padding: EdgeInsets.only(
                          right: i == _displayed.length - 1 ? 0 : 10,
                        ),
                        child: Tooltip(
                          message:
                              _showAccounts &&
                                  _displayed[i].account != 'default' &&
                                  _displayed[i].account != 'unknown'
                              ? '${_displayed[i].displayName} (${_displayed[i].account})'
                              : _displayed[i].stale
                              ? '${_displayed[i].displayName} (cached)'
                              : _displayed[i].displayName,
                          child: _compactChip(_displayed[i], now, fg),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            _iconButton(Icons.open_in_full_rounded, muted, _toggleCompact),
            _iconButton(Icons.close_rounded, muted, windowManager.close),
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

  /// Average remaining headroom across visible providers that report quota,
  /// as a percent (0..100), or null when nothing has data. This is the "pool"
  /// the header gauge fills to.
  double? _poolHeadroom() {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    double sum = 0;
    int n = 0;
    for (final q in _visible) {
      final h = providerHeadroom(q, now);
      if (h != null) {
        sum += h;
        n++;
      }
    }
    return n == 0 ? null : sum / n;
  }

  Widget _header(bool dark) {
    final muted = dark ? const Color(0xFF8A91A0) : const Color(0xFF6B7280);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 6),
        child: Row(
          children: [
            Expanded(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  () {
                    final pool = _poolHeadroom();
                    final track = dark
                        ? const Color(0xFF333842)
                        : const Color(0xFFD8DBE0);
                    return AppGauge(
                      size: 17,
                      value: (pool ?? 0) / 100.0,
                      fillColor: pool == null ? track : _availColor(pool),
                      trackColor: track,
                    );
                  }(),
                  const SizedBox(width: 7),
                  Text(
                    'Quota',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                      color: dark ? Colors.white : const Color(0xFF111317),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _ago(_updated),
                    style: TextStyle(fontSize: 10.5, color: muted),
                  ),
                ],
              ),
            ),
            // Order: the two things you actively do (refresh, open analytics),
            // then the view toggle, then settings and help, then close last.
            _iconButton(
              _isRefreshing ? Icons.sync : Icons.refresh_rounded,
              muted,
              _refresh,
              tooltip: 'Refresh now',
            ),
            _iconButton(
              Icons.bar_chart_rounded,
              muted,
              _showFleet,
              tooltip: 'Quota analytics',
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
              windowManager.close,
              tooltip: 'Close',
            ),
          ],
        ),
      ),
    );
  }

  Widget _menuButton(Color muted) {
    return PopupMenuButton<String>(
      tooltip: 'Providers and refresh',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      icon: Icon(Icons.more_vert_rounded, size: 16, color: muted),
      onSelected: _onMenu,
      itemBuilder: (_) => [
        const PopupMenuItem(
          enabled: false,
          height: 26,
          child: Text(
            'PROVIDERS',
            style: TextStyle(fontSize: 10, letterSpacing: 0.6),
          ),
        ),
        for (final q in _data)
          CheckedPopupMenuItem(
            value: 'show:${q.provider}',
            checked: !_hidden.contains(q.provider),
            child: Text(
              _showAccounts && q.account != 'default' && q.account != 'unknown'
                  ? '${q.displayName} (${q.account})'
                  : q.displayName,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          enabled: false,
          height: 26,
          child: Text(
            'REFRESH',
            style: TextStyle(fontSize: 10, letterSpacing: 0.6),
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
            style: TextStyle(fontSize: 10, letterSpacing: 0.6),
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
            style: TextStyle(fontSize: 10, letterSpacing: 0.6),
          ),
        ),
        CheckedPopupMenuItem(
          value: 'always_on_top',
          checked: _alwaysOnTop,
          child: Text('Always on top', style: const TextStyle(fontSize: 12.5)),
        ),
        CheckedPopupMenuItem(
          value: 'show_in_taskbar',
          checked: _showInTaskbar,
          child: Text(
            'Show in taskbar',
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
        CheckedPopupMenuItem(
          value: 'notifications',
          checked: _enableNotifications,
          child: Text('Notifications', style: const TextStyle(fontSize: 12.5)),
        ),
        CheckedPopupMenuItem(
          value: 'show_accounts',
          checked: _showAccounts,
          child: Text(
            'Show account names',
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          enabled: false,
          height: 26,
          child: Text(
            'TEXT SIZE',
            style: TextStyle(fontSize: 10, letterSpacing: 0.6),
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
        child: Text(label, style: const TextStyle(fontSize: 12.5)),
      );

  PopupMenuItem<String> _cadenceItem(String value, Cadence c, String label) =>
      CheckedPopupMenuItem(
        value: value,
        checked: _cadence == c,
        child: Text(label, style: const TextStyle(fontSize: 12.5)),
      );

  PopupMenuItem<String> _sortItem(String value, ProviderSort s, String label) =>
      CheckedPopupMenuItem(
        value: value,
        checked: _sort == s,
        child: Text(label, style: const TextStyle(fontSize: 12.5)),
      );

  void _onMenu(String value) {
    if (value.startsWith('show:')) {
      _toggleHidden(value.substring(5));
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
    } else if (value == 'text:small') {
      _setTextSize(TextSize.small);
    } else if (value == 'text:medium') {
      _setTextSize(TextSize.medium);
    } else if (value == 'text:large') {
      _setTextSize(TextSize.large);
    }
  }

  void _setShowAccounts(bool value) {
    setState(() => _showAccounts = value);
    _persistPrefs();
  }

  void _setTextSize(TextSize t) {
    setState(() => _textSize = t);
    textScale.value = t.scale; // applied app-wide by the MaterialApp builder
    _persistPrefs();
    WidgetsBinding.instance.addPostFrameCallback((_) => _applySize());
  }

  void _setCadence(Cadence c) {
    setState(() => _cadence = c);
    _scheduleNext(); // apply the new cadence immediately
    _persistPrefs();
  }

  void _setSort(ProviderSort s) {
    if (_sort == s) return;
    setState(() => _sort = s);
    _applySize();
    _persistPrefs();
  }

  void _setAlwaysOnTop(bool value) {
    setState(() => _alwaysOnTop = value);
    windowManager.setAlwaysOnTop(value);
    _persistPrefs();
  }

  void _setShowInTaskbar(bool value) {
    setState(() => _showInTaskbar = value);
    windowManager.setSkipTaskbar(!value);
    _persistPrefs();
  }

  Future<void> _checkAndNotify() async {
    if (!_enableNotifications) return;
    try {
      final now = DateTime.now();
      final nowSec = now.millisecondsSinceEpoch ~/ 1000;
      // Compute the routing recommendation once so a low-quota alert can point
      // the user at where to send work instead.
      final suggestion = suggestRoute(_data, nowSec);
      for (final q in _data) {
        final h = providerHeadroom(q, nowSec);
        if (h != null && h < 15 && !q.stale) {
          final key = '${q.provider}:low';
          if (_shouldNotify(key, now)) {
            final id = _notificationId(key);
            await flutterLocalNotificationsPlugin.cancel(id);
            final rec = suggestion.recommended;
            final hint = (rec != null && rec.provider != q.provider)
                ? ' Route to ${rec.provider}'
                      '${rec.isLocal ? ' (local)' : ' (${rec.headroom?.round()}% free)'}.'
                : '';
            await flutterLocalNotificationsPlugin.show(
              id,
              'Low quota',
              '${q.displayName} has ${h.toStringAsFixed(0)}% headroom.$hint',
              _buildDetails(q.displayName),
            );
          }
        }
        if (q.stale) continue;
        for (final w in q.windows) {
          if (w.resetsAt != null &&
              w.resetsAt! > nowSec &&
              w.percent != null &&
              w.percent! > 80) {
            final key = '${q.provider}:${w.label}:reset';
            if (_shouldNotify(key, now)) {
              final resetDt = DateTime.fromMillisecondsSinceEpoch(
                w.resetsAt! * 1000,
              );
              final tzReset = tz.TZDateTime.from(resetDt, tz.local);
              final id = _notificationId(key);
              await flutterLocalNotificationsPlugin.cancel(id);
              await flutterLocalNotificationsPlugin.zonedSchedule(
                id,
                'Quota reset soon',
                '${q.displayName} ${w.label} resets soon',
                tzReset,
                _buildDetails(q.displayName),
                androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
                uiLocalNotificationDateInterpretation:
                    UILocalNotificationDateInterpretation.absoluteTime,
              );
            }
          }
        }
      }
    } catch (_) {
      // ignore notif errors
    }
  }

  bool _shouldNotify(String key, DateTime now) {
    final last = _lastNotified[key];
    if (last == null || now.difference(last).inSeconds > 300) {
      _lastNotified[key] = now;
      return true;
    }
    return false;
  }

  // Platform-aware details. Android base works via compat on desktop;
  // full Darwin/Linux specifics supplied for better integration where supported.
  // Windows falls back gracefully. Errors are caught by caller.
  NotificationDetails _buildDetails(String name) => const NotificationDetails(
    android: AndroidNotificationDetails(
      'quotabot_quota',
      'Quota Alerts',
      importance: Importance.high,
    ),
    macOS: DarwinNotificationDetails(),
    linux: LinuxNotificationDetails(defaultActionName: 'View'),
  );

  void _toggleNotifications() {
    setState(() => _enableNotifications = !_enableNotifications);
    _persistPrefs();
  }

  void _showHelp() => _showSetup();

  /// Opens the Fleet Analytics dashboard in the same window. It is a mobile-style
  /// vertical scroll, so the window size is left exactly as it is.
  Future<void> _showFleet() async {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Open analytics in the existing window: no resize, no move, so nothing
    // reflows or appears to change scale. The analytics body scrolls to fit.
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FleetScreen(data: _data, buckets: _buckets, dark: dark),
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _applySize());
  }

  /// Compact setup/help panel: a short intro, then every detected provider with
  /// its live status and an inline Connect for Grok/Antigravity (login then
  /// re-validate). Reachable from the help button; never pops up on its own.
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
          builder: (ctx, setDlg) => Dialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 24,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320, maxHeight: 460),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Providers',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: fg,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
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
                    Text(
                      'Detected automatically. Grok and Antigravity can be '
                      'connected once to stay live. Local models (Ollama, LM '
                      'Studio, Lemonade) appear only while their server is '
                      'running; in LM Studio, start the local server.',
                      style: TextStyle(fontSize: 11, height: 1.3, color: muted),
                    ),
                    const SizedBox(height: 8),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final q in _data)
                              _setupRow(ctx, q, muted, fg, connecting, setDlg),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Tip: right-click any card to set it up or hide it.',
                      style: TextStyle(fontSize: 10.5, color: muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _setupRow(
    BuildContext ctx,
    ProviderQuota q,
    Color muted,
    Color fg,
    Set<String> connecting,
    StateSetter setDlg,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final (label, color) = _stateChip(q, now);
    final canConnect = _canConnectProvider(q.provider);
    final isLive = label == 'live' || label == 'in use' || label == 'running';
    final busy = connecting.contains(q.provider);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          ProviderLogo(q.provider, size: 18, color: fg),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              q.displayName,
              style: TextStyle(fontSize: 12.5, color: fg),
            ),
          ),
          if (busy)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Text(label, style: TextStyle(fontSize: 10.5, color: color)),
          const SizedBox(width: 8),
          if (canConnect && !isLive && !busy)
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30),
              ),
              onPressed: () async {
                setDlg(() => connecting.add(q.provider));
                await _connectAndValidate(q.provider);
                if (ctx.mounted) setDlg(() => connecting.remove(q.provider));
              },
              child: const Text('Connect', style: TextStyle(fontSize: 11)),
            )
          else if (!busy)
            IconButton(
              icon: Icon(Icons.help_outline_rounded, size: 16, color: muted),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              onPressed: () => _showProviderSetup(q),
            ),
        ],
      ),
    );
  }

  /// Runs quotabot's own login for a provider, then re-collects so the setup
  /// row reflects the new state. Returns whether the provider is now live.
  Future<bool> _connectAndValidate(String provider) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (provider == 'antigravity') {
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
      await _refresh();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final match = _data.where((x) => x.provider == provider);
      final ok =
          match.isNotEmpty &&
          !match.first.stale &&
          providerHeadroom(match.first, now) != null;
      messenger.showSnackBar(
        SnackBar(
          content: Text(ok ? '$provider connected' : '$provider not live yet'),
        ),
      );
      return ok;
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not connect $provider: $e')),
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
  (String, Color) _stateChip(ProviderQuota q, int now) {
    const green = Color(0xFF3FB950),
        amber = Color(0xFFD29922),
        red = Color(0xFFF85149),
        grey = Color(0xFF8A91A0),
        blue = Color(0xFF58A6FF);
    if (q.isLocal) return q.active ? ('in use', green) : ('running', blue);
    if (!q.ok || q.windows.isEmpty) return ('no data', grey);
    if (q.stale) return ('cached', amber);
    final h = providerHeadroom(q, now) ?? 100;
    if (h <= 0.5) return ('spent', red);
    return ('live', green);
  }

  Widget _iconButton(
    IconData icon,
    Color color,
    VoidCallback? onTap, {
    String? tooltip,
  }) {
    final button = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 15, color: color),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: button,
    );
  }
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
  final bool showAccounts;
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
    this.showAccounts = true,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final muted = dark ? const Color(0xFF8A91A0) : const Color(0xFF6B7280);
    final fg = dark ? Colors.white : const Color(0xFF111317);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final views = quota.windows.map((w) => _view(w, now)).toList();

    // Binding constraint from pure analysis. A spent longer window overrides
    // shorter ones so the display never shows healthy when the binding cap is spent.
    final bindingWin = bindingWindow(quota, now);
    WinView? binding;
    if (bindingWin != null) {
      binding = _view(bindingWin, now);
    }
    final blocked = binding != null && binding.exhausted;
    final statusColor = binding == null
        ? muted
        : _availColor(binding.remaining);
    final hasInsights = insights != null && insights!.samples > 0;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: hasInsights ? onToggle : null,
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
          border: Border.all(
            color: dark ? const Color(0xFF272B33) : const Color(0xFFEDEEF1),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ProviderLogo(quota.provider, size: 20, color: fg),
                const SizedBox(width: 10),
                Text(
                  quota.displayName,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
                if (showAccounts &&
                    quota.account != 'default' &&
                    quota.account != 'unknown' &&
                    quota.account != 'installed' &&
                    quota.account != 'cli')
                  Text(
                    ' (${quota.account})',
                    style: TextStyle(fontSize: 10.5, color: muted),
                  ),
                const SizedBox(width: 8),
                if (quota.isLocal)
                  _Dot(
                    quota.active
                        ? const Color(0xFF3FB950) // a model is loaded / in use
                        : const Color(0xFF58A6FF),
                  ) // running but idle
                else if (quota.windows.isNotEmpty)
                  _Dot(statusColor),
                const Spacer(),
                if (quota.stale) ...[
                  Icon(Icons.history_rounded, size: 12, color: muted),
                  const SizedBox(width: 3),
                  Text(
                    _ageLabel(quota.asOf, now),
                    style: TextStyle(fontSize: 10, color: muted),
                  ),
                  const SizedBox(width: 8),
                ],
                if (quota.plan != null)
                  Text(
                    quota.plan!.toLowerCase(),
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                      color: muted,
                    ),
                  ),
                if (hasInsights) ...[
                  const SizedBox(width: 4),
                  Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.insights_rounded,
                    size: 13,
                    color: muted,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            if (quota.isLocal)
              _localRow(quota, muted, fg)
            else if (quota.windows.isEmpty)
              ((quota.plan ?? '').toLowerCase().contains('free')
                  ? _freeTierRow(muted)
                  : _noData(quota.error, muted))
            else if (blocked)
              _blockedRow(binding, now, muted)
            else
              ...views.map(
                (v) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: WindowBar(view: v, muted: muted, fg: fg, dark: dark),
                ),
              ),
            if (history.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: () {
                  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
                  final avg = averageRecentHeadroom(history, now);
                  return Text(
                    avg == null
                        ? '${history.length} recent checks'
                        : 'usually ~${avg.toStringAsFixed(0)}% free (last ${history.length})',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                      color: muted,
                    ),
                  );
                }(),
              ),
            if (expanded && hasInsights)
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
    );
  }

  /// Single collapsed line shown when the binding window is exhausted.
  Widget _blockedRow(WinView v, int now, Color muted) {
    const red = Color(0xFFF85149);
    return Row(
      children: [
        const _Dot(red),
        const SizedBox(width: 8),
        Text(
          '${v.label} spent',
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: red,
          ),
        ),
        const Spacer(),
        Text(
          'resets ${_resetLabel(v.resetsAt, now)}',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w500,
            color: muted,
          ),
        ),
      ],
    );
  }

  Widget _noData(String? err, Color muted) {
    final msg = (err != null && err.length < 80) ? err : 'no live data';
    return Row(
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
        Text(msg, style: TextStyle(fontSize: 10.5, color: muted)),
      ],
    );
  }

  Widget _freeTierRow(Color muted) {
    return Row(
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
        Text('free tier', style: TextStyle(fontSize: 10.5, color: muted)),
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
                  fontSize: 10.5,
                  fontWeight: FontWeight.w500,
                  color: fg,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              loaded ? 'in use' : 'idle',
              style: TextStyle(fontSize: 9.5, color: muted),
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
              style: TextStyle(fontSize: 9.5, color: muted),
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
  final bool rolledOver; // reset time already passed -> fresh window
  final int? resetsAt;
  const WinView(this.label, this.remaining, this.rolledOver, this.resetsAt);
  bool get exhausted => !rolledOver && remaining <= 0.5;
}

WinView _view(QuotaWindow w, int now) {
  final rolled = w.resetsAt != null && w.resetsAt! < now;
  final rem = rolled
      ? 100.0
      : (100.0 - (w.percent ?? 0)).clamp(0, 100).toDouble();
  return WinView(w.label, rem, rolled, w.resetsAt);
}

Color _availColor(num remaining) {
  if (remaining >= 50) return const Color(0xFF3FB950); // healthy green
  if (remaining >= 25) return const Color(0xFFD29922); // amber
  if (remaining > 0) return const Color(0xFFDB6D28); // orange
  return const Color(0xFFF85149); // red (exhausted)
}

/// One rolling window rendered as: [label] [availability bar] [reset / %].
class WindowBar extends StatelessWidget {
  final WinView view;
  final Color muted;
  final Color fg;
  final bool dark;
  const WindowBar({
    super.key,
    required this.view,
    required this.muted,
    required this.fg,
    required this.dark,
  });

  @override
  Widget build(BuildContext context) {
    final remaining = view.remaining;
    final color = _availColor(remaining);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    return Row(
      children: [
        SizedBox(
          width: 42,
          child: Text(
            view.label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: muted,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: remaining / 100.0,
              minHeight: 7,
              backgroundColor: dark
                  ? const Color(0xFF2A2E36)
                  : const Color(0xFFE9EBEF),
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 96,
          child: Text(
            view.rolledOver
                ? 'ready'
                : view.resetsAt != null
                ? '${remaining.round()}% free  ${_resetLabel(view.resetsAt, now)}'
                : '${remaining.round()}% free',
            textAlign: TextAlign.end,
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
              color: view.rolledOver ? const Color(0xFF3FB950) : fg,
            ),
          ),
        ),
      ],
    );
  }
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
            SizedBox(
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
                        fontSize: 10.5,
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
                style: TextStyle(fontSize: 10, color: muted),
              ),
            ),
          if (heatmap != null && _filledCells(heatmap!) >= 8) ...[
            const SizedBox(height: 6),
            Text(
              'free by hour x weekday (greener = freer)',
              style: TextStyle(fontSize: 9, color: muted),
            ),
            const SizedBox(height: 3),
            SizedBox(
              height: 30,
              width: double.infinity,
              child: CustomPaint(painter: _HeatmapPainter(heatmap!, dark)),
            ),
          ],
          if (showPace)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                pace.verdict,
                style: TextStyle(
                  fontSize: 10,
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
    return const PStatus(Color(0xFF3FB950), true, false);
  }
  final h = providerHeadroom(q, now);
  if (h == null) {
    return const PStatus(Color(0xFF8A91A0), false, false);
  }
  if (q.stale) {
    return const PStatus(Color(0xFF8A91A0), true, false);
  }
  return PStatus(_availColor(h), true, h <= 0.5);
}

int _notificationId(String key) {
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

/// Compact "3h12m" / "2d4h" reset label.
String _resetLabel(int? resetsAt, int now) {
  if (resetsAt == null) return '';
  var s = resetsAt - now;
  if (s <= 0) return 'now';
  final d = s ~/ 86400;
  s %= 86400;
  final h = s ~/ 3600;
  s %= 3600;
  final m = s ~/ 60;
  if (d > 0) return '${d}d${h}h';
  if (h > 0) return '${h}h${m}m';
  return '${m}m';
}

String _ago(DateTime t) {
  // Show an absolute clock time ("as of 8:38 AM") so it is unambiguous whether
  // the data is current. Append a short date only once it is no longer today,
  // so a stale snapshot can never masquerade as fresh.
  final now = DateTime.now();
  final clock = _formatTime(t);
  final sameDay =
      now.year == t.year && now.month == t.month && now.day == t.day;
  if (sameDay) return 'as of $clock';
  return 'as of $clock ${t.month}/${t.day}';
}

String _formatTime(DateTime t) {
  final h = t.hour;
  final min = t.minute.toString().padLeft(2, '0');
  final ampm = h >= 12 ? 'PM' : 'AM';
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12:$min $ampm';
}

/// Short age of a cached snapshot, e.g. "12m", "3h", "2d".
String _ageLabel(int asOf, int now) {
  final s = now - asOf;
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m';
  if (s < 86400) return '${s ~/ 3600}h';
  return '${s ~/ 86400}d';
}
