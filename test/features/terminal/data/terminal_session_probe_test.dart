import 'dart:async';
// Tests for the host probe TerminalSession runs while establishing a
// session, and for the multiplexer it picks from the result.
//
// Two defects are pinned here:
//
// 1. The profile's multiplexer choice used to be ignored entirely — the
//    attach path hardcoded TmuxAdapter, so picking zellij silently ran
//    tmux.
// 2. `which herdr` over a non-interactive SSH shell finds nothing on the
//    verified real host even though the binary is at ~/.local/bin/herdr,
//    because ~/.local/bin is not on that shell's inherited PATH. Attaching
//    by bare name would fail; attaching by the probe-resolved absolute
//    path works.
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_advisory.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/multiplexer_selection.dart';
import 'package:helm/core/host/probe/host_report.dart';
import 'package:helm/core/host/probe/probe_script_v1.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:xterm/xterm.dart';

import '../../../helpers/fake_host_command_runner.dart';
import '../../../helpers/fake_ssh_service.dart';
import '../../../helpers/fake_ssh_session.dart';

class RecordingTerminal extends Terminal {
  RecordingTerminal() : super(maxLines: 500);

  final List<String> writes = [];

  @override
  void write(String data) => writes.add(data);
}

ConnectionProfile _profile({String? multiplexer}) => ConnectionProfile(
  id: 'profile-1',
  name: 'Test Host',
  host: 'example.test',
  username: 'tester',
  multiplexer: multiplexer,
);

SSHClient _buildFakeClient() => SSHClient(FakeSSHSocket(), username: 'tester');

/// Probe output matching the verified real host: tmux on PATH, herdr
/// installed but off the inherited PATH, no zellij.
const _realHostProbeOutput =
    'helm-probe/1\n'
    'env\tpath_inherited\t/usr/local/bin:/usr/bin:/bin\n'
    'mux\therdr\t1\t/home/deployer/.local/bin/herdr\therdr 0.8.0\t0\n'
    'mux\ttmux\t1\t/usr/bin/tmux\ttmux 3.4\t1\n'
    'mux\tzellij\t0\t\t\t0\n'
    'session\ttmux\thelm-0\tactive\t0\n'
    'end\tok\t120';

/// Builds a runner that answers the probe script with [stdout].
FakeHostCommandRunner _probeRunner(String stdout) {
  final runner = FakeHostCommandRunner();
  runner.whenRunScript(
    probeScriptV1,
    HostCommandResult(stdout: stdout, exitCode: 0),
  );
  return runner;
}

