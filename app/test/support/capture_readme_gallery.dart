// Render-only driver for real application widgets with synthetic data, without native
// desktop integration, credentials, provider reads, or preference writes.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/local_model_details.dart';
import 'package:quotabot/main.dart';
import 'package:quotabot/prefs.dart';
import 'package:quotabot/termshot.dart';
import 'package:quotabot/theme_spec.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/ansi.dart';
import 'package:quotabot_collector/demo.dart' as demo;
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/profiles.dart';
import 'package:quotabot_collector/top.dart';

const _gib = 1024 * 1024 * 1024;
const _profiles = [QuotaProfile(name: defaultProfileName, theme: appThemeDark)];

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final path in paths) {
    loader.addFont(File(path).readAsBytes().then(ByteData.sublistView));
  }
  await loader.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final output = Platform.environment['QUOTABOT_GALLERY_OUTPUT'];
  final fontRoot = Platform.environment['QUOTABOT_GALLERY_FONTS'];
  final iconFont = Platform.environment['QUOTABOT_GALLERY_ICON_FONT'];
  if (output == null || fontRoot == null || iconFont == null) {
    throw StateError(
      'Run tools/capture_readme_gallery.py with explicit fonts.',
    );
  }
  setUpAll(() async {
    await _loadFont('Segoe UI', [
      '$fontRoot/segoeui.ttf',
      '$fontRoot/segoeuib.ttf',
    ]);
    await _loadFont('Consolas', [
      '$fontRoot/consola.ttf',
      '$fontRoot/consolab.ttf',
    ]);
    await _loadFont('MaterialIcons', [iconFont]);
  });

  testWidgets('render the static README gallery', (tester) async {
    appThemeSpec.value = appThemeDark;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final boundary = GlobalKey();
    Future<void> show(Widget home, Size size) async {
      await tester.pumpWidget(const SizedBox());
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: ColoredBox(
            color: const Color(0xFF0D1117),
            child: QuotaBotApp.test(prefs: const Prefs(), testHome: home),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    Future<void> capture(String name) async {
      await tester.pump();
      await tester.runAsync(() async {
        final paint =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final rendered = await paint.toImage(pixelRatio: 2);
        final bytes = await rendered.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) throw StateError('Screenshot encoding failed.');
        await File('$output/$name').writeAsBytes(bytes.buffer.asUint8List());
        rendered.dispose();
      });
    }

    const square = Size(480, 480);
    const visiblePlans = Prefs(
      setupDone: true,
      enableNotifications: false,
      hidden: {'cursor', 'ollama', 'lmstudio', 'lemonade'},
    );
    await show(
      const Dashboard.test(prefs: visiblePlans, testProfiles: _profiles),
      square,
    );
    await capture('quota.png');

    await show(
      const Dashboard.test(
        prefs: visiblePlans,
        initialAnalytics: true,
        testProfiles: _profiles,
      ),
      square,
    );
    await tester.tap(find.text('90d'));
    await tester.pumpAndSettle();
    await capture('analytics.png');

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final local = ProviderQuota(
      provider: 'ollama',
      displayName: 'Ollama',
      account: 'demo',
      kind: ProviderQuotaKind.local,
      asOf: now,
      models: const [
        ModelInfo(
          id: 'qwen3:8b',
          local: true,
          loaded: true,
          contextTokens: 32768,
          quant: 'Q4_K_M',
          tools: true,
          vision: false,
          reasoning: 'reasoning',
          sizeBytes: 5 * _gib,
          vramBytes: 5 * _gib,
        ),
        ModelInfo(
          id: 'vision-model:7b',
          local: true,
          contextTokens: 8192,
          quant: 'Q4_K_M',
          vision: true,
          sizeBytes: 4 * _gib,
        ),
      ],
    );
    await show(
      Scaffold(
        body: LocalModelDetailsDialog(quota: local, now: now),
      ),
      square,
    );
    await capture('local-models.png');

    final fleet = demo.demoProviders(now);
    final lines = renderTopFrame(
      providers: fleet,
      suggestion: suggestRoute(fleet, now),
      now: now,
      width: 64,
      color: true,
      clock: '11:43:07',
      depth: ColorDepth.truecolor,
    );
    await show(
      Scaffold(
        backgroundColor: const Color(0xFF0D1117),
        body: Center(
          child: FittedBox(
            fit: BoxFit.contain,
            child: TerminalShot(ansiLines: lines),
          ),
        ),
      ),
      square,
    );
    await capture('terminal.png');

    await show(
      const Dashboard.test(
        testProfiles: _profiles,
        prefs: Prefs(
          compact: true,
          setupDone: true,
          enableNotifications: false,
        ),
      ),
      const Size(800, 48),
    );
    await capture('mini.png');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
