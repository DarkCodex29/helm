// The remote PTY must be opened at the size the user can actually see.
//
// Measured on an iPhone 17 Pro simulator before this unit existed:
// `connect()` read `Terminal.viewWidth`/`viewHeight` while the view had not
// laid out yet, so the shell PTY was opened at xterm's 80x24 default while
// the phone's viewport was 51x29. Verified against the real host that a
// multiplexer handed an 80-column PTY paints 80 columns wide, so 29 columns
// fall off the right edge of a 51-column phone — the reported truncation.
//
// These tests pin the contract that fixes it: a session that has a viewport
// attached WAITS for that viewport's first real size instead of connecting
// at a fabricated one, and every PTY it opens uses that same size.
import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:xterm/xterm.dart';

import '../../../helpers/fake_host_command_runner.dart';
import '../../../helpers/fake_ssh_service.dart';
import '../../../helpers/fake_ssh_session.dart';

const _testProfile = ConnectionProfile(
  id: 'profile-1',
  name: 'Test Host',
  host: 'example.test',
  username: 'tester',
);

SSHClient _buildFakeClient() => SSHClient(FakeSSHSocket(), username: 'tester');

HostCommandRunner _unprobeableHost(SSHClient _) => FakeHostCommandRunner();

/// Records the [SSHPtyConfig] every attach was opened with, so the attach
/// PTY can be asserted independently of the shell PTY.
class _RecordingAttachOpener {
  final List<SSHPtyConfig> ptyConfigs = [];

