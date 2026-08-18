// Tests for the session-reference storage migration (spec.md:
// session-reference-storage). See openspec/changes/host-session-contract/
// specs/session-reference-storage/spec.md for the normative requirements
// these groups are named after. Third and last of the three persisted
// models this change migrates (after ConnectionProfile and ProjectShortcut
// — see connection_profile_test.dart and project_shortcut_test.dart).
//
// Structural difference from both prior models, disclosed here and in the
// apply report: `TabSnapshot` has NO codegen at all — no freezed, no
// json_serializable. `fromJson`/`toJson` are hand-written plain Dart, so
// the freezed-detection constraint that forced the `@JsonKey(readValue:)`
// technique on `ConnectionProfile`/`ProjectShortcut` does not apply here;
// the precedence logic can live directly in a hand-written `fromJson`.
//
// Legacy field: `TabSnapshot.tmuxSessionName` — `required String`,
// non-nullable (matches `ProjectShortcut.tmuxSession`'s nullability, not
// `ConnectionProfile.tmuxSession`'s; the field NAME matches neither prior
// model). As with `ProjectShortcut`, a JSON object missing
// `tmuxSessionName` already fails to load today (`json['tmuxSessionName']
// as String` throws on null/missing) — pre-existing behavior, unchanged
// by this migration. So, same as ProjectShortcut, spec.md's three
// requirements are tested exactly as written: none of them requires a
// record with the legacy key entirely absent, only "legacy key present
// alone" or "both keys present".
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/terminal/data/session_snapshot_repository.dart';

void main() {
  group('Legacy Field Still Readable', () {
    test(
      'a record containing only the legacy tmuxSessionName key loads with '
      'its value available under the new sessionRef field',
      () {
        final snapshot = TabSnapshot.fromJson({
          'profileId': 'profile-1',
          'profileName': 'Mac Studio',
          'tmuxSessionName': 'helm-work',
        });

        expect(snapshot.sessionRef, 'helm-work');
      },
    );
  });

  group('Legacy Key Is Not Deleted', () {
    test(
      'saving a record loaded from a legacy-only JSON emits both the '
      'tmuxSessionName and sessionRef keys',
      () {
        final snapshot = TabSnapshot.fromJson({
          'profileId': 'profile-1',
          'profileName': 'Mac Studio',
          'tmuxSessionName': 'helm-work',
        });

        final json = snapshot.toJson();

        expect(json.containsKey('tmuxSessionName'), isTrue);
        expect(json.containsKey('sessionRef'), isTrue);
      },
    );

    test(
      'saving a newly created record (constructed directly, sessionRef '
      'set) still emits both keys',
      () {
        const snapshot = TabSnapshot(
          profileId: 'profile-new',
          profileName: 'New Profile',
          tmuxSessionName: 'legacy-name',
          sessionRef: 'neutral-name',
        );

        final json = snapshot.toJson();

        expect(json.containsKey('tmuxSessionName'), isTrue);
        expect(json.containsKey('sessionRef'), isTrue);
        expect(json['sessionRef'], 'neutral-name');
      },
    );
  });

  group('Neutral Field Takes Precedence When Both Are Present', () {
    test(
      'when tmuxSessionName and sessionRef hold different values, the '
      "resolved sessionRef equals the neutral field's own value",
      () {
        final snapshot = TabSnapshot.fromJson({
          'profileId': 'profile-1',
          'profileName': 'Mac Studio',
          'tmuxSessionName': 'old-legacy-name',
          'sessionRef': 'new-neutral-name',
        });

        expect(snapshot.sessionRef, 'new-neutral-name');
      },
    );

    test(
      'precedence holds regardless of key order in the source map',
      () {
        final snapshot = TabSnapshot.fromJson({
          'profileId': 'profile-1',
          'profileName': 'Mac Studio',
          'sessionRef': 'neutral-wins',
          'tmuxSessionName': 'legacy-loses',
        });

        expect(snapshot.sessionRef, 'neutral-wins');
      },
    );
  });

  group('Round-trip: snapshot written by the pre-migration app version', () {
    // Captured VERBATIM from the pre-migration TabSnapshot class — NOT
    // hand-written. Constructed two TabSnapshot instances with the CURRENT
    // (unmodified, commit cb523eb) class, called the real .toJson(), and
    // copied the exact resulting jsonEncode() output below, via a
    // temporary capture test file (test/_capture_fixture_test.dart)
    // deleted immediately after use — before touching
    // session_snapshot_repository.dart in any way. See the apply report
    // for the exact capture script.
    //
    // Unlike ConnectionProfile's round-trip fixtures, there is no
    // "without session" variant here: tmuxSessionName is `required
    // String`, not nullable, so every real TabSnapshot instance always
    // carries one (same structural reason as ProjectShortcut's fixtures).
    //
    // If a future change makes either fixture below fail to load, the
    // correct response is to fix session_snapshot_repository.dart, never
    // to edit these two strings — they are the shape of data that is
    // actually sitting in SharedPreferences on real devices right now.
    const preMigrationJsonA =
        '{"profileId":"profile-1","profileName":"Mac Studio",'
        '"tmuxSessionName":"helm-work"}';
    const preMigrationJsonB =
        '{"profileId":"profile-2","profileName":"Contabo VPS",'
        '"tmuxSessionName":"deploy-session"}';

    test(
      'FIXTURE_A loads with every field intact and the session name '
      'available under sessionRef',
      () {
        final snapshot = TabSnapshot.fromJson(
          jsonDecode(preMigrationJsonA) as Map<String, dynamic>,
        );

        expect(snapshot.profileId, 'profile-1');
        expect(snapshot.profileName, 'Mac Studio');
        expect(snapshot.tmuxSessionName, 'helm-work');
        expect(snapshot.sessionRef, 'helm-work');
      },
    );

    test(
      'FIXTURE_B loads with every field intact and the session name '
      'available under sessionRef',
      () {
        final snapshot = TabSnapshot.fromJson(
          jsonDecode(preMigrationJsonB) as Map<String, dynamic>,
        );

        expect(snapshot.profileId, 'profile-2');
        expect(snapshot.profileName, 'Contabo VPS');
        expect(snapshot.tmuxSessionName, 'deploy-session');
        expect(snapshot.sessionRef, 'deploy-session');
      },
    );

    test(
      'loading then re-saving a pre-migration snapshot keeps every '
      'original field value and adds the neutral key alongside the '
      'untouched legacy key',
      () {
        final snapshot = TabSnapshot.fromJson(
          jsonDecode(preMigrationJsonB) as Map<String, dynamic>,
        );

        final resaved = snapshot.toJson();

        expect(resaved['profileId'], 'profile-2');
        expect(resaved['profileName'], 'Contabo VPS');
        expect(resaved['tmuxSessionName'], 'deploy-session');
        expect(resaved['sessionRef'], 'deploy-session');
      },
    );
  });
}
