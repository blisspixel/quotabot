import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/catalog_audit.dart';
import 'package:quotabot_collector/util.dart';

void main(List<String> args) async {
  final wantsJson = args.contains('--json');
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
    _printReport(report);
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

void _printReport(CatalogAuditReport report) {
  print('quotabot model catalog audit');
  print('catalog updated ${report.catalogUpdated}\n');
  for (final provider in report.providers) {
    final status = provider.skipped
        ? 'skipped'
        : provider.ok
            ? (provider.hasDrift ? 'drift' : 'clean')
            : 'error';
    print('${provider.provider}: $status');
    if (provider.error != null) {
      print('  ${provider.error}');
    }
    if (provider.ok) {
      print(
        '  catalog ${provider.catalogModelIds.length}, '
        'endpoint ${provider.endpointModelIds.length}',
      );
      if (provider.missingFromCatalog.isNotEmpty) {
        print(
            '  missing from catalog: ${provider.missingFromCatalog.join(', ')}');
      }
      if (provider.catalogOnly.isNotEmpty) {
        print('  catalog only: ${provider.catalogOnly.join(', ')}');
      }
    }
  }
  print(
      '\nUse --json for a machine-readable quotabot.catalog_audit.v1 report.');
  print('Use --fail-on-drift or --fail-on-error when wiring this into CI.');
}
