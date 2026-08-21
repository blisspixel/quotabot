/// Public JSON schema contracts for routable quotabot output.
///
/// The `quotabot.v1` contract is intentionally additive: existing fields keep
/// their meaning and type, while unknown future fields are allowed so older
/// routers keep working. The validator below is not a general JSON Schema
/// engine; it enforces the stable invariants that matter to local routers and
/// contract tests.
library;

import 'models.dart';

const quotabotV1SchemaId = 'quotabot.v1';
const quotabotV1SchemaUri =
    'https://quotabot.local/schemas/quotabot.v1.schema.json';

/// Single-provider availability answer (`quotabot check --json` and the MCP
/// `check_provider_availability` tool). Not a `quotabot.v1` snapshot: it has
/// no `providers` array, so it carries its own id.
const quotabotCheckV1SchemaId = 'quotabot.check.v1';

/// The `provider_with_most_headroom` pick shape.
const quotabotHeadroomV1SchemaId = 'quotabot.headroom.v1';
const quotabotAnalyticsIncidentInventoryV1SchemaId =
    'quotabot.analytics-incident-inventory.v1';
const quotabotAnalyticsIncidentV1SchemaId = 'quotabot.analytics-incident.v1';

const _rootRequired = ['schema', 'generated_at', 'providers'];
const _providerRequired = [
  'provider',
  'display_name',
  'account',
  'kind',
  'ok',
  'as_of',
  'stale',
  'windows',
];
const _windowRequired = ['label'];
const quotabotV1JsonSchema = <String, Object?>{
  r'$schema': 'https://json-schema.org/draft/2020-12/schema',
  r'$id': quotabotV1SchemaUri,
  'title': 'quotabot.v1 quota snapshot',
  'type': 'object',
  'additionalProperties': true,
  'required': _rootRequired,
  'properties': {
    'schema': {'const': quotabotV1SchemaId},
    'snapshot_source': {
      'type': 'string',
      'enum': ['live', 'simulation'],
    },
    'profile': {'type': 'string', 'minLength': 1},
    'account_filter': {'type': 'string', 'minLength': 1},
    'error': {'type': 'string'},
    'generated_at': {'type': 'integer', 'minimum': 0},
    'providers': {
      'type': 'array',
      'items': {r'$ref': r'#/$defs/providerQuota'},
    },
    'analytics_incident_inventory': {
      r'$ref': r'#/$defs/analyticsIncidentInventory',
    },
  },
  r'$defs': {
    'analyticsIncidentInventory': {
      'type': 'object',
      'additionalProperties': true,
      'required': [
        'schema',
        'state',
        'scope',
        'scanned_markers',
        'unverifiable_markers',
        'invalid_markers',
        'truncated',
        'incidents',
      ],
      'properties': {
        'schema': {'const': quotabotAnalyticsIncidentInventoryV1SchemaId},
        'state': {
          'type': 'string',
          'enum': ['complete', 'partial', 'suppressed'],
        },
        'scope': {
          'type': 'string',
          'enum': ['all_local', 'visible_snapshot', 'simulation'],
        },
        'scanned_markers': {'type': 'integer', 'minimum': 0, 'maximum': 256},
        'unverifiable_markers': {
          'type': 'integer',
          'minimum': 0,
          'maximum': 256,
        },
        'invalid_markers': {
          'type': 'integer',
          'minimum': 0,
          'maximum': 256,
        },
        'truncated': {'type': 'boolean'},
        'incidents': {
          'type': 'array',
          'maxItems': 256,
          'items': {r'$ref': r'#/$defs/analyticsIncident'},
        },
      },
    },
    'analyticsIncident': {
      'type': 'object',
      'additionalProperties': true,
      'required': [
        'schema',
        'state',
        'provider',
        'tiers',
        'recorded_at',
        'exact_account_in_snapshot',
      ],
      'properties': {
        'schema': {'const': quotabotAnalyticsIncidentV1SchemaId},
        'state': {'const': 'diverged'},
        'provider': {'type': 'string', 'minLength': 1},
        'tiers': {
          'type': 'array',
          'minItems': 1,
          'maxItems': 2,
          'uniqueItems': true,
          'items': {
            'type': 'string',
            'enum': ['history', 'buckets'],
          },
        },
        'recorded_at': {'type': 'integer', 'minimum': 1},
        'exact_account_in_snapshot': {'type': 'boolean'},
        'provider_row_index': {'type': 'integer', 'minimum': 0},
        'incident_id': {
          'type': 'string',
          'pattern': r'^[a-f0-9]{32}$',
        },
      },
    },
    'providerQuota': {
      'type': 'object',
      'additionalProperties': true,
      'required': _providerRequired,
      'properties': {
        'provider': {'type': 'string', 'minLength': 1},
        'display_name': {'type': 'string', 'minLength': 1},
        'account': {'type': 'string', 'minLength': 1},
        'plan': {'type': 'string'},
        'plan_evidence_source': {
          'type': 'string',
          'enum': ProviderPlanEvidenceSource.wireValues,
        },
        'plan_evidence_as_of': {'type': 'integer', 'minimum': 1},
        'source': {'type': 'string'},
        'source_class': {
          'type': 'string',
          'enum': ProviderSourceClass.wireValues,
        },
        'supplemental_manual_quota': {
          r'$ref': r'#/$defs/supplementalManualQuota',
        },
        'kind': {
          'type': 'string',
          'enum': ['subscription', 'local'],
        },
        'status': {'type': 'string'},
        'active': {'type': 'boolean'},
        'details': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'pipe_health': {
          'type': 'string',
          'enum': providerPipeHealthValues,
        },
        'http_status': {
          'type': 'integer',
          'minimum': 100,
          'maximum': 599,
        },
        'retry_after_seconds': {
          'type': 'integer',
          'minimum': 0,
        },
        'ok': {'type': 'boolean'},
        'error': {'type': 'string'},
        'as_of': {'type': 'integer', 'minimum': 0},
        'stale': {'type': 'boolean'},
        'suspect': {'type': 'string'},
        'drift_reason': {
          'type': 'string',
          'minLength': 1,
          'pattern': r'\S',
        },
        'drift_observed_at': {'type': 'integer', 'minimum': 0},
        'per_machine': {'type': 'boolean'},
        'reset_credits_available': {'type': 'integer', 'minimum': 0},
        'windows': {
          'type': 'array',
          'items': {r'$ref': r'#/$defs/quotaWindow'},
        },
        'models': {
          'type': 'array',
          'items': {r'$ref': r'#/$defs/modelInfo'},
        },
        'local_hardware': {r'$ref': r'#/$defs/localHardware'},
        'model_quotas': {
          'type': 'array',
          'items': {r'$ref': r'#/$defs/modelQuota'},
        },
      },
    },
    'supplementalManualQuota': {
      'type': 'object',
      'additionalProperties': true,
      'required': [
        'source',
        'source_class',
        'display_name',
        'as_of',
        'windows',
      ],
      'properties': {
        'source': {'const': providerQuotaManualSource},
        'source_class': {'const': 'manual'},
        'display_name': {'type': 'string', 'minLength': 1},
        'plan': {'type': 'string'},
        'as_of': {'type': 'integer', 'minimum': 0},
        'windows': {
          'type': 'array',
          'minItems': 1,
          'items': {r'$ref': r'#/$defs/quotaWindow'},
        },
      },
    },
    'localHardware': {
      'type': 'object',
      'additionalProperties': true,
      'required': ['as_of'],
      'properties': {
        'as_of': {'type': 'integer', 'minimum': 0},
        'system_memory_total_bytes': {'type': 'integer', 'minimum': 1},
        'system_memory_available_bytes': {'type': 'integer', 'minimum': 0},
        'gpu_memory_total_bytes': {'type': 'integer', 'minimum': 1},
        'gpu_memory_available_bytes': {'type': 'integer', 'minimum': 0},
        'gpu_count': {'type': 'integer', 'minimum': 0, 'maximum': 64},
        'gpu_name': {'type': 'string', 'minLength': 1},
      },
    },
    'quotaWindow': {
      'type': 'object',
      'additionalProperties': true,
      'required': _windowRequired,
      'properties': {
        'label': {'type': 'string', 'minLength': 1},
        'used_percent': {'type': 'number', 'minimum': 0, 'maximum': 100},
        'used': {'type': 'number', 'minimum': 0},
        'limit': {'type': 'number', 'exclusiveMinimum': 0},
        'resets_at': {'type': 'integer', 'minimum': 0},
      },
    },
    'modelInfo': {
      'type': 'object',
      'additionalProperties': true,
      'required': ['id'],
      'properties': {
        'id': {'type': 'string', 'minLength': 1},
        'display_name': {'type': 'string'},
        'context_tokens': {'type': 'integer', 'minimum': 1},
        'max_output_tokens': {'type': 'integer', 'minimum': 1},
        'tools': {'type': 'boolean'},
        'vision': {'type': 'boolean'},
        'embedding': {'type': 'boolean'},
        'reasoning': {'type': 'string'},
        'tier': {'type': 'string'},
        'quota_included_until': {'type': 'integer', 'minimum': 0},
        'local': {'type': 'boolean'},
        'cloud_offloaded': {'type': 'boolean'},
        'loaded': {'type': 'boolean'},
        'size_bytes': {'type': 'integer', 'minimum': 0},
        'vram_bytes': {'type': 'integer', 'minimum': 0},
        'quant': {'type': 'string'},
      },
    },
    'modelQuota': {
      'type': 'object',
      'additionalProperties': true,
      'required': ['model'],
      'properties': {
        'model': {'type': 'string', 'minLength': 1},
        'used_percent': {'type': 'number', 'minimum': 0, 'maximum': 100},
        'resets_at': {'type': 'integer', 'minimum': 0},
        'window_label': {
          'type': 'string',
          'minLength': 1,
          'maxLength': kMaxModelQuotaWindowLabelCharacters,
          'pattern': r'^\S(?:[\s\S]*\S)?$',
        },
        'category': {'type': 'string'},
        'note': {'type': 'string'},
      },
    },
  },
};

