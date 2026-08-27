// Characterization tests for TerminalSession.
//
// TerminalSession has zero test coverage today (per design.md's own
// Testing Strategy table) and slice 5b will replace the stdin-based attach
// write below with an exec-with-PTY request. These tests pin the CURRENT
// behavior of connect/reconnect/dispose/onResize/_bridgeIO exactly as it
// stands -- including behavior that looks like a bug -- so 5b's diff has to
// justify every change it makes.
//
// No production code is modified by this file. See test/helpers/README
// notes in fake_ssh_session.dart for why a dartssh2-internal import was
// required there.
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:xterm/xterm.dart';

import '../../../helpers/fake_host_command_runner.dart';
import '../../../helpers/fake_ssh_service.dart';
import '../../../helpers/fake_ssh_session.dart';

/// Spy [Terminal] that records every [write] call instead of mutating the
/// real render buffer, so tests can assert on exactly what TerminalSession
/// pushed toward the UI without reading xterm's internal buffer state.
///
/// [Terminal] is a normal (non-final, non-sealed) class from the `xterm`
/// package with a plain public constructor, so this needs no special seam.
class RecordingTerminal extends Terminal {
  RecordingTerminal() : super(maxLines: 500);

  final List<String> writes = [];

  @override
  void write(String data) {
    writes.add(data);
  }
}

const _testProfile = ConnectionProfile(
  id: 'profile-1',
  name: 'Test Host',
  host: 'example.test',
  username: 'tester',
);

/// Channel name dartssh2's SSHClient talks over via [FakeSSHSocket] --
/// never real, just used to build a genuine, otherwise-inert [SSHClient].
SSHClient _buildFakeClient() => SSHClient(FakeSSHSocket(), username: 'tester');

/// Host runner these tests hand TerminalSession so its connect-time probe
/// never reaches the inert [FakeSSHSocket] client above.
///
/// [FakeHostCommandRunner] throws for any script it was not given a result
/// for, which `HostProber` absorbs into an explicitly unknown report. That
/// resolves to the profile's multiplexer under a bare binary name -- the
/// exact attach command this file characterized before the probe existed,
/// so every expectation below still describes the same behavior. The probe
/// itself is covered in terminal_session_probe_test.dart.
HostCommandRunner _unprobeableHost(SSHClient _) => FakeHostCommandRunner();

