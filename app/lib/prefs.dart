import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/profiles.dart';
import 'package:quotabot_collector/util.dart';

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
    if (windowX != null) 'window_x': windowX,
    if (windowY != null) 'window_y': windowY,
  };

  factory Prefs.fromJson(Map<String, dynamic> j) => Prefs(
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
    windowX: (j['window_x'] as num?)?.toDouble(),
    windowY: (j['window_y'] as num?)?.toDouble(),
  );

  static File _file() => File('${quotabotDir('app').path}/prefs.json');

  static Prefs load() {
    try {
      final f = _file();
      if (!f.existsSync()) return const Prefs();
      return Prefs.fromJson(
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
      );
    } catch (_) {
      return const Prefs();
    }
  }

  void save() {
    try {
      // prefs.json can hold a webhook URL (a secret-bearing capability for
      // chat webhooks), so write it owner-only like other local metadata.
      final f = _file();
      restrictOwnerOnlyDirectory(f.parent);
      if (!f.existsSync()) f.createSync(recursive: true);
      restrictOwnerOnlyFile(f);
      f.writeAsStringSync(jsonEncode(toJson()));
      restrictOwnerOnlyFile(f);
    } catch (_) {
      // Preferences are best-effort; ignore write failures.
    }
  }
}