List<String> validateQuotabotV1Snapshot(Map<String, dynamic> snapshot) {
  final errors = <String>[];
  _checkRequired(snapshot, _rootRequired, r'$', errors);
  if (snapshot['schema'] != quotabotV1SchemaId) {
    errors.add(r'$.schema must be "quotabot.v1"');
  }
  _checkOptionalString(snapshot, 'profile', r'$', errors);
  _checkOptionalString(snapshot, 'account_filter', r'$', errors);
  _checkOptionalString(snapshot, 'error', r'$', errors);
  _checkStringEnum(
    snapshot,
    'snapshot_source',
    r'$',
    {'live', 'simulation'},
    errors,
    required: false,
  );
  _checkNonNegativeInt(snapshot, 'generated_at', r'$', errors);

  final providers = snapshot['providers'];
  if (providers is! List) {
    errors.add(r'$.providers must be an array');
  } else {
    for (var i = 0; i < providers.length; i++) {
      final provider = providers[i];
      final path = '\$.providers[$i]';
      if (provider is Map<String, dynamic>) {
        _validateProvider(provider, path, errors);
      } else if (provider is Map) {
        _validateProvider(provider.cast<String, dynamic>(), path, errors);
      } else {
        errors.add('$path must be an object');
      }
    }
  }
  final incidentInventory = snapshot['analytics_incident_inventory'];
  if (incidentInventory is Map<String, dynamic>) {
    _validateAnalyticsIncidentInventory(
      incidentInventory,
      providers is List ? providers : const [],
      snapshot['snapshot_source'],
      errors,
    );
  } else if (incidentInventory is Map) {
    _validateAnalyticsIncidentInventory(
      incidentInventory.cast<String, dynamic>(),
      providers is List ? providers : const [],
      snapshot['snapshot_source'],
      errors,
    );
  } else if (incidentInventory != null) {
    errors.add(r'$.analytics_incident_inventory must be an object');
  }
  return errors;
}

