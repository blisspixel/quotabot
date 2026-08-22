import 'dart:io';

import 'mcp_http.dart';

const mcpServerUsage = '''
Usage:
  dart run bin/mcp_server.dart
  dart run bin/mcp_server.dart --http [--host 127.0.0.1] [--port 8722] [--path /mcp] [--token-file PATH]

Options:
  --http              Run MCP Streamable HTTP instead of stdio.
  --host HOST         Loopback bind host: localhost, 127.0.0.1, or ::1.
  --port PORT         TCP port, 1..65535. Default: 8722.
  --path PATH         MCP endpoint path. Default: /mcp.
  --token TOKEN       Required HTTP bearer token. Prefer --token-file for real use.
  --token-env NAME    Read the required HTTP bearer token from an environment variable.
  --token-file PATH   Read the required HTTP bearer token from a local file.
  --help              Show this usage.
''';

class McpServerCliOptions {
  final bool http;
  final bool help;
  final String host;
  final int port;
  final String path;
  final String? token;
  final String? tokenEnv;
  final String? tokenFile;

  const McpServerCliOptions({
    required this.http,
    required this.help,
    required this.host,
    required this.port,
    required this.path,
    this.token,
    this.tokenEnv,
    this.tokenFile,
  });

  factory McpServerCliOptions.parse(List<String> args) {
    var http = false;
    var help = false;
    var host = defaultMcpHttpHost;
    var port = defaultMcpHttpPort;
    var path = defaultMcpHttpPath;
    String? token;
    String? tokenEnv;
    String? tokenFile;
    var tokenSourceCount = 0;
    var hostCount = 0;
    var portCount = 0;
    var pathCount = 0;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--help' || arg == '-h') {
        help = true;
      } else if (arg == '--http') {
        http = true;
      } else if (arg == '--host' || arg.startsWith('--host=')) {
        hostCount++;
        final next = _readOptionValue(args, i, '--host');
        host = next.value;
        i = next.index;
      } else if (arg == '--port' || arg.startsWith('--port=')) {
        portCount++;
        final next = _readOptionValue(args, i, '--port');
        port = _parsePort(next.value);
        i = next.index;
      } else if (arg == '--path' || arg.startsWith('--path=')) {
        pathCount++;
        final next = _readOptionValue(args, i, '--path');
        path = normalizeMcpHttpPath(next.value);
        i = next.index;
      } else if (arg == '--token' || arg.startsWith('--token=')) {
        final next = _readOptionValue(args, i, '--token');
        token = next.value;
        tokenSourceCount++;
        i = next.index;
      } else if (arg == '--token-env' || arg.startsWith('--token-env=')) {
        final next = _readOptionValue(args, i, '--token-env');
        tokenEnv = next.value;
        tokenSourceCount++;
        i = next.index;
      } else if (arg == '--token-file' || arg.startsWith('--token-file=')) {
        final next = _readOptionValue(args, i, '--token-file');
        tokenFile = next.value;
        tokenSourceCount++;
        i = next.index;
      } else {
        throw FormatException('unknown option: $arg');
      }
    }

    if (!http &&
        (host != defaultMcpHttpHost ||
            port != defaultMcpHttpPort ||
            path != defaultMcpHttpPath ||
            token != null ||
            tokenEnv != null ||
            tokenFile != null)) {
      throw const FormatException('HTTP options require --http');
    }
    if (http && !isLoopbackMcpHost(host)) {
      throw FormatException(
        'HTTP MCP host must be loopback: localhost, 127.0.0.1, or ::1',
      );
    }
    if (hostCount > 1 || portCount > 1 || pathCount > 1) {
      throw const FormatException(
        'HTTP MCP bind options may be specified only once',
      );
    }
    if (http && tokenSourceCount > 1) {
      throw const FormatException(
        'HTTP MCP accepts exactly one token source',
      );
    }
    if (http && !help && tokenSourceCount == 0) {
      throw const FormatException(
        'HTTP MCP requires --token-file, --token-env, or --token',
      );
    }

    return McpServerCliOptions(
      http: http,
      help: help,
      host: host,
      port: port,
      path: path,
      token: token,
      tokenEnv: tokenEnv,
      tokenFile: tokenFile,
    );
  }
}

({int index, String value}) _readOptionValue(
  List<String> args,
  int index,
  String name,
) {
  final arg = args[index];
  final prefix = '$name=';
  if (arg.startsWith(prefix)) {
    final value = arg.substring(prefix.length);
    if (value.isEmpty) throw FormatException('$name requires a value');
    return (index: index, value: value);
  }
  if (index + 1 >= args.length || args[index + 1].startsWith('-')) {
    throw FormatException('$name requires a value');
  }
  return (index: index + 1, value: args[index + 1]);
}

int _parsePort(String value) {
  final port = int.tryParse(value);
  if (port == null || port < 1 || port > 65535) {
    throw FormatException('invalid --port: $value');
  }
  return port;
}

Future<String?> loadMcpBearerToken(McpServerCliOptions options) async {
  if (options.token != null) return _nonEmptyToken(options.token!, '--token');
  if (options.tokenEnv != null) {
    final value = Platform.environment[options.tokenEnv!];
    if (value == null) {
      throw FormatException(
        'missing token environment variable: ${options.tokenEnv}',
      );
    }
    return _nonEmptyToken(value, '--token-env');
  }
  final tokenFile = options.tokenFile;
  if (tokenFile == null) return null;
  final file = File(tokenFile);
  final type = FileSystemEntity.typeSync(file.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    throw FormatException('token file does not exist: $tokenFile');
  }
  if (type != FileSystemEntityType.file) {
    throw FormatException('token file must be a regular file: $tokenFile');
  }
  if (!Platform.isWindows) {
    final mode = (await file.stat()).mode;
    if ((mode & 0x3f) != 0) {
      throw const FormatException(
        'token file must not grant group or other permissions',
      );
    }
  }
  try {
    return _nonEmptyToken(await file.readAsString(), '--token-file');
  } on FileSystemException {
    throw FormatException('token file is unreadable: $tokenFile');
  }
}

String _nonEmptyToken(String value, String source) {
  final token = value.trim();
  if (token.isEmpty) throw FormatException('$source token must not be empty');
  if (token.length < minMcpHttpBearerTokenCharacters) {
    throw FormatException(
      '$source token must be at least '
      '$minMcpHttpBearerTokenCharacters characters',
    );
  }
  return token;
}
