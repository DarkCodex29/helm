// A dismissed advisory must STAY dismissed across a reconnect.
//
// The reported defect, verified against a real host: dismissal lived in
// `_HostAdvisoryCardState._dismissed`. `connect()` clears
// `advisoriesNotifier` and `_resolveMultiplexer` repopulates it, which
// unmounts and remounts the card — so every reconnect resurrected every
// advisory the user had already dealt with. On a flaky link that is an
// advisory the user can never get rid of.
//
// The store therefore belongs to the SESSION, which outlives that cycle,
// and it is keyed on [HostAdvisory.dismissalKey] rather than on the
// advisory object, because the advisories themselves are rebuilt from the
// probe on every connect and are never the same instances twice.
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_advisory.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/probe/probe_script_v1.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';

import '../../../helpers/fake_host_command_runner.dart';
import '../../../helpers/fake_ssh_service.dart';
import '../../../helpers/fake_ssh_session.dart';

/// The verified real host as it behaved when this defect was reported:
/// only herdr installed, and NOT on a non-interactive shell's PATH.
///
/// A profile asking for zellij therefore raises BOTH advisories the audit
/// measured together — a substitution and an off-PATH note — which is the
/// two-at-once case the bounded surface has to survive.
const _herdrOnlyOffPathProbe =
    'helm-probe/1\n'
    'mux\therdr\t1\t/home/deployer/.local/bin/herdr\therdr 0.8.0\t0\n'
    'mux\ttmux\t0\t\t\t0\n'
    'mux\tzellij\t0\t\t\t0\n'
    'end\tok\t120';

/// The same host after tmux was installed. The substitution still fires,
/// but now says something different — tmux is preferred over herdr, so
/// the session attaches through tmux instead.
const _tmuxInstalledProbe =
    'helm-probe/1\n'
    'mux\therdr\t1\t/home/deployer/.local/bin/herdr\therdr 0.8.0\t0\n'
    'mux\ttmux\t1\t/usr/bin/tmux\ttmux 3.4\t1\n'
    'mux\tzellij\t0\t\t\t0\n'
    'end\tok\t120';

class _Fixture {
  _Fixture({required this.session, required this.ssh, required this.runner});

  final TerminalSession session;
  final FakeSSHService ssh;
  final FakeHostCommandRunner runner;

  /// Queues one more successful dial, so [TerminalSession.connect] can be
  /// called again after a disconnect.
  void queueDial() {
    ssh.queueConnectSuccess(
      SSHConnectionResult(
        client: SSHClient(FakeSSHSocket(), username: 'tester'),
        session: FakeSSHSession(),
      ),
    );
  }

  void answerProbeWith(String stdout) {
    runner.whenRunScript(
      probeScriptV1,
      HostCommandResult(stdout: stdout, exitCode: 0),
    );
  }

  /// Drops the link the way the app sees it, so [TerminalSession.connect]
  /// will run again.
  ///
  /// Flipping the status rather than calling [TerminalSession.reconnect]
  /// is the pattern already used in `terminal_session_test.dart`, and for
  /// the same reason recorded there: `reconnect()` reaches for a real
  /// `SSHKeyService()` with no injection point. What matters for this
  /// defect is reached either way — `connect()` clearing
  /// `advisoriesNotifier` and `_resolveMultiplexer` repopulating it.
  void dropLink() {
    session.statusNotifier.value = ConnectionStatus.disconnected;
  }
}