void _validateAnalyticsIncidentInventory(
  Map<String, dynamic> inventory,
  List<dynamic> providers,
  Object? snapshotSource,
  List<String> errors,
) {
  const path = r'$.analytics_incident_inventory';
  const required = [
    'schema',
    'state',
    'scope',
    'scanned_markers',
    'unverifiable_markers',
    'invalid_markers',
    'truncated',
    'incidents',
  ];
  _checkRequired(inventory, required, path, errors);
  if (inventory['schema'] != quotabotAnalyticsIncidentInventoryV1SchemaId) {
    errors.add(
      '$path.schema must be "$quotabotAnalyticsIncidentInventoryV1SchemaId"',
    );
  }
  _checkStringEnum(
    inventory,
    'state',
    path,
    {'complete', 'partial', 'suppressed'},
    errors,
  );
  _checkStringEnum(
    inventory,
    'scope',
    path,
    {'all_local', 'visible_snapshot', 'simulation'},
    errors,
  );
  for (final field in const [
    'scanned_markers',
    'unverifiable_markers',
    'invalid_markers',
  ]) {
    _checkIntRange(
      inventory,
      field,
      path,
      errors,
      min: 0,
      max: 256,
    );
  }
  _checkBool(inventory, 'truncated', path, errors);

  final state = inventory['state'];
  final scope = inventory['scope'];
  final scanned = inventory['scanned_markers'];
  final unverifiable = inventory['unverifiable_markers'];
  final invalid = inventory['invalid_markers'];
  final truncated = inventory['truncated'];
  if (state == 'complete' &&
      (unverifiable != 0 || invalid != 0 || truncated != false)) {
    errors.add('$path.state complete requires no incomplete scan evidence');
  }
  if (state == 'suppressed' &&
      (scope != 'simulation' ||
          scanned != 0 ||
          unverifiable != 0 ||
          invalid != 0 ||
          truncated != false)) {
    errors.add('$path.state suppressed requires an empty simulation scan');
  }
  if (scope == 'simulation' && state != 'suppressed') {
    errors.add('$path.scope simulation requires state suppressed');
  }
  if (snapshotSource == 'simulation' && state != 'suppressed') {
    errors.add('$path must be suppressed for a simulation snapshot');
  }
  if (snapshotSource == 'live' && state == 'suppressed') {
    errors.add('$path must not be suppressed for a live snapshot');
  }

  final incidents = inventory['incidents'];
  if (incidents is! List) {
    errors.add('$path.incidents must be an array');
    return;
  }
  if (incidents.length > 256) {
    errors.add('$path.incidents must contain at most 256 entries');
  }
  for (var index = 0; index < incidents.length; index++) {
    final incident = incidents[index];
    final incidentPath = '$path.incidents[$index]';
    if (incident is Map<String, dynamic>) {
      _validateAnalyticsIncident(
        incident,
        incidentPath,
        providers,
        errors,
      );
    } else if (incident is Map) {
      _validateAnalyticsIncident(
        incident.cast<String, dynamic>(),
        incidentPath,
        providers,
        errors,
      );
    } else {
      errors.add('$incidentPath must be an object');
    }
  }
}

