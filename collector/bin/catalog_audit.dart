import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/catalog_audit.dart';
import 'package:quotabot_collector/util.dart';

void main(List<String> args) async {
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

  if ((failOnDrift && report.hasDrift) || (failOnError && report.hasErrors)) {
    exitCode = 1;
  }
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
