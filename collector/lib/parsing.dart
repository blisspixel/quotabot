/// Pure parsing logic shared by the adapters, separated from all network and
/// disk I/O so it can be unit tested directly against fixture inputs.
///
/// Provider parsers are parts of this library. They share private wire helpers,
/// and every public name stays here so adapters and tests keep importing
/// `parsing.dart`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';
import 'util.dart';

part 'src/parsing/wire.dart';
part 'src/parsing/codex.dart';
part 'src/parsing/claude.dart';
part 'src/parsing/claude_status.dart';
part 'src/parsing/antigravity.dart';
part 'src/parsing/local_quota.dart';
part 'src/parsing/identity.dart';
part 'src/parsing/grok.dart';
