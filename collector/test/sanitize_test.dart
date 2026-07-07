import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/mcp.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/schema_contracts.dart';
import 'package:quotabot_collector/top.dart';
import 'package:test/test.dart';

const _now = 1782000000;

void main() {
  group('stripTerminalControl', () {
    test('removes C0 controls, DEL, C1 controls, and escape sequences', () {
      expect(stripTerminalControl('qwen\x1B[2Jcoder'), 'qwen[2Jcoder');
      expect(
        stripTerminalControl('a\x1B]52;c;payload\x07b'),
        'a]52;c;payloadb',
      );
      expect(stripTerminalControl('tab\tnewline\ncr\r'), 'tabnewlinecr');
      expect(stripTerminalControl('del\x7Fc1'), 'delc1');
    });

    test('passes printable text and non-control unicode through unchanged', () {
      const clean = 'claude max 48% frei . ollama qwen2.5 7B é中';
      expect(stripTerminalControl(clean), same(clean));
    });
  });

  group('sanitizeProviderQuota', () {
    test('clears control bytes from every provider-sourced text field', () {
      final dirty = ProviderQuota(
        provider: 'oll\x1Bama',
        displayName: 'Oll\x1B[31mama',
        account: '3 mo\x07dels',
        plan: 'lo\x1Bcal',
        source: 'man\x1Bual',
        asOf: _now,
        status: 'qwen\x1B]52;c;x\x07 loaded',
        active: true,
        error: 'to\x1Bken expired',
        details: const ['4 GB\x1B[2J VRAM'],
        windows: [
          QuotaWindow(label: '5\x1Bh', usedPercent: 10, resetsAt: _now + 60),
        ],
        models: const [
          ModelInfo(
            id: 'qwen\x1B[8m:7b',
            displayName: 'Qw\x1Ben',
            reasoning: 'adap\x1Btive',
            tier: 'fla\x1Bgship',
            quant: 'Q4\x1B_K_M',
            local: true,
          ),
        ],
      );
      final clean = sanitizeProviderQuota(dirty);
      final joined = [
        clean.provider,
        clean.displayName,
        clean.account,
        clean.plan,
        clean.source,
        clean.status,
        clean.error,
        ...clean.details,
        ...clean.windows.map((w) => w.label),
        ...clean.models.expand(
          (m) => [m.id, m.displayName, m.reasoning, m.tier, m.quant],
        ),
      ].join('|');
      expect(joined.contains('\x1B'), isFalse);
      expect(joined.contains('\x07'), isFalse);
      // Numbers, flags, and timing pass through untouched.
      expect(clean.asOf, _now);
      expect(clean.active, isTrue);
      expect(clean.windows.single.usedPercent, 10);
      expect(clean.windows.single.resetsAt, _now + 60);
      expect(clean.models.single.local, isTrue);
    });
  });

  group('terminal injection regression', () {
    test('a malicious provider string cannot smuggle escapes into top', () {
      final providers = [
        ProviderQuota(
          provider: 'grok',
          displayName: 'Grok',
          account: 'a\x1B]52;c;ZXZpbA==\x07b',
          asOf: _now,
          ok: false,
          error: 'boom\x1B[2J\x1B[H fake screen',
        ),
        ProviderQuota(
          provider: 'ollama',
          displayName: 'Ollama',
          account: 'local',
          kind: ProviderQuotaKind.local,
          asOf: _now,
          status: 'qwen\x1B[8m hidden loaded',
        ),
      ];
      final out = renderTopFrame(
        providers: providers,
        suggestion: suggestRoute(providers, _now),
        now: _now,
        width: 100,
        color: false,
        clock: '12:00:00',
      ).join('\n');
      // color: false means quotabot emits no ANSI of its own, so any escape
      // byte in the output could only have come from the provider strings.
      expect(out.contains('\x1B'), isFalse);
      expect(out.contains('\x07'), isFalse);
    });
  });

  group('single-provider response contracts', () {
    ProviderQuota quota() => ProviderQuota(
          provider: 'claude',
          displayName: 'Claude',
          account: 'default',
          asOf: _now,
          windows: [
            QuotaWindow(label: '5h', usedPercent: 20, resetsAt: _now + 3600),
          ],
        );

    test('check_provider_availability carries its own schema id and as_of', () {
      final found = availabilityResponse([quota()], _now, 'claude', null);
      expect(found['schema'], quotabotCheckV1SchemaId);
      expect(found['as_of'], _now);
      expect(found['available'], isTrue);

      final unknown = availabilityResponse([quota()], _now, 'nope', null);
      expect(unknown['schema'], quotabotCheckV1SchemaId);
      expect(unknown['as_of'], _now);
      expect(unknown['error'], isNotNull);
    });

    test('provider_with_most_headroom carries a schema id and as_of', () {
      final pick = mostHeadroomResponse([quota()], _now);
      expect(pick['schema'], quotabotHeadroomV1SchemaId);
      expect(pick['as_of'], _now);
      expect(pick['provider'], 'claude');

      final none = mostHeadroomResponse(const [], _now);
      expect(none['schema'], quotabotHeadroomV1SchemaId);
      expect(none['as_of'], _now);
      expect(none['provider'], isNull);
    });
  });
}