void _validateAnalyticsIncident(
  Map<String, dynamic> incident,
  String path,
  List<dynamic> providers,
  List<String> errors,
) {
  const required = [
    'schema',
    'state',
    'provider',
    'tiers',
    'recorded_at',
    'exact_account_in_snapshot',
  ];
  _checkRequired(incident, required, path, errors);
  if (incident['schema'] != quotabotAnalyticsIncidentV1SchemaId) {
    errors.add('$path.schema must be "$quotabotAnalyticsIncidentV1SchemaId"');
  }
  if (incident['state'] != 'diverged') {
    errors.add('$path.state must be "diverged"');
  }
  _checkNonEmptyString(incident, 'provider', path, errors);
  _checkPositiveInt(incident, 'recorded_at', path, errors);
  _checkBool(incident, 'exact_account_in_snapshot', path, errors);
  for (final prohibited in const [
    'account',
    'account_digest',
    'path',
    'recovery_target',
  ]) {
    if (incident.containsKey(prohibited)) {
      errors.add('$path.$prohibited is prohibited');
    }
  }
  final rowIndex = incident['provider_row_index'];
  if (rowIndex != null &&
      (rowIndex is! int || rowIndex < 0 || rowIndex >= providers.length)) {
    errors.add('$path.provider_row_index must reference a provider row');
  }
  final incidentId = incident['incident_id'];
  if (incidentId != null &&
      (incidentId is! String ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(incidentId))) {
    errors.add('$path.incident_id must be 32 lowercase hexadecimal characters');
  }
  final tiers = incident['tiers'];
  if (tiers is! List ||
      tiers.isEmpty ||
      tiers.length > 2 ||
      tiers.any((tier) => tier != 'history' && tier != 'buckets') ||
      tiers.toSet().length != tiers.length) {
    errors.add('$path.tiers must contain one or both unique analytics tiers');
  }
  final exact = incident['exact_account_in_snapshot'];
  if (exact == true && rowIndex == null) {
    errors.add('$path.provider_row_index is required for an exact account');
  }
  if (exact == false && rowIndex != null) {
    errors.add('$path.provider_row_index requires an exact account');
  }
  if (rowIndex is int && rowIndex >= 0 && rowIndex < providers.length) {
    final providerRow = providers[rowIndex];
    final providerId = providerRow is Map ? providerRow['provider'] : null;
    if (providerId != incident['provider']) {
      errors.add('$path.provider_row_index must reference the same provider');
    }
  }
}

