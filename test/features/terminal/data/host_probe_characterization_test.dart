// Characterization of the host probe, pinned through the PUBLIC surface of
// TerminalSession only: `hostReport`, `multiplexerSelection`, the notice
// written to the terminal, `advisoriesNotifier`, and the commands the fake
// host runner records when the adapter the probe chose is asked to work.
//
// These tests describe what the code does TODAY, value for value, so the
// extraction of the probe into its own class can be proven behavior-
// preserving. `terminal_session_probe_test.dart` pins the same ground with
// `isA<T>` in several places; each case here is the exact-value companion,
// not a replacement.
//
// Which adapter drives the session is observed through the runner, not
// through a type check: the probe builds its adapter over the host runner,
// so the exact command an agent or focus call sends names the multiplexer,
// the absolute path and the session scope that were chosen.
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_advisory.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/multiplexer_selection.dart';
import 'package:helm/core/host/probe/host_report.dart';
import 'package:helm/core/host/probe/probe_script_v1.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:xterm/xterm.dart';

import '../../../helpers/fake_agent_adapter.dart';
import '../../../helpers/fake_host_command_runner.dart';
import '../../../helpers/fake_ssh_service.dart';
import '../../../helpers/fake_ssh_session.dart';

class _RecordingTerminal extends Terminal {
  _RecordingTerminal() : super(maxLines: 500);

  final List<String> writes = [];

  @override
  void write(String data) => writes.add(data);
}

const _secureStorageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

ConnectionProfile _profile({String? multiplexer}) => ConnectionProfile(
  id: 'profile-1',
  name: 'Test Host',
  host: 'example.test',
  username: 'tester',
  multiplexer: multiplexer,
);

SSHClient _buildFakeClient() => SSHClient(FakeSSHSocket(), username: 'tester');

/// tmux on PATH, herdr installed but off the inherited PATH, no zellij.
const _realHostProbeOutput =
    'helm-probe/1\n'
    'env\tpath_inherited\t/usr/local/bin:/usr/bin:/bin\n'
    'mux\therdr\t1\t/home/deployer/.local/bin/herdr\therdr 0.8.0\t0\n'
    'mux\ttmux\t1\t/usr/bin/tmux\ttmux 3.4\t1\n'
    'mux\tzellij\t0\t\t\t0\n'
    'session\ttmux\thelm-0\tactive\t0\n'
    'end\tok\t120';

/// Only zellij and tmux, both on the inherited PATH.
const _zellijHostProbeOutput =
    'helm-probe/1\n'
    'mux\therdr\t0\t\t\t0\n'
    'mux\ttmux\t1\t/usr/bin/tmux\ttmux 3.4\t1\n'
    'mux\tzellij\t1\t/usr/bin/zellij\tzellij 0.44.3\t1\n'
    'end\tok\t80';

/// The probe ran and found nothing at all.
const _emptyHostProbeOutput =
    'helm-probe/1\n'
    'mux\therdr\t0\t\t\t0\n'
    'mux\ttmux\t0\t\t\t0\n'
    'mux\tzellij\t0\t\t\t0\n'
    'end\tok\t40';

FakeHostCommandRunner _probeRunner(String stdout) {
  final runner = FakeHostCommandRunner();
  runner.whenRunScript(
    probeScriptV1,
    HostCommandResult(stdout: stdout, exitCode: 0),
  );
  return runner;
}

/// A runner whose probe throws, standing in for a transport that drops
/// mid-probe.
FakeHostCommandRunner _throwingRunner() => FakeHostCommandRunner();

class _Fixture {
  _Fixture(
    this.session,
    this.service,
    this.terminal,
    this.commands,
    this.drops,
  );

  final TerminalSession session;
  final FakeSSHService service;
  final _RecordingTerminal terminal;
  final List<String> commands;
  final List<FakeSSHSession> drops;
}

Future<_Fixture> _connect({
  required FakeHostCommandRunner runner,
  String? multiplexer,
  String? sessionName = 'helm-0',
  MultiplexerAdapter? muxAdapter,
}) async {
  final service = FakeSSHService();
  service.queueConnectSuccess(
    SSHConnectionResult(client: _buildFakeClient(), session: FakeSSHSession()),
  );
  final terminal = _RecordingTerminal();
  final commands = <String>[];
  final attaches = <FakeSSHSession>[];
  final session = TerminalSession(
    profile: _profile(multiplexer: multiplexer),
    sshService: service,
    tmuxSessionName: sessionName,
    terminal: terminal,
    muxAdapter: muxAdapter,
    hostRunnerFactory: (_) => runner,
    attachOpener: (client, command, pty) async {
      commands.add(command);
      final attach = FakeSSHSession();
      attaches.add(attach);
      return attach;
    },
  );
  await session.connect('key');
  return _Fixture(session, service, terminal, commands, attaches);
}

