import 'package:flutter/material.dart';
import 'package:quotabot_collector/collector.dart';

import 'prefs.dart';
import 'profile_ui.dart';
import 'theme_spec.dart';
import 'typography.dart';

enum ProfileEditorAction { save, delete }

class ProfileEditorResult {
  final ProfileEditorAction action;
  final QuotaProfile? profile;
  final String? deleteName;

  const ProfileEditorResult.save(this.profile)
    : action = ProfileEditorAction.save,
      deleteName = null;

  const ProfileEditorResult.delete(this.deleteName)
    : action = ProfileEditorAction.delete,
      profile = null;
}

class ProfileEditorDialog extends StatefulWidget {
  final List<QuotaProfile> profiles;
  final List<ProviderQuota> providers;
  final String activeProfile;
  final ProviderSort currentSort;
  final Set<String> currentHidden;

  const ProfileEditorDialog({
    super.key,
    required this.profiles,
    required this.providers,
    required this.activeProfile,
    required this.currentSort,
    required this.currentHidden,
  });

  @override
  State<ProfileEditorDialog> createState() => _ProfileEditorDialogState();
}

class _ProfileEditorDialogState extends State<ProfileEditorDialog> {
  static const _newProfileValue = '__new__';

  late final List<ProfileProviderOption> _options;
  late final TextEditingController _name;
  late String _selection;
  late ProfileRoutingPolicy _policy;
  late ProviderSort _sort;
  late String _theme;
  late Set<String> _hidden;
  late Set<String> _providers;
  late Map<String, Set<String>> _accounts;

  bool get _creating => _selection == _newProfileValue;