void _validateProvider(
  Map<String, dynamic> provider,
  String path,
  List<String> errors,
) {
  _checkRequired(provider, _providerRequired, path, errors);
  _checkNonEmptyString(provider, 'provider', path, errors);
  _checkNonEmptyString(provider, 'display_name', path, errors);
  _checkNonEmptyString(provider, 'account', path, errors);
  _checkOptionalString(provider, 'plan', path, errors);
  _checkStringEnum(
    provider,
    'plan_evidence_source',
    path,
    ProviderPlanEvidenceSource.wireValues.toSet(),
    errors,
    required: false,
  );
  _checkIntRange(
    provider,
    'plan_evidence_as_of',
    path,
    errors,
    min: 1,
    max: 0x7FFFFFFFFFFFFFFF,
    required: false,
  );
  final hasPlanEvidenceSource = provider['plan_evidence_source'] != null;
  final hasPlanEvidenceAsOf = provider['plan_evidence_as_of'] != null;
  if (hasPlanEvidenceSource != hasPlanEvidenceAsOf) {
    errors.add(
      '$path.plan_evidence_source and plan_evidence_as_of must appear together',
    );
  }
  if (hasPlanEvidenceSource && provider['plan'] is! String) {
    errors.add('$path.plan evidence requires a plan label');
  }
  _checkOptionalString(provider, 'source', path, errors);
  _checkStringEnum(
    provider,
    'source_class',
    path,
    ProviderSourceClass.wireValues.toSet(),
    errors,
    required: false,
  );
  _checkStringEnum(provider, 'kind', path, {'subscription', 'local'}, errors);
  final supplementalManualQuota = provider['supplemental_manual_quota'];
  if (provider.containsKey('supplemental_manual_quota')) {
    if (provider['source'] == providerQuotaManualSource ||
        provider['source_class'] == ProviderSourceClass.manual.wireName ||
        provider['kind'] == providerQuotaLocalKind) {
      errors.add(
        '$path.supplemental_manual_quota requires a built-in subscription row',
      );
    }
    if (supplementalManualQuota is Map<String, dynamic>) {
      _validateSupplementalManualQuota(
        supplementalManualQuota,
        '$path.supplemental_manual_quota',
        errors,
      );
    } else if (supplementalManualQuota is Map) {
      _validateSupplementalManualQuota(
        supplementalManualQuota.cast<String, dynamic>(),
        '$path.supplemental_manual_quota',
        errors,
      );
    } else {
      errors.add('$path.supplemental_manual_quota must be an object');
    }
  }
  _checkOptionalString(provider, 'status', path, errors);
  _checkBool(provider, 'active', path, errors, required: false);
  _checkStringList(provider, 'details', path, errors);
  _checkStringEnum(
    provider,
    'pipe_health',
    path,
    providerPipeHealthValues.toSet(),
    errors,
    required: false,
  );
  _checkIntRange(provider, 'http_status', path, errors,
      min: 100, max: 599, required: false);
  _checkNonNegativeInt(provider, 'retry_after_seconds', path, errors,
      required: false);
  _checkBool(provider, 'ok', path, errors);
  _checkOptionalString(provider, 'error', path, errors);
  _checkNonNegativeInt(provider, 'as_of', path, errors);
  _checkBool(provider, 'stale', path, errors);
  _checkOptionalString(provider, 'suspect', path, errors);
  _checkOptionalString(provider, 'drift_reason', path, errors);
  final driftReason = provider['drift_reason'];
  if (driftReason is String && driftReason.trim().isEmpty) {
    errors.add('$path.drift_reason must not be blank');
  }
  _checkNonNegativeInt(provider, 'drift_observed_at', path, errors,
      required: false);
  _checkBool(provider, 'per_machine', path, errors, required: false);
  _checkNonNegativeInt(
    provider,
    'reset_credits_available',
    path,
    errors,
    required: false,
  );

  final windows = provider['windows'];
  if (windows is! List) {
    errors.add('$path.windows must be an array');
  } else {
    for (var i = 0; i < windows.length; i++) {
      final window = windows[i];
      final windowPath = '$path.windows[$i]';
      if (window is Map<String, dynamic>) {
        _validateWindow(window, windowPath, errors);
      } else if (window is Map) {
        _validateWindow(window.cast<String, dynamic>(), windowPath, errors);
      } else {
        errors.add('$windowPath must be an object');
      }
    }
  }

  final models = provider['models'];
  if (models != null) {
    if (models is! List) {
      errors.add('$path.models must be an array');
    } else {
      for (var i = 0; i < models.length; i++) {
        final model = models[i];
        final modelPath = '$path.models[$i]';
        if (model is Map<String, dynamic>) {
          _validateModel(model, modelPath, errors);
        } else if (model is Map) {
          _validateModel(model.cast<String, dynamic>(), modelPath, errors);
        } else {
          errors.add('$modelPath must be an object');
        }
      }
    }
  }

  final localHardware = provider['local_hardware'];
  if (localHardware != null) {
    if (provider['kind'] != providerQuotaLocalKind) {
      errors.add('$path.local_hardware requires kind=local');
    }
    if (localHardware is Map<String, dynamic>) {
      _validateLocalHardware(localHardware, '$path.local_hardware', errors);
    } else if (localHardware is Map) {
      _validateLocalHardware(
        localHardware.cast<String, dynamic>(),
        '$path.local_hardware',
        errors,
      );
    } else {
      errors.add('$path.local_hardware must be an object');
    }
  }

  final modelQuotas = provider['model_quotas'];
  if (modelQuotas != null) {
    if (modelQuotas is! List) {
      errors.add('$path.model_quotas must be an array');
    } else {
      for (var i = 0; i < modelQuotas.length; i++) {
        final modelQuota = modelQuotas[i];
        final modelQuotaPath = '$path.model_quotas[$i]';
        if (modelQuota is Map<String, dynamic>) {
          _validateModelQuota(modelQuota, modelQuotaPath, errors);
        } else if (modelQuota is Map) {
          _validateModelQuota(
            modelQuota.cast<String, dynamic>(),
            modelQuotaPath,
            errors,
          );
        } else {
          errors.add('$modelQuotaPath must be an object');
        }
      }
    }
  }
}

