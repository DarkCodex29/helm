// Tests for the share-to-helm delivery path: HomeScreen must hold at most
// ONE pending share in memory and deliver it the FIRST moment a session is
// connected, whether that session exists already or appears later.
//
// This is the defect fix for the primary use case of sharing: helm is
// COLD (no session, no tab) when the share lands from the Android share
// sheet. `_deliverSharedText` used to apply `TerminalSession.typeAtPrompt`
// immediately and rely on its connected-state guard to drop anything it
// couldn't deliver — silently losing the share in exactly that case.
//
// Harness borrowed from `home_screen_settings_overflow_test.dart` (tabs
// notifier override + router) and `terminal_session_focus_test.dart`
// (building a `TerminalSession` whose connection state is controlled by
// hand through `FakeSSHService`/`FakeSSHSession`, with no `tmuxSessionName`
// so `typeAtPrompt`'s underlying write lands directly on the fake SSH
// session returned by `connect`).
import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/share/data/shared_text_receiver.dart';
import 'package:helm/features/share/presentation/shared_text_provider.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/domain/auto_connect_decision.dart';
import 'package:helm/features/terminal/domain/terminal_tab.dart';
import 'package:helm/features/terminal/presentation/home_screen.dart';
import 'package:helm/features/terminal/presentation/providers/tabs_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fake_host_command_runner.dart';
import '../../../helpers/fake_ssh_service.dart';
import '../../../helpers/fake_ssh_session.dart';

const _profile = ConnectionProfile(
  id: 'shared-text-test',
  name: 'Test',
  host: 'example.test',
  username: 'tester',
);

/// A fake [SharedTextReceiver] with no initial (cold-start) share, so
/// every test here drives delivery purely through [sharedText] — the
/// "helm already running" push path — which is the one `HomeScreen`
/// subscribes to for the lifetime of the widget.
class _FakeSharedTextReceiver implements SharedTextReceiver {
  final _controller = StreamController<String>.broadcast();

  void push(String text) => _controller.add(text);

  @override
  Future<String?> takeInitialSharedText() async => null;

  @override
  Stream<String> get sharedText => _controller.stream;

  void dispose() => _controller.close();
}

/// A tabs notifier whose tab list can change AFTER the widget has been
/// pumped, so a test can simulate the "no tab yet" cold-start moment and
/// then let a tab (and its session) appear afterwards — exactly what
/// auto-connect/openSessionNamed do in the real post-frame callback.
class _Tabs extends TabsNotifier {
  _Tabs({TerminalSession? initialSession}) : _initialSession = initialSession;

  final TerminalSession? _initialSession;

  @override
  TabsState build() {
    final session = _initialSession;
    if (session == null) return const TabsState(tabs: []);
    return TabsState(
      tabs: [
        TerminalTab(
          id: 'test',
          title: 'Test',
          session: session,
          profile: _profile,
        ),
      ],
    );
  }

  @override
  Future<AutoConnectDecision> autoConnectDefault({
    required bool recoveryPending,
  }) async => const AutoConnectSkip(AutoConnectSkipReason.alreadyOpen);

  void addSessionTab(TerminalSession session) {
    state = TabsState(
      tabs: [
        TerminalTab(
          id: 'test',
          title: 'Test',
          session: session,
          profile: _profile,
        ),
      ],
    );
  }
}

GoRouter _router() => GoRouter(
  initialLocation: '/',
  routes: [GoRoute(path: '/', builder: (context, state) => const HomeScreen())],
);

Widget _app(GoRouter router, _Tabs tabs, _FakeSharedTextReceiver receiver) =>
    ProviderScope(
      overrides: [
        tabsProvider.overrideWith(() => tabs),
        sharedTextReceiverProvider.overrideWithValue(receiver),
      ],
      child: MaterialApp.router(routerConfig: router),
    );

SSHClient _buildFakeClient(FakeSSHSocket socket) =>
    SSHClient(socket, username: 'tester');

/// A disconnected session over a fully controllable [FakeSSHService]. No
/// `tmuxSessionName` is supplied, so once [connectNow] runs,
/// `TerminalSession`'s internal `_session` is the connect call's own
/// [FakeSSHSession] directly (no attach hop), and every byte
/// `typeAtPrompt` writes lands in [FakeSSHSession.writes].
class _Harness {
  final FakeSSHService service;
  final FakeSSHSession fakeSshSession;
  final TerminalSession session;

  static Future<_Harness> create() async {
    final service = FakeSSHService();
    final fakeSshSession = FakeSSHSession();
    final session = TerminalSession(
      profile: _profile,
      sshService: service,
      hostRunnerFactory: (_) => FakeHostCommandRunner(),
    );
    return _Harness._(service, fakeSshSession, session);
  }

