// Pins the ORDER of the connect-time host probe's effects, through the
// public surface only: the host runner, `advisoriesNotifier`, the terminal
// write, the attach opener and `statusNotifier`.
//
// The characterization tests pin outcomes. This one pins the sequence:
// probe script, then (report, selection, adapter adoption), then advisories
// published, then the terminal notice, then the attach, then `connected`.
//
// Report, selection and adapter adoption happen synchronously with no
// public hook between them, so they are observed as snapshots taken at the
// next observable event. A snapshot is taken INSIDE each event callback:
// whether `hostReport`/`multiplexerSelection` are already published, and
// whether the adapter is already adopted (a herdr focus call reaches the
// host runner only when the herdr adapter, not the unconnected default, is
// the live one). The relative order of report/selection/adoption among
// themselves is therefore NOT distinguishable from outside and is not
// claimed.
import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/probe/probe_script_v1.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:xterm/xterm.dart';

import '../../../helpers/fake_host_command_runner.dart';
import '../../../helpers/fake_ssh_service.dart';
import '../../../helpers/fake_ssh_session.dart';

const _bound = Duration(seconds: 10);

// herdr off the inherited PATH, tmux on it; the profile asks for zellij,
// which is absent, so the selection is substituted: advisories AND a
// notice are produced, and herdr's focus reaches the runner.
const _output =
    'helm-probe/1\n'
    'env\tpath_inherited\t/usr/local/bin:/usr/bin:/bin\n'
    'mux\therdr\t1\t/home/deployer/.local/bin/herdr\therdr 0.8.0\t0\n'
    'mux\ttmux\t1\t/usr/bin/tmux\ttmux 3.4\t1\n'
    'mux\tzellij\t0\t\t\t0\n'
    'end\tok\t120';

const _focus =
    "/home/deployer/.local/bin/herdr --session 'helm-0' agent focus 'w1:p1'";

class _TracingRunner extends FakeHostCommandRunner {
  _TracingRunner(this.trace);
  final List<String> trace;

  @override
  Future<HostCommandResult> runScript(String script, {Duration? timeout}) {
    trace.add('probe-script');
    return super.runScript(script, timeout: timeout);
  }
}

class _TracingTerminal extends Terminal {
  _TracingTerminal(this.onWrite) : super(maxLines: 500);
  final void Function(String data) onWrite;

  @override
  void write(String data) {
    onWrite(data);
    super.write(data);
  }
}

void main() {
  test('probe effects happen in the pinned order during connect', () async {
    final trace = <String>[];
    final runner = _TracingRunner(trace)
      ..whenRunScript(
        probeScriptV1,
        const HostCommandResult(stdout: _output, exitCode: 0),
      )
      ..whenRun(_focus, const HostCommandResult(exitCode: 0));

    late final TerminalSession session;

    // What is already true at this instant, from the outside.
    var probing = false;
    // focusAgent holds an in-flight guard until its request settles, so
    // adoption can be sampled once, at the first event that can see it.
    // Later events only repeat the report/selection snapshot; the adopted
    // adapter is then confirmed by the attach command itself.
    var adoptionSampled = false;
    String snapshot() {
      var adopted = 'n/a';
      if (!adoptionSampled) {
        adoptionSampled = true;
        final before = runner.runCalls.length;
        // focusAgent refuses unless the session is connected, so the
        // status is lifted for this one synchronous call and restored. The
        // herdr adapter reaches the runner synchronously; the default
        // unconnected adapter refuses without touching it.
        final previous = session.status;
        probing = true;
        session.statusNotifier.value = ConnectionStatus.connected;
        unawaited(session.focusAgent('w1:p1'));
        session.statusNotifier.value = previous;
        probing = false;
        adopted = '${runner.runCalls.length > before}';
      }
      return '{report=${session.hostReport != null}, '
          'selection=${session.multiplexerSelection != null}, '
          'adopted=$adopted}';
    }

    final service = FakeSSHService()
      ..queueConnectSuccess(
        SSHConnectionResult(
          client: SSHClient(FakeSSHSocket(), username: 'tester'),
          session: FakeSSHSession(),
        ),
      );
    final terminal = _TracingTerminal((data) {
      if (data.startsWith('\r\n[Helm] ')) trace.add('notice ${snapshot()}');
    });
    session = TerminalSession(
      profile: ConnectionProfile(
        id: 'profile-1',
        name: 'Test Host',
        host: 'example.test',
        username: 'tester',
        multiplexer: 'zellij',
      ),
      sshService: service,
      tmuxSessionName: 'helm-0',
      terminal: terminal,
      hostRunnerFactory: (_) => runner,
      attachOpener: (client, command, pty) async {
        trace.add('attach ${snapshot()}');
        return FakeSSHSession();
      },
    );
    session.advisoriesNotifier.addListener(() {
      if (session.advisoriesNotifier.value.isNotEmpty) {
        trace.add('advisories ${snapshot()}');
      }
    });
    session.statusNotifier.addListener(() {
      if (!probing && session.status == ConnectionStatus.connected) {
        trace.add('connected');
      }
    });

    await session.connect('key').timeout(_bound);

    expect(trace, [
      'probe-script',
      'advisories {report=true, selection=true, adopted=true}',
      'notice {report=true, selection=true, adopted=n/a}',
      'attach {report=true, selection=true, adopted=n/a}',
      'connected',
    ]);
    expect(runner.runCalls, [_focus]);
    await session.dispose().timeout(_bound);
  });
}