void _validateSupplementalManualQuota(
  Map<String, dynamic> supplemental,
  String path,
  List<String> errors,
) {
  const required = [
    'source',
    'source_class',
    'display_name',
    'as_of',
    'windows',
  ];
  _checkRequired(supplemental, required, path, errors);
  if (supplemental['source'] != providerQuotaManualSource) {
    errors.add('$path.source must be "$providerQuotaManualSource"');
  }
  if (supplemental['source_class'] != 'manual') {
    errors.add('$path.source_class must be "manual"');
  }
  _checkNonEmptyString(supplemental, 'display_name', path, errors);
  _checkOptionalString(supplemental, 'plan', path, errors);
  _checkNonNegativeInt(supplemental, 'as_of', path, errors);
  final windows = supplemental['windows'];
  if (windows is! List) {
    errors.add('$path.windows must be an array');
    return;
  }
  if (windows.isEmpty) errors.add('$path.windows must not be empty');
  for (var i = 0; i < windows.length; i++) {
    final window = windows[i];
    final windowPath = '$path.windows[$i]';
    if (window is Map<String, dynamic>) {
      _validateWindow(window, windowPath, errors);
    } else if (window is Map) {
      _validateWindow(window.cast<String, dynamic>(), windowPath, errors);
    } else {
      errors.add('$windowPath must be an object');
    }
  }
}