  @override
  void initState() {
    super.initState();
    _options = profileProviderOptions(
      widget.providers,
      profiles: widget.profiles,
    );
    _name = TextEditingController();
    final active = widget.profiles.any((p) => p.name == widget.activeProfile)
        ? widget.activeProfile
        : defaultProfileName;
    _loadExisting(active);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _loadExisting(String name) {
    final profile = widget.profiles.firstWhere(
      (p) => p.name == name,
      orElse: QuotaProfile.defaultProfile,
    );
    _selection = profile.name;
    _name.text = profile.name;
    _policy = profile.routingPolicy;
    _theme = normalizeAppTheme(profile.theme);
    _sort = profile.name == widget.activeProfile
        ? widget.currentSort
        : sortFromProfile(profile);
    _hidden = profile.name == widget.activeProfile
        ? {...widget.currentHidden}
        : {...profile.hiddenProviders};
    _providers = _selectedProvidersFor(profile);
    _accounts = _selectedAccountsFor(profile);
  }

  void _loadNew() {
    _selection = _newProfileValue;
    _name.text = '';
    _policy = ProfileRoutingPolicy.balanced;
    _theme = appThemeSystem;
    _sort = ProviderSort.defaultOrder;
    _hidden = const {};
    _providers = _options.map((option) => option.provider).toSet();
    _accounts = {
      for (final option in _options)
        if (option.accounts.isNotEmpty)
          option.provider: option.accounts.toSet(),
    };
  }

  Set<String> _selectedProvidersFor(QuotaProfile profile) {
    if (_options.isEmpty) return {...profile.providers};
    if (profile.providers.isEmpty) {
      return _options.map((option) => option.provider).toSet();
    }
    return {
      for (final option in _options)
        if (profile.providers.contains(option.provider)) option.provider,
    };
  }

  Map<String, Set<String>> _selectedAccountsFor(QuotaProfile profile) {
    final out = <String, Set<String>>{};
    for (final option in _options) {
      final selected = profile.accounts[option.provider];
      if (option.accounts.isEmpty) continue;
      out[option.provider] = selected == null || selected.isEmpty
          ? option.accounts.toSet()
          : option.accounts.where(selected.contains).toSet();
    }
    return out;
  }

  String? get _normalizedName => normalizeProfileName(_name.text);

  bool get _nameCollides =>
      _creating &&
      widget.profiles.any((profile) => profile.name == _normalizedName);

  bool get _canSave {
    if (!_creating && _selection == defaultProfileName) return false;
    final normalized = _normalizedName;
    if (normalized == null || normalized == defaultProfileName) return false;
    if (_nameCollides) return false;
    return true;
  }

  QuotaProfile _draft() => profileFromSelection(
    name: _normalizedName ?? _name.text,
    options: _options,
    selectedProviders: _providers,
    selectedAccounts: _accounts,
    hiddenProviders: _hidden,
    routingPolicy: _policy,
    sort: _sort,
    theme: storedAppTheme(_theme),
  );

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final muted = dark ? const Color(0xFF8A91A0) : const Color(0xFF6B7280);
    return AlertDialog(
      title: const Text('Profiles'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 560),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _selection,
                decoration: const InputDecoration(
                  labelText: 'Profile',
                  isDense: true,
                ),
                items: [
                  for (final profile in widget.profiles)
                    DropdownMenuItem(
                      value: profile.name,
                      child: Text(profileLabel(profile)),
                    ),
                  const DropdownMenuItem(
                    value: _newProfileValue,
                    child: Text('New profile'),
                  ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    if (value == _newProfileValue) {
                      _loadNew();
                    } else {
                      _loadExisting(value);
                    }
                  });
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _name,
                enabled: _creating,
                decoration: InputDecoration(
                  labelText: 'Name',
                  isDense: true,
                  errorText: _nameError(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<ProfileRoutingPolicy>(
                key: ValueKey('routing:$_selection'),
                initialValue: _policy,
                decoration: const InputDecoration(
                  labelText: 'Routing policy',
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(
                    value: ProfileRoutingPolicy.balanced,
                    child: Text('Balanced'),
                  ),
                  DropdownMenuItem(
                    value: ProfileRoutingPolicy.subscriptionsFirst,
                    child: Text('Subscriptions first'),
                  ),
                  DropdownMenuItem(
                    value: ProfileRoutingPolicy.localOnly,
                    child: Text('Local only'),
                  ),
                ],
                onChanged: _selection == defaultProfileName
                    ? null
                    : (value) => setState(
                        () => _policy = value ?? ProfileRoutingPolicy.balanced,
                      ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                key: ValueKey('theme:$_selection'),
                initialValue: _theme,
                decoration: const InputDecoration(
                  labelText: 'Theme',
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(
                    value: appThemeSystem,
                    child: Text('System'),
                  ),
                  DropdownMenuItem(value: appThemeLight, child: Text('Light')),
                  DropdownMenuItem(value: appThemeDark, child: Text('Dark')),
                  DropdownMenuItem(
                    value: appThemeHacker,
                    child: Text('Hacker'),
                  ),
                ],
                onChanged: _selection == defaultProfileName
                    ? null
                    : (value) =>
                          setState(() => _theme = normalizeAppTheme(value)),
              ),
              const SizedBox(height: 12),
              Text(
                'Providers',
                style: TextStyle(
                  fontSize: AppType.label,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: muted,
                ),
              ),
              const SizedBox(height: 4),
              if (_options.isEmpty)
                Text(
                  'No providers detected yet.',
                  style: TextStyle(fontSize: AppType.caption, color: muted),
                )
              else
                for (final option in _options) _providerOption(option),
            ],
          ),
        ),
      ),
      actions: [
        if (!_creating && _selection != defaultProfileName)
          TextButton(
            onPressed: () => Navigator.of(
              context,
            ).pop(ProfileEditorResult.delete(_selection)),
            child: const Text('Delete'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _canSave
              ? () => Navigator.of(
                  context,
                ).pop(ProfileEditorResult.save(_draft()))
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }

  String? _nameError() {
    if (!_creating) return null;
    if (_name.text.trim().isEmpty) return null;
    if (_normalizedName == null) {
      return 'Use letters, numbers, dots, dashes, or underscores';
    }
    if (_normalizedName == defaultProfileName) return 'Default already exists';
    if (_nameCollides) return 'Profile already exists';
    return null;
  }

  Widget _providerOption(ProfileProviderOption option) {
    final selected = _providers.contains(option.provider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CheckboxListTile(
          value: selected,
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(
            option.displayName,
            style: const TextStyle(fontSize: AppType.subtitle),
          ),
          onChanged: _selection == defaultProfileName
              ? null
              : (value) => _setProvider(option, value ?? false),
        ),
        if (selected)
          for (final account in option.accounts)
            Padding(
              padding: const EdgeInsets.only(left: 24),
              child: CheckboxListTile(
                value: _accounts[option.provider]?.contains(account) ?? false,
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  account,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: AppType.caption),
                ),
                onChanged: _selection == defaultProfileName
                    ? null
                    : (value) => _setAccount(option, account, value ?? false),
              ),
            ),
      ],
    );
  }

  void _setProvider(ProfileProviderOption option, bool selected) {
    setState(() {
      if (selected) {
        _providers.add(option.provider);
        if (option.accounts.isNotEmpty) {
          _accounts[option.provider] = option.accounts.toSet();
        }
      } else {
        _providers.remove(option.provider);
        _accounts.remove(option.provider);
      }
    });
  }

  void _setAccount(
    ProfileProviderOption option,
    String account,
    bool selected,
  ) {
    setState(() {
      final accounts = {...?_accounts[option.provider]};
      if (selected) {
        accounts.add(account);
        _providers.add(option.provider);
      } else {
        accounts.remove(account);
      }
      if (accounts.isEmpty) {
        _providers.remove(option.provider);
        _accounts.remove(option.provider);
      } else {
        _accounts[option.provider] = accounts;
      }
    });
  }
}
