import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/host_diagnostics.dart';

import '../../helpers/fake_host_command_runner.dart';

// Exact commands HostDiagnostics runs. See the class doc comment on
// [HostDiagnostics] in lib/core/host/host_diagnostics.dart for the full
// reasoning behind each choice and every disclosed assumption —
// particularly for Tailscale, where no live sample exists on any host
// reachable while implementing this slice (tailscale is not installed on
// the real host used to gather the rest of this slice's ground truth).
const _tailscalePresenceCommand = 'command -v tailscale >/dev/null 2>&1';
const _tailscaleDebugPrefsCommand = 'tailscale debug prefs';
const _tailscaleStatusCommand = 'tailscale status --peers=false --json';
const _loginctlPresenceCommand = 'command -v loginctl >/dev/null 2>&1';
const _lingerCommand = 'loginctl show-user \$(id -un) --property=Linger';
const _killUserProcessesCommand =
    "grep -E '^[[:space:]]*KillUserProcesses[[:space:]]*=' "
    '/etc/systemd/logind.conf';

void main() {
  late FakeHostCommandRunner runner;
  late HostDiagnostics diagnostics;

  setUp(() {
    runner = FakeHostCommandRunner();
    diagnostics = HostDiagnostics(runner);
  });

  group('Tailscale interception (Diagnostics Are Display-Only)', () {
    test('warns with remediation copy when Tailscale SSH is enabled', () async {
      runner.whenRun(
        _tailscalePresenceCommand,
        const HostCommandResult(exitCode: 0),
      );
      runner.whenRun(
        _tailscaleDebugPrefsCommand,
        const HostCommandResult(
          stdout: '{"RunSSH":true,"OtherField":"x"}\n',
          exitCode: 0,
        ),
      );

      final finding = await diagnostics.evaluateTailscaleInterception();

      expect(finding.status, DiagnosticStatus.warn);
      expect(finding.remediationCopy, isNotNull);
      expect(finding.remediationCopy, contains('tailscale set --ssh=false'));
    });

    test('never executes the remediation command, even though it would '
        'resolve the warning', () async {
      runner.whenRun(
        _tailscalePresenceCommand,
        const HostCommandResult(exitCode: 0),
      );
      runner.whenRun(
        _tailscaleDebugPrefsCommand,
        const HostCommandResult(stdout: '{"RunSSH":true}\n', exitCode: 0),
      );
      // Deliberately NOT registering a result for `tailscale set
      // --ssh=false` or any other mutating command: if evaluate() ever
      // executed it, FakeHostCommandRunner.run() throws StateError for
      // an unregistered command, and this test fails loudly instead of
      // passing silently.

      final finding = await diagnostics.evaluateTailscaleInterception();

      expect(finding.status, DiagnosticStatus.warn);
      expect(runner.runCalls, isNot(anyElement(contains('tailscale set'))));
    });

    test('reports ok when Tailscale is not installed on the host', () async {
      runner.whenRun(
        _tailscalePresenceCommand,
        const HostCommandResult(exitCode: 1),
      );

      final finding = await diagnostics.evaluateTailscaleInterception();

      expect(finding.status, DiagnosticStatus.ok);
      // Never even attempts to read prefs from a binary that is not there.
      expect(runner.runCalls, isNot(contains(_tailscaleDebugPrefsCommand)));
    });

    test('reports unknown, never ok or warn, when the preference cannot be '
        'read', () async {
      runner.whenRun(
        _tailscalePresenceCommand,
        const HostCommandResult(exitCode: 0),
      );
      runner.whenRun(
        _tailscaleDebugPrefsCommand,
        const HostCommandResult(stderr: 'permission denied', exitCode: 1),
      );

      final finding = await diagnostics.evaluateTailscaleInterception();

      expect(finding.status, DiagnosticStatus.unknown);
    });
  });

  group(
    'Logout persistence - linger finding (Diagnostics Are Display-Only)',
    () {
      test('warns with remediation copy when linger is off and '
          'KillUserProcesses is on', () async {
        runner.whenRun(
          _loginctlPresenceCommand,
          const HostCommandResult(exitCode: 0),
        );
        runner.whenRun(
          _lingerCommand,
          const HostCommandResult(stdout: 'Linger=no\n', exitCode: 0),
        );
        runner.whenRun(
          _killUserProcessesCommand,
          const HostCommandResult(
            stdout: 'KillUserProcesses=yes\n',
            exitCode: 0,
          ),
        );

        final finding = await diagnostics.evaluateLogoutPersistence();

        expect(finding.status, DiagnosticStatus.warn);
        expect(finding.remediationCopy, isNotNull);
        expect(finding.remediationCopy, contains('loginctl enable-linger'));
      });

      test('never executes the remediation command, even though it would '
          'resolve the warning', () async {
        runner.whenRun(
          _loginctlPresenceCommand,
          const HostCommandResult(exitCode: 0),
        );
        runner.whenRun(
          _lingerCommand,
          const HostCommandResult(stdout: 'Linger=no\n', exitCode: 0),
        );
        runner.whenRun(
          _killUserProcessesCommand,
          const HostCommandResult(
            stdout: 'KillUserProcesses=yes\n',
            exitCode: 0,
          ),
        );
        // Deliberately NOT registering a result for `loginctl
        // enable-linger`: an accidental execution would hit
        // FakeHostCommandRunner's unregistered-command StateError and
        // fail this test loudly.

        final finding = await diagnostics.evaluateLogoutPersistence();

        expect(finding.status, DiagnosticStatus.warn);
        expect(runner.runCalls, isNot(anyElement(contains('enable-linger'))));
      });
    },
  );

  group('Logout persistence - systemd absence', () {
    test(
      'reports unsupported, never disabled, when systemd is not available',
      () async {
        runner.whenRun(
          _loginctlPresenceCommand,
          const HostCommandResult(exitCode: 1),
        );
        // Deliberately NOT registering results for the linger/
        // KillUserProcesses commands: an implementation that reports
        // unsupported correctly never calls either of them once
        // `loginctl` itself is confirmed absent.

        final finding = await diagnostics.evaluateLogoutPersistence();

        expect(finding.status, DiagnosticStatus.unsupported);
        // There is no `disabled` member on DiagnosticStatus at all, so
        // this is also enforced structurally by the type — see
        // DiagnosticStatus's own doc comment.
        expect(DiagnosticStatus.values, isNot(contains('disabled')));
        expect(runner.runCalls, isNot(contains(_lingerCommand)));
        expect(runner.runCalls, isNot(contains(_killUserProcessesCommand)));
      },
    );
  });

  group('Logout persistence - truth table (No False Alarm)', () {
    test('reports ok, not a warning, when both linger and KillUserProcesses '
        'are off', () async {
      runner.whenRun(
        _loginctlPresenceCommand,
        const HostCommandResult(exitCode: 0),
      );
      runner.whenRun(
        _lingerCommand,
        const HostCommandResult(stdout: 'Linger=no\n', exitCode: 0),
      );
      runner.whenRun(
        _killUserProcessesCommand,
        const HostCommandResult(stdout: 'KillUserProcesses=no\n', exitCode: 0),
      );

      final finding = await diagnostics.evaluateLogoutPersistence();

      expect(finding.status, DiagnosticStatus.ok);
      expect(finding.remediationCopy, isNull);
    });

    test(
      'reports ok when linger is on, regardless of KillUserProcesses',
      () async {
        runner.whenRun(
          _loginctlPresenceCommand,
          const HostCommandResult(exitCode: 0),
        );
        runner.whenRun(
          _lingerCommand,
          const HostCommandResult(stdout: 'Linger=yes\n', exitCode: 0),
        );
        // Deliberately NOT registering the KillUserProcesses command: a
        // correct implementation short-circuits to ok on linger=yes and
        // never needs to read it.
        final finding = await diagnostics.evaluateLogoutPersistence();

        expect(finding.status, DiagnosticStatus.ok);
        expect(runner.runCalls, isNot(contains(_killUserProcessesCommand)));
      },
    );

    test(
      'reports unknown, never ok or warn, when linger cannot be determined',
      () async {
        runner.whenRun(
          _loginctlPresenceCommand,
          const HostCommandResult(exitCode: 0),
        );
        runner.whenRun(
          _lingerCommand,
          const HostCommandResult(stderr: 'unexpected output', exitCode: 1),
        );

        final finding = await diagnostics.evaluateLogoutPersistence();

        expect(finding.status, DiagnosticStatus.unknown);
      },
    );

    test('reports unknown, never ok or warn, when linger is off and '
        'KillUserProcesses cannot be determined (e.g. commented out, or '
        "systemctl show returning empty output with exit 0 - both are "
        'traps, neither is a value)', () async {
      runner.whenRun(
        _loginctlPresenceCommand,
        const HostCommandResult(exitCode: 0),
      );
      runner.whenRun(
        _lingerCommand,
        const HostCommandResult(stdout: 'Linger=no\n', exitCode: 0),
      );
      runner.whenRun(
        _killUserProcessesCommand,
        const HostCommandResult(exitCode: 1),
      );

      final finding = await diagnostics.evaluateLogoutPersistence();

      expect(finding.status, DiagnosticStatus.unknown);
    });
  });

  group('Tailscale interception is detected only post-connect '
      '(Tailscale SSH Detected Post-Connect)', () {
    test(
      'evaluateLogoutPersistence never queries Tailscale, even when a '
      'Tailscale-intercepting host is scripted underneath it - proves '
      'the Tailscale check has no reachable path from the pre-connect '
      'surface, not just that the two methods happen to look separate',
      () async {
        runner.whenRun(
          _loginctlPresenceCommand,
          const HostCommandResult(exitCode: 0),
        );
        runner.whenRun(
          _lingerCommand,
          const HostCommandResult(stdout: 'Linger=yes\n', exitCode: 0),
        );
        // Deliberately NOT registering EITHER Tailscale command: if
        // evaluateLogoutPersistence ever reached them — directly, or by
        // some future refactor accidentally bundling the checks — the
        // fake throws StateError for the unregistered command and this
        // test fails loudly, proving the gate rather than assuming it.

        final finding = await diagnostics.evaluateLogoutPersistence();

        expect(finding.status, DiagnosticStatus.ok);
        expect(runner.runCalls, isNot(anyElement(contains('tailscale'))));
      },
    );

    test('the Tailscale finding is reachable only through '
        'evaluateTailscaleInterception, the dedicated post-connect call '
        'site', () async {
      runner.whenRun(
        _tailscalePresenceCommand,
        const HostCommandResult(exitCode: 0),
      );
      runner.whenRun(
        _tailscaleDebugPrefsCommand,
        const HostCommandResult(stdout: '{"RunSSH":true}\n', exitCode: 0),
      );

      final finding = await diagnostics.evaluateTailscaleInterception();

      expect(finding.id, DiagnosticId.tailscaleOwnsPort22);
      expect(finding.status, DiagnosticStatus.warn);
    });
  });

  group('Tailscale raw-address stability (the misdiagnosed-as-network-failure '
      'defect)', () {
    // Measured ground truth, owner's real Mac, Tailscale 1.102.4. See
    // the class doc comment section above
    // `HostDiagnostics._tailscaleStatusCommand` for the full citation.
    const statusJson =
        '{"BackendState":"Running",'
        '"TailscaleIPs":["100.64.0.1","fd7a:115c:a1e0::1"],'
        '"Self":{"DNSName":"example-host.tailnet-example.ts.net."},'
        '"CurrentTailnet":{"MagicDNSSuffix":"tailnet-example.ts.net",'
        '"MagicDNSEnabled":true}}';

    test('warns and names the MagicDNS name, stripped of its trailing dot, '
        'when the profile connected by a raw Tailscale address that '
        'exactly matches TailscaleIPs', () async {
      runner.whenRun(
        _tailscalePresenceCommand,
        const HostCommandResult(exitCode: 0),
      );
      runner.whenRun(
        _tailscaleStatusCommand,
        const HostCommandResult(stdout: statusJson, exitCode: 0),
      );

      final finding = await diagnostics.evaluateTailscaleAddressStability(
        '100.64.0.1',
      );

      expect(finding.status, DiagnosticStatus.warn);
      expect(finding.detail, contains('example-host.tailnet-example.ts.net'));
      // The trailing dot from Self.DNSName must never survive into
      // user-facing text.
      expect(finding.detail, isNot(contains('ts.net..')));
      expect(
        finding.remediationCopy,
        contains('example-host.tailnet-example.ts.net'),
      );
      expect(finding.remediationCopy, isNot(contains('ts.net..')));
    });

    test('reports ok when the connect host is already a name, not a raw '
        'Tailscale address', () async {
      runner.whenRun(
        _tailscalePresenceCommand,
        const HostCommandResult(exitCode: 0),
      );
      runner.whenRun(
        _tailscaleStatusCommand,
        const HostCommandResult(stdout: statusJson, exitCode: 0),
      );

      final finding = await diagnostics.evaluateTailscaleAddressStability(
        'example-host.tailnet-example.ts.net',
      );

      expect(finding.status, DiagnosticStatus.ok);
    });

    test('reports ok when the connect host is a LAN address, not a raw '
        'Tailscale address - a different problem the README covers, not '
        'this check', () async {
      runner.whenRun(
        _tailscalePresenceCommand,
        const HostCommandResult(exitCode: 0),
      );
      runner.whenRun(
        _tailscaleStatusCommand,
        const HostCommandResult(stdout: statusJson, exitCode: 0),
      );

      final finding = await diagnostics.evaluateTailscaleAddressStability(
        '192.168.1.50',
      );

      expect(finding.status, DiagnosticStatus.ok);
    });

    test('never matches via the 100.64.0.0/10 CGNAT range - only an exact '
        'TailscaleIPs membership counts, because that range is shared '
        'with NetBird and some ISPs', () async {
      runner.whenRun(
        _tailscalePresenceCommand,
        const HostCommandResult(exitCode: 0),
      );
      runner.whenRun(
        _tailscaleStatusCommand,
        const HostCommandResult(stdout: statusJson, exitCode: 0),
      );

      // In-range but NOT the exact address this host's TailscaleIPs
      // lists — must not be treated as a match. Kept deliberately far
      // from the fixture's own 100.64.0.1 so the two can never collapse
      // into the same literal again: when they did, this test failed
      // honestly rather than passing on a coincidence.
      final finding = await diagnostics.evaluateTailscaleAddressStability(
        '100.64.0.77',
      );

      expect(finding.status, DiagnosticStatus.ok);
    });

    test('reports ok when Tailscale is not installed on the host', () async {
      runner.whenRun(
        _tailscalePresenceCommand,
        const HostCommandResult(exitCode: 1),
      );

      final finding = await diagnostics.evaluateTailscaleAddressStability(
        '100.64.0.1',
      );

      expect(finding.status, DiagnosticStatus.ok);
      // Never even attempts to read status from a binary that is not
      // there.
      expect(runner.runCalls, isNot(contains(_tailscaleStatusCommand)));
    });

    test(
      'reports unknown, never ok, when tailscale status exits non-zero',
      () async {
        runner.whenRun(
          _tailscalePresenceCommand,
          const HostCommandResult(exitCode: 0),
        );
        runner.whenRun(
          _tailscaleStatusCommand,
          const HostCommandResult(
            stderr: 'failed to connect to local tailscaled',
            exitCode: 1,
          ),
        );

        final finding = await diagnostics.evaluateTailscaleAddressStability(
          '100.64.0.1',
        );

        expect(finding.status, DiagnosticStatus.unknown);
      },
    );

    test('reports unknown, never ok, when tailscale status returns '
        'malformed JSON', () async {
      runner.whenRun(
        _tailscalePresenceCommand,
        const HostCommandResult(exitCode: 0),
      );
      runner.whenRun(
        _tailscaleStatusCommand,
        const HostCommandResult(stdout: 'not json at all', exitCode: 0),
      );

      final finding = await diagnostics.evaluateTailscaleAddressStability(
        '100.64.0.1',
      );

      expect(finding.status, DiagnosticStatus.unknown);
    });

    test('reports warn, never ok, when the connect host matches but '
        'MagicDNS is disabled for this tailnet - the fragility is real '
        'even with no name to suggest yet, and remediation never '
        'instructs an impossible action', () async {
      runner.whenRun(
        _tailscalePresenceCommand,
        const HostCommandResult(exitCode: 0),
      );
      runner.whenRun(
        _tailscaleStatusCommand,
        const HostCommandResult(
          stdout:
              '{"BackendState":"Running",'
              '"TailscaleIPs":["100.64.0.1"],'
              '"Self":{"DNSName":"example-host.tailnet-example.ts.net."},'
              '"CurrentTailnet":{"MagicDNSSuffix":"tailnet-example.ts.net",'
              '"MagicDNSEnabled":false}}',
          exitCode: 0,
        ),
      );

      final finding = await diagnostics.evaluateTailscaleAddressStability(
        '100.64.0.1',
      );

      expect(finding.status, DiagnosticStatus.warn);
      // Must not suggest switching to a name while MagicDNS is off —
      // that would be advising an action the user cannot take, the
      // exact antipattern this project already paid for elsewhere
      // (an error message instructing "forget the pinned key" when
      // no such UI existed).
      expect(finding.remediationCopy, isNot(contains('example-host')));
      expect(finding.remediationCopy, contains('MagicDNS'));
    });
  });
}
