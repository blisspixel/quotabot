import 'mcp_fixture_server.dart' as fixture;
import 'stdin_state_extension.dart';

Future<void> main(List<String> args) async {
  registerStdinStateExtension();
  await fixture.main(args);
}
