import 'dart:async';

import 'package:flutter/material.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/drift.dart';

import 'logos.dart';
import 'provider_connection.dart';
import 'theme_spec.dart';
import 'typography.dart';

enum FirstRunPresence { live, found, missing }

class FirstRunEntry {
  final String id;
  final String name;
  final FirstRunPresence presence;
  final String statusLabel;
  final String setupHint;
  final bool canConnect;

  const FirstRunEntry({
    required this.id,
    required this.name,
    required this.presence,
    required this.statusLabel,
    required this.setupHint,
    this.canConnect = false,
  });

  bool get defaultSelected => presence != FirstRunPresence.missing;
  bool get needsSetup => presence != FirstRunPresence.live;
}

const firstRunProviderIds = <String>[
  claudeProviderId,
  codexProviderId,
  grokProviderId,
  antigravityProviderId,
  cursorProviderId,
  windsurfProviderId,
  kiroProviderId,
  ollamaProviderId,
  lmStudioProviderId,
  lemonadeProviderId,
  nvidiaProviderId,
];

const firstRunProviderNames = <String, String>{
  claudeProviderId: claudeProviderName,
  codexProviderId: codexProviderName,
  grokProviderId: grokProviderName,
  antigravityProviderId: antigravityProviderName,
  cursorProviderId: cursorProviderName,
  windsurfProviderId: windsurfProviderName,
  kiroProviderId: kiroProviderName,
  ollamaProviderId: ollamaProviderName,
  lmStudioProviderId: lmStudioProviderName,
  lemonadeProviderId: lemonadeProviderName,
  nvidiaProviderId: nvidiaProviderName,
};

class FirstRunResult {
  final Set<String> selected;
  final bool skipped;

  const FirstRunResult.skipped() : selected = const {}, skipped = true;

  const FirstRunResult.done(this.selected) : skipped = false;
}

Set<String> firstRunHiddenProviders(Set<String> selected) => {
  for (final id in firstRunProviderIds)
    if (!selected.contains(id)) id,
};

FirstRunPresence firstRunPresence(ProviderQuota? quota, int now) {
  if (quota == null) return FirstRunPresence.missing;
  if (quota.isLocal && isLocalRuntimeAvailableAt(quota, now)) {
    return FirstRunPresence.live;
  }
  if (isTrustedQuotaEvidenceAt(quota, now)) return FirstRunPresence.live;
  final error = (quota.error ?? '').toLowerCase();
  if (error.contains('not installed') || error.contains('not configured')) {
    return FirstRunPresence.missing;
  }
  return FirstRunPresence.found;
}

String firstRunStatusLabel(FirstRunPresence presence, {String? error}) {
  final text = (error ?? '').toLowerCase();
  if (text.contains('invalid') && text.contains('usage')) {
    return 'signed in';
  }
  return switch (presence) {
    FirstRunPresence.live => 'live',
    FirstRunPresence.found => 'found on this machine',
    FirstRunPresence.missing => 'not seen yet',
  };
}

String firstRunSetupHint(
  String id,
  FirstRunPresence presence, {
  String? error,
}) {
  final text = (error ?? '').toLowerCase();
  if (text.contains('invalid') && text.contains('usage')) {
    return 'This account is on this machine. Refresh after opening the app once.';
  }
  if (presence == FirstRunPresence.live) return 'Ready.';
  return switch (id) {
    claudeProviderId => 'Open Claude Code and sign in once.',
    codexProviderId => 'Open the Codex CLI and sign in once.',
    grokProviderId => 'Connect Grok, or open the Grok CLI and sign in.',
    antigravityProviderId =>
      'Connect Antigravity, or open agy or the Antigravity app and sign in.',
    cursorProviderId ||
    windsurfProviderId ||
    kiroProviderId => 'Open the app once and sign in, then come back.',
    ollamaProviderId ||
    lmStudioProviderId ||
    lemonadeProviderId => 'Start the local server. No login.',
    nvidiaProviderId => 'Set NVIDIA_API_KEY if you use NVIDIA NIM. Optional.',
    _ => 'Open that app once, then come back.',
  };
}

List<FirstRunEntry> firstRunEntries(
  List<ProviderQuota> snapshot,
  int now, {
  bool Function(String id)? canConnect,
}) {
  final latest = <String, ProviderQuota>{};
  for (final quota in snapshot) {
    final current = latest[quota.provider];
    final candidatePresence = firstRunPresence(quota, now);
    final currentPresence = firstRunPresence(current, now);
    final candidateWinsTie =
        current != null &&
        candidatePresence == currentPresence &&
        (quota.asOf > current.asOf ||
            (quota.asOf == current.asOf &&
                quota.account.compareTo(current.account) < 0));
    if (current == null ||
        candidatePresence.index < currentPresence.index ||
        candidateWinsTie) {
      latest[quota.provider] = quota;
    }
  }
  return [
    for (final id in firstRunProviderIds)
      FirstRunEntry(
        id: id,
        name: firstRunProviderNames[id] ?? id,
        presence: firstRunPresence(latest[id], now),
        statusLabel: firstRunStatusLabel(
          firstRunPresence(latest[id], now),
          error: latest[id]?.error,
        ),
        setupHint: firstRunSetupHint(
          id,
          firstRunPresence(latest[id], now),
          error: latest[id]?.error,
        ),
        canConnect:
            (canConnect?.call(id) ?? false) &&
            (latest[id] == null || providerNeedsConnection(latest[id]!)),
      ),
  ];
}

