import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/leases.dart';

const _workerReady = 'quotabot-lease-worker-ready';
const _workerResult = 'quotabot-lease-worker-result:';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('expected lease directory and id');
    exitCode = 64;
    return;
  }

  stdout.writeln(_workerReady);
  await stdout.flush();
  final start =
      await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
  if (start != 'start') {
    stderr.writeln('invalid start signal');
    exitCode = 64;
    return;
  }

  try {
    final store = FileRouteLeaseStore(
      dirFactory: () => Directory(args[0]),
      idFactory: () => args[1],
    );
    final reservation = store.selectAndReserve(
      select: (active) {
        // Widen the old read-then-write race. With selection inside the file
        // lock, only the first process can observe an empty ledger.
        if (active.isEmpty) sleep(const Duration(milliseconds: 150));
        final provider = active.any((lease) => lease.provider == 'claude')
            ? 'codex'
            : 'claude';
        return RouteLeaseSelection.selected(
          RouteLeaseTarget(provider: provider, account: 'a'),
        );
      },
      now: 100,
      leaseSeconds: 60,
      weightPercent: 30,
    );
    stdout.writeln(
      '$_workerResult${jsonEncode({
            'reserved': reservation.reserved,
            'provider': reservation.lease?.provider,
            'reason': reservation.reason,
          })}',
    );
    await stdout.flush();
  } catch (error) {
    stdout.writeln(
      '$_workerResult${jsonEncode({
            'reserved': false,
            'error': error.toString(),
          })}',
    );
    await stdout.flush();
  }
}
