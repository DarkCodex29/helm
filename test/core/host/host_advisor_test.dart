// Unit tests for HostAdvisor — the collector that combines the free,
// probe-derived findings with the ones HostDiagnostics has to ask the host
// about.
//
// The contract worth pinning: it never throws (a dead transport must not
// break the very surface that explains the failure), it never runs a
// remediation command, and it orders warnings ahead of information.
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_advisor.dart';
import 'package:helm/core/host/host_advisory.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/multiplexer_selection.dart';

import '../../helpers/fake_host_command_runner.dart';

// Mirrors the private constants in host_diagnostics.dart. See that file's
// class doc comment for why each command was chosen.
const _tailscalePresenceCommand = 'command -v tailscale >/dev/null 2>&1';
const _loginctlPresenceCommand = 'command -v loginctl >/dev/null 2>&1';
const _lingerCommand = 'loginctl show-user \$(id -un) --property=Linger';
const _killUserProcessesCommand =
    "grep -E '^[[:space:]]*KillUserProcesses[[:space:]]*=' "
    '/etc/systemd/logind.conf';
const _tailscaleStatusCommand = 'tailscale status --peers=false --json';

/// A host where nothing is wrong: no Tailscale, and linger is on.
FakeHostCommandRunner _healthyHost() {
  final runner = FakeHostCommandRunner();
  runner.whenRun(
    _tailscalePresenceCommand,
    const HostCommandResult(exitCode: 1),
  );
  runner.whenRun(
    _loginctlPresenceCommand,
    const HostCommandResult(exitCode: 0),
  );
  runner.whenRun(
    _lingerCommand,
    const HostCommandResult(stdout: 'Linger=yes', exitCode: 0),
  );
  return runner;
}

/// A host whose work dies on logout: no linger, and it kills user
/// processes.
FakeHostCommandRunner _hostThatKillsOnLogout() {
  final runner = FakeHostCommandRunner();
  runner.whenRun(
    _tailscalePresenceCommand,
    const HostCommandResult(exitCode: 1),
  );
  runner.whenRun(
    _loginctlPresenceCommand,
    const HostCommandResult(exitCode: 0),
  );
  runner.whenRun(
    _lingerCommand,
    const HostCommandResult(stdout: 'Linger=no', exitCode: 0),
  );
  runner.whenRun(
    _killUserProcessesCommand,
    const HostCommandResult(stdout: 'KillUserProcesses=yes', exitCode: 0),
  );
  return runner;
}

const _verifiedTmux = MultiplexerVerified(
  id: MultiplexerId.tmux,
  absPath: '/usr/bin/tmux',
  onInheritedPath: true,
);