void _validateLocalHardware(
  Map<String, dynamic> hardware,
  String path,
  List<String> errors,
) {
  _checkRequired(hardware, const ['as_of'], path, errors);
  _checkNonNegativeInt(hardware, 'as_of', path, errors);
  _checkPositiveInt(
    hardware,
    'system_memory_total_bytes',
    path,
    errors,
    required: false,
  );
  _checkNonNegativeInt(
    hardware,
    'system_memory_available_bytes',
    path,
    errors,
    required: false,
  );
  _checkPositiveInt(
    hardware,
    'gpu_memory_total_bytes',
    path,
    errors,
    required: false,
  );
  _checkNonNegativeInt(
    hardware,
    'gpu_memory_available_bytes',
    path,
    errors,
    required: false,
  );
  _checkIntRange(
    hardware,
    'gpu_count',
    path,
    errors,
    min: 0,
    max: 64,
    required: false,
  );
  final gpuName = hardware['gpu_name'];
  if (gpuName != null && (gpuName is! String || gpuName.trim().isEmpty)) {
    errors.add('$path.gpu_name must be a non-empty string');
  }

  final systemTotal = hardware['system_memory_total_bytes'];
  final systemAvailable = hardware['system_memory_available_bytes'];
  if (systemTotal is int &&
      systemAvailable is int &&
      systemAvailable > systemTotal) {
    errors.add(
      '$path.system_memory_available_bytes must not exceed '
      'system_memory_total_bytes',
    );
  }
  final gpuTotal = hardware['gpu_memory_total_bytes'];
  final gpuAvailable = hardware['gpu_memory_available_bytes'];
  if (gpuTotal is int && gpuAvailable is int && gpuAvailable > gpuTotal) {
    errors.add(
      '$path.gpu_memory_available_bytes must not exceed '
      'gpu_memory_total_bytes',
    );
  }
}

void _validateWindow(
  Map<String, dynamic> window,
  String path,
  List<String> errors,
) {
  _checkRequired(window, _windowRequired, path, errors);
  _checkNonEmptyString(window, 'label', path, errors);
  final usedPercent = window['used_percent'];
  if (usedPercent != null &&
      !_finiteNumberInRange(usedPercent, min: 0, max: 100)) {
    errors.add('$path.used_percent must be a finite number from 0 to 100');
  }
  final used = window['used'];
  if (used != null && !_finiteNumberInRange(used, min: 0)) {
    errors.add('$path.used must be a finite non-negative number');
  }
  final limit = window['limit'];
  if (limit != null && !_finiteNumberInRange(limit, minExclusive: 0)) {
    errors.add('$path.limit must be a finite number greater than 0');
  }
  _checkNonNegativeInt(window, 'resets_at', path, errors, required: false);
}

void _validateModel(
  Map<String, dynamic> model,
  String path,
  List<String> errors,
) {
  _checkRequired(model, const ['id'], path, errors);
  _checkNonEmptyString(model, 'id', path, errors);
  _checkPositiveInt(model, 'context_tokens', path, errors, required: false);
  _checkPositiveInt(model, 'max_output_tokens', path, errors, required: false);
  _checkBool(model, 'tools', path, errors, required: false);
  _checkBool(model, 'vision', path, errors, required: false);
  _checkBool(model, 'embedding', path, errors, required: false);
  _checkOptionalString(model, 'display_name', path, errors);
  _checkOptionalString(model, 'reasoning', path, errors);
  _checkOptionalString(model, 'tier', path, errors);
  _checkOptionalString(model, 'quant', path, errors);
  _checkNonNegativeInt(model, 'quota_included_until', path, errors,
      required: false);
  _checkBool(model, 'local', path, errors, required: false);
  _checkBool(model, 'cloud_offloaded', path, errors, required: false);
  _checkBool(model, 'loaded', path, errors, required: false);
  _checkNonNegativeInt(model, 'size_bytes', path, errors, required: false);
  _checkNonNegativeInt(model, 'vram_bytes', path, errors, required: false);
}

void _validateModelQuota(
  Map<String, dynamic> quota,
  String path,
  List<String> errors,
) {
  _checkRequired(quota, const ['model'], path, errors);
  _checkNonEmptyString(quota, 'model', path, errors);
  final usedPercent = quota['used_percent'];
  if (usedPercent != null &&
      !_finiteNumberInRange(usedPercent, min: 0, max: 100)) {
    errors.add('$path.used_percent must be a finite number from 0 to 100');
  }
  _checkNonNegativeInt(quota, 'resets_at', path, errors, required: false);
  _checkModelQuotaWindowLabel(quota, path, errors);
  _checkOptionalString(quota, 'category', path, errors);
  _checkOptionalString(quota, 'note', path, errors);
}

