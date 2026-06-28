/// Synthetic provider data for previews and screenshots (`QUOTABOT_DEMO=1`).
///
/// The numbers are invented and the accounts are fake; nothing here reads a real
/// account. It mirrors the desktop app's demo fleet so the CLI and the widget
/// tell the same made-up story in documentation. `collectAll` returns this and
/// skips analytics writes when the env var is set, so demo runs never pollute
/// real history.
library;

import 'adapters/ollama.dart';
import 'models.dart';

/// A believable full fleet of made-up quota for demos: a few metered
/// subscriptions at various headrooms and a few local runtimes.
List<ProviderQuota> demoProviders(int now) {
  QuotaWindow w(String label, double usedPercent, int resetInSecs) =>
      QuotaWindow(
        label: label,
        usedPercent: usedPercent,
        resetsAt: now + resetInSecs,
      );

  ProviderQuota sub(
    String id,
    String name,
    String account,
    String plan,
    List<QuotaWindow> windows,
  ) =>
      ProviderQuota(
        provider: id,
        displayName: name,
        account: account,
        plan: plan,
        asOf: now,
        windows: windows,
      );

  LocalModel m(
    String name, {
    int? bytes,
    String? param,
    String? quant,
    int? vram,
    int? ctx,
  }) =>
      (
        name: name,
        bytes: bytes,
        param: param,
        quant: quant,
        vramBytes: vram,
        expiresAt: null,
        context: ctx,
      );

  const gb = 1024 * 1024 * 1024;
  return [
    sub('claude', 'Claude', 'default', 'max', [
      w('5h', 81, 4500), // 19% free, resets ~1h15m
      w('weekly', 52, 388800), // 48% free, resets ~4d12h
    ]),
    sub('codex', 'Codex', 'default', 'pro', [
      w('5h', 44, 11400), // 56% free, resets ~3h10m
      w('weekly', 68, 294000), // 32% free, resets ~3d10h
    ]),
    sub('antigravity', 'Antigravity', 'you@example.com', 'ai pro', [
      w('5h', 9, 9600), // 91% free, resets ~2h40m
      w('weekly', 21, 468000), // 79% free, resets ~5d10h
    ]),
    sub('grok', 'Grok', 'you@example.com', 'supergrok', [
      w('monthly', 57, 712800), // 43% free, resets ~8d6h
    ]),
    sub('cursor', 'Cursor', 'default', 'pro', [
      w('monthly', 38, 745200), // 62% free, resets ~8d15h
    ]),
    localRuntimeQuota(
      id: 'ollama',
      name: 'Ollama',
      asOf: now,
      now: now,
      installed: [
        m('qwen2.5-coder:7b', bytes: 4 * gb),
        m('llama3:8b', bytes: 5 * gb),
        m('phi3:mini', bytes: 2 * gb),
      ],
      loaded: [
        m('qwen2.5-coder:7b',
            param: '7B', quant: 'Q4_K_M', vram: 4 * gb, ctx: 32768),
      ],
    ),
    localRuntimeQuota(
      id: 'lmstudio',
      name: 'LM Studio',
      asOf: now,
      now: now,
      installed: [
        m('llama-3.1-8b', bytes: 5 * gb),
        m('mistral-7b', bytes: 4 * gb),
      ],
      loaded: [m('llama-3.1-8b', vram: 5 * gb, ctx: 16384)],
    ),
    localRuntimeQuota(
      id: 'lemonade',
      name: 'Lemonade',
      asOf: now,
      now: now,
      installed: [m('gpt-oss-20b', bytes: 12 * gb)],
      loaded: const [],
    ),
  ];
}