/// Drives one connect() with an attach session reference and returns the
/// commands the attach opener was handed.
Future<({List<String> commands, TerminalSession session})> _connect({
  required FakeHostCommandRunner runner,
  ConnectionProfile? profile,
  RecordingTerminal? terminal,
}) async {
  final service = FakeSSHService();
  service.queueConnectSuccess(
    SSHConnectionResult(client: _buildFakeClient(), session: FakeSSHSession()),
  );
  final commands = <String>[];
  final session = TerminalSession(
    profile: profile ?? _profile(),
    sshService: service,
    tmuxSessionName: 'helm-0',
    terminal: terminal ?? RecordingTerminal(),
    hostRunnerFactory: (_) => runner,
    attachOpener: (client, command, pty) async {
      commands.add(command);
      return FakeSSHSession();
    },
  );

  await session.connect('key');
  return (commands: commands, session: session);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalSession.connect — runs the probe', () {
    test('probes over the already-open connection, not a second one', () async {
      final runner = _probeRunner(_realHostProbeOutput);
      final service = FakeSSHService();
      service.queueConnectSuccess(
        SSHConnectionResult(
          client: _buildFakeClient(),
          session: FakeSSHSession(),
        ),
      );
      final clientsHandedToFactory = <SSHClient>[];

      final session = TerminalSession(
        profile: _profile(),
        sshService: service,
        tmuxSessionName: 'helm-0',
        terminal: RecordingTerminal(),
        hostRunnerFactory: (client) {
          clientsHandedToFactory.add(client);
          return runner;
        },
        attachOpener: (client, command, pty) async => FakeSSHSession(),
      );

      await session.connect('key');

      // One connect, one runner, built from that same connect's client.
      expect(service.connectCalls, hasLength(1));
      expect(clientsHandedToFactory, hasLength(1));
      expect(runner.runScriptCalls, [probeScriptV1]);
    });

    test('exposes the parsed report for later inspection', () async {
      final result = await _connect(runner: _probeRunner(_realHostProbeOutput));

      final report = result.session.hostReport;
      expect(report, isNotNull);
      expect(report!.status, HostReportStatus.ok);
      expect(report.sessions.single.name, 'helm-0');
    });

    test(
      'the probe reports herdr as PRESENT even though a non-interactive '
      'shell cannot resolve the bare name',
      () async {
        final result = await _connect(
          runner: _probeRunner(_realHostProbeOutput),
        );

        final herdr = result.session.hostReport!.mux.firstWhere(
          (m) => m.id == 'herdr',
        );
        expect(herdr.found, isTrue);
        expect(herdr.onInheritedPath, isFalse);
        expect(herdr.absPath, '/home/deployer/.local/bin/herdr');
      },
    );
  });

  group('TerminalSession.connect — honors the persisted multiplexer', () {
    test('attaches with zellij when the profile asks for zellij', () async {
      final result = await _connect(
        profile: _profile(multiplexer: 'zellij'),
        runner: _probeRunner(
          'helm-probe/1\n'
          'mux\ttmux\t1\t/usr/bin/tmux\ttmux 3.4\t1\n'
          'mux\tzellij\t1\t/usr/bin/zellij\tzellij 0.44.3\t1\n'
          'end\tok\t80',
        ),
      );

      expect(result.commands, ["/usr/bin/zellij attach --create 'helm-0'"]);
    });

    test(
      'attaches herdr through its absolute path when it is off the '
      'inherited PATH',
      () async {
        final result = await _connect(
          profile: _profile(multiplexer: 'herdr'),
          runner: _probeRunner(_realHostProbeOutput),
        );

        expect(
          result.commands.single,
          startsWith('/home/deployer/.local/bin/herdr'),
        );
      },
    );

    test('attaches tmux through its probe-resolved absolute path', () async {
      final result = await _connect(
        profile: _profile(multiplexer: 'tmux'),
        runner: _probeRunner(_realHostProbeOutput),
      );

      expect(result.commands, ["/usr/bin/tmux new-session -A -s 'helm-0'"]);
    });

    test('an explicit muxAdapter override still wins and skips the probe', () {
      // The existing injection point must keep working for callers that
      // already know which adapter they want.
      final runner = _probeRunner(_realHostProbeOutput);
      final service = FakeSSHService();
      service.queueConnectSuccess(
        SSHConnectionResult(
          client: _buildFakeClient(),
          session: FakeSSHSession(),
        ),
      );
      final commands = <String>[];
      final session = TerminalSession(
        profile: _profile(multiplexer: 'zellij'),
        sshService: service,
        tmuxSessionName: 'helm-0',
        terminal: RecordingTerminal(),
        muxAdapter: _StubAdapter(),
        hostRunnerFactory: (_) => runner,
        attachOpener: (client, command, pty) async {
          commands.add(command);
          return FakeSSHSession();
        },
      );

      return session.connect('key').then((_) {
        expect(commands, ['stub-attach helm-0']);
        expect(runner.runScriptCalls, isEmpty);
      });
    });
  });

  group('TerminalSession.connect — discloses a substitution', () {
    test('does not silently run a different multiplexer', () async {
      final terminal = RecordingTerminal();
      final result = await _connect(
        profile: _profile(multiplexer: 'zellij'),
        runner: _probeRunner(_realHostProbeOutput),
        terminal: terminal,
      );

      // It still attaches — refusing would leave the user with nothing —
      // but it says so, and names both sides. The stand-in is herdr, the
      // top of the host default preference, reached through the absolute
      // path the probe resolved rather than a bare name this host's
      // non-interactive PATH cannot find.
      expect(
        result.commands.single,
        startsWith('/home/deployer/.local/bin/herdr'),
      );
      final notice = terminal.writes.firstWhere(
        (w) => w.contains('zellij'),
        orElse: () => '',
      );
      expect(notice, contains('not installed'));
      expect(notice, contains('herdr'));
      expect(
        result.session.multiplexerSelection,
        isA<MultiplexerSubstituted>(),
      );
    });

    test('says nothing when the chosen multiplexer is present', () async {
      final terminal = RecordingTerminal();
      await _connect(
        profile: _profile(multiplexer: 'tmux'),
        runner: _probeRunner(_realHostProbeOutput),
        terminal: terminal,
      );

      expect(
        terminal.writes.where((w) => w.contains('not installed')),
        isEmpty,
      );
    });

    test('reports when the host has no known multiplexer at all', () async {
      final terminal = RecordingTerminal();
      await _connect(
        profile: _profile(multiplexer: 'tmux'),
        runner: _probeRunner(
          'helm-probe/1\n'
          'mux\therdr\t0\t\t\t0\n'
          'mux\ttmux\t0\t\t\t0\n'
          'mux\tzellij\t0\t\t\t0\n'
          'end\tok\t40',
        ),
        terminal: terminal,
      );

      expect(
        terminal.writes.any((w) => w.contains('No supported multiplexer')),
        isTrue,
      );
    });
  });

  group('TerminalSession.connect — a failed probe never blocks a session', () {
    test('still attaches when the probe throws', () async {
      // FakeHostCommandRunner throws StateError for an unregistered
      // script, standing in for a transport that drops mid-probe.
      final result = await _connect(runner: FakeHostCommandRunner());

      // No probe answer and no persisted choice, so the host default leads:
      // herdr, under a bare binary name because nothing was resolved.
      expect(result.commands, ["herdr session attach 'helm-0'"]);
      expect(result.session.status.name, 'connected');
    });

    test('an unverified report is never reported as a missing multiplexer', () async {
      final terminal = RecordingTerminal();
      final result = await _connect(
        profile: _profile(multiplexer: 'zellij'),
        runner: FakeHostCommandRunner(),
        terminal: terminal,
      );

      // The probe could not report. That is NOT evidence zellij is absent,
      // so the user must not be told it is — and the attach proceeds with
      // the multiplexer they chose, exactly as before the probe existed.
      expect(
        result.session.multiplexerSelection,
        isA<MultiplexerUnverified>(),
      );
      expect(
        terminal.writes.where((w) => w.contains('not installed')),
        isEmpty,
      );
      expect(result.commands, ["zellij attach --create 'helm-0'"]);
    });

    test('a timed-out probe leaves the session connected', () async {
      final runner = FakeHostCommandRunner();
      runner.whenRunScript(
        probeScriptV1,
        const HostCommandResult(stdout: 'helm-probe/1\n', timedOut: true),
      );

      final result = await _connect(runner: runner);

      expect(result.session.status.name, 'connected');
      expect(
        result.session.hostReport!.status,
        HostReportStatus.truncated,
      );
    });
  });

  group('TerminalSession — advisories survive the multiplexer redraw', () {
    // The connect-time terminal notice is written into the same buffer the
    // multiplexer is about to take over. Verified on a real host: tmux
    // clears the screen on attach, so the notice is gone before the user
    // can read it. The finding therefore has to live somewhere the attach
    // cannot erase — published here, rendered by the UI.
    test('publishes a substitution as soon as the probe resolves', () async {
      final result = await _connect(
        profile: _profile(multiplexer: 'zellij'),
        runner: _probeRunner(_realHostProbeOutput),
      );

      expect(
        result.session.advisoriesNotifier.value.map((a) => a.id),
        contains(HostAdvisoryId.multiplexerSubstituted),
      );
    });

    test('publishes an off-PATH finding for the selected multiplexer', () async {
      final result = await _connect(
        profile: _profile(multiplexer: 'herdr'),
        runner: _probeRunner(_realHostProbeOutput),
      );

      expect(
        result.session.advisoriesNotifier.value.map((a) => a.id),
        contains(HostAdvisoryId.multiplexerOffPath),
      );
    });

    test('costs no host round-trips beyond the probe itself', () async {
      // Diagnostics are NOT run here: a healthy connect must not pay for
      // four extra commands. FakeHostCommandRunner throws for any
      // unregistered command, so a diagnostic slipping in fails loudly.
      final runner = _probeRunner(_realHostProbeOutput);

      await _connect(profile: _profile(multiplexer: 'zellij'), runner: runner);

      expect(runner.runCalls, isEmpty);
    });
  });

  group('TerminalSession — advisories reach the failure path', () {
    test('a healthy connect surfaces nothing', () async {
      final result = await _connect(
        profile: _profile(multiplexer: 'tmux'),
        runner: _probeRunner(_realHostProbeOutput),
      );

      expect(result.session.advisoriesNotifier.value, isEmpty);
    });

    test('a substitution is published when the session drops', () async {
      final service = FakeSSHService();
      service.queueConnectSuccess(
        SSHConnectionResult(
          client: _buildFakeClient(),
          session: FakeSSHSession(),
        ),
      );
      final attachSession = FakeSSHSession();
      // Registered so the diagnostics pass finds a clean host; the
      // substitution must still come through.
      final runner = _probeRunner(_realHostProbeOutput);
      runner.whenRun(
        'command -v tailscale >/dev/null 2>&1',
        const HostCommandResult(exitCode: 1),
      );
      runner.whenRun(
        'command -v loginctl >/dev/null 2>&1',
        const HostCommandResult(exitCode: 0),
      );
      runner.whenRun(
        r'loginctl show-user $(id -un) --property=Linger',
        const HostCommandResult(stdout: 'Linger=yes', exitCode: 0),
      );

      final session = TerminalSession(
        profile: _profile(multiplexer: 'zellij'),
        sshService: service,
        tmuxSessionName: 'helm-0',
        terminal: RecordingTerminal(),
        hostRunnerFactory: (_) => runner,
        attachOpener: (client, command, pty) async => attachSession,
      );
      await session.connect('key');

      await attachSession.endWithExitCode(1);
      // The collect is kicked off without blocking the disconnect path.
      await Future.delayed(const Duration(milliseconds: 20));

      expect(
        session.advisoriesNotifier.value.map((a) => a.id),
        contains(HostAdvisoryId.multiplexerSubstituted),
      );
    });

    test('host diagnostics reach the user when the session drops', () async {
      final service = FakeSSHService();
      service.queueConnectSuccess(
        SSHConnectionResult(
          client: _buildFakeClient(),
          session: FakeSSHSession(),
        ),
      );
      final attachSession = FakeSSHSession();
      final runner = _probeRunner(_realHostProbeOutput);
      runner.whenRun(
        'command -v tailscale >/dev/null 2>&1',
        const HostCommandResult(exitCode: 1),
      );
      runner.whenRun(
        'command -v loginctl >/dev/null 2>&1',
        const HostCommandResult(exitCode: 0),
      );
      runner.whenRun(
        r'loginctl show-user $(id -un) --property=Linger',
        const HostCommandResult(stdout: 'Linger=no', exitCode: 0),
      );
      runner.whenRun(
        "grep -E '^[[:space:]]*KillUserProcesses[[:space:]]*=' "
        '/etc/systemd/logind.conf',
        const HostCommandResult(stdout: 'KillUserProcesses=yes', exitCode: 0),
      );

      final session = TerminalSession(
        profile: _profile(multiplexer: 'tmux'),
        sshService: service,
        tmuxSessionName: 'helm-0',
        terminal: RecordingTerminal(),
        hostRunnerFactory: (_) => runner,
        attachOpener: (client, command, pty) async => attachSession,
      );
      await session.connect('key');

      await attachSession.endWithExitCode(1);
      await Future.delayed(const Duration(milliseconds: 20));

      expect(
        session.advisoriesNotifier.value.map((a) => a.id),
        contains(HostAdvisoryId.sessionsMayDieOnLogout),
      );
    });

    test('a failed connect publishes without needing a live host', () async {
      final service = FakeSSHService();
      service.queueConnectError(StateError('refused'));
      final session = TerminalSession(
        profile: _profile(),
        sshService: service,
        tmuxSessionName: 'helm-0',
        terminal: RecordingTerminal(),
        hostRunnerFactory: (_) => FakeHostCommandRunner(),
      );

      await expectLater(session.connect('key'), throwsA(isA<StateError>()));
      await Future.delayed(const Duration(milliseconds: 20));

      // Nothing to report — there was never a host to ask — but the
      // collect must not have thrown either.
      expect(session.advisoriesNotifier.value, isEmpty);
    });
  });

  group('TerminalSession — advisory collection outlives nothing', () {
    test('does not publish after dispose', () async {
      // Observed on a real device: closing a tab disposes the session
      // while the advisory collect is still awaiting host round-trips.
      // The late .then() then wrote to a disposed ValueNotifier and threw
      // "used after being disposed" into the zone.
      final service = FakeSSHService();
      service.queueConnectSuccess(
        SSHConnectionResult(
          client: _buildFakeClient(),
          session: FakeSSHSession(),
        ),
      );
      final attachSession = FakeSSHSession();
      final runner = _SlowDiagnosticsRunner(_realHostProbeOutput);

      final session = TerminalSession(
        profile: _profile(multiplexer: 'zellij'),
        sshService: service,
        tmuxSessionName: 'helm-0',
        terminal: RecordingTerminal(),
        hostRunnerFactory: (_) => runner,
        attachOpener: (client, command, pty) async => attachSession,
      );

      final errors = <Object>[];
      await runZonedGuarded(() async {
        await session.connect('key');
        // Kicks off _publishAdvisories, which is deliberately not awaited.
        await attachSession.endWithExitCode(1);
        // Dispose lands while the collect is still blocked on the host.
        await session.dispose();
        runner.release();
        await Future.delayed(const Duration(milliseconds: 60));
      }, (error, _) => errors.add(error));

      expect(errors, isEmpty);
    });
  });

  group('TerminalSession — host state is bound to the live connection', () {
    test('exposes a runner while connected', () async {
      final result = await _connect(runner: _probeRunner(_realHostProbeOutput));

      expect(result.session.hostRunner, isNotNull);
    });

    test('drops the runner on dispose so no caller reaches a dead client', () async {
      final result = await _connect(runner: _probeRunner(_realHostProbeOutput));

      await result.session.dispose();

      expect(result.session.hostRunner, isNull);
    });
  });

  group('TerminalSession.connect — no session reference', () {
    test('does not probe when there is nothing to attach to', () async {
      final runner = _probeRunner(_realHostProbeOutput);
      final service = FakeSSHService();
      service.queueConnectSuccess(
        SSHConnectionResult(
          client: _buildFakeClient(),
          session: FakeSSHSession(),
        ),
      );
      final session = TerminalSession(
        profile: _profile(),
        sshService: service,
        terminal: RecordingTerminal(),
        hostRunnerFactory: (_) => runner,
      );

      await session.connect('key');

      // Nothing to select, so nothing to pay for.
      expect(runner.runScriptCalls, isEmpty);
      expect(session.hostReport, isNull);
    });
  });
}