/// Registers a successful answer for the exact herdr focus [command].
void _answerFocus(FakeHostCommandRunner runner, String command) =>
    runner.whenRun(command, const HostCommandResult(exitCode: 0));

String _describe(MultiplexerSelection? s) => switch (s) {
  null => 'null',
  MultiplexerVerified() =>
    'Verified(${s.id.name}, ${s.absPath}, inherited=${s.onInheritedPath})',
  MultiplexerSubstituted() =>
    'Substituted(requested=${s.requested.name}, ${s.id.name}, ${s.absPath}, '
        'inherited=${s.onInheritedPath}, '
        'available=${s.available.map((m) => m.name).toList()})',
  MultiplexerNoneFound() =>
    'NoneFound(requested=${s.requested?.name}, ${s.id.name}, ${s.absPath})',
  MultiplexerUnverified() => 'Unverified(${s.id.name}, ${s.absPath})',
};

List<String> _notices(_RecordingTerminal t) =>
    t.writes.where((w) => w.startsWith('\r\n[Helm] ')).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('herdr is selected', () {
    test('exact report, selection, no notice, and herdr drives focus '
        'through its absolute path scoped to the attached session', () async {
      final runner = _probeRunner(_realHostProbeOutput);
      final f = await _connect(runner: runner, multiplexer: 'herdr');

      final report = f.session.hostReport!;
      expect(report.status, HostReportStatus.ok);
      expect(report.mux, [
        (
          id: 'herdr',
          found: true,
          absPath: '/home/deployer/.local/bin/herdr',
          version: 'herdr 0.8.0',
          onInheritedPath: false,
        ),
        (
          id: 'tmux',
          found: true,
          absPath: '/usr/bin/tmux',
          version: 'tmux 3.4',
          onInheritedPath: true,
        ),
        (
          id: 'zellij',
          found: false,
          absPath: '',
          version: '',
          onInheritedPath: false,
        ),
      ]);
      expect(report.sessions, [
        (muxId: 'tmux', name: 'helm-0', state: 'active', attached: '0'),
      ]);
      expect(
        _describe(f.session.multiplexerSelection),
        'Verified(herdr, /home/deployer/.local/bin/herdr, inherited=false)',
      );
      expect(_notices(f.terminal), isEmpty);
      expect(f.commands, [
        "/home/deployer/.local/bin/herdr session attach 'helm-0'",
      ]);

      const focus =
          "/home/deployer/.local/bin/herdr --session 'helm-0' "
          "agent focus 'w1:p1'";
      _answerFocus(runner, focus);
      final result = await f.session.focusAgent('w1:p1');

      expect(result, isA<MuxAgentFocused>());
      expect(runner.runCalls, [focus]);
      await f.session.dispose();
    });

    test('publishes only the off-PATH advisory, exactly', () async {
      final f = await _connect(
        runner: _probeRunner(_realHostProbeOutput),
        multiplexer: 'herdr',
      );

      final advisories = f.session.advisoriesNotifier.value;
      expect(advisories.map((a) => a.id).toList(), [
        HostAdvisoryId.multiplexerOffPath,
      ]);
      await f.session.dispose();
    });
  });

  group('tmux is selected', () {
    test('exact selection, no notice, and the adapter cannot focus an '
        'agent so the runner is never asked', () async {
      final runner = _probeRunner(_realHostProbeOutput);
      final f = await _connect(runner: runner, multiplexer: 'tmux');

      expect(
        _describe(f.session.multiplexerSelection),
        'Verified(tmux, /usr/bin/tmux, inherited=true)',
      );
      expect(f.session.hostReport!.status, HostReportStatus.ok);
      expect(_notices(f.terminal), isEmpty);
      expect(f.session.advisoriesNotifier.value, isEmpty);
      expect(f.commands, ["/usr/bin/tmux new-session -A -s 'helm-0'"]);

      final result = await f.session.focusAgent('w1:p1');

      expect(result, isA<MuxAgentFocusFailed>());
      expect((result as MuxAgentFocusFailed).code, 'multiplexer_cannot_focus');
      expect(runner.runCalls, isEmpty);
      await f.session.dispose();
    });
  });

  group('zellij is selected', () {
    test('exact selection, no notice, and the adapter cannot focus an '
        'agent so the runner is never asked', () async {
      final runner = _probeRunner(_zellijHostProbeOutput);
      final f = await _connect(runner: runner, multiplexer: 'zellij');

      expect(
        _describe(f.session.multiplexerSelection),
        'Verified(zellij, /usr/bin/zellij, inherited=true)',
      );
      expect(_notices(f.terminal), isEmpty);
      expect(f.commands, ["/usr/bin/zellij attach --create 'helm-0'"]);

      final result = await f.session.focusAgent('w1:p1');

      expect((result as MuxAgentFocusFailed).code, 'multiplexer_cannot_focus');
      expect(runner.runCalls, isEmpty);
      await f.session.dispose();
    });
  });

  group('no persisted choice', () {
    test('takes the host default without announcing a substitution', () async {
      final runner = _probeRunner(_zellijHostProbeOutput);
      final f = await _connect(runner: runner);

      // herdr is absent, so the best available is tmux; nothing was
      // overridden, so nothing is said.
      expect(
        _describe(f.session.multiplexerSelection),
        'Verified(tmux, /usr/bin/tmux, inherited=true)',
      );
      expect(_notices(f.terminal), isEmpty);
      expect(f.commands, ["/usr/bin/tmux new-session -A -s 'helm-0'"]);
      await f.session.dispose();
    });
  });

  group('the requested multiplexer is absent but another is present', () {
    test('exact selection, the exact notice, the exact advisories, and the '
        'substitute drives focus', () async {
      final runner = _probeRunner(_realHostProbeOutput);
      final f = await _connect(runner: runner, multiplexer: 'zellij');

      expect(
        _describe(f.session.multiplexerSelection),
        'Substituted(requested=zellij, herdr, '
        '/home/deployer/.local/bin/herdr, inherited=false, '
        'available=[herdr, tmux])',
      );
      expect(f.session.hostReport!.status, HostReportStatus.ok);
      expect(_notices(f.terminal), [
        '\r\n[Helm] zellij is not installed on this host - '
            'attaching with herdr instead. Available: herdr, tmux.\r\n',
      ]);
      expect(f.session.advisoriesNotifier.value.map((a) => a.id).toList(), [
        HostAdvisoryId.multiplexerSubstituted,
        HostAdvisoryId.multiplexerOffPath,
      ]);
      expect(
        f.session.advisoriesNotifier.value.first.title,
        'zellij is not installed',
      );
      expect(f.commands, [
        "/home/deployer/.local/bin/herdr session attach 'helm-0'",
      ]);

      const focus =
          "/home/deployer/.local/bin/herdr --session 'helm-0' "
          "agent focus 'w1:p1'";
      _answerFocus(runner, focus);
      expect(await f.session.focusAgent('w1:p1'), isA<MuxAgentFocused>());
      expect(runner.runCalls, [focus]);
      await f.session.dispose();
    });

    test('the notice is the only [Helm] line the probe writes', () async {
      final f = await _connect(
        runner: _probeRunner(_realHostProbeOutput),
        multiplexer: 'zellij',
      );

      expect(f.terminal.writes.where((w) => w.contains('[Helm]')).toList(), [
        '\r\n[Helm] zellij is not installed on this host - '
            'attaching with herdr instead. Available: herdr, tmux.\r\n',
      ]);
      await f.session.dispose();
    });
  });

  group('the host has no known multiplexer', () {
    test('exact selection, the exact notice and advisory, and the bare '
        'binary name drives the attach', () async {
      final runner = _probeRunner(_emptyHostProbeOutput);
      final f = await _connect(runner: runner, multiplexer: 'tmux');

      expect(f.session.hostReport!.status, HostReportStatus.ok);
      expect(
        _describe(f.session.multiplexerSelection),
        'NoneFound(requested=tmux, tmux, null)',
      );
      expect(_notices(f.terminal), [
        '\r\n[Helm] No supported multiplexer was found on this host '
            '(looked for herdr, tmux, zellij). Attaching with tmux anyway.'
            '\r\n',
      ]);
      expect(f.session.advisoriesNotifier.value.map((a) => a.id).toList(), [
        HostAdvisoryId.multiplexerMissing,
      ]);
      expect(f.commands, ["tmux new-session -A -s 'helm-0'"]);

      final result = await f.session.focusAgent('w1:p1');
      expect((result as MuxAgentFocusFailed).code, 'multiplexer_cannot_focus');
      expect(runner.runCalls, isEmpty);
      await f.session.dispose();
    });

    test('with no choice, the herdr default is named and drives focus under '
        'a bare binary name', () async {
      final runner = _probeRunner(_emptyHostProbeOutput);
      final f = await _connect(runner: runner);

      expect(
        _describe(f.session.multiplexerSelection),
        'NoneFound(requested=null, herdr, null)',
      );
      expect(_notices(f.terminal), [
        '\r\n[Helm] No supported multiplexer was found on this host '
            '(looked for herdr, tmux, zellij). Attaching with herdr anyway.'
            '\r\n',
      ]);

      const focus = "herdr --session 'helm-0' agent focus 'w1:p1'";
      _answerFocus(runner, focus);
      expect(await f.session.focusAgent('w1:p1'), isA<MuxAgentFocused>());
      expect(runner.runCalls, [focus]);
      await f.session.dispose();
    });
  });

  group('the probe fails', () {
    test('a throwing probe publishes the exact truncated report, an '
        'unverified selection, and no notice', () async {
      final runner = _throwingRunner();
      final f = await _connect(runner: runner, multiplexer: 'zellij');

      expect(
        f.session.hostReport,
        const HostReport(status: HostReportStatus.truncated),
      );
      expect(f.session.hostReport!.mux, isEmpty);
      expect(f.session.hostReport!.sessions, isEmpty);
      expect(
        _describe(f.session.multiplexerSelection),
        'Unverified(zellij, null)',
      );
      expect(f.terminal.writes.where((w) => w.contains('[Helm]')), isEmpty);
      expect(f.session.advisoriesNotifier.value, isEmpty);
      expect(f.commands, ["zellij attach --create 'helm-0'"]);
      expect(f.session.status, ConnectionStatus.connected);
      expect(runner.runScriptCalls, [probeScriptV1]);
      await f.session.dispose();
    });

    test('a failed probe with no choice leaves the herdr default under a '
        'bare name, and it still drives focus', () async {
      final runner = _throwingRunner();
      final f = await _connect(runner: runner);

      expect(
        _describe(f.session.multiplexerSelection),
        'Unverified(herdr, null)',
      );
      expect(f.commands, ["herdr session attach 'helm-0'"]);

      const focus = "herdr --session 'helm-0' agent focus 'w1:p1'";
      _answerFocus(runner, focus);
      expect(await f.session.focusAgent('w1:p1'), isA<MuxAgentFocused>());
      expect(runner.runCalls, [focus]);
      await f.session.dispose();
    });

    test('a timed-out probe publishes the exact truncated report and an '
        'unverified selection', () async {
      final runner = FakeHostCommandRunner();
      runner.whenRunScript(
        probeScriptV1,
        const HostCommandResult(stdout: 'helm-probe/1\n', timedOut: true),
      );
      final f = await _connect(runner: runner, multiplexer: 'tmux');

      expect(f.session.hostReport!.status, HostReportStatus.truncated);
      expect(f.session.hostReport!.mux, isEmpty);
      expect(
        _describe(f.session.multiplexerSelection),
        'Unverified(tmux, null)',
      );
      expect(f.terminal.writes.where((w) => w.contains('[Helm]')), isEmpty);
      expect(f.commands, ["tmux new-session -A -s 'helm-0'"]);
      expect(f.session.status, ConnectionStatus.connected);
      await f.session.dispose();
    });
  });

  group('the probe does not run', () {
    test('without a session reference nothing is published and the default '
        'adapter keeps refusing to focus', () async {
      final runner = _probeRunner(_realHostProbeOutput);
      final f = await _connect(runner: runner, sessionName: null);

      expect(f.session.hostReport, isNull);
      expect(f.session.multiplexerSelection, isNull);
      expect(f.session.advisoriesNotifier.value, isEmpty);
      expect(f.terminal.writes.where((w) => w.contains('[Helm]')), isEmpty);
      expect(runner.runScriptCalls, isEmpty);

      final result = await f.session.focusAgent('w1:p1');
      expect((result as MuxAgentFocusFailed).code, 'multiplexer_cannot_focus');
      expect(runner.runCalls, isEmpty);
      await f.session.dispose();
    });

    test('an explicit adapter skips the probe: nothing published, nothing '
        'written, and the adapter given is the one asked', () async {
      final runner = _probeRunner(_realHostProbeOutput);
      final adapter = FakeAgentAdapter();
      final f = await _connect(
        runner: runner,
        multiplexer: 'zellij',
        muxAdapter: adapter,
      );

      expect(f.session.hostReport, isNull);
      expect(f.session.multiplexerSelection, isNull);
      expect(f.terminal.writes.where((w) => w.contains('[Helm]')), isEmpty);
      expect(f.commands, ['fake-attach helm-0']);

      expect(await f.session.focusAgent('w1:p1'), isA<MuxAgentFocused>());
      expect(adapter.focusTargets, ['w1:p1']);
      expect(runner.runCalls, isEmpty);
      await f.session.dispose();
    });
  });

  group('the published state is bound to the connection', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_secureStorageChannel, null);
    });

    test('a drop keeps the report and the selection', () async {
      final f = await _connect(
        runner: _probeRunner(_realHostProbeOutput),
        multiplexer: 'herdr',
      );
      final report = f.session.hostReport;
      final selection = f.session.multiplexerSelection;

      await f.drops.last.endWithExitCode(0);
      await pumpEventQueue();

      expect(f.session.status, ConnectionStatus.disconnected);
      expect(identical(f.session.hostReport, report), isTrue);
      expect(identical(f.session.multiplexerSelection, selection), isTrue);
      await f.session.dispose();
    });

    test('dispose resets both to null', () async {
      final f = await _connect(
        runner: _probeRunner(_realHostProbeOutput),
        multiplexer: 'herdr',
      );
      expect(f.session.hostReport, isNotNull);
      expect(f.session.multiplexerSelection, isNotNull);

      await f.session.dispose();

      expect(f.session.hostReport, isNull);
      expect(f.session.multiplexerSelection, isNull);
    });

    test('reconnect resets both to null before it looks for a key', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_secureStorageChannel, (call) async {
            return null;
          });
      final f = await _connect(
        runner: _probeRunner(_realHostProbeOutput),
        multiplexer: 'herdr',
      );
      f.session.statusNotifier.value = ConnectionStatus.disconnected;
      expect(f.session.hostReport, isNotNull);
      expect(f.session.multiplexerSelection, isNotNull);

      await f.session.reconnect();

      expect(
        f.terminal.writes,
        contains('[Helm] No SSH key found - cannot reconnect\r\n'),
      );
      expect(f.session.hostReport, isNull);
      expect(f.session.multiplexerSelection, isNull);
      expect(f.session.hostRunner, isNull);
      await f.session.dispose();
    });

    test('a reconnect that finds a key probes again and publishes the new '
        'outcome', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_secureStorageChannel, (call) async {
            return call.method == 'read' ? 'stored-pem-key' : null;
          });
      final first = _probeRunner(_realHostProbeOutput);
      final second = _probeRunner(_zellijHostProbeOutput);
      final runners = [first, second];
      final service = FakeSSHService();
      service.queueConnectSuccess(
        SSHConnectionResult(
          client: _buildFakeClient(),
          session: FakeSSHSession(),
        ),
      );
      final commands = <String>[];
      final session = TerminalSession(
        profile: _profile(multiplexer: 'herdr'),
        sshService: service,
        tmuxSessionName: 'helm-0',
        terminal: _RecordingTerminal(),
        hostRunnerFactory: (_) => runners.removeAt(0),
        attachOpener: (client, command, pty) async {
          commands.add(command);
          return FakeSSHSession();
        },
      );
      await session.connect('key');
      expect(
        _describe(session.multiplexerSelection),
        'Verified(herdr, /home/deployer/.local/bin/herdr, inherited=false)',
      );
      session.statusNotifier.value = ConnectionStatus.disconnected;
      service.queueConnectSuccess(
        SSHConnectionResult(
          client: _buildFakeClient(),
          session: FakeSSHSession(),
        ),
      );

      await session.reconnect();

      // herdr is absent on the second host, so the choice is substituted.
      expect(
        _describe(session.multiplexerSelection),
        'Substituted(requested=herdr, tmux, /usr/bin/tmux, inherited=true, '
        'available=[tmux, zellij])',
      );
      expect(commands.last, "/usr/bin/tmux new-session -A -s 'helm-0'");
      expect(first.runScriptCalls, [probeScriptV1]);
      expect(second.runScriptCalls, [probeScriptV1]);
      await session.dispose();
    });
  });
}
