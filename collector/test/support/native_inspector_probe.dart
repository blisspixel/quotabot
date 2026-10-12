import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.single == 'hang') {
    await Future<void>.delayed(const Duration(seconds: 30));
  } else if (args.single == 'stderr-overflow') {
    stderr.write('x' * (70 * 1024));
  } else {
    stdout.writeln('QUOTABOT_NATIVE_STACK_BEGIN');
    stdout.writeln('00 ntdll!NtReadFile+0x14');
    stdout.writeln('01 private_module!PRIVATE_FUNCTION+0x44');
    stdout.writeln('QUOTABOT_NATIVE_STACK_END');
    stderr.writeln('PRIVATE_ERROR');
  }
}