/// The exact channel `flutter_secure_storage`'s platform-interface package
/// invokes (see flutter_secure_storage_platform_interface's
/// method_channel_flutter_secure_storage.dart). TerminalSession.reconnect()
/// constructs its own unconfigurable `SSHKeyService()` -- unlike
/// `SSHService`, it has no injection point -- so exercising `reconnect()`'s
/// full body requires answering this channel directly.
const _secureStorageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalSession.connect — guard and status', () {
    test('is a no-op when already connecting', () async {
      final service = FakeSSHService();
      final session = TerminalSession(
        profile: _testProfile,
        sshService: service,
        terminal: RecordingTerminal(),
      );
      session.statusNotifier.value = ConnectionStatus.connecting;

      await session.connect('key');

      expect(service.connectCalls, isEmpty);
      expect(session.statusNotifier.value, ConnectionStatus.connecting);
    });

    test('is a no-op when already connected', () async {
      final service = FakeSSHService();
      final session = TerminalSession(
        profile: _testProfile,
        sshService: service,
        terminal: RecordingTerminal(),
      );
      session.statusNotifier.value = ConnectionStatus.connected;

      await session.connect('key');

      expect(service.connectCalls, isEmpty);
      expect(session.statusNotifier.value, ConnectionStatus.connected);
    });

    test(
      'transitions to connecting synchronously, before the async '
      'connectAndOpenShell call resolves',
      () async {
        final service = FakeSSHService();
        service.queueConnectSuccess(
          SSHConnectionResult(client: _buildFakeClient(), session: FakeSSHSession()),
        );
        final session = TerminalSession(
          profile: _testProfile,
          sshService: service,
          terminal: RecordingTerminal(),
        );

        final future = session.connect('key');
        // No await yet: connect()'s body runs synchronously up to its
        // first `await`, so the status flip must already be visible here.
        expect(session.statusNotifier.value, ConnectionStatus.connecting);

        await future;
      },
    );

    test(
      'calls sshService.connectAndOpenShell with the profile, the given '
      'key, and the terminal current view size',
      () async {
        final service = FakeSSHService();
        service.queueConnectSuccess(
          SSHConnectionResult(client: _buildFakeClient(), session: FakeSSHSession()),
        );
        final session = TerminalSession(
          profile: _testProfile,
          sshService: service,
          terminal: RecordingTerminal(),
        );

        await session.connect('private-key-pem');

        expect(service.connectCalls, hasLength(1));
        final call = service.connectCalls.single;
        expect(call.profile, _testProfile);
        expect(call.privateKeyPem, 'private-key-pem');
        // Terminal()'s undisturbed defaults are 80x24.
        expect(call.columns, 80);
        expect(call.rows, 24);
      },
    );

    test('sets status to connected on success', () async {
      final service = FakeSSHService();
      service.queueConnectSuccess(
        SSHConnectionResult(client: _buildFakeClient(), session: FakeSSHSession()),
      );
      final session = TerminalSession(
        profile: _testProfile,
        sshService: service,
        terminal: RecordingTerminal(),
      );

      await session.connect('key');

      expect(session.statusNotifier.value, ConnectionStatus.connected);
      expect(session.isConnected, isTrue);
    });
  });

  group('TerminalSession.connect — attach without a stdin race (5.3/5.4)', () {
    test(
      'attaches via an exec request with the pseudo-terminal allocated up '
      'front, instead of writing the multiplexer command into an '
      'already-open shell\'s stdin — session-attach spec\'s "Attach '
      'Without a Stdin Race" requirement',
      () async {
        final service = FakeSSHService();
        final shellSession = FakeSSHSession();
        final attachSession = FakeSSHSession();
        service.queueConnectSuccess(
          SSHConnectionResult(
            client: _buildFakeClient(),
            session: shellSession,
          ),
        );

        final openedCommands = <String>[];
        final openedPtyConfigs = <SSHPtyConfig>[];
        final terminal = RecordingTerminal();
        final session = TerminalSession(
          profile: _testProfile,
          sshService: service,
          tmuxSessionName: 'mysession',
          terminal: terminal,
          hostRunnerFactory: _unprobeableHost,
          attachOpener: (client, command, pty) async {
            openedCommands.add(command);
            openedPtyConfigs.add(pty);
            return attachSession;
          },
        );

        await session.connect('key');

        // The attach command is quoted per design.md AD-3 and reaches the
        // multiplexer as part of the exec+pty request itself. This profile
        // records no multiplexer and the host is unprobeable, so the
        // command is the host default's — herdr, under a bare binary name.
        expect(openedCommands, ["herdr session attach 'mysession'"]);
        expect(openedPtyConfigs, hasLength(1));
        // Nothing is ever written into the shell session that
        // connectAndOpenShell opened — that channel is never the target
        // of the attach command.
        expect(shellSession.writes, isEmpty);
        expect(attachSession.writes, isEmpty);

        // _bridgeIO must wire up the ATTACH session, not the discarded
        // shell session.
        attachSession.emitStdout(utf8.encode('from attached session'));
        await Future.delayed(Duration.zero);
        expect(terminal.writes, contains('from attached session'));

        terminal.onOutput?.call('ls\n');
        expect(attachSession.writes, [utf8.encode('ls\n')]);
        expect(shellSession.writes, isEmpty);

        // The shell connectAndOpenShell already opened is dead weight once
        // attach replaces it with the exec+pty session — it must be closed,
        // not abandoned, or every attach leaks an orphan remote shell
        // process plus an undrained channel for the life of the connection.
        expect(shellSession.closeCallCount, 1);
      },
    );

    test(
      'writes nothing to the session stdin during connect() when '
      'tmuxSessionName is null, and never invokes the attach opener '
      'either, since there is no session reference to attach to',
      () async {
        final service = FakeSSHService();
        final fakeSession = FakeSSHSession();
        service.queueConnectSuccess(
          SSHConnectionResult(client: _buildFakeClient(), session: fakeSession),
        );
        var attachOpenerCalls = 0;
        final session = TerminalSession(
          profile: _testProfile,
          sshService: service,
          terminal: RecordingTerminal(),
          attachOpener: (client, command, pty) async {
            attachOpenerCalls++;
            return fakeSession;
          },
        );

        await session.connect('key');

        expect(fakeSession.writes, isEmpty);
        expect(attachOpenerCalls, 0);
        // On this path result.session IS the terminal — it must never be
        // closed, unlike the attach path's abandoned shell above.
        expect(fakeSession.closeCallCount, 0);
      },
    );
  });

  group('TerminalSession.connect — failure path', () {
    test(
      'sets status to error, writes a message built from '
      'SSHService.describeError, and rethrows',
      () async {
        final service = FakeSSHService();
        service.queueConnectError(SSHAuthFailError('no supported methods'));
        final terminal = RecordingTerminal();
        final session = TerminalSession(
          profile: _testProfile,
          sshService: service,
          terminal: terminal,
        );

        await expectLater(
          session.connect('key'),
          throwsA(isA<SSHAuthFailError>()),
        );

        expect(session.statusNotifier.value, ConnectionStatus.error);
        expect(
          terminal.writes,
          contains(
            '\r\n[Helm] Connection failed: '
            '${SSHService.describeError(SSHAuthFailError('x'))}\r\n',
          ),
        );
      },
    );
  });

  group('TerminalSession._bridgeIO — stdout/stderr to terminal', () {
    late FakeSSHService service;
    late FakeSSHSession fakeSession;
    late RecordingTerminal terminal;
    late TerminalSession session;

    setUp(() async {
      service = FakeSSHService();
      fakeSession = FakeSSHSession();
      terminal = RecordingTerminal();
      service.queueConnectSuccess(
        SSHConnectionResult(client: _buildFakeClient(), session: fakeSession),
      );
      session = TerminalSession(
        profile: _testProfile,
        sshService: service,
        terminal: terminal,
      );
      await session.connect('key');
    });

    test('forwards stdout bytes to terminal.write, decoded as UTF-8', () async {
      fakeSession.emitStdout(utf8.encode('hello from host'));
      await Future.delayed(Duration.zero);

      expect(terminal.writes, contains('hello from host'));
    });

    test('forwards stderr bytes to terminal.write, decoded as UTF-8', () async {
      fakeSession.emitStderr(utf8.encode('an error line'));
      await Future.delayed(Duration.zero);

      expect(terminal.writes, contains('an error line'));
    });

    test('decodes malformed UTF-8 without throwing (allowMalformed)', () async {
      // A lone continuation byte (0x80) is not valid standalone UTF-8.
      fakeSession.emitStdout(Uint8List.fromList([0x80, 0x41]));
      await Future.delayed(Duration.zero);

      expect(terminal.writes, hasLength(1));
      expect(terminal.writes.single, contains('A'));
    });

    test('a stdout stream error is logged and never reaches the terminal', () async {
      fakeSession.errorStdout(Exception('boom'));
      await Future.delayed(Duration.zero);

      expect(terminal.writes, isEmpty);
    });

    test('closing the stdout stream does not throw', () async {
      await fakeSession.closeStdout();
      await Future.delayed(Duration.zero);

      // No assertion beyond "did not throw" -- onDone only logs (_log.i),
      // matching the source at terminal_session.dart:160.
    });

    test('terminal.onOutput writes the typed data to the session', () {
      terminal.onOutput?.call('ls -la\n');

      expect(fakeSession.writes, hasLength(1));
      expect(fakeSession.writes.single, utf8.encode('ls -la\n'));
    });

    test(
      'terminal.onOutput is a no-op once the connection is no longer '
      'connected (the guard at terminal_session.dart:170-171)',
      () {
        session.statusNotifier.value = ConnectionStatus.disconnected;

        terminal.onOutput?.call('ls -la\n');

        expect(fakeSession.writes, isEmpty);
      },
    );

    test(
      'terminal.onResize calls sshService.resizeTerminal with the live '
      'session and the new size',
      () {
        terminal.resize(120, 40);

        expect(service.resizeCalls, hasLength(1));
        final call = service.resizeCalls.single;
        expect(call.session, same(fakeSession));
        expect(call.columns, 120);
        expect(call.rows, 40);
      },
    );
  });

  group('TerminalSession.onResize — direct calls', () {
    test('does nothing before any session exists', () {
      final service = FakeSSHService();
      final session = TerminalSession(
        profile: _testProfile,
        sshService: service,
        terminal: RecordingTerminal(),
      );

      session.onResize(10, 10);

      expect(service.resizeCalls, isEmpty);
    });
  });

  group('TerminalSession — disconnect via client.done', () {
    test(
      'a normal client.done completion runs _handleDisconnect: status '
      'flips to disconnected and the terminal reports it',
      () async {
        final service = FakeSSHService();
        final socket = FakeSSHSocket();
        final client = SSHClient(socket, username: 'tester');
        service.queueConnectSuccess(
          SSHConnectionResult(client: client, session: FakeSSHSession()),
        );
        final terminal = RecordingTerminal();
        final session = TerminalSession(
          profile: _testProfile,
          sshService: service,
          terminal: terminal,
        );
        await session.connect('key');

        socket.simulateRemoteClosed();
        // client.done completes asynchronously off the socket's onDone
        // event; give the microtask/event-loop queue a turn to drain.
        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);

        expect(session.statusNotifier.value, ConnectionStatus.disconnected);
        expect(terminal.writes, contains('\r\n[Helm] Disconnected\r\n'));
      },
    );

    test(
      'an errored client.done completion also runs _handleDisconnect',
      () async {
        final service = FakeSSHService();
        final socket = FakeSSHSocket();
        final client = SSHClient(socket, username: 'tester');
        service.queueConnectSuccess(
          SSHConnectionResult(client: client, session: FakeSSHSession()),
        );
        final terminal = RecordingTerminal();
        final session = TerminalSession(
          profile: _testProfile,
          sshService: service,
          terminal: terminal,
        );
        await session.connect('key');

        socket.simulateError(Exception('transport died'));
        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);

        expect(session.statusNotifier.value, ConnectionStatus.disconnected);
        expect(terminal.writes, contains('\r\n[Helm] Disconnected\r\n'));
      },
    );

    test(
      '_handleDisconnect is idempotent: the disconnect message is written '
      'only once even if client.done-driven disconnects overlap with a '
      'later dispose()',
      () async {
        final service = FakeSSHService();
        final socket = FakeSSHSocket();
        final client = SSHClient(socket, username: 'tester');
        service.queueConnectSuccess(
          SSHConnectionResult(client: client, session: FakeSSHSession()),
        );
        final terminal = RecordingTerminal();
        final session = TerminalSession(
          profile: _testProfile,
          sshService: service,
          terminal: terminal,
        );
        await session.connect('key');

        socket.simulateRemoteClosed();
        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);
        final disconnectWritesAfterFirst = terminal.writes
            .where((w) => w.contains('Disconnected'))
            .length;

        await session.dispose();

        final disconnectWritesAfterDispose = terminal.writes
            .where((w) => w.contains('Disconnected'))
            .length;

        expect(disconnectWritesAfterFirst, 1);
        expect(disconnectWritesAfterDispose, 1);
      },
    );
  });

  group(
    'TerminalSession — attach exit status (C1: distinguishing detach '
    'from a killed session)',
    () {
      test(
        'reports the ambiguous "session ended" message when the attach '
        'session exits with code 0 and no signal -- detach and a session '
        'kill with the multiplexer server still alive are '
        'indistinguishable from exit status alone, per '
        'AttachExitOutcome\'s doc comment',
        () async {
          final service = FakeSSHService();
          final attachSession = FakeSSHSession();
          service.queueConnectSuccess(
            SSHConnectionResult(
              client: _buildFakeClient(),
              session: FakeSSHSession(),
            ),
          );
          final terminal = RecordingTerminal();
          final session = TerminalSession(
            profile: _testProfile,
            sshService: service,
            tmuxSessionName: 'mysession',
            terminal: terminal,
            hostRunnerFactory: _unprobeableHost,
            attachOpener: (client, command, pty) async => attachSession,
          );
          await session.connect('key');

          await attachSession.endWithExitCode(0);

          expect(
            session.statusNotifier.value,
            ConnectionStatus.disconnected,
          );
          expect(
            terminal.writes,
            contains(
              '\r\n[Helm] Disconnected — the session ended (you may have '
              'detached, or it was closed on the host)\r\n',
            ),
          );
        },
      );

      test(
        'reports an abnormal-exit message with the exit code when the '
        'attach session exits non-zero -- the only case verified to '
        'distinguish a killed session from a detach (tmux `kill-server`)',
        () async {
          final service = FakeSSHService();
          final attachSession = FakeSSHSession();
          service.queueConnectSuccess(
            SSHConnectionResult(
              client: _buildFakeClient(),
              session: FakeSSHSession(),
            ),
          );
          final terminal = RecordingTerminal();
          final session = TerminalSession(
            profile: _testProfile,
            sshService: service,
            tmuxSessionName: 'mysession',
            terminal: terminal,
            hostRunnerFactory: _unprobeableHost,
            attachOpener: (client, command, pty) async => attachSession,
          );
          await session.connect('key');

          await attachSession.endWithExitCode(1);

          expect(
            terminal.writes,
            contains(
              '\r\n[Helm] Disconnected — the session exited abnormally '
              '(exit code 1)\r\n',
            ),
          );
        },
      );

      test(
        'reports an abnormal-exit message with the signal name when the '
        'attach session ends via an exit signal',
        () async {
          final service = FakeSSHService();
          final attachSession = FakeSSHSession();
          service.queueConnectSuccess(
            SSHConnectionResult(
              client: _buildFakeClient(),
              session: FakeSSHSession(),
            ),
          );
          final terminal = RecordingTerminal();
          final session = TerminalSession(
            profile: _testProfile,
            sshService: service,
            tmuxSessionName: 'mysession',
            terminal: terminal,
            hostRunnerFactory: _unprobeableHost,
            attachOpener: (client, command, pty) async => attachSession,
          );
          await session.connect('key');

          await attachSession.endWithExitSignal(
            SSHSessionExitSignal(
              signalName: 'KILL',
              coreDumped: false,
              errorMessage: '',
              languageTag: '',
            ),
          );

          expect(
            terminal.writes,
            contains(
              '\r\n[Helm] Disconnected — the session exited abnormally '
              '(signal KILL)\r\n',
            ),
          );
        },
      );

      test(
        'falls back to the pre-existing generic disconnect message when '
        'the attach session ends with no exit status at all -- e.g. an '
        'abrupt transport drop before any exit-status/exit-signal '
        'request arrived',
        () async {
          final service = FakeSSHService();
          final attachSession = FakeSSHSession();
          service.queueConnectSuccess(
            SSHConnectionResult(
              client: _buildFakeClient(),
              session: FakeSSHSession(),
            ),
          );
          final terminal = RecordingTerminal();
          final session = TerminalSession(
            profile: _testProfile,
            sshService: service,
            tmuxSessionName: 'mysession',
            terminal: terminal,
            hostRunnerFactory: _unprobeableHost,
            attachOpener: (client, command, pty) async => attachSession,
          );
          await session.connect('key');

          await attachSession.endWithNoExitStatus();

          expect(terminal.writes, contains('\r\n[Helm] Disconnected\r\n'));
        },
      );

      test(
        'the attach session ending wins over a later client.done firing '
        'for the same disconnect -- only the exit-status-classified '
        'message is written, never a duplicate generic one',
        () async {
          final service = FakeSSHService();
          final socket = FakeSSHSocket();
          final client = SSHClient(socket, username: 'tester');
          final attachSession = FakeSSHSession();
          service.queueConnectSuccess(
            SSHConnectionResult(client: client, session: FakeSSHSession()),
          );
          final terminal = RecordingTerminal();
          final session = TerminalSession(
            profile: _testProfile,
            sshService: service,
            tmuxSessionName: 'mysession',
            terminal: terminal,
            hostRunnerFactory: _unprobeableHost,
            attachOpener: (c, command, pty) async => attachSession,
          );
          await session.connect('key');

          await attachSession.endWithExitCode(0);
          socket.simulateRemoteClosed();
          await Future.delayed(Duration.zero);
          await Future.delayed(Duration.zero);

          final disconnectWrites = terminal.writes
              .where((w) => w.contains('Disconnected'))
              .toList();
          expect(disconnectWrites, hasLength(1));
          expect(
            disconnectWrites.single,
            '\r\n[Helm] Disconnected — the session ended (you may have '
            'detached, or it was closed on the host)\r\n',
          );
        },
      );
    },
  );

  group('TerminalSession.dispose', () {
    test(
      'cancels stream subscriptions, disconnects the client, and sets '
      'status to disconnected',
      () async {
        final service = FakeSSHService();
        final client = _buildFakeClient();
        service.queueConnectSuccess(
          SSHConnectionResult(client: client, session: FakeSSHSession()),
        );
        final session = TerminalSession(
          profile: _testProfile,
          sshService: service,
          terminal: RecordingTerminal(),
        );
        await session.connect('key');

        await session.dispose();

        expect(service.disconnectCalls, [client]);
        expect(session.statusNotifier.value, ConnectionStatus.disconnected);
      },
    );

    test('is safe to call when never connected', () async {
      final service = FakeSSHService();
      final session = TerminalSession(
        profile: _testProfile,
        sshService: service,
        terminal: RecordingTerminal(),
      );

      await session.dispose();

      expect(service.disconnectCalls, isEmpty);
    });

    test(
      '[DISCOVERY] is NOT safe to call twice: the second call throws '
      'because statusNotifier.dispose() (terminal_session.dart:153) is '
      'unconditional -- there is no guard against disposing an '
      'already-disposed ValueNotifier. Pinned as current behavior, not '
      'fixed here.',
      () async {
        final service = FakeSSHService();
        final session = TerminalSession(
          profile: _testProfile,
          sshService: service,
          terminal: RecordingTerminal(),
        );

        await session.dispose();

        await expectLater(session.dispose(), throwsFlutterError);
      },
    );
  });

  group('TerminalSession.reconnect — guards', () {
    test('is a no-op when already connecting', () async {
      final service = FakeSSHService();
      final session = TerminalSession(
        profile: _testProfile,
        sshService: service,
        terminal: RecordingTerminal(),
      );
      session.statusNotifier.value = ConnectionStatus.connecting;

      await session.reconnect();

      expect(service.disconnectCalls, isEmpty);
      expect(service.connectCalls, isEmpty);
    });

    test('is a no-op when already connected', () async {
      final service = FakeSSHService();
      final session = TerminalSession(
        profile: _testProfile,
        sshService: service,
        terminal: RecordingTerminal(),
      );
      session.statusNotifier.value = ConnectionStatus.connected;

      await session.reconnect();

      expect(service.disconnectCalls, isEmpty);
      expect(service.connectCalls, isEmpty);
    });
  });

  group(
    'TerminalSession.reconnect — full body '
    '(requires mocking flutter_secure_storage: see comment on '
    '_secureStorageChannel above)',
    () {
      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_secureStorageChannel, null);
      });

      test(
        'tears down the old client/streams and writes "Reconnecting…" '
        'before checking for a stored key, then reports "No SSH key '
        'found" when none is stored',
        () async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(_secureStorageChannel, (call) async {
            if (call.method == 'read') return null;
            return null;
          });

          final service = FakeSSHService();
          final oldClient = _buildFakeClient();
          service.queueConnectSuccess(
            SSHConnectionResult(client: oldClient, session: FakeSSHSession()),
          );
          final terminal = RecordingTerminal();
          final session = TerminalSession(
            profile: _testProfile,
            sshService: service,
            terminal: terminal,
          );
          await session.connect('key');
          // reconnect() no-ops while statusNotifier is connecting/connected
          // (terminal_session.dart:96-99); simulate that the connection
          // already dropped, as would happen before a real caller invokes
          // reconnect().
          session.statusNotifier.value = ConnectionStatus.disconnected;

          await session.reconnect();

          expect(terminal.writes, contains('\r\n[Helm] Reconnecting…\r\n'));
          expect(service.disconnectCalls, [oldClient]);
          expect(
            terminal.writes,
            contains('[Helm] No SSH key found — cannot reconnect\r\n'),
          );
          // No second connect attempt: reconnect() returns right after the
          // "no key" message, per terminal_session.dart:119-122.
          expect(service.connectCalls, hasLength(1));
        },
      );

      test(
        'forwards the stored private key into connect() when one exists',
        () async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(_secureStorageChannel, (call) async {
            if (call.method == 'read') return 'stored-pem-key';
            return null;
          });

          final service = FakeSSHService();
          final oldClient = _buildFakeClient();
          service.queueConnectSuccess(
            SSHConnectionResult(client: oldClient, session: FakeSSHSession()),
          );
          final session = TerminalSession(
            profile: _testProfile,
            sshService: service,
            terminal: RecordingTerminal(),
          );
          await session.connect('key');
          session.statusNotifier.value = ConnectionStatus.disconnected;

          // The second connect (inside reconnect()) needs its own queued
          // result.
          service.queueConnectSuccess(
            SSHConnectionResult(
              client: _buildFakeClient(),
              session: FakeSSHSession(),
            ),
          );

          await session.reconnect();

          expect(service.connectCalls, hasLength(2));
          expect(service.connectCalls.last.privateKeyPem, 'stored-pem-key');
        },
      );
    },
  );

  group('TerminalSession.reconnect — testability gap (discovery)', () {
    test(
      '[DISCOVERY] with no secure-storage channel handler registered, '
      'reconnect() propagates the resulting exception uncaught -- '
      'SSHKeyService() is constructed directly inside reconnect() with no '
      'injection point (unlike SSHService), and the '
      '`await keyService.getPrivateKey()` call at terminal_session.dart:118 '
      'sits outside any try/catch. This is a testability/robustness gap '
      'in the current code, pinned here rather than fixed, since fixing '
      'it is not part of this slice\'s scope.',
      () async {
        final service = FakeSSHService();
        final oldClient = _buildFakeClient();
        service.queueConnectSuccess(
          SSHConnectionResult(client: oldClient, session: FakeSSHSession()),
        );
        final session = TerminalSession(
          profile: _testProfile,
          sshService: service,
          terminal: RecordingTerminal(),
        );
        await session.connect('key');
        session.statusNotifier.value = ConnectionStatus.disconnected;

        await expectLater(session.reconnect(), throwsA(anything));
      },
    );
  });
}
