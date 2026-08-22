// Unit tests for the host advisory layer — the decision logic behind what
// the failure surface tells the user.
//
// All of it is pure so the wording and the show/hide rules are testable
// without pumping a widget. The widget that renders these is deliberately
// thin, the same split session_reference.dart uses.
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_advisory.dart';
import 'package:helm/core/host/host_diagnostics.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/multiplexer_selection.dart';

void main() {
  group('advisoriesForSelection — nothing to say', () {
    test('a verified multiplexer on the inherited PATH produces none', () {
      final advisories = advisoriesForSelection(
        const MultiplexerVerified(
          id: MultiplexerId.tmux,
          absPath: '/usr/bin/tmux',
          onInheritedPath: true,
        ),
      );

      expect(advisories, isEmpty);
    });

    test('an unverified selection produces none, never a false absence', () {
      // The probe could not report. Saying anything here would be
      // manufacturing a finding out of missing evidence.
      final advisories = advisoriesForSelection(
        const MultiplexerUnverified(id: MultiplexerId.tmux),
      );

      expect(advisories, isEmpty);
    });

    test('a null selection (no probe ran) produces none', () {
      expect(advisoriesForSelection(null), isEmpty);
    });
  });

  group('advisoriesForSelection — the multiplexer is not what was asked', () {
    test('a substitution names both sides', () {
      final advisories = advisoriesForSelection(
        const MultiplexerSubstituted(
          requested: MultiplexerId.zellij,
          id: MultiplexerId.tmux,
          absPath: '/usr/bin/tmux',
          onInheritedPath: true,
          available: [MultiplexerId.tmux, MultiplexerId.herdr],
        ),
      );

      final advisory = advisories.single;
      expect(advisory.id, HostAdvisoryId.multiplexerSubstituted);
      expect(advisory.severity, HostAdvisorySeverity.warning);
      expect(advisory.detail, contains('zellij'));
      expect(advisory.detail, contains('tmux'));
      expect(advisory.detail, contains('herdr'));
    });

    test('no multiplexer at all is a warning that names what was sought', () {
      final advisories = advisoriesForSelection(
        const MultiplexerNoneFound(
          requested: MultiplexerId.tmux,
          id: MultiplexerId.tmux,
        ),
      );

      final advisory = advisories.single;
      expect(advisory.id, HostAdvisoryId.multiplexerMissing);
      expect(advisory.severity, HostAdvisorySeverity.warning);
      expect(advisory.detail, contains('tmux'));
    });
  });

  group('advisoriesForSelection — installed but off the inherited PATH', () {
    test('reports the verified real-host herdr case', () {
      final advisories = advisoriesForSelection(
        const MultiplexerVerified(
          id: MultiplexerId.herdr,
          absPath: '/home/deployer/.local/bin/herdr',
          onInheritedPath: false,
        ),
      );

      final advisory = advisories.single;
      expect(advisory.id, HostAdvisoryId.multiplexerOffPath);
      expect(advisory.detail, contains('/home/deployer/.local/bin/herdr'));
      // It must NOT read as "not installed" — that is the exact lie this
      // whole layer exists to prevent.
      expect(advisory.detail, isNot(contains('not installed')));
      expect(advisory.detail, contains('herdr'));
    });

    test('a substituted multiplexer that is itself off-PATH reports both', () {
      final advisories = advisoriesForSelection(
        const MultiplexerSubstituted(
          requested: MultiplexerId.zellij,
          id: MultiplexerId.herdr,
          absPath: '/home/deployer/.local/bin/herdr',
          onInheritedPath: false,
          available: [MultiplexerId.herdr],
        ),
      );

      expect(
        advisories.map((a) => a.id),
        containsAll([
          HostAdvisoryId.multiplexerSubstituted,
          HostAdvisoryId.multiplexerOffPath,
        ]),
      );
    });
  });

  group('advisoryForDiagnostic — maps host findings', () {
    test('a warn finding becomes a warning advisory with its remediation', () {
      final advisory = advisoryForDiagnostic(
        const HostDiagnostic(
          id: DiagnosticId.sessionsMayDieOnLogout,
          status: DiagnosticStatus.warn,
          detail: 'Linger is disabled and this host kills user processes.',
          remediationCopy: "Run 'loginctl enable-linger' as this user.",
        ),
      );

      expect(advisory, isNotNull);
      expect(advisory!.id, HostAdvisoryId.sessionsMayDieOnLogout);
      expect(advisory.severity, HostAdvisorySeverity.warning);
      expect(advisory.detail, contains('Linger is disabled'));
      expect(advisory.remediationCopy, contains('enable-linger'));
    });

    test('a tailscale warn finding maps to its own advisory', () {
      final advisory = advisoryForDiagnostic(
        const HostDiagnostic(
          id: DiagnosticId.tailscaleOwnsPort22,
          status: DiagnosticStatus.warn,
          detail: 'Tailscale SSH is enabled and may be intercepting port 22.',
        ),
      );

      expect(advisory!.id, HostAdvisoryId.tailscaleOwnsPort22);
      expect(advisory.severity, HostAdvisorySeverity.warning);
    });

    test('an ok finding produces nothing to show', () {
      final advisory = advisoryForDiagnostic(
        const HostDiagnostic(
          id: DiagnosticId.sessionsMayDieOnLogout,
          status: DiagnosticStatus.ok,
          detail: 'Linger is enabled for this user.',
        ),
      );

      expect(advisory, isNull);
    });

    test('an unsupported finding produces nothing to show', () {
      // Not a problem with this host, just a check that does not apply.
      final advisory = advisoryForDiagnostic(
        const HostDiagnostic(
          id: DiagnosticId.sessionsMayDieOnLogout,
          status: DiagnosticStatus.unsupported,
          detail: 'systemd is not available on this host.',
        ),
      );

      expect(advisory, isNull);
    });

    test('an unknown finding is shown, but only as information', () {
      // "Could not determine" is never collapsed into ok (which would
      // silence a real problem) or into warn (which would cry wolf) —
      // the same tri-state discipline HostDiagnostics itself applies.
      final advisory = advisoryForDiagnostic(
        const HostDiagnostic(
          id: DiagnosticId.sessionsMayDieOnLogout,
          status: DiagnosticStatus.unknown,
          detail: "This host's linger setting could not be determined.",
        ),
      );

      expect(advisory, isNotNull);
      expect(advisory!.severity, HostAdvisorySeverity.info);
    });
  });
}
