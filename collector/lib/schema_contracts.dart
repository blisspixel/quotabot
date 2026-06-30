/// Public JSON schema contracts for routable quotabot output.
///
/// The `quotabot.v1` contract is intentionally additive: existing fields keep
/// their meaning and type, while unknown future fields are allowed so older
/// routers keep working. The validator below is not a general JSON Schema
/// engine; it enforces the stable invariants that matter to local routers and
/// contract tests.
library;

const quotabotV1SchemaId = 'quotabot.v1';
const quotabotV1SchemaUri =
    'https://quotabot.local/schemas/quotabot.v1.schema.json';

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
    'profile': {'type': 'string', 'minLength': 1},
    'account_filter': {'type': 'string', 'minLength': 1},
    'error': {'type': 'string'},
    'generated_at': {'type': 'integer', 'minimum': 0},
    'providers': {
      'type': 'array',
      'items': {r'$ref': r'#/$defs/providerQuota'},
    },
  },
  r'$defs': {
    'providerQuota': {
      'type': 'object',
      'additionalProperties': true,
      'required': _providerRequired,
      'properties': {
        'provider': {'type': 'string', 'minLength': 1},
        'display_name': {'type': 'string', 'minLength': 1},
        'account': {'type': 'string', 'minLength': 1},
        'plan': {'type': 'string'},
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
        'ok': {'type': 'boolean'},
        'error': {'type': 'string'},
        'as_of': {'type': 'integer', 'minimum': 0},
        'stale': {'type': 'boolean'},
        'windows': {
          'type': 'array',
          'items': {r'$ref': r'#/$defs/quotaWindow'},
        },
        'models': {
          'type': 'array',
          'items': {r'$ref': r'#/$defs/modelInfo'},
        },
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
        'reasoning': {'type': 'string'},
        'tier': {'type': 'string'},
        'local': {'type': 'boolean'},
        'loaded': {'type': 'boolean'},
        'size_bytes': {'type': 'integer', 'minimum': 0},
        'vram_bytes': {'type': 'integer', 'minimum': 0},
        'quant': {'type': 'string'},
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
  return errors;
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
  _checkStringEnum(provider, 'kind', path, {'subscription', 'local'}, errors);
  _checkOptionalString(provider, 'status', path, errors);
  _checkBool(provider, 'active', path, errors, required: false);
  _checkStringList(provider, 'details', path, errors);
  _checkBool(provider, 'ok', path, errors);
  _checkOptionalString(provider, 'error', path, errors);
  _checkNonNegativeInt(provider, 'as_of', path, errors);
  _checkBool(provider, 'stale', path, errors);

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
  _checkOptionalString(model, 'display_name', path, errors);
  _checkOptionalString(model, 'reasoning', path, errors);
  _checkOptionalString(model, 'tier', path, errors);
  _checkOptionalString(model, 'quant', path, errors);
  _checkBool(model, 'local', path, errors, required: false);
  _checkBool(model, 'loaded', path, errors, required: false);
  _checkNonNegativeInt(model, 'size_bytes', path, errors, required: false);
  _checkNonNegativeInt(model, 'vram_bytes', path, errors, required: false);
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
  List<String> errors,
) {
  final fieldValue = value[field];
  if (fieldValue is! String || !allowed.contains(fieldValue)) {
    errors.add('$path.$field must be one of ${allowed.join(', ')}');
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
