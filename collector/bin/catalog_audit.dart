import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/catalog_audit.dart';
import 'package:quotabot_collector/cli_stdio.dart';
import 'package:quotabot_collector/util.dart';

Future<void> main(List<String> args) {
  return runCliBody(() async {
    final wantsJson = args.contains('--json');
    final summaryOnly = args.contains('--summary');
    final failOnDrift = args.contains('--fail-on-drift');
    final failOnError = args.contains('--fail-on-error');
    final providers = _providerFilter(args);
    final sources = defaultModelListSources()
        .where((s) => providers.isEmpty || providers.contains(s.provider))
        .toList();
    final report = await auditModelCatalog(
      now: nowEpoch(),
      sources: sources,
      environment: Platform.environment,
    );

    if (wantsJson) {
      print(const JsonEncoder.withIndent('  ').convert(report.toJson()));
    } else {
      print(formatCatalogAuditReport(report, includeModelIds: !summaryOnly));
    }

    exitCode = catalogAuditExitCode(
      report,
      failOnDrift: failOnDrift,
      failOnError: failOnError,
    );
  });
}

Set<String> _providerFilter(List<String> args) {
  final providers = <String>{};
  for (final arg in args) {
    if (arg.startsWith('--provider=')) {
      providers.add(arg.substring('--provider='.length).trim().toLowerCase());
    }
  }
  return providers;
}
