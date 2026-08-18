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
    test(
      'warns with remediation copy when Tailscale SSH is enabled',
      () async {
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
        expect(
          finding.remediationCopy,
          contains('tailscale set --ssh=false'),
        );
      },
    );

    test(
      'never executes the remediation command, even though it would '
      'resolve the warning',
      () async {
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
      },
    );

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

    test(
      'reports unknown, never ok or warn, when the preference cannot be '
      'read',
      () async {
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
      },
    );
  });

  group(
    'Logout persistence — linger finding (Diagnostics Are Display-Only)',
    () {
      test(
        'warns with remediation copy when linger is off and '
        'KillUserProcesses is on',
        () async {
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
          expect(
            finding.remediationCopy,
            contains('loginctl enable-linger'),
          );
        },
      );

      test(
        'never executes the remediation command, even though it would '
        'resolve the warning',
        () async {
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
          expect(
            runner.runCalls,
            isNot(anyElement(contains('enable-linger'))),
          );
        },
      );
    },
  );

  group('Logout persistence — systemd absence', () {
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

  group('Logout persistence — truth table (No False Alarm)', () {
    test(
      'reports ok, not a warning, when both linger and KillUserProcesses '
      'are off',
      () async {
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
            stdout: 'KillUserProcesses=no\n',
            exitCode: 0,
          ),
        );

        final finding = await diagnostics.evaluateLogoutPersistence();

        expect(finding.status, DiagnosticStatus.ok);
        expect(finding.remediationCopy, isNull);
      },
    );

    test('reports ok when linger is on, regardless of KillUserProcesses', () async {
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
    });

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

    test(
      'reports unknown, never ok or warn, when linger is off and '
      'KillUserProcesses cannot be determined (e.g. commented out, or '
      "systemctl show returning empty output with exit 0 — both are "
      'traps, neither is a value)',
      () async {
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
      },
    );
  });

  group(
    'Tailscale interception is detected only post-connect '
    '(Tailscale SSH Detected Post-Connect)',
    () {
      test(
        'evaluateLogoutPersistence never queries Tailscale, even when a '
        'Tailscale-intercepting host is scripted underneath it — proves '
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
          expect(
            runner.runCalls,
            isNot(anyElement(contains('tailscale'))),
          );
        },
      );

      test(
        'the Tailscale finding is reachable only through '
        'evaluateTailscaleInterception, the dedicated post-connect call '
        'site',
        () async {
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
        },
      );
    },
  );
}
