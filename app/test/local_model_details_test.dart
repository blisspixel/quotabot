import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/local_model_details.dart';
import 'package:quotabot/main.dart';
import 'package:quotabot/prefs.dart';
import 'package:quotabot/theme_spec.dart';
import 'package:quotabot_collector/models.dart';

const _now = 1809500000;
const _gib = 1024 * 1024 * 1024;

ProviderQuota _quota({
  List<ModelInfo> models = const [],
  LocalHardwareInfo? hardware,
  String provider = 'ollama',
  String displayName = 'Ollama',
  bool stale = false,
  bool ok = true,
  String? error,
  int asOf = _now,
}) => ProviderQuota(
  provider: provider,
  displayName: displayName,
  account: 'default',
  asOf: asOf,
  kind: ProviderQuotaKind.local,
  perMachine: true,
  models: models,
  localHardware: hardware,
  active: models.any((model) => model.loaded),
  stale: stale,
  ok: ok,
  error: error,
);

Widget _wrap(
  Widget child, {
  double textScale = 1,
  String theme = appThemeDark,
}) => MaterialApp(
  theme: (theme == appThemeLight ? ThemeData.light() : ThemeData.dark())
      .copyWith(
        extensions: [
          AppChromeTheme.forSpec(
            theme == appThemeLight ? Brightness.light : Brightness.dark,
            theme,
          ),
        ],
      ),
  builder: (context, built) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: true,
    ),
    child: built!,
  ),
  home: Scaffold(body: child),
);

Widget _tile(ProviderQuota quota, {VoidCallback? onToggle}) => Align(
  alignment: Alignment.topCenter,
  child: SizedBox(
    width: 340,
    child: ProviderTile(
      quota: quota,
      cardColor: const Color(0xFF1C1F25),
      nowEpochSeconds: _now,
      onToggle: onToggle,
    ),
  ),
);