  _Harness._(this.service, this.fakeSshSession, this.session);

  /// The fake socket behind the most recent [connectNow] call, so a test
  /// can drive a real disconnect through `SSHClient.done` via
  /// [FakeSSHSocket.simulateRemoteClosed].
  FakeSSHSocket? _socket;

  /// Connects the session so `statusNotifier` flips to `connected` and
  /// `typeAtPrompt`'s underlying write targets [fakeSshSession].
  Future<void> connectNow() async {
    final socket = FakeSSHSocket();
    _socket = socket;
    service.queueConnectSuccess(
      SSHConnectionResult(
        client: _buildFakeClient(socket),
        session: fakeSshSession,
      ),
    );
    await session.connect('key');
    expect(session.status, ConnectionStatus.connected);
  }

  /// Drives the connected session to `disconnected`, the way a dropped
  /// transport would, without any public `disconnect()` on
  /// [TerminalSession] to call directly.
  ///
  /// Takes [tester] and pumps rather than awaiting `Future.delayed`
  /// directly: under `testWidgets`' fake clock a bare `Future.delayed`
  /// Timer never fires without a pump to advance it, which is exactly
  /// what hung this call the first time it was written.
  Future<void> disconnectNow(WidgetTester tester) async {
    _socket?.simulateRemoteClosed();
    // Let `SSHClient.done`'s listener (installed by `connect`) run.
    await tester.pump();
    await tester.pump();
  }

  String get typed =>
      fakeSshSession.writes.map((bytes) => String.fromCharCodes(bytes)).join();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'a share arriving with NO connected session (and no tab at all) is '
    'delivered once a session appears and connects',
    (tester) async {
      final tabs = _Tabs();
      final receiver = _FakeSharedTextReceiver();
      addTearDown(receiver.dispose);

      await tester.pumpWidget(_app(_router(), tabs, receiver));
      await tester.pumpAndSettle();

      // The cold-start moment this defect is about: no tab exists yet.
      receiver.push('git status');
      await tester.pump();

      final harness = await _Harness.create();
      addTearDown(harness.session.dispose);

      // A tab (and its disconnected session) now appears, as it would
      // from auto-connect's post-frame callback.
      tabs.addSessionTab(harness.session);
      await tester.pump();

      expect(harness.typed, isEmpty, reason: 'not connected yet');

      await harness.connectNow();
      await tester.pump();

      expect(harness.typed, 'git status');
    },
  );

  testWidgets('a share arriving with an already-connected session is delivered '
      'immediately', (tester) async {
    final harness = await _Harness.create();
    addTearDown(harness.session.dispose);
    await harness.connectNow();

    final tabs = _Tabs(initialSession: harness.session);
    final receiver = _FakeSharedTextReceiver();
    addTearDown(receiver.dispose);

    await tester.pumpWidget(_app(_router(), tabs, receiver));
    await tester.pumpAndSettle();

    receiver.push('echo hello');
    await tester.pump();

    expect(harness.typed, 'echo hello');
  });

  testWidgets(
    'a second share replaces a still-pending first one; only the second '
    'is typed',
    (tester) async {
      final tabs = _Tabs();
      final receiver = _FakeSharedTextReceiver();
      addTearDown(receiver.dispose);

      await tester.pumpWidget(_app(_router(), tabs, receiver));
      await tester.pumpAndSettle();

      receiver.push('first share');
      await tester.pump();
      receiver.push('second share');
      await tester.pump();

      final harness = await _Harness.create();
      addTearDown(harness.session.dispose);
      tabs.addSessionTab(harness.session);
      await tester.pump();
      await harness.connectNow();
      await tester.pump();

      expect(harness.typed, 'second share');
      expect(harness.typed, isNot(contains('first share')));
    },
  );

  testWidgets(
    'a pending share is delivered AT MOST ONCE - no repeat on a later '
    'status change',
    (tester) async {
      final tabs = _Tabs();
      final receiver = _FakeSharedTextReceiver();
      addTearDown(receiver.dispose);

      await tester.pumpWidget(_app(_router(), tabs, receiver));
      await tester.pumpAndSettle();

      receiver.push('only once');
      await tester.pump();

      final harness = await _Harness.create();
      addTearDown(harness.session.dispose);
      tabs.addSessionTab(harness.session);
      await tester.pump();
      await harness.connectNow();
      await tester.pump();

      expect(harness.typed, 'only once');

      // Disconnect and reconnect: a second "becomes connected" moment
      // that must NOT redeliver the already-spent share.
      await harness.disconnectNow(tester);
      expect(harness.session.status, ConnectionStatus.disconnected);
      await harness.connectNow();
      await tester.pump();

      expect(harness.typed, 'only once');
    },
  );
}