  Future<SSHSession> call(
    SSHClient client,
    String command,
    SSHPtyConfig pty,
  ) async {
    ptyConfigs.add(pty);
    return FakeSSHSession();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
  });

  group('TerminalSession - the PTY matches the viewport', () {
    test(
      'a session with a viewport waits for its first real size instead of '
      "opening the PTY at xterm's 80x24 default",
      () async {
        final service = FakeSSHService()
          ..queueConnectSuccess(
            SSHConnectionResult(
              client: _buildFakeClient(),
              session: FakeSSHSession(),
            ),
          );
        final session = TerminalSession(
          profile: _testProfile,
          sshService: service,
          hostRunnerFactory: _unprobeableHost,
        );

        // A view exists but has not laid out yet — exactly the state
        // auto-connect leaves the session in on launch.
        session.attachViewport();

        final connecting = session.connect('pem');
        await Future<void>.delayed(Duration.zero);

        // connect() must not have opened anything yet: there is no real
        // size to open it at.
        expect(
          service.connectCalls,
          isEmpty,
          reason: 'connect() opened a PTY before the viewport reported a size',
        );

        // The view lays out and reports what it actually renders.
        session.onResize(51, 29);
        await connecting;

        expect(service.connectCalls, hasLength(1));
        expect(service.connectCalls.single.columns, 51);
        expect(service.connectCalls.single.rows, 29);

        await session.dispose();
      },
    );

    test(
      'the attach PTY is opened at the same viewport size as the shell PTY',
      () async {
        final service = FakeSSHService()
          ..queueConnectSuccess(
            SSHConnectionResult(
              client: _buildFakeClient(),
              session: FakeSSHSession(),
            ),
          );
        final opener = _RecordingAttachOpener();
        final session = TerminalSession(
          profile: _testProfile,
          sshService: service,
          tmuxSessionName: 'helm-0',
          attachOpener: opener.call,
          hostRunnerFactory: _unprobeableHost,
        );

        session.attachViewport();
        final connecting = session.connect('pem');
        await Future<void>.delayed(Duration.zero);
        session.onResize(51, 29);
        await connecting;

        expect(opener.ptyConfigs, hasLength(1));
        expect(opener.ptyConfigs.single.width, 51);
        expect(opener.ptyConfigs.single.height, 29);

        await session.dispose();
      },
    );

    test(
      'a size reported before connect() is used without waiting - the '
      'reconnect path, where the view laid out long ago',
      () async {
        final service = FakeSSHService()
          ..queueConnectSuccess(
            SSHConnectionResult(
              client: _buildFakeClient(),
              session: FakeSSHSession(),
            ),
          );
        final session = TerminalSession(
          profile: _testProfile,
          sshService: service,
          hostRunnerFactory: _unprobeableHost,
        );

        session.attachViewport();
        session.onResize(64, 33);

        await session.connect('pem');

        expect(service.connectCalls.single.columns, 64);
        expect(service.connectCalls.single.rows, 33);

        await session.dispose();
      },
    );

    test(
      'a session with NO viewport attached uses the documented default '
      'immediately rather than hanging',
      () async {
        final service = FakeSSHService()
          ..queueConnectSuccess(
            SSHConnectionResult(
              client: _buildFakeClient(),
              session: FakeSSHSession(),
            ),
          );
        final session = TerminalSession(
          profile: _testProfile,
          sshService: service,
          hostRunnerFactory: _unprobeableHost,
        );

        await session.connect('pem');

        expect(
          service.connectCalls.single.columns,
          AppConstants.defaultTerminalColumns,
        );
        expect(
          service.connectCalls.single.rows,
          AppConstants.defaultTerminalRows,
        );

        await session.dispose();
      },
    );

    test(
      'the latest reported size wins when the viewport changes while '
      'connect() is still waiting',
      () async {
        final service = FakeSSHService()
          ..queueConnectSuccess(
            SSHConnectionResult(
              client: _buildFakeClient(),
              session: FakeSSHSession(),
            ),
          );
        final session = TerminalSession(
          profile: _testProfile,
          sshService: service,
          hostRunnerFactory: _unprobeableHost,
        );

        session.attachViewport();
        final connecting = session.connect('pem');
        await Future<void>.delayed(Duration.zero);

        // Keyboard opens mid-connect: two layouts before the PTY is opened.
        session.onResize(51, 29);
        session.onResize(51, 17);
        await connecting;

        expect(service.connectCalls.single.columns, 51);
        expect(service.connectCalls.single.rows, 17);

        await session.dispose();
      },
    );

    test(
      'detachViewport releases a connect() that is still waiting, so a tab '
      'closed mid-connect cannot hang forever',
      () async {
        final service = FakeSSHService()
          ..queueConnectSuccess(
            SSHConnectionResult(
              client: _buildFakeClient(),
              session: FakeSSHSession(),
            ),
          );
        final session = TerminalSession(
          profile: _testProfile,
          sshService: service,
          hostRunnerFactory: _unprobeableHost,
        );

        session.attachViewport();
        final connecting = session.connect('pem');
        await Future<void>.delayed(Duration.zero);
        expect(service.connectCalls, isEmpty);

        session.detachViewport();
        await connecting;

        expect(
          service.connectCalls.single.columns,
          AppConstants.defaultTerminalColumns,
        );

        await session.dispose();
      },
    );

    test(
      'the first reported size RESUMES the waiting connect immediately - it '
      'does not sit out the layout deadline first',
      () {
        // Timing, not just the value: a connect that only unblocks when
        // kViewportLayoutDeadline expires still opens the PTY at the right
        // size, but leaves the user staring at "Connecting…" for three
        // extra seconds. FakeAsync makes the deadline observable.
        FakeAsync().run((async) {
          final service = FakeSSHService()
            ..queueConnectSuccess(
              SSHConnectionResult(
                client: _buildFakeClient(),
                session: FakeSSHSession(),
              ),
            );
          final session = TerminalSession(
            profile: _testProfile,
            sshService: service,
            hostRunnerFactory: _unprobeableHost,
          );

          session.attachViewport();
          unawaited(session.connect('pem'));
          async.flushMicrotasks();
          expect(service.connectCalls, isEmpty);

          session.onResize(51, 29);
          // Only microtasks — no clock movement at all. The connect must
          // already be through.
          async.flushMicrotasks();

          expect(
            service.connectCalls,
            hasLength(1),
            reason:
                'connect() waited on the deadline instead of resuming on the '
                'reported size',
          );
          expect(service.connectCalls.single.columns, 51);
        });
      },
    );

    test(
      'detachViewport resumes the waiting connect immediately rather than '
      'letting it sit out the layout deadline',
      () {
        FakeAsync().run((async) {
          final service = FakeSSHService()
            ..queueConnectSuccess(
              SSHConnectionResult(
                client: _buildFakeClient(),
                session: FakeSSHSession(),
              ),
            );
          final session = TerminalSession(
            profile: _testProfile,
            sshService: service,
            hostRunnerFactory: _unprobeableHost,
          );

          session.attachViewport();
          unawaited(session.connect('pem'));
          async.flushMicrotasks();
          expect(service.connectCalls, isEmpty);

          session.detachViewport();
          async.flushMicrotasks();

          expect(
            service.connectCalls,
            hasLength(1),
            reason:
                'detachViewport left the connect parked until the deadline',
          );
        });
      },
    );

    test(
      'dispose() resumes a connect still waiting for a viewport, rather '
      'than leaving it parked until the deadline',
      () {
        FakeAsync().run((async) {
          final service = FakeSSHService()
            ..queueConnectSuccess(
              SSHConnectionResult(
                client: _buildFakeClient(),
                session: FakeSSHSession(),
              ),
            );
          final session = TerminalSession(
            profile: _testProfile,
            sshService: service,
            hostRunnerFactory: _unprobeableHost,
          );

          session.attachViewport();
          unawaited(session.connect('pem'));
          async.flushMicrotasks();
          expect(service.connectCalls, isEmpty);

          // A tab closed while it was still opening.
          unawaited(session.dispose());
          async.flushMicrotasks();

          expect(
            service.connectCalls,
            hasLength(1),
            reason:
                'dispose() left the connect parked on a completer nothing '
                'will ever finish',
          );
        });
      },
    );

    test(
      'onResize records the size while disconnected without pushing a '
      'resize at a dead session',
      () async {
        final service = FakeSSHService();
        final session = TerminalSession(
          profile: _testProfile,
          sshService: service,
        );

        session.attachViewport();
        session.onResize(51, 29);

        expect(
          service.resizeCalls,
          isEmpty,
          reason: 'nothing is connected, so nothing can be resized remotely',
        );
        expect(session.viewportColumns, 51);
        expect(session.viewportRows, 29);

        await session.dispose();
      },
    );

    test(
      "xterm's own resize is observed before connect() runs, so the size "
      'the renderer computed is the size the PTY is opened at',
      () async {
        final service = FakeSSHService()
          ..queueConnectSuccess(
            SSHConnectionResult(
              client: _buildFakeClient(),
              session: FakeSSHSession(),
            ),
          );
        final terminal = Terminal(maxLines: 500);
        final session = TerminalSession(
          profile: _testProfile,
          sshService: service,
          terminal: terminal,
          hostRunnerFactory: _unprobeableHost,
        );

        session.attachViewport();

        // This is what xterm's RenderTerminal does during performLayout,
        // long before _bridgeIO ever runs.
        terminal.resize(51, 29);

        await session.connect('pem');

        expect(service.connectCalls.single.columns, 51);
        expect(service.connectCalls.single.rows, 29);

        await session.dispose();
      },
    );
  });
}