_Fixture _fixture({String? multiplexer}) {
  final ssh = FakeSSHService();
  final runner = FakeHostCommandRunner();
  final session = TerminalSession(
    profile: ConnectionProfile(
      id: 'p1',
      name: 'Test Host',
      host: 'example.test',
      username: 'tester',
      multiplexer: multiplexer,
    ),
    sshService: ssh,
    tmuxSessionName: 'helm-0',
    hostRunnerFactory: (_) => runner,
    attachOpener: (client, command, pty) async => FakeSSHSession(),
  );
  addTearDown(session.dispose);
  return _Fixture(session: session, ssh: ssh, runner: runner);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('nothing is dismissed on a fresh session', () {
    final f = _fixture();

    expect(f.session.dismissedAdvisoriesNotifier.value, isEmpty);
  });

  test('dismissing an advisory records its key', () async {
    final f = _fixture(multiplexer: 'zellij')
      ..queueDial()
      ..answerProbeWith(_herdrOnlyOffPathProbe);
    await f.session.connect('key');

    final advisory = f.session.advisoriesNotifier.value.first;
    f.session.dismissAdvisory(advisory);

    expect(
      f.session.dismissedAdvisoriesNotifier.value,
      contains(advisory.dismissalKey),
    );
  });

  test('dismissing notifies listeners, so a card can rebuild', () async {
    final f = _fixture(multiplexer: 'zellij')
      ..queueDial()
      ..answerProbeWith(_herdrOnlyOffPathProbe);
    await f.session.connect('key');

    var notified = 0;
    void listener() => notified++;
    f.session.dismissedAdvisoriesNotifier.addListener(listener);
    addTearDown(
      () => f.session.dismissedAdvisoriesNotifier.removeListener(listener),
    );

    f.session.dismissAdvisory(f.session.advisoriesNotifier.value.first);

    expect(notified, 1);
  });

  test(
    'a dismissal SURVIVES a reconnect that republishes the same advisory',
    () async {
      final f = _fixture(multiplexer: 'zellij')
        ..queueDial()
        ..answerProbeWith(_herdrOnlyOffPathProbe);
      await f.session.connect('key');

      final before = f.session.advisoriesNotifier.value
          .where((a) => a.id == HostAdvisoryId.multiplexerSubstituted)
          .single;
      f.session.dismissAdvisory(before);

      // Reconnect: connect() clears advisoriesNotifier, the probe runs
      // again, and _resolveMultiplexer republishes the same finding.
      f.dropLink();
      expect(f.session.status, ConnectionStatus.disconnected);
      f
        ..queueDial()
        ..answerProbeWith(_herdrOnlyOffPathProbe);
      await f.session.connect('key');

      final after = f.session.advisoriesNotifier.value
          .where((a) => a.id == HostAdvisoryId.multiplexerSubstituted)
          .single;

      expect(
        after.dismissalKey,
        before.dismissalKey,
        reason: 'the same finding must key the same across a reconnect',
      );
      expect(
        f.session.dismissedAdvisoriesNotifier.value,
        contains(after.dismissalKey),
        reason:
            'the reconnect must not hand the user back an advisory they '
            'already dismissed',
      );
    },
  );

  test(
    'a genuinely DIFFERENT finding from the same check still arrives '
    'undismissed',
    () async {
      final f = _fixture(multiplexer: 'zellij')
        ..queueDial()
        ..answerProbeWith(_herdrOnlyOffPathProbe);
      await f.session.connect('key');

      final zellijFinding = f.session.advisoriesNotifier.value
          .where((a) => a.id == HostAdvisoryId.multiplexerSubstituted)
          .single;
      f.session.dismissAdvisory(zellijFinding);

      // Same check fires again, but tmux has since been installed, so
      // the substitution now names a different multiplexer entirely.
      f.dropLink();
      f
        ..queueDial()
        ..answerProbeWith(_tmuxInstalledProbe);
      await f.session.connect('key');

      final newFinding = f.session.advisoriesNotifier.value
          .where((a) => a.id == HostAdvisoryId.multiplexerSubstituted)
          .single;

      expect(
        newFinding.dismissalKey,
        isNot(zellijFinding.dismissalKey),
        reason: 'a different substitution is a different finding',
      );
      expect(
        f.session.dismissedAdvisoriesNotifier.value,
        isNot(contains(newFinding.dismissalKey)),
        reason: 'dismissing one finding must never pre-silence the next',
      );
    },
  );

  test('dismissing twice is idempotent', () async {
    final f = _fixture(multiplexer: 'zellij')
      ..queueDial()
      ..answerProbeWith(_herdrOnlyOffPathProbe);
    await f.session.connect('key');

    final advisory = f.session.advisoriesNotifier.value.first;
    f.session
      ..dismissAdvisory(advisory)
      ..dismissAdvisory(advisory);

    expect(f.session.dismissedAdvisoriesNotifier.value, hasLength(1));
  });

  test('a repeat dismissal does not notify, so nothing redraws for it', () {
    // A Set already refuses the duplicate, so the stored value is right
    // either way. What this pins is the NOTIFICATION: assigning a fresh
    // set unconditionally would wake every listener to announce that
    // nothing changed, and both advisory surfaces listen.
    final f = _fixture();
    const advisory = HostAdvisory(
      id: HostAdvisoryId.multiplexerOffPath,
      severity: HostAdvisorySeverity.info,
      title: 'herdr is not on the login PATH',
      detail: 'Installed at /home/deployer/.local/bin/herdr.',
    );

    var notified = 0;
    void listener() => notified++;
    f.session.dismissedAdvisoriesNotifier.addListener(listener);
    addTearDown(
      () => f.session.dismissedAdvisoriesNotifier.removeListener(listener),
    );

    f.session
      ..dismissAdvisory(advisory)
      ..dismissAdvisory(advisory);

    expect(notified, 1);
  });

  test('dismissing one advisory leaves the others alone', () async {
    // The real host produces TWO at once: a substitution and an
    // off-PATH note about the binary that was substituted in.
    final f = _fixture(multiplexer: 'zellij')
      ..queueDial()
      ..answerProbeWith(_herdrOnlyOffPathProbe);
    await f.session.connect('key');

    final all = f.session.advisoriesNotifier.value;
    expect(all.length, greaterThanOrEqualTo(2));
    f.session.dismissAdvisory(all.first);

    expect(
      f.session.dismissedAdvisoriesNotifier.value,
      isNot(contains(all[1].dismissalKey)),
    );
  });
}
