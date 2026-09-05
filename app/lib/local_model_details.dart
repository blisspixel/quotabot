import 'package:flutter/material.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/labels.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/registry.dart';
import 'package:quotabot_collector/util.dart';

import 'quota_labels.dart';
import 'theme_spec.dart';
import 'typography.dart';

/// Opens details from the displayed snapshot without collecting or loading.
class LocalModelDetailsButton extends StatefulWidget {
  final ProviderQuota quota;
  final int now;

  const LocalModelDetailsButton({
    super.key,
    required this.quota,
    required this.now,
  });

  @override
  State<LocalModelDetailsButton> createState() =>
      _LocalModelDetailsButtonState();
}

class _LocalModelDetailsButtonState extends State<LocalModelDetailsButton> {
  final _focusNode = FocusNode(debugLabel: 'Local model details');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _showDetails() async {
    final quota = widget.quota;
    final now = widget.now;
    await showDialog<void>(
      context: context,
      builder: (_) => LocalModelDetailsDialog(quota: quota, now: now),
    );
    if (mounted) _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Inspect ${widget.quota.displayName} model inventory',
    child: TextButton.icon(
      focusNode: _focusNode,
      onPressed: _showDetails,
      icon: const Icon(Icons.view_list_rounded, size: 15),
      label: Text('Models (${widget.quota.models.length})'),
      style: TextButton.styleFrom(
        foregroundColor: AppChromeTheme.of(context).accent,
        minimumSize: const Size(28, 28),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
          fontSize: AppType.caption,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

/// Read-only model inventory in the existing collector registry order.
class LocalModelDetailsDialog extends StatefulWidget {
  final ProviderQuota quota;
  final int now;

  const LocalModelDetailsDialog({
    super.key,
    required this.quota,
    required this.now,
  });

  @override
  State<LocalModelDetailsDialog> createState() =>
      _LocalModelDetailsDialogState();
}

class _LocalModelDetailsDialogState extends State<LocalModelDetailsDialog> {
  final _scroll = ScrollController();
  late final _entries = buildModelRegistry([widget.quota], widget.now);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chrome = AppChromeTheme.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      constraints: const BoxConstraints(maxWidth: 560),
      backgroundColor: chrome.scaffold,
      child: SizedBox(
        width: 560,
        height: 640,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  '${widget.quota.displayName} models',
                  style: TextStyle(
                    fontSize: AppType.title,
                    fontWeight: FontWeight.w700,
                    color: chrome.foreground,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${_entries.length} reported. '
                '${_captureLabel(widget.quota.asOf, widget.now)}.',
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: chrome.muted,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  child: ListView.builder(
                    key: const ValueKey('local-model-details-list'),
                    controller: _scroll,
                    padding: const EdgeInsets.only(right: 8),
                    itemCount: _entries.length + 1,
                    itemBuilder: (context, index) => index == 0
                        ? _inventorySummary(chrome)
                        : _ModelDetail(
                            entry: _entries[index - 1],
                            chrome: chrome,
                            inventoryCurrent:
                                isLocalRuntimeReachableAt(
                                  widget.quota,
                                  widget.now,
                                ) &&
                                widget.quota.error == null &&
                                widget.quota.driftReason == null,
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(foregroundColor: chrome.accent),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _inventorySummary(AppChromeTheme chrome) {
    final hardware = widget.quota.localHardware;
    final hostFacts = <String>[
      if (hardware?.systemMemoryTotalBytes != null)
        'RAM: ${_memoryLabel(hardware!.systemMemoryTotalBytes!, hardware.systemMemoryAvailableBytes)}',
      if (hardware?.gpuName != null) 'GPU: ${hardware!.gpuName}',
      if (hardware?.gpuMemoryTotalBytes != null)
        'GPU memory: ${_memoryLabel(hardware!.gpuMemoryTotalBytes!, hardware.gpuMemoryAvailableBytes)}',
      if (hardware?.gpuUtilizationPercent != null)
        'GPU activity: ${hardware!.gpuUtilizationPercent}%',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Listed models may run on another device. '
            'Context may be a configured or maximum limit.',
            style: TextStyle(
              fontSize: AppType.caption,
              height: 1.4,
              color: chrome.muted,
            ),
          ),
          if (hostFacts.isNotEmpty) ...[
            const SizedBox(height: 4),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              minTileHeight: 32,
              iconColor: chrome.muted,
              collapsedIconColor: chrome.muted,
              shape: const Border(),
              collapsedShape: const Border(),
              title: Text(
                'This computer',
                style: TextStyle(
                  fontSize: AppType.caption,
                  fontWeight: FontWeight.w600,
                  color: chrome.foreground,
                ),
              ),
              children: [
                Text(
                  '${hostFacts.join('\n')}\n'
                  '${_captureLabel(hardware!.asOf, widget.now)}. '
                  'Models running elsewhere use that device\'s memory.',
                  style: TextStyle(
                    fontSize: AppType.caption,
                    height: 1.4,
                    color: chrome.muted,
                  ),
                ),
              ],
            ),
          ],
          if (_entries.isEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'No models were reported in this snapshot. '
              'Use Refresh on the dashboard after the runtime inventory changes.',
              style: TextStyle(
                fontSize: AppType.body,
                color: chrome.foreground,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ModelDetail extends StatelessWidget {
  final ModelEntry entry;
  final AppChromeTheme chrome;
  final bool inventoryCurrent;

  const _ModelDetail({
    required this.entry,
    required this.chrome,
    required this.inventoryCurrent,
  });

  @override
  Widget build(BuildContext context) {
    final model = entry.model;
    // Request admission and generation eligibility do not age an otherwise
    // current metadata observation or prove that its runtime is unreachable.
    final lastObserved = !inventoryCurrent;
    final upstream = model.upstreamRouting;
    final residency = upstream != UpstreamRouting.notReported
        ? model.loaded
              ? 'Runtime reports loaded'
              : 'No runtime residency reported'
        : model.loaded
        ? 'Loaded'
        : 'Cold';
    final exclusions = <String>[
      ?requestAdmissionDetail(entry.requestAdmission),
      if (model.cloudOffloaded)
        'Cloud-offloaded. Excluded from local and quota budgets.',
      if (upstream == UpstreamRouting.declared && !model.cloudOffloaded)
        'Upstream configured. Execution location and cost are unverified. '
            'Excluded from local and quota budgets.',
      if (upstream == UpstreamRouting.unresolved)
        'Upstream configuration is unresolved. Excluded from routing.',
      if (model.embedding == true)
        'Embedding model. Excluded from generation routing.',
      if (entry.stale)
        'Stale inventory. Excluded from routing.'
      else if (entry.driftReason != null)
        'Untrusted inventory. Excluded from routing.'
      else if (!inventoryCurrent)
        'Runtime unavailable. Excluded from routing.',
    ];
    final contextLabel = model.contextTokens == null
        ? 'unknown'
        : '${formatContextTokens(model.contextTokens!)} tokens';
    final quant = model.quant?.trim();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: chrome.card,
        border: Border.all(color: chrome.tileBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            model.id,
            style: TextStyle(
              fontSize: AppType.subtitle,
              fontWeight: FontWeight.w600,
              color: chrome.foreground,
            ),
          ),
          if (model.displayName != null && model.displayName != model.id)
            _line(model.displayName!),
          const SizedBox(height: 6),
          Text(
            lastObserved ? '$residency (last observed)' : residency,
            style: TextStyle(
              fontSize: AppType.caption,
              fontWeight: FontWeight.w600,
              color: chrome.foreground,
            ),
          ),
          _line('Reported context: $contextLabel'),
          _line(
            'Quantization: ${quant?.isNotEmpty == true ? quant : 'unknown'}',
          ),
          _line(
            'Tools: ${_capability(model.tools)}. '
            'Vision: ${_capability(model.vision)}. '
            'Reasoning: ${_reasoningLabel(model.reasoning)}.',
          ),
          if (model.sizeBytes != null)
            _line('Model size: ${formatCompactBytes(model.sizeBytes!)}'),
          if (model.loaded && model.vramBytes != null)
            _line(
              'Reported GPU memory: ${formatCompactBytes(model.vramBytes!)}',
            ),
          const SizedBox(height: 6),
          _line(_fitLabel(entry, lastObserved: lastObserved)),
          for (final exclusion in exclusions) ...[
            const SizedBox(height: 4),
            _line(exclusion, emphasized: true),
          ],
        ],
      ),
    );
  }

  Widget _line(String text, {bool emphasized = false}) => Text(
    text,
    style: TextStyle(
      fontSize: AppType.caption,
      height: 1.4,
      fontWeight: emphasized ? FontWeight.w600 : FontWeight.normal,
      color: emphasized ? chrome.foreground : chrome.muted,
    ),
  );
}

String _capability(bool? value) => switch (value) {
  true => 'supported',
  false => 'not supported',
  null => 'unknown',
};

String _reasoningLabel(String? value) {
  final label = value?.trim();
  if (label == null || label.isEmpty) return 'unknown';
  return label.toLowerCase() == 'reasoning' ? 'supported' : label;
}

String _fitLabel(ModelEntry entry, {required bool lastObserved}) {
  if (entry.model.cloudOffloaded) {
    return 'Advisory host fit: not applicable to cloud execution.';
  }
  if (entry.model.upstreamRouting != UpstreamRouting.notReported) {
    return 'Advisory host fit: unavailable for upstream configuration.';
  }
  final fit = entry.hardwareFit;
  final prefix = lastObserved ? 'Last observed advisory fit' : 'Advisory fit';
  if (fit == null || fit.status == LocalHardwareFitStatus.unknown) {
    return '$prefix: unknown. Model size or host memory evidence is incomplete.';
  }
  if (fit.status == LocalHardwareFitStatus.loaded) {
    return '$prefix: runtime reports loaded; memory pool unknown.';
  }
  final pool = switch (fit.basis) {
    'system_memory' => 'system RAM',
    'gpu_memory' => 'one GPU memory pool',
    _ => 'unknown memory pool',
  };
  final estimate = fit.estimatedMemoryBytes == null
      ? ''
      : ' Estimated requirement: ${formatCompactBytes(fit.estimatedMemoryBytes!)}.';
  return '$prefix: ${fit.status.wireName} using $pool.$estimate '
      'Context and runtime overhead can vary.';
}

String _memoryLabel(int total, int? available) => available == null
    ? '${formatCompactBytes(total)} total; availability unknown'
    : '${formatCompactBytes(available)} available of ${formatCompactBytes(total)}';

String _captureLabel(int asOf, int now) => asOf <= 0
    ? 'Capture time unknown'
    : asOf > now
    ? 'Capture time ahead of this clock'
    : 'Captured ${ageLabel(asOf, now)} ago';
