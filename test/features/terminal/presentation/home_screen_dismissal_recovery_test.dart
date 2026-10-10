// Tests for odd/tasks/user-dismissed-is-not-a-crash.md.
//
// A plain crash-recovery snapshot (`helm_session_dirty` + a snapshot, no
// dismissal flag) must still surface the offer banner - that is the
// EXISTING behaviour exercised in home_screen_auto_connect_test.dart and
// must not regress here. A snapshot ALSO carrying the native dismissal
// flag (written by `SessionHoldService.onTaskRemoved` on a real device)
// must instead be applied automatically, with no banner at all.
//
// Harness copied from home_screen_auto_connect_test.dart: a real
// TabsNotifier, a FakeSSHService whose connect always fails (so this
// stays about WHAT gets dialled/recovered, never about a live socket),
// and SharedPreferences.setMockInitialValues to seed the snapshot.
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

/// Stands in for what an unroutable host produces, same as
/// home_screen_auto_connect_test.dart's `_SocketFailure`.
class _SocketFailure implements Exception {
  const _SocketFailure();

  @override
  String toString() => 'SocketException: No route to host';
}

/// A real crash: dirty + a snapshot old enough to clear the 5s
/// fast-resume threshold, with NO dismissal flag.
Map<String, Object> _crashSnapshotFor(ConnectionProfile profile) => {
  AppConstants.sessionDirtyKey: true,
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

/// A deliberate swipe-from-Recents: the same shape, plus the dismissal
/// flag `SessionHoldService.onTaskRemoved` writes natively. Timestamp is
/// deliberately FRESH (unlike the crash fixture) - a swipe-then-relaunch
/// can easily happen inside the 5s fast-resume window, and that window
/// must not swallow a real dismissal.
Map<String, Object> _dismissalSnapshotFor(ConnectionProfile profile) => {
  AppConstants.sessionDirtyKey: true,
  AppConstants.sessionDismissedKey: true,
  AppConstants.sessionSnapshotKey: jsonEncode([
    TabSnapshot(
      profileId: profile.id,
      profileName: profile.name,
      tmuxSessionName: 'helm-0',
      sessionRef: 'helm-0',
    ).toJson(),
  ]),
  'helm_session_snapshot_ts': DateTime.now().millisecondsSinceEpoch,
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
  await tester.pumpAndSettle();
  return ssh;
}

void main() {
  testWidgets('a real crash still offers the recovery banner and does not '
      'auto-recover - this is the existing behaviour that must not regress', (
    tester,
  ) async {
    final ssh = await _pumpHome(
      tester,
      profiles: [_defaultProfile],
      extraPrefs: _crashSnapshotFor(_defaultProfile),
    );

    // No dial for the snapshotted tab happened on its own.
    expect(ssh.connectCalls, isEmpty);
    expect(find.byType(SessionRecoveryBanner), findsOneWidget);
  });

  testWidgets(
    'a deliberate swipe-from-Recents recovers the tabs automatically, '
    'with no prompt shown at all',
    (tester) async {
      final ssh = await _pumpHome(
        tester,
        profiles: [_defaultProfile],
        extraPrefs: _dismissalSnapshotFor(_defaultProfile),
      );

      // recoverSession dialled the snapshotted tab on its own, with no
      // tap from the test.
      expect(ssh.connectCalls, hasLength(1));
      expect(ssh.connectCalls.single.profile.id, 'p-default');
      // And the offer never appeared - this is the whole point of the
      // change: a dismissal is applied, not asked about.
      expect(find.byType(SessionRecoveryBanner), findsNothing);
    },
  );

  testWidgets('after auto-recovering a dismissal, the dismissal flag does not '
      'survive - a THIRD launch must not auto-apply a stale flag', (
    tester,
  ) async {
    await _pumpHome(
      tester,
      profiles: [_defaultProfile],
      extraPrefs: _dismissalSnapshotFor(_defaultProfile),
    );

    final repo = SessionSnapshotRepository();
    expect(await repo.wasUserDismissed(), isFalse);
    expect(await repo.getPendingRecovery(), isNull);
  });
}
