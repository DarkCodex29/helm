import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/features/connection/data/ssh_key_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/terminal/data/session_snapshot_repository.dart';
import 'package:helm/features/terminal/presentation/home_screen.dart';
import 'package:helm/features/terminal/presentation/providers/tabs_provider.dart';
import 'package:helm/features/terminal/presentation/widgets/session_recovery_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fake_secure_storage.dart';
import '../../../helpers/fake_ssh_service.dart';

const _defaultProfile = ConnectionProfile(
  id: 'p-default',
  name: 'VPS',
  host: '158.220.106.131',
  username: 'deployer',
  isDefault: true,
);

const _unmarkedProfile = ConnectionProfile(
  id: 'p-unmarked',
  name: 'Laptop',
  host: '10.0.0.9',
  username: 'gian',
);

/// Stands in for what an unroutable host produces. Every test here uses
/// the FAILING dial on purpose: a real handshake needs a real socket, and
/// what these tests are about is whether launch dials at all — plus the
/// guarantee that the worst case still leaves Home usable.
class _SocketFailure implements Exception {
  const _SocketFailure();

  @override
  String toString() => 'SocketException: No route to host';
}

/// Seeds a REAL pending crash-recovery snapshot, the way
/// [SessionSnapshotRepository] persists one: dirty flag, encoded tabs, and
/// a timestamp old enough to clear its 5-second fast-resume threshold.
Map<String, Object> _crashSnapshotFor(ConnectionProfile profile) => {
  'helm_session_dirty': true,
  AppConstants.sessionSnapshotKey: jsonEncode([
    TabSnapshot(
      profileId: profile.id,
      profileName: profile.name,
      tmuxSessionName: 'helm-0',
      sessionRef: 'helm-0',
    ).toJson(),
  ]),
  'helm_session_snapshot_ts':
      DateTime.now().millisecondsSinceEpoch -
      const Duration(minutes: 1).inMilliseconds,
};

Future<FakeSSHService> _pumpHome(
  WidgetTester tester, {
  required List<ConnectionProfile> profiles,
  Map<String, Object> extraPrefs = const {},
}) async {
  SharedPreferences.setMockInitialValues({
    AppConstants.profilesStorageKey: profiles
        .map((p) => jsonEncode(p.toJson()))
        .toList(),
    ...extraPrefs,
  });

  final ssh = FakeSSHService()..queueConnectError(const _SocketFailure());

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sshServiceProvider.overrideWithValue(ssh),
        sshKeyServiceProvider.overrideWithValue(
          SSHKeyService(
            storage: FakeSecureStorage({
              AppConstants.sshPrivateKeyStorageKey: 'fake-pem',
            }),
          ),
        ),
      ],
      child: const MaterialApp(home: HomeScreen()),
    ),
  );
  // Let the post-frame callback and its awaits run. NO gesture is made
  // anywhere in these tests — that is the whole claim under test.
  await tester.pumpAndSettle();
  return ssh;
}

void main() {
  testWidgets(
    'launching with a default profile dials it with no taps at all — the '
    'user opening the app must not be met by "No active sessions" when '
    'they already told us which host to open',
    (tester) async {
      final ssh = await _pumpHome(tester, profiles: [_defaultProfile]);

      expect(ssh.connectCalls, hasLength(1));
      expect(ssh.connectCalls.single.profile.id, 'p-default');
    },
  );

  testWidgets(
    'a host that cannot be reached still lands the user on a usable Home '
    'rather than an error screen or a spinner that never resolves',
    (tester) async {
      await _pumpHome(tester, profiles: [_defaultProfile]);

      // No exception escaped the post-frame callback into the framework.
      expect(tester.takeException(), isNull);
      // Home rendered, and its own chrome is reachable.
      expect(find.byType(HomeScreen), findsOneWidget);
      // The hamburger, and no longer Settings: Settings moved into the
      // drawer's footer, so its absence from this bar is the new correct
      // state rather than the failure this line used to catch. The drawer
      // button is what still proves Home's own chrome survived — and it
      // is also the route to Settings now, so one assertion covers both.
      expect(find.byTooltip('Projects'), findsOneWidget);
    },
  );

  testWidgets(
    'launching with NO profile marked default changes nothing — the empty '
    'state stands and nothing is dialed',
    (tester) async {
      final ssh = await _pumpHome(tester, profiles: [_unmarkedProfile]);

      expect(ssh.connectCalls, isEmpty);
      expect(find.text('No active sessions'), findsOneWidget);
    },
  );

  testWidgets('launching with no profiles saved dials nothing', (tester) async {
    final ssh = await _pumpHome(tester, profiles: const []);

    expect(ssh.connectCalls, isEmpty);
    expect(find.text('No active sessions'), findsOneWidget);
  });

  testWidgets(
    'launching with a crash-recovery offer outstanding does NOT dial the '
    'default profile — accepting that offer reopens this very profile, '
    'and dialing beside it is how one host ends up with two sessions',
    (tester) async {
      // The guard lives in decideAutoConnect, but only HomeScreen knows
      // whether a recovery is pending, and only HomeScreen can get the
      // ORDERING wrong. This is the test that fails if the wiring stops
      // forwarding the real answer and hardcodes `false` instead.
      final ssh = await _pumpHome(
        tester,
        profiles: [_defaultProfile],
        extraPrefs: _crashSnapshotFor(_defaultProfile),
      );

      expect(ssh.connectCalls, isEmpty);
      // And the offer the user is meant to answer is actually on screen.
      expect(find.byType(SessionRecoveryBanner), findsOneWidget);
    },
  );
}
