import 'package:quotabot_collector/collect_progress.dart';
import 'package:test/test.dart';

void main() {
  group('fleetSpinnerFrame', () {
    test('cycles through the frames and wraps', () {
      expect(fleetSpinnerFrame(0), kFleetSpinnerFrames.first);
      expect(
        fleetSpinnerFrame(kFleetSpinnerFrames.length),
        kFleetSpinnerFrames.first,
      );
      expect(fleetSpinnerFrame(3), kFleetSpinnerFrames[3]);
    });
  });

  group('fleetProviderDoneLine', () {
    test('marks a live provider with its count and elapsed time', () {
      expect(
        fleetProviderDoneLine(
          done: 6,
          total: 11,
          displayName: 'Grok',
          ok: true,
          elapsedSeconds: 14,
        ),
        '  [6/11] Grok - live (14s)',
      );
    });

    test('marks an empty read as no data', () {
      expect(
        fleetProviderDoneLine(
          done: 7,
          total: 11,
          displayName: 'LM Studio',
          ok: false,
          elapsedSeconds: 6,
        ),
        '  [7/11] LM Studio - no data (6s)',
      );
    });
  });

  group('fleetProgressLine', () {
    test('names the outstanding providers while a read is in flight', () {
      expect(
        fleetProgressLine(
          spinner: '⠋',
          done: 9,
          total: 11,
          elapsedSeconds: 27,
          pending: ['Grok', 'Antigravity'],
        ),
        '  ⠋ reading quota  9/11 - 27s - waiting: Grok, Antigravity',
      );
    });

    test('caps the named pending providers at three with a remainder', () {
      expect(
        fleetProgressLine(
          spinner: '⠹',
          done: 2,
          total: 11,
          elapsedSeconds: 3,
          pending: ['Claude', 'Codex', 'Grok', 'Antigravity', 'Kiro'],
        ),
        '  ⠹ reading quota  2/11 - 3s - waiting: Claude, Codex, Grok +2 more',
      );
    });

    test('drops the waiting clause once nothing is outstanding', () {
      expect(
        fleetProgressLine(
          spinner: '⠏',
          done: 11,
          total: 11,
          elapsedSeconds: 44,
          pending: const [],
        ),
        '  ⠏ reading quota  11/11 - 44s',
      );
    });
  });

  group('fleetReadHeader', () {
    test('states the provider count and the time expectation', () {
      expect(
        fleetReadHeader(11),
        'reading quota from 11 providers - live reads, usually under a minute',
      );
    });
  });

  group('FleetProgress', () {
    test('emits header and an initial status line naming all pending', () {
      final buf = StringBuffer();
      var clock = 0;
      FleetProgress(
        sink: buf,
        pending: ['Claude', 'Codex', 'Grok'],
        elapsedSeconds: () => clock,
      ).start();
      expect(
        buf.toString(),
        'reading quota from 3 providers - live reads, usually under a minute\n'
        '  ⠋ reading quota  0/3 - 0s - waiting: Claude, Codex, Grok',
      );
    });

    test('commits a settled provider above a rewritten status line', () {
      final buf = StringBuffer();
      var clock = 0;
      final p = FleetProgress(
        sink: buf,
        pending: ['Claude', 'Codex'],
        elapsedSeconds: () => clock,
      );
      p.start();
      final initialStatus = fleetProgressLine(
        spinner: fleetSpinnerFrame(0),
        done: 0,
        total: 2,
        elapsedSeconds: 0,
        pending: ['Claude', 'Codex'],
      );
      clock = 12;
      buf.clear();
      p.providerDone('Claude', true);
      final doneLine = fleetProviderDoneLine(
        done: 1,
        total: 2,
        displayName: 'Claude',
        ok: true,
        elapsedSeconds: 12,
      );
      final newStatus = fleetProgressLine(
        spinner: fleetSpinnerFrame(0),
        done: 1,
        total: 2,
        elapsedSeconds: 12,
        pending: ['Codex'],
      );
      // Clears the prior status line with CR + spaces + CR (no VT escape),
      // commits the done line, then repaints the shorter status line.
      expect(
        buf.toString(),
        '\r${' ' * initialStatus.length}\r$doneLine\n$newStatus',
      );
    });

    test('stop erases the live status line and leaves no trailing escape', () {
      final buf = StringBuffer();
      final p = FleetProgress(
        sink: buf,
        pending: ['Claude'],
        elapsedSeconds: () => 0,
      );
      p.start();
      final status = fleetProgressLine(
        spinner: fleetSpinnerFrame(0),
        done: 0,
        total: 1,
        elapsedSeconds: 0,
        pending: ['Claude'],
      );
      buf.clear();
      p.stop();
      expect(buf.toString(), '\r${' ' * status.length}\r');
      expect(buf.toString(), isNot(contains('\x1B')));
    });

    test('a color styler wraps every line but clearing stays visible-width',
        () {
      final buf = StringBuffer();
      final p = FleetProgress(
        sink: buf,
        pending: ['Claude'],
        elapsedSeconds: () => 0,
        dim: (s) => '<$s>',
      );
      p.start();
      buf.clear();
      p.stop();
      // The clear width tracks the raw (unstyled) status length, so a styled
      // line does not leave residual characters behind.
      final rawStatus = fleetProgressLine(
        spinner: fleetSpinnerFrame(0),
        done: 0,
        total: 1,
        elapsedSeconds: 0,
        pending: ['Claude'],
      );
      expect(buf.toString(), '\r${' ' * rawStatus.length}\r');
    });
  });
}