void _checkModelQuotaWindowLabel(
  Map<String, dynamic> quota,
  String path,
  List<String> errors,
) {
  if (!quota.containsKey('window_label') || quota['window_label'] == null) {
    return;
  }
  final value = quota['window_label'];
  if (value is! String) {
    errors.add('$path.window_label must be a string');
    return;
  }
  final stripped = stripTerminalControl(value);
  if (value.isEmpty ||
      value.length > kMaxModelQuotaWindowLabelCharacters ||
      value.trim() != value ||
      stripped != value) {
    errors.add(
      '$path.window_label must be a trimmed, non-empty, control-free string '
      'up to $kMaxModelQuotaWindowLabelCharacters characters',
    );
  }
}

void _checkRequired(
  Map<String, dynamic> value,
  Iterable<String> required,
  String path,
  List<String> errors,
) {
  for (final field in required) {
    if (!value.containsKey(field)) errors.add('$path.$field is required');
  }
}

void _checkNonEmptyString(
  Map<String, dynamic> value,
  String field,
  String path,
  List<String> errors,
) {
  final fieldValue = value[field];
  if (fieldValue is! String || fieldValue.trim().isEmpty) {
    errors.add('$path.$field must be a non-empty string');
  }
}

void _checkOptionalString(
  Map<String, dynamic> value,
  String field,
  String path,
  List<String> errors,
) {
  final fieldValue = value[field];
  if (fieldValue != null && fieldValue is! String) {
    errors.add('$path.$field must be a string');
  }
}

void _checkStringList(
  Map<String, dynamic> value,
  String field,
  String path,
  List<String> errors,
) {
  final fieldValue = value[field];
  if (fieldValue == null) return;
  if (fieldValue is! List) {
    errors.add('$path.$field must be an array');
    return;
  }
  for (var i = 0; i < fieldValue.length; i++) {
    if (fieldValue[i] is! String) {
      errors.add('$path.$field[$i] must be a string');
    }
  }
}

void _checkStringEnum(
  Map<String, dynamic> value,
  String field,
  String path,
  Set<String> allowed,
  List<String> errors, {
  bool required = true,
}) {
  final fieldValue = value[field];
  if (fieldValue == null && !required) return;
  if (fieldValue is! String || !allowed.contains(fieldValue)) {
    errors.add('$path.$field must be one of ${allowed.join(', ')}');
  }
}

void _checkIntRange(
  Map<String, dynamic> value,
  String field,
  String path,
  List<String> errors, {
  required int min,
  required int max,
  bool required = true,
}) {
  final fieldValue = value[field];
  if (fieldValue == null && !required) return;
  if (fieldValue is! int || fieldValue < min || fieldValue > max) {
    errors.add('$path.$field must be an integer from $min to $max');
  }
}

void _checkBool(
  Map<String, dynamic> value,
  String field,
  String path,
  List<String> errors, {
  bool required = true,
}) {
  final fieldValue = value[field];
  if (fieldValue == null && !required) return;
  if (fieldValue is! bool) errors.add('$path.$field must be a boolean');
}

void _checkNonNegativeInt(
  Map<String, dynamic> value,
  String field,
  String path,
  List<String> errors, {
  bool required = true,
}) {
  final fieldValue = value[field];
  if (fieldValue == null && !required) return;
  if (fieldValue is! int || fieldValue < 0) {
    errors.add('$path.$field must be a non-negative integer');
  }
}

void _checkPositiveInt(
  Map<String, dynamic> value,
  String field,
  String path,
  List<String> errors, {
  bool required = true,
}) {
  final fieldValue = value[field];
  if (fieldValue == null && !required) return;
  if (fieldValue is! int || fieldValue < 1) {
    errors.add('$path.$field must be a positive integer');
  }
}

bool _finiteNumberInRange(
  Object? value, {
  num? min,
  num? max,
  num? minExclusive,
}) {
  if (value is! num || !value.isFinite) return false;
  if (min != null && value < min) return false;
  if (max != null && value > max) return false;
  if (minExclusive != null && value <= minExclusive) return false;
  return true;
}
