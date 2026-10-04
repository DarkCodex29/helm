// Unit tests for resolveMultiplexer — the pure decision that matches a
// profile's persisted multiplexer choice against what the probe actually
// observed on the host.
//
// The governing discipline these tests pin is the same one the rest of
// this layer already enforces (see MuxSessionsResult, HostDiagnostics'
// tri-state combine): absence of a signal is never evidence of a negative
// answer. A probe that could not report is NOT a probe that reported
// "not installed".
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/multiplexer_selection.dart';
import 'package:helm/core/host/probe/host_report.dart';

HostMuxInfo _mux(
  String id, {
  bool found = true,
  String absPath = '',
  String version = '',
  bool onInheritedPath = true,
}) => (
  id: id,
  found: found,
  absPath: absPath,
  version: version,
  onInheritedPath: onInheritedPath,
);

/// A report shaped like the real host used to verify this change: tmux on
/// PATH at /usr/bin/tmux, herdr installed at ~/.local/bin/herdr but NOT on
/// the PATH a non-interactive SSH shell inherits, and no zellij.
HostReport _realHostReport() => HostReport(
  status: HostReportStatus.ok,
  mux: [
    _mux(
      'herdr',
      absPath: '/home/deployer/.local/bin/herdr',
      version: 'herdr 0.8.0',
      onInheritedPath: false,
    ),
    _mux('tmux', absPath: '/usr/bin/tmux', version: 'tmux 3.4'),
    _mux('zellij', found: false, onInheritedPath: false),
  ],
);

