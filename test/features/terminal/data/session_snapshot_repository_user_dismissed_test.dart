// Tests for odd/tasks/user-dismissed-is-not-a-crash.md.
//
// `SessionHoldService.onTaskRemoved` (Kotlin, swipe-from-Recents only)
// writes a boolean flag into the SAME SharedPreferences file/key prefix
// the Flutter `shared_preferences` plugin reads, verified against the
// actual plugin source at the pinned version (see the apply report).
// These tests cover the Dart half: the repository must be able to tell a
// deliberate dismissal apart from a plain crash, and must never let that
// flag leak into a later launch once consumed.
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/features/terminal/data/session_snapshot_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('wasUserDismissed', () {
    test(
      'reports true when the native dismissal flag is set alongside a '
      'pending snapshot',
      () async {
        SharedPreferences.setMockInitialValues({
          AppConstants.sessionDirtyKey: true,
          AppConstants.sessionDismissedKey: true,
        });

        final repo = SessionSnapshotRepository();

        expect(await repo.wasUserDismissed(), isTrue);
      },
    );

    test(
      'reports false for a plain crash snapshot - dirty with no dismissal '
      'flag written',
      () async {
        SharedPreferences.setMockInitialValues({
          AppConstants.sessionDirtyKey: true,
        });

        final repo = SessionSnapshotRepository();

        expect(await repo.wasUserDismissed(), isFalse);
      },
    );

    test(
      'reports false when nothing has ever been persisted',
      () async {
        SharedPreferences.setMockInitialValues({});

        final repo = SessionSnapshotRepository();

        expect(await repo.wasUserDismissed(), isFalse);
      },
    );
  });

  group('getPendingRecovery bypasses the fast-resume threshold for a '
      'dismissal', () {
    test(
      'a dismissed snapshot younger than the 5s crash threshold is still '
      'returned, because a deliberate swipe is not the flicker the '
      'threshold exists to filter',
      () async {
        SharedPreferences.setMockInitialValues({
          AppConstants.sessionDirtyKey: true,
          AppConstants.sessionDismissedKey: true,
          AppConstants.sessionSnapshotKey:
              '[{"profileId":"p1","profileName":"Mac","tmuxSessionName":"helm-0"}]',
          'helm_session_snapshot_ts': DateTime.now().millisecondsSinceEpoch,
        });

        final repo = SessionSnapshotRepository();

        final pending = await repo.getPendingRecovery();

        expect(pending, isNotNull);
        expect(pending, hasLength(1));
      },
    );

    test(
      'a NON-dismissed snapshot younger than the 5s crash threshold is '
      'still ignored - the existing fast-resume guard is untouched for '
      'the real crash path',
      () async {
        SharedPreferences.setMockInitialValues({
          AppConstants.sessionDirtyKey: true,
          AppConstants.sessionSnapshotKey:
              '[{"profileId":"p1","profileName":"Mac","tmuxSessionName":"helm-0"}]',
          'helm_session_snapshot_ts': DateTime.now().millisecondsSinceEpoch,
        });

        final repo = SessionSnapshotRepository();

        final pending = await repo.getPendingRecovery();

        expect(pending, isNull);
      },
    );
  });

  group('the dismissal flag is cleared wherever the other three are', () {
    test(
      'markClean removes the dismissal flag alongside dirty/snapshot/ts, '
      'so it cannot leak into a later launch',
      () async {
        SharedPreferences.setMockInitialValues({
          AppConstants.sessionDirtyKey: true,
          AppConstants.sessionDismissedKey: true,
          AppConstants.sessionSnapshotKey:
              '[{"profileId":"p1","profileName":"Mac","tmuxSessionName":"helm-0"}]',
          'helm_session_snapshot_ts': DateTime.now().millisecondsSinceEpoch,
        });

        final repo = SessionSnapshotRepository();
        await repo.markClean();

        expect(await repo.wasUserDismissed(), isFalse);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey(AppConstants.sessionDismissedKey), isFalse);
      },
    );
  });
}