void main() {
  group('HostAdvisor.collect — without a live runner', () {
    test('still returns the probe-derived findings', () async {
      // A connect that failed outright has no client, so no host question
      // can be asked. What the probe already told us must survive that.
      final advisories = await const HostAdvisor().collect(
        selection: const MultiplexerNoneFound(
          requested: MultiplexerId.tmux,
          id: MultiplexerId.tmux,
        ),
      );

      expect(advisories.single.id, HostAdvisoryId.multiplexerMissing);
    });

    test('returns nothing when there is nothing to report', () async {
      final advisories = await const HostAdvisor().collect(
        selection: _verifiedTmux,
      );

      expect(advisories, isEmpty);
    });
  });

  group('HostAdvisor.collect — with a live runner', () {
    test('a healthy host produces no advisories at all', () async {
      final advisories = await const HostAdvisor().collect(
        selection: _verifiedTmux,
        runner: _healthyHost(),
      );

      expect(advisories, isEmpty);
    });

    test('surfaces missing logout persistence', () async {
      final advisories = await const HostAdvisor().collect(
        selection: _verifiedTmux,
        runner: _hostThatKillsOnLogout(),
      );

      final advisory = advisories.single;
      expect(advisory.id, HostAdvisoryId.sessionsMayDieOnLogout);
      expect(advisory.severity, HostAdvisorySeverity.warning);
      expect(advisory.remediationCopy, contains('enable-linger'));
    });

    test('surfaces Tailscale port-22 interception', () async {
      final runner = FakeHostCommandRunner();
      runner.whenRun(
        _tailscalePresenceCommand,
        const HostCommandResult(exitCode: 0),
      );
      runner.whenRun(
        'tailscale debug prefs',
        const HostCommandResult(stdout: '{"RunSSH":true}', exitCode: 0),
      );
      runner.whenRun(
        _loginctlPresenceCommand,
        const HostCommandResult(exitCode: 0),
      );
      runner.whenRun(
        _lingerCommand,
        const HostCommandResult(stdout: 'Linger=yes', exitCode: 0),
      );

      final advisories = await const HostAdvisor().collect(
        selection: _verifiedTmux,
        runner: runner,
      );

      expect(
        advisories.map((a) => a.id),
        contains(HostAdvisoryId.tailscaleOwnsPort22),
      );
    });

    test('never executes a remediation command', () async {
      // FakeHostCommandRunner throws for any unregistered command, so if
      // collect() ever ran `loginctl enable-linger` or `tailscale set
      // --ssh=false` this test fails loudly rather than passing silently.
      final advisories = await const HostAdvisor().collect(
        selection: _verifiedTmux,
        runner: _hostThatKillsOnLogout(),
      );

      expect(advisories, isNotEmpty);
    });

    test('surfaces a raw-Tailscale-address warning only when connectHost is '
        'supplied and matches', () async {
      final runner = FakeHostCommandRunner();
      runner.whenRun(
        _tailscalePresenceCommand,
        const HostCommandResult(exitCode: 0),
      );
      runner.whenRun(
        _tailscaleStatusCommand,
        const HostCommandResult(
          stdout:
              '{"BackendState":"Running",'
              '"TailscaleIPs":["100.108.167.71"],'
              '"Self":{"DNSName":"gian-macbook-pro.taila49d8e.ts.net."},'
              '"CurrentTailnet":{"MagicDNSSuffix":"taila49d8e.ts.net",'
              '"MagicDNSEnabled":true}}',
          exitCode: 0,
        ),
      );
      runner.whenRun(
        _loginctlPresenceCommand,
        const HostCommandResult(exitCode: 0),
      );
      runner.whenRun(
        _lingerCommand,
        const HostCommandResult(stdout: 'Linger=yes', exitCode: 0),
      );

      final advisories = await const HostAdvisor().collect(
        selection: _verifiedTmux,
        runner: runner,
        connectHost: '100.108.167.71',
      );

      expect(
        advisories.map((a) => a.id),
        contains(HostAdvisoryId.tailscaleAddressUnstable),
      );
    });

    test('does not run the Tailscale-address check at all when no '
        'connectHost is supplied, even on an otherwise live runner', () async {
      // Deliberately NOT registering `tailscale status --peers=false
      // --json`: if collect() ran the address-stability check anyway
      // without a host to compare against, the fake throws for the
      // unregistered command and this test fails loudly.
      final advisories = await const HostAdvisor().collect(
        selection: _verifiedTmux,
        runner: _healthyHost(),
      );

      expect(advisories, isEmpty);
    });

    test('orders warnings before information', () async {
      final advisories = await const HostAdvisor().collect(
        selection: const MultiplexerVerified(
          id: MultiplexerId.herdr,
          absPath: '/home/deployer/.local/bin/herdr',
          onInheritedPath: false,
        ),
        runner: _hostThatKillsOnLogout(),
      );

      expect(advisories.first.severity, HostAdvisorySeverity.warning);
      expect(advisories.last.severity, HostAdvisorySeverity.info);
    });
  });

  group(
    'HostAdvisor.collect — a broken transport cannot break the surface',
    () {
      test(
        'a throwing runner still yields the probe-derived findings',
        () async {
          // FakeHostCommandRunner with nothing registered throws on the first
          // diagnostic command, standing in for a client that has already died.
          final advisories = await const HostAdvisor().collect(
            selection: const MultiplexerNoneFound(
              requested: MultiplexerId.zellij,
              id: MultiplexerId.zellij,
            ),
            runner: FakeHostCommandRunner(),
          );

          expect(advisories.single.id, HostAdvisoryId.multiplexerMissing);
        },
      );

      test('a throwing runner never propagates its exception', () async {
        await expectLater(
          const HostAdvisor().collect(
            selection: _verifiedTmux,
            runner: FakeHostCommandRunner(),
          ),
          completion(isEmpty),
        );
      });
    },
  );
}
