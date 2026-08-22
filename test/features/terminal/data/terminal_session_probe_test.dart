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
      // but it says so, and names both sides.
      expect(result.commands.single, startsWith('/usr/bin/tmux'));
      final notice = terminal.writes.firstWhere(
        (w) => w.contains('zellij'),
        orElse: () => '',
      );
      expect(notice, contains('not installed'));
      expect(notice, contains('tmux'));
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

      expect(result.commands, ["tmux new-session -A -s 'helm-0'"]);
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
