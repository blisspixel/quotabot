import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets ||
        input.config.code.targetOS != OS.windows) {
      return;
    }
    await CBuilder.library(
      name: 'quotabot_pipe_input',
      assetName: 'src/io/windows_pipe_input.dart',
      sources: ['src/windows_pipe_input.c'],
      flags: ['/W4', '/WX', '/MT'],
    ).run(input: input, output: output);
  });
}