Future<FirstRunResult?> showFirstRunWizard({
  required BuildContext context,
  required List<FirstRunEntry> Function() entries,
  Future<bool> Function(String id)? onConnect,
}) {
  return showDialog<FirstRunResult>(
    context: context,
    barrierDismissible: false,
    builder: (context) =>
        FirstRunWizard(entries: entries, onConnect: onConnect),
  );
}

class FirstRunWizard extends StatefulWidget {
  final List<FirstRunEntry> Function() entries;
  final Future<bool> Function(String id)? onConnect;

  const FirstRunWizard({super.key, required this.entries, this.onConnect});

  @override
  State<FirstRunWizard> createState() => _FirstRunWizardState();
}

class _FirstRunWizardState extends State<FirstRunWizard> {
  late List<FirstRunEntry> _entries;
  late Set<String> _selected;
  int _step = 0;
  final Set<String> _connecting = {};

  @override
  void initState() {
    super.initState();
    _entries = widget.entries();
    _selected = {
      for (final entry in _entries)
        if (entry.defaultSelected) entry.id,
    };
  }

  void _reload() {
    setState(() => _entries = widget.entries());
  }

  List<FirstRunEntry> get _setupNeeded => [
    for (final entry in _entries)
      if (_selected.contains(entry.id) && entry.needsSetup) entry,
  ];

  void _continueFromFound() => setState(() => _step = 1);

  void _continueFromChoose() {
    if (_setupNeeded.isEmpty) {
      Navigator.of(context).pop(FirstRunResult.done(_selected));
      return;
    }
    setState(() => _step = 2);
  }

  @override
  Widget build(BuildContext context) {
    final chrome = AppChromeTheme.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380, maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _step == 0
                    ? 'What we found'
                    : _step == 1
                    ? 'What do you use?'
                    : 'Set these up',
                style: TextStyle(
                  fontSize: AppType.title,
                  fontWeight: FontWeight.w700,
                  color: chrome.foreground,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _step == 0
                    ? 'quotabot looked at this machine. Nothing extra is required for tools that are already live.'
                    : _step == 1
                    ? 'Check the tools you actually use. Unchecked ones stay hidden.'
                    : 'Only the tools you checked that are not live yet.',
                style: TextStyle(
                  fontSize: AppType.bodySmall,
                  height: 1.3,
                  color: chrome.muted,
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: ListView(
                  children: _step == 0
                      ? [
                          for (final entry in _entries)
                            _FoundRow(entry: entry, chrome: chrome),
                        ]
                      : _step == 1
                      ? [
                          for (final entry in _entries)
                            CheckboxListTile(
                              value: _selected.contains(entry.id),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                              controlAffinity: ListTileControlAffinity.leading,
                              secondary: ProviderLogo(
                                entry.id,
                                size: 18,
                                color: chrome.foreground,
                              ),
                              title: Text(
                                entry.name,
                                style: TextStyle(
                                  fontSize: AppType.subtitle,
                                  color: chrome.foreground,
                                ),
                              ),
                              subtitle: Text(
                                entry.statusLabel,
                                style: TextStyle(
                                  fontSize: AppType.caption,
                                  color: chrome.muted,
                                ),
                              ),
                              onChanged: (value) {
                                setState(() {
                                  if (value ?? false) {
                                    _selected.add(entry.id);
                                  } else {
                                    _selected.remove(entry.id);
                                  }
                                });
                              },
                            ),
                        ]
                      : [
                          for (final entry in _setupNeeded)
                            _SetupRow(
                              entry: entry,
                              chrome: chrome,
                              connecting: _connecting.contains(entry.id),
                              onConnect:
                                  entry.canConnect && widget.onConnect != null
                                  ? () async {
                                      setState(() => _connecting.add(entry.id));
                                      await widget.onConnect!(entry.id);
                                      if (mounted) {
                                        setState(
                                          () => _connecting.remove(entry.id),
                                        );
                                        _reload();
                                      }
                                    }
                                  : null,
                            ),
                        ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Flexible(
                    child: TextButton(
                      onPressed: () => Navigator.of(
                        context,
                      ).pop(const FirstRunResult.skipped()),
                      child: const Text(
                        'Skip for now',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  FilledButton(
                    onPressed: _step == 0
                        ? _continueFromFound
                        : _step == 1
                        ? _continueFromChoose
                        : () => Navigator.of(
                            context,
                          ).pop(FirstRunResult.done(_selected)),
                    child: Text(_step == 2 ? 'Done' : 'Continue'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FoundRow extends StatelessWidget {
  final FirstRunEntry entry;
  final AppChromeTheme chrome;

  const _FoundRow({required this.entry, required this.chrome});

  @override
  Widget build(BuildContext context) {
    final live = entry.presence == FirstRunPresence.live;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          ProviderLogo(entry.id, size: 18, color: chrome.foreground),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.subtitle,
                color: chrome.foreground,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            entry.statusLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppType.caption,
              color: live ? const Color(0xFF3FB950) : chrome.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _SetupRow extends StatelessWidget {
  final FirstRunEntry entry;
  final AppChromeTheme chrome;
  final bool connecting;
  final Future<void> Function()? onConnect;

  const _SetupRow({
    required this.entry,
    required this.chrome,
    required this.connecting,
    this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ProviderLogo(entry.id, size: 18, color: chrome.foreground),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.name,
                  style: TextStyle(
                    fontSize: AppType.subtitle,
                    color: chrome.foreground,
                  ),
                ),
                Text(
                  entry.setupHint,
                  style: TextStyle(
                    fontSize: AppType.caption,
                    color: chrome.muted,
                  ),
                ),
              ],
            ),
          ),
          if (connecting)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (onConnect != null)
            TextButton(
              onPressed: () => unawaited(onConnect!()),
              child: const Text('Connect'),
            ),
        ],
      ),
    );
  }
}
