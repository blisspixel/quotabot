const stdinStateExtension = 'ext.quotabot.stdinState';

Map<String, bool>? projectStdinState(Object? value) {
  if (value is! Map || value['available'] is! bool) return null;
  if (value['available'] == false) {
    return value.length == 1 ? {'available': false} : null;
  }
  const base = {'available', 'closed', 'controllerClosed', 'raw_present'};
  const native = {
    'isClosing',
    'isClosed',
    'isClosedRead',
    'isClosedWrite',
    'event_port_present',
  };
  if (value['raw_present'] is! bool) return null;
  final keys = {...base, if (value['raw_present'] == true) ...native};
  if (value.length != keys.length ||
      value.keys.any((key) => !keys.contains(key)) ||
      value.values.any((field) => field is! bool)) {
    return null;
  }
  return {for (final key in keys) key: value[key] as bool};
}