Future<void> _open(WidgetTester tester, ProviderQuota quota) async {
  await tester.pumpWidget(_wrap(_tile(quota)));
  await tester.tap(find.byType(LocalModelDetailsButton));
  await tester.pumpAndSettle();
}

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    160,
    maxScrolls: 200,
    scrollable: find
        .descendant(
          of: find.byKey(const ValueKey('local-model-details-list')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

Finder _model(String id) => find.byWidgetPredicate(
  (widget) => widget is SelectableText && widget.data == id,
);

void main() {
  testWidgets('shows loaded and cold models with reported capabilities', (
    tester,
  ) async {
    await _open(
      tester,
      _quota(
        models: const [
          ModelInfo(id: 'cold-model', local: true, sizeBytes: 4 * _gib),
          ModelInfo(
            id: 'loaded-model',
            displayName: 'Loaded model label',
            local: true,
            loaded: true,
            contextTokens: 32768,
            quant: 'Q4_K_M',
            tools: true,
            vision: false,
            reasoning: 'reasoning',
            sizeBytes: 8 * _gib,
            vramBytes: 6 * _gib,
          ),
          ModelInfo(
            id: 'second-loaded',
            local: true,
            loaded: true,
            reasoning: 'high',
          ),
        ],
        hardware: const LocalHardwareInfo(
          asOf: _now - 10,
          systemMemoryTotalBytes: 32 * _gib,
          systemMemoryAvailableBytes: 24 * _gib,
          gpuMemoryTotalBytes: 12 * _gib,
          gpuMemoryAvailableBytes: 4 * _gib,
          gpuName: 'Host GPU',
          gpuCount: 1,
          gpuUtilizationPercent: 20,
        ),
      ),
    );

    expect(find.text('Ollama models'), findsOneWidget);
    expect(find.text('3 reported. Captured 0s ago.'), findsOneWidget);
    expect(find.text('This computer'), findsOneWidget);
    await tester.tap(find.text('This computer'));
    await tester.pumpAndSettle();
    expect(find.textContaining('GPU activity: 20%'), findsOneWidget);
    expect(_model('loaded-model'), findsOneWidget);
    expect(find.text('Loaded model label'), findsOneWidget);
    expect(find.text('Reported context: 32K tokens'), findsOneWidget);
    expect(find.text('Quantization: Q4_K_M'), findsOneWidget);
    expect(
      find.text(
        'Tools: supported. Vision: not supported. Reasoning: supported.',
      ),
      findsOneWidget,
    );
    expect(find.text('Reported GPU memory: 6.0 GB'), findsOneWidget);
    expect(
      find.text('Advisory fit: runtime reports loaded; memory pool unknown.'),
      findsWidgets,
    );

    await _scrollTo(tester, _model('second-loaded'));
    expect(_model('second-loaded'), findsOneWidget);
    expect(find.textContaining('Reasoning: high.'), findsOneWidget);
    await _scrollTo(tester, _model('cold-model'));
    expect(find.text('Cold'), findsOneWidget);
    expect(
      find.textContaining('Advisory fit: comfortable using system RAM.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unknown context, quantization, capabilities and fit stay visible',
    (tester) async {
      await _open(
        tester,
        _quota(models: const [ModelInfo(id: 'unknown', local: true)]),
      );

      expect(find.text('Reported context: unknown'), findsOneWidget);
      expect(find.text('Quantization: unknown'), findsOneWidget);
      expect(
        find.text('Tools: unknown. Vision: unknown. Reasoning: unknown.'),
        findsOneWidget,
      );
      expect(find.textContaining('Advisory fit: unknown.'), findsOneWidget);
      expect(find.text('This computer'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cloud and embedding exclusions remain visible in inventory', (
    tester,
  ) async {
    await _open(
      tester,
      _quota(
        models: const [
          ModelInfo(id: 'embedding-model', local: true, embedding: true),
          ModelInfo(id: 'remote-cloud', local: true, cloudOffloaded: true),
        ],
      ),
    );

    expect(
      find.text('Embedding model. Excluded from generation routing.'),
      findsOneWidget,
    );
    await _scrollTo(tester, _model('remote-cloud'));
    expect(
      find.text('Cloud-offloaded. Excluded from local and quota budgets.'),
      findsOneWidget,
    );
    expect(
      find.text('Advisory host fit: not applicable to cloud execution.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale inventory keeps last-observed residency excluded', (
    tester,
  ) async {
    await _open(
      tester,
      _quota(
        stale: true,
        asOf: _now - 3600,
        models: const [ModelInfo(id: 'was-loaded', local: true, loaded: true)],
      ),
    );

    expect(find.text('1 reported. Captured 1h ago.'), findsOneWidget);
    expect(find.text('Loaded (last observed)'), findsOneWidget);
    expect(
      find.text('Stale inventory. Excluded from routing.'),
      findsOneWidget,
    );
    expect(find.textContaining('Last observed advisory fit:'), findsOneWidget);
    expect(find.text('Loaded'), findsNothing);
  });

  testWidgets('unavailable runtime inventory remains inspectable', (
    tester,
  ) async {
    await _open(
      tester,
      _quota(
        ok: false,
        error: 'server unavailable',
        models: const [ModelInfo(id: 'retained-model', local: true)],
      ),
    );

    expect(_model('retained-model'), findsOneWidget);
    expect(find.text('Cold (last observed)'), findsOneWidget);
    expect(
      find.text('Runtime unavailable. Excluded from routing.'),
      findsOneWidget,
    );
  });

  testWidgets('GPU fit names its selected pool and unknown availability', (
    tester,
  ) async {
    await _open(
      tester,
      _quota(
        models: const [
          ModelInfo(id: 'gpu-fit', local: true, sizeBytes: 4 * _gib),
        ],
        hardware: const LocalHardwareInfo(
          asOf: _now,
          gpuMemoryTotalBytes: 12 * _gib,
          gpuCount: 1,
        ),
      ),
    );

    await tester.tap(find.text('This computer'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('12.0 GB total; availability unknown'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Advisory fit: tight using one GPU memory pool.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Estimated requirement: 5.0 GB.'),
      findsOneWidget,
    );
  });

  testWidgets('LM Studio inventory does not promise on-device execution', (
    tester,
  ) async {
    await _open(
      tester,
      _quota(
        provider: 'lmstudio',
        displayName: 'LM Studio',
        models: const [
          ModelInfo(id: 'linked-model', local: true, loaded: true),
        ],
      ),
    );

    expect(find.text('LM Studio models'), findsOneWidget);
    expect(
      find.textContaining('Listed models may run on another device.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Context may be a configured or maximum limit.'),
      findsOneWidget,
    );
  });

  testWidgets('empty inventory gives a snapshot-specific repair', (
    tester,
  ) async {
    await _open(tester, _quota());

    expect(find.text('0 reported. Captured 0s ago.'), findsOneWidget);
    expect(
      find.textContaining('No models were reported in this snapshot.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(LocalModelDetailsDialog), findsNothing);
  });

  testWidgets('keyboard opens and closes details with focus restored', (
    tester,
  ) async {
    var toggles = 0;
    await tester.pumpWidget(
      _wrap(
        _tile(
          _quota(models: const [ModelInfo(id: 'keyboard-model', local: true)]),
          onToggle: () => toggles++,
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final button = tester.widget<TextButton>(
      find.descendant(
        of: find.byType(LocalModelDetailsButton),
        matching: find.byType(TextButton),
      ),
    );
    expect(button.focusNode!.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(LocalModelDetailsDialog), findsOneWidget);
    expect(toggles, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(LocalModelDetailsDialog), findsNothing);
    expect(button.focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byType(LocalModelDetailsDialog), findsOneWidget);
    expect(toggles, 0);
  });

  for (final theme in [appThemeLight, appThemeDark, appThemeHacker]) {
    testWidgets('$theme model details meet desktop accessibility guidelines', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _wrap(
            _tile(
              _quota(
                models: const [ModelInfo(id: 'readable-model', local: true)],
                hardware: const LocalHardwareInfo(
                  asOf: _now,
                  systemMemoryTotalBytes: 32 * _gib,
                  systemMemoryAvailableBytes: 20 * _gib,
                ),
              ),
            ),
            theme: theme,
          ),
        );
        await tester.tap(find.byType(LocalModelDetailsButton));
        await tester.pumpAndSettle();
        await tester.tap(find.text('This computer'));
        await tester.pumpAndSettle();
        for (final guideline in [
          labeledTapTargetGuideline,
          const MinimumTapTargetGuideline(
            size: Size(28, 28),
            link:
                'https://learn.microsoft.com/windows/apps/design/input/guidelines-for-targeting',
          ),
          textContrastGuideline,
        ]) {
          await expectLater(tester, meetsGuideline(guideline));
        }
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets(
    'compact dashboard can expand to model details without collecting',
    (tester) async {
      var collects = 0;
      final quota = _quota(
        asOf: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        models: const [ModelInfo(id: 'compact-model', local: true)],
      );
      await tester.pumpWidget(
        _wrap(
          Dashboard.test(
            demoMode: false,
            prefs: const Prefs(
              compact: true,
              setupDone: true,
              enableNotifications: false,
              cadence: Cadence.h1,
            ),
            collector: () async {
              collects++;
              return [quota];
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LocalModelDetailsButton), findsNothing);
      await tester.tap(find.byTooltip('Expand'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(LocalModelDetailsButton));
      await tester.pumpAndSettle();
      expect(_model('compact-model'), findsOneWidget);
      expect(collects, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'narrow scaled details scroll long IDs without clipping controls',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(260, 540);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final longId = 'model-${'long-identifier-' * 16}';
      final quota = _quota(
        models: [
          for (var index = 0; index < 12; index++)
            ModelInfo(id: '$index-$longId', local: true),
        ],
      );
      await tester.pumpWidget(_wrap(_tile(quota), textScale: 2));
      await tester.tap(find.byType(LocalModelDetailsButton));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _scrollTo(tester, _model('9-$longId'));
      expect(_model('9-$longId'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final close = find.text('Close');
      expect(tester.getRect(close).bottom, lessThan(540));
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.byType(LocalModelDetailsDialog), findsNothing);
    },
  );

  testWidgets('opening and inspecting details does not invoke collection', (
    tester,
  ) async {
    var collects = 0;
    final quota = _quota(
      asOf: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      models: const [ModelInfo(id: 'snapshot-model', local: true)],
    );
    await tester.pumpWidget(
      _wrap(
        Dashboard.test(
          demoMode: false,
          prefs: const Prefs(
            setupDone: true,
            enableNotifications: false,
            cadence: Cadence.h1,
          ),
          collector: () async {
            collects++;
            return [quota];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(collects, 1);
    await tester.tap(find.byType(LocalModelDetailsButton));
    await tester.pumpAndSettle();
    expect(_model('snapshot-model'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(collects, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'open details retain one snapshot through refresh and provider removal',
    (tester) async {
      final displayed = ValueNotifier<ProviderQuota?>(
        _quota(
          asOf: _now - 8,
          models: const [ModelInfo(id: 'original-model', local: true)],
          hardware: const LocalHardwareInfo(
            asOf: _now - 8,
            systemMemoryTotalBytes: 32 * _gib,
            gpuName: 'Original GPU',
          ),
        ),
      );
      addTearDown(displayed.dispose);
      var displayedNow = _now;
      final host = ValueListenableBuilder<ProviderQuota?>(
        valueListenable: displayed,
        builder: (context, quota, child) => quota == null
            ? const Text('Provider removed')
            : LocalModelDetailsButton(quota: quota, now: displayedNow),
      );
      await tester.pumpWidget(_wrap(host));
      await tester.tap(find.byType(LocalModelDetailsButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('This computer'));
      await tester.pumpAndSettle();

      void expectOriginalSnapshot() {
        expect(find.text('Ollama models'), findsOneWidget);
        expect(find.text('1 reported. Captured 8s ago.'), findsOneWidget);
        expect(find.textContaining('32.0 GB total'), findsOneWidget);
        expect(find.textContaining('GPU: Original GPU'), findsOneWidget);
        expect(_model('original-model'), findsOneWidget);
        expect(_model('replacement-model'), findsNothing);
        expect(find.textContaining('Replacement GPU'), findsNothing);
        expect(tester.takeException(), isNull);
      }

      expectOriginalSnapshot();
      displayedNow = _now + 300;
      displayed.value = _quota(
        displayName: 'Updated runtime',
        asOf: displayedNow,
        models: const [
          ModelInfo(id: 'replacement-model', local: true),
          ModelInfo(id: 'additional-model', local: true),
        ],
        hardware: const LocalHardwareInfo(
          asOf: _now + 300,
          systemMemoryTotalBytes: 64 * _gib,
          gpuName: 'Replacement GPU',
        ),
      );
      await tester.pumpAndSettle();
      // Rebuilding the Navigator's inherited theme also rebuilds its routes.
      await tester.pumpWidget(_wrap(host, theme: appThemeLight));
      await tester.pumpAndSettle();
      expectOriginalSnapshot();

      displayed.value = null;
      await tester.pumpAndSettle();
      expect(find.byType(LocalModelDetailsButton), findsNothing);
      await tester.pumpWidget(_wrap(host));
      await tester.pumpAndSettle();
      expectOriginalSnapshot();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Provider removed'), findsOneWidget);
      expect(find.byType(LocalModelDetailsDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