/// Minimal [MultiplexerAdapter] proving an explicit override is used
/// verbatim instead of anything the probe would have chosen.
class _StubAdapter implements MultiplexerAdapter {
  @override
  MultiplexerId get id => MultiplexerId.tmux;

  @override
  Set<MuxCapability> get capabilities => const {};

  @override
  AgentAwareMultiplexer? get agents => null;

  @override
  Future<MuxDetection> detect() async => const MuxDetection.notInstalled();

  @override
  Future<MuxSessionsResult> listSessions() async =>
      const MuxSessionsAvailable([]);

  @override
  Future<bool> hasSession(String name) async => false;

  @override
  String attachCommand(String sessionName) => 'stub-attach $sessionName';
}

/// Answers the probe immediately but BLOCKS every diagnostic command until
/// [release] is called, so a test can dispose the session at a precisely
/// chosen point while HostAdvisor.collect is still awaiting the host.
class _SlowDiagnosticsRunner implements HostCommandRunner {
  _SlowDiagnosticsRunner(this._probeStdout);

  final String _probeStdout;
  final _gate = Completer<void>();

  /// Lets the stalled diagnostic commands finish.
  void release() => _gate.complete();

  @override
  Future<HostCommandResult> run(String command, {Duration? timeout}) async {
    await _gate.future;
    return const HostCommandResult(exitCode: 1);
  }

  @override
  Future<HostCommandResult> runScript(String script, {Duration? timeout}) async =>
      HostCommandResult(stdout: _probeStdout, exitCode: 0);
}
