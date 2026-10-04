// Tests for the VIRGIN vs LIVED-IN verdict.
//
// The incident this exists for, measured on a real host: the owner shut
// his Mac down, herdr restored the session SHAPE (workspaces, tabs, panes)
// on reboot but lost all CONTENT, and helm redrew the tabs as if nothing
// had happened. The host's own words at that moment:
//
//   herdr pane list --session default → every pane "revision": 1,
//                                       "cwd": "/home/deployer" (== $HOME),
//                                       "agent_status": "unknown"
//   herdr agent list                  → {"agents":[]}
//
// `AgentsKnown([])` is NOT the bug and must not be overloaded to carry
// this: it honestly means "no agents are running right now", which is also
// true of a session the user simply has not started work in yet. Telling
// those two apart needs a SECOND, INDEPENDENT fact, and that is what this
// judge produces.
//
// The assertions below are deliberately two-sided in the same way the
// agent-snapshot tests are. A wrong VIRGIN verdict tells a user their work
// is gone when it is not; a wrong LIVED-IN verdict stays silent when their
// world has actually been reset. So every degradation case asserts both
// the honest variant it MUST publish AND, explicitly, that it is not
// [SessionVitalityKnown] — the one variant a reader may act on.
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/agent_snapshot.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/session_vitality.dart';

const _home = '/home/deployer';

/// One pane, defaulting to the exact shape a resurrected-empty session
/// reported on the real host: never touched (revision 1) and sitting in
/// $HOME.
MuxPane _pane({String paneId = 'w1:p1', int revision = 1, String? cwd}) =>
    (paneId: paneId, revision: revision, cwd: cwd ?? _home);

const _anAgent = (
  target: 'w1:p1',
  label: 'claude',
  state: AgentState.working,
  tabId: 'w1:t1',
  workspaceId: 'w1',
);

void main() {
  group('judgeSessionVitality - VIRGIN needs every negative fact', () {
    test('the measured resurrected-empty session: untouched panes at home with '
        'an authoritative empty agent list reads as VIRGIN', () {
      final verdict = judgeSessionVitality(
        panes: [
          _pane(paneId: 'w1:p1'),
          _pane(paneId: 'w1:p2'),
        ],
        agents: const AgentsKnown([]),
        homeDirectory: _home,
      );

      expect(verdict, isA<SessionVitalityKnown>());
      expect((verdict as SessionVitalityKnown).shape, SessionShape.virgin);
    });

    test('a single pane is enough evidence when it is the only pane', () {
      final verdict = judgeSessionVitality(
        panes: [_pane()],
        agents: const AgentsKnown([]),
        homeDirectory: _home,
      );

      expect((verdict as SessionVitalityKnown).shape, SessionShape.virgin);
    });
  });

  group('judgeSessionVitality - any ONE positive fact makes it LIVED-IN', () {
    test('a pane whose revision moved past 1 has been used', () {
      final verdict = judgeSessionVitality(
        panes: [
          _pane(paneId: 'w1:p1'),
          _pane(paneId: 'w1:p2', revision: 7),
        ],
        agents: const AgentsKnown([]),
        homeDirectory: _home,
      );

      expect((verdict as SessionVitalityKnown).shape, SessionShape.livedIn);
    });

    test('a pane that has been cd-ed away from home has been used', () {
      final verdict = judgeSessionVitality(
        panes: [
          _pane(paneId: 'w1:p1'),
          _pane(paneId: 'w1:p2', cwd: '/srv/app'),
        ],
        agents: const AgentsKnown([]),
        homeDirectory: _home,
      );

      expect((verdict as SessionVitalityKnown).shape, SessionShape.livedIn);
    });

    test('an agent that exists at all means the session is alive', () {
      final verdict = judgeSessionVitality(
        panes: [_pane()],
        agents: const AgentsKnown([_anAgent]),
        homeDirectory: _home,
      );

      expect((verdict as SessionVitalityKnown).shape, SessionShape.livedIn);
    });

    test('revision alone settles LIVED-IN even when the agent list could not '
        'be read - one positive fact does not need the others', () {
      final verdict = judgeSessionVitality(
        panes: [_pane(revision: 4)],
        agents: const AgentsUnreachable(),
        homeDirectory: _home,
      );

      expect((verdict as SessionVitalityKnown).shape, SessionShape.livedIn);
    });

    test('a live agent settles LIVED-IN even with no home to compare cwd '
        'against', () {
      final verdict = judgeSessionVitality(
        panes: [_pane()],
        agents: const AgentsKnown([_anAgent]),
        homeDirectory: null,
      );

      expect((verdict as SessionVitalityKnown).shape, SessionShape.livedIn);
    });
  });

  group('judgeSessionVitality - never guesses', () {
    test('an unknown home directory yields INDETERMINATE, never VIRGIN: '
        '"cwd equals home" is unanswerable without home', () {
      final verdict = judgeSessionVitality(
        panes: [_pane()],
        agents: const AgentsKnown([]),
        homeDirectory: null,
      );

      expect(verdict, isA<SessionVitalityIndeterminate>());
      expect(verdict, isNot(isA<SessionVitalityKnown>()));
    });

    test('an unreachable agent server yields INDETERMINATE: panes that look '
        'untouched cannot rule out an agent nobody could ask about', () {
      final verdict = judgeSessionVitality(
        panes: [_pane()],
        agents: const AgentsUnreachable(),
        homeDirectory: _home,
      );

      expect(verdict, isA<SessionVitalityIndeterminate>());
      expect(verdict, isNot(isA<SessionVitalityKnown>()));
    });

    test(
      'an unprobed agent snapshot yields INDETERMINATE for the same reason',
      () {
        final verdict = judgeSessionVitality(
          panes: [_pane()],
          agents: const AgentsNotProbed(),
          homeDirectory: _home,
        );

        expect(verdict, isA<SessionVitalityIndeterminate>());
      },
    );

    test('a multiplexer that cannot report agents yields INDETERMINATE, not a '
        'VIRGIN verdict built on a capability it never had', () {
      final verdict = judgeSessionVitality(
        panes: [_pane()],
        agents: const AgentsUnsupported(MultiplexerId.tmux),
        homeDirectory: _home,
      );

      expect(verdict, isA<SessionVitalityIndeterminate>());
    });

    test('zero panes yields INDETERMINATE, not a vacuously VIRGIN verdict: '
        '"every pane is a fresh shell" is a claim about panes that exist', () {
      final verdict = judgeSessionVitality(
        panes: const [],
        agents: const AgentsKnown([]),
        homeDirectory: _home,
      );

      expect(verdict, isA<SessionVitalityIndeterminate>());
      expect(verdict, isNot(isA<SessionVitalityKnown>()));
    });

    test('revision 0 is still untouched - the threshold is "past 1"', () {
      final verdict = judgeSessionVitality(
        panes: [_pane(revision: 0)],
        agents: const AgentsKnown([]),
        homeDirectory: _home,
      );

      expect((verdict as SessionVitalityKnown).shape, SessionShape.virgin);
    });
  });
}
