import 'package:flutter/material.dart';

import 'theme_spec.dart';
import 'typography.dart';

enum SettingsCategory {
  providers('Providers'),
  display('Display'),
  alerts('Alerts'),
  updates('Updates');

  const SettingsCategory(this.label);

  final String label;
}

/// Keeps navigation and Close reachable independently of the active settings.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.onClose,
    required this.providers,
    required this.display,
    required this.alerts,
    required this.updates,
  });

  final VoidCallback onClose;
  final Widget providers;
  final Widget display;
  final Widget alerts;
  final Widget updates;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final _scroll = ScrollController();
  var _category = SettingsCategory.providers;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _select(SettingsCategory category) {
    if (category == _category) return;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() => _category = category);
  }

  @override
  Widget build(BuildContext context) {
    final chrome = AppChromeTheme.of(context);
    final content = switch (_category) {
      SettingsCategory.providers => widget.providers,
      SettingsCategory.display => widget.display,
      SettingsCategory.alerts => widget.alerts,
      SettingsCategory.updates => widget.updates,
    };
    return Dialog(
      backgroundColor: chrome.scaffold,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: chrome.border),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Settings',
                      style: TextStyle(
                        fontSize: AppType.title,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('settings-close'),
                    tooltip: 'Close settings',
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < 400) {
                    return DropdownButtonFormField<SettingsCategory>(
                      key: const ValueKey('settings-category'),
                      initialValue: _category,
                      isExpanded: true,
                      itemHeight: null,
                      decoration: const InputDecoration(
                        labelText: 'Section',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        for (final category in SettingsCategory.values)
                          DropdownMenuItem(
                            value: category,
                            child: Text(category.label),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) _select(value);
                      },
                    );
                  }
                  return Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final category in SettingsCategory.values)
                        ChoiceChip(
                          key: ValueKey('settings-category-${category.name}'),
                          label: Text(category.label),
                          selected: category == _category,
                          showCheckmark: false,
                          onSelected: (_) => _select(category),
                        ),
                    ],
                  );
                },
              ),
              Divider(height: 20, color: chrome.border),
              Expanded(
                child: Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(
                      context,
                    ).copyWith(scrollbars: false),
                    child: SingleChildScrollView(
                      controller: _scroll,
                      padding: const EdgeInsets.only(right: 10),
                      child: KeyedSubtree(
                        key: ValueKey(_category),
                        child: content,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