void main() {
  group('resolveMultiplexer - the request is present on the host', () {
    test('returns the requested multiplexer with its probe-resolved path', () {
      final selection = resolveMultiplexer(
        requested: MultiplexerId.tmux,
        report: _realHostReport(),
      );

      expect(
        selection,
        isA<MultiplexerVerified>()
            .having((s) => s.id, 'id', MultiplexerId.tmux)
            .having((s) => s.absPath, 'absPath', '/usr/bin/tmux')
            .having((s) => s.onInheritedPath, 'onInheritedPath', isTrue),
      );
    });

    test(
      'reports a binary that is installed but off the inherited PATH as '
      'present, not missing',
      () {
        final selection = resolveMultiplexer(
          requested: MultiplexerId.herdr,
          report: _realHostReport(),
        );

        expect(
          selection,
          isA<MultiplexerVerified>()
              .having((s) => s.id, 'id', MultiplexerId.herdr)
              .having(
                (s) => s.absPath,
                'absPath',
                '/home/deployer/.local/bin/herdr',
              )
              .having((s) => s.onInheritedPath, 'onInheritedPath', isFalse),
        );
      },
    );
  });

  group('resolveMultiplexer - the request is positively absent', () {
    test('substitutes and names both the missing and the available ones', () {
      final selection = resolveMultiplexer(
        requested: MultiplexerId.zellij,
        report: _realHostReport(),
      );

      expect(
        selection,
        isA<MultiplexerSubstituted>()
            .having((s) => s.requested, 'requested', MultiplexerId.zellij)
            .having((s) => s.id, 'id', MultiplexerId.herdr)
            .having(
              (s) => s.absPath,
              'absPath',
              '/home/deployer/.local/bin/herdr',
            )
            .having((s) => s.available, 'available', [
              MultiplexerId.herdr,
              MultiplexerId.tmux,
            ]),
      );
    });

    test('reports none found when the host has no known multiplexer', () {
      final selection = resolveMultiplexer(
        requested: MultiplexerId.zellij,
        report: const HostReport(
          status: HostReportStatus.ok,
          mux: [
            (
              id: 'herdr',
              found: false,
              absPath: '',
              version: '',
              onInheritedPath: false,
            ),
            (
              id: 'tmux',
              found: false,
              absPath: '',
              version: '',
              onInheritedPath: false,
            ),
            (
              id: 'zellij',
              found: false,
              absPath: '',
              version: '',
              onInheritedPath: false,
            ),
          ],
        ),
      );

      expect(
        selection,
        isA<MultiplexerNoneFound>().having(
          (s) => s.requested,
          'requested',
          MultiplexerId.zellij,
        ),
      );
    });
  });

  group('resolveMultiplexer - host default (no persisted choice)', () {
    test('prefers herdr when present, even off the inherited PATH', () {
      final selection = resolveMultiplexer(
        requested: null,
        report: _realHostReport(),
      );

      expect(
        selection,
        isA<MultiplexerVerified>().having(
          (s) => s.id,
          'id',
          MultiplexerId.herdr,
        ),
      );
    });

    test('selects herdr when every supported multiplexer is installed', () {
      // The contract the ordering exists for: herdr is the only adapter
      // that advertises agent-state capability, so a host carrying all
      // three must attach through herdr rather than a degraded fallback.
      //
      // The records are listed herdr-LAST on purpose. Preference order, not
      // the order the probe happened to emit, is what decides this.
      final selection = resolveMultiplexer(
        requested: null,
        report: HostReport(
          status: HostReportStatus.ok,
          mux: [
            _mux('tmux', absPath: '/usr/bin/tmux', version: 'tmux 3.4'),
            _mux(
              'zellij',
              absPath: '/usr/bin/zellij',
              version: 'zellij 0.44.3',
            ),
            _mux(
              'herdr',
              absPath: '/usr/local/bin/herdr',
              version: 'herdr 0.8.0',
            ),
          ],
        ),
      );

      expect(
        selection,
        isA<MultiplexerVerified>()
            .having((s) => s.id, 'id', MultiplexerId.herdr)
            .having((s) => s.absPath, 'absPath', '/usr/local/bin/herdr'),
      );
    });

    test('falls to tmux, not zellij, when herdr is absent', () {
      // tmux and zellij are both fallbacks, but they are ORDERED fallbacks.
      // Listing zellij first in the report proves the preference list is
      // what breaks the tie.
      final selection = resolveMultiplexer(
        requested: null,
        report: HostReport(
          status: HostReportStatus.ok,
          mux: [
            _mux(
              'zellij',
              absPath: '/usr/bin/zellij',
              version: 'zellij 0.44.3',
            ),
            _mux('tmux', absPath: '/usr/bin/tmux', version: 'tmux 3.4'),
            _mux('herdr', found: false, onInheritedPath: false),
          ],
        ),
      );

      expect(
        selection,
        isA<MultiplexerVerified>().having((s) => s.id, 'id', MultiplexerId.tmux),
      );
    });

    test('falls through to zellij when herdr and tmux are both absent', () {
      final selection = resolveMultiplexer(
        requested: null,
        report: const HostReport(
          status: HostReportStatus.ok,
          mux: [
            (
              id: 'herdr',
              found: false,
              absPath: '',
              version: '',
              onInheritedPath: false,
            ),
            (
              id: 'tmux',
              found: false,
              absPath: '',
              version: '',
              onInheritedPath: false,
            ),
            (
              id: 'zellij',
              found: true,
              absPath: '/usr/bin/zellij',
              version: 'zellij 0.44.3',
              onInheritedPath: true,
            ),
          ],
        ),
      );

      expect(
        selection,
        isA<MultiplexerVerified>().having(
          (s) => s.id,
          'id',
          MultiplexerId.zellij,
        ),
      );
    });

    test('never reports a substitution when nothing specific was asked', () {
      // Substitution copy names what the USER chose. With no persisted
      // choice there is nothing to have been overridden, so picking the
      // host default must never read as "your choice was unavailable".
      final selection = resolveMultiplexer(
        requested: null,
        report: _realHostReport(),
      );

      expect(selection, isNot(isA<MultiplexerSubstituted>()));
    });
  });

  group('resolveMultiplexer - the probe could not report', () {
    test('a truncated report is unverified, never "not installed"', () {
      final selection = resolveMultiplexer(
        requested: MultiplexerId.zellij,
        report: const HostReport(status: HostReportStatus.truncated),
      );

      expect(
        selection,
        isA<MultiplexerUnverified>().having(
          (s) => s.id,
          'id',
          MultiplexerId.zellij,
        ),
      );
    });

    test('a version-mismatched report is unverified', () {
      final selection = resolveMultiplexer(
        requested: MultiplexerId.herdr,
        report: const HostReport(status: HostReportStatus.versionMismatch),
      );

      expect(
        selection,
        isA<MultiplexerUnverified>().having(
          (s) => s.id,
          'id',
          MultiplexerId.herdr,
        ),
      );
    });

    test(
      'an ok report carrying no mux records at all is unverified, not empty',
      () {
        // Forward compatibility: a future probe that drops mux emission
        // must not be read as "this host has no multiplexers".
        final selection = resolveMultiplexer(
          requested: MultiplexerId.tmux,
          report: const HostReport(status: HostReportStatus.ok),
        );

        expect(selection, isA<MultiplexerUnverified>());
      },
    );

    test('unverified with no persisted choice still yields a usable id', () {
      final selection = resolveMultiplexer(
        requested: null,
        report: const HostReport(status: HostReportStatus.truncated),
      );

      expect(
        selection,
        isA<MultiplexerUnverified>().having(
          (s) => s.id,
          'id',
          MultiplexerId.herdr,
        ),
      );
    });

    test('a partial report is still trusted for the records it did carry', () {
      // `partial` means the probe finished and said so — unlike
      // `truncated`, its records are real observations.
      final selection = resolveMultiplexer(
        requested: MultiplexerId.tmux,
        report: HostReport(
          status: HostReportStatus.partial,
          mux: [_mux('tmux', absPath: '/usr/bin/tmux')],
        ),
      );

      expect(
        selection,
        isA<MultiplexerVerified>().having(
          (s) => s.absPath,
          'absPath',
          '/usr/bin/tmux',
        ),
      );
    });
  });

  group('resolveMultiplexer - malformed records', () {
    test('ignores a mux record whose id this build does not know', () {
      final selection = resolveMultiplexer(
        requested: null,
        report: HostReport(
          status: HostReportStatus.ok,
          mux: [
            _mux('screen', absPath: '/usr/bin/screen'),
            _mux('tmux', absPath: '/usr/bin/tmux'),
          ],
        ),
      );

      expect(
        selection,
        isA<MultiplexerVerified>().having((s) => s.id, 'id', MultiplexerId.tmux),
      );
    });

    test('treats a found record with an empty path as unusable', () {
      // `found=1` with no absolute path cannot produce a command to run.
      // Reporting it as available would hand the attach path a bare name
      // the probe already proved is ambiguous.
      final selection = resolveMultiplexer(
        requested: MultiplexerId.zellij,
        report: HostReport(
          status: HostReportStatus.ok,
          mux: [
            _mux('zellij', absPath: ''),
            _mux('tmux', absPath: '/usr/bin/tmux'),
          ],
        ),
      );

      expect(selection, isA<MultiplexerSubstituted>());
    });
  });

  group('multiplexerSelectionNotice', () {
    test('names the host default preference order it actually searched', () {
      // The only place the preference list becomes user-visible copy.
      // Reordering the list without updating this expectation would ship a
      // sentence that misreports what the probe looked for, and in what
      // order it would have accepted them.
      final notice = multiplexerSelectionNotice(
        const MultiplexerNoneFound(requested: null, id: MultiplexerId.herdr),
      );

      expect(notice, contains('looked for herdr, tmux, zellij'));
    });
  });
}
