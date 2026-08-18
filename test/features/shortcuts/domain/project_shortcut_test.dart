// Tests for the session-reference storage migration (spec.md:
// session-reference-storage). See openspec/changes/host-session-contract/
// specs/session-reference-storage/spec.md for the normative requirements
// these groups are named after. Mirrors
// test/features/connection/domain/connection_profile_test.dart's shape
// and fixture-capture discipline (task 6.10 repeats 6.1-6.9 for
// ProjectShortcut).
//
// One structural difference from ConnectionProfile, disclosed here and in
// the apply report: ProjectShortcut.tmuxSession is `required String`, not
// `String?`. Every ProjectShortcut has always carried a legacy session
// name, so a record missing the tmuxSession key entirely already fails to
// load today (json_serializable's `json['tmuxSession'] as String` throws
// on null) — that is pre-existing behavior, unchanged by this migration,
// and none of spec.md's three requirements need that state: each of them
// assumes the legacy key is present, either alone or alongside the
// neutral key.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/shortcuts/domain/project_shortcut.dart';

void main() {
  group('Legacy Field Still Readable', () {
    test(
      'a record containing only the legacy tmuxSession key loads with its '
      'value available under the new sessionRef field',
      () {
        final shortcut = ProjectShortcut.fromJson({
          'id': 'shortcut-abc',
          'name': 'Metalpren',
          'projectPath': '/home/gian/proyectos/metalpren',
          'tmuxSession': 'metalpren',
          'profileId': 'profile-1',
        });

        expect(shortcut.sessionRef, 'metalpren');
      },
    );
  });

  group('Legacy Key Is Not Deleted', () {
    test(
      'saving a record loaded from a legacy-only JSON emits both the '
      'tmuxSession and sessionRef keys',
      () {
        final shortcut = ProjectShortcut.fromJson({
          'id': 'shortcut-abc',
          'name': 'Metalpren',
          'projectPath': '/home/gian/proyectos/metalpren',
          'tmuxSession': 'metalpren',
          'profileId': 'profile-1',
        });

        final json = shortcut.toJson();

        expect(json.containsKey('tmuxSession'), isTrue);
        expect(json.containsKey('sessionRef'), isTrue);
      },
    );

    test(
      'saving a newly created record (constructed directly, sessionRef '
      'set) still emits both keys',
      () {
        const shortcut = ProjectShortcut(
          id: 'shortcut-new',
          name: 'New Project',
          projectPath: '/home/gian/new-project',
          tmuxSession: 'legacy-name',
          profileId: 'profile-1',
          sessionRef: 'neutral-name',
        );

        final json = shortcut.toJson();

        expect(json.containsKey('tmuxSession'), isTrue);
        expect(json.containsKey('sessionRef'), isTrue);
        expect(json['sessionRef'], 'neutral-name');
      },
    );
  });

  group('Neutral Field Takes Precedence When Both Are Present', () {
    test(
      'when tmuxSession and sessionRef hold different values, the resolved '
      'sessionRef equals the neutral field\'s own value',
      () {
        final shortcut = ProjectShortcut.fromJson({
          'id': 'shortcut-abc',
          'name': 'Metalpren',
          'projectPath': '/home/gian/proyectos/metalpren',
          'tmuxSession': 'old-legacy-name',
          'sessionRef': 'new-neutral-name',
          'profileId': 'profile-1',
        });

        expect(shortcut.sessionRef, 'new-neutral-name');
      },
    );

    test(
      'precedence holds regardless of key order in the source map',
      () {
        final shortcut = ProjectShortcut.fromJson({
          'id': 'shortcut-abc',
          'name': 'Metalpren',
          'projectPath': '/home/gian/proyectos/metalpren',
          'sessionRef': 'neutral-wins',
          'tmuxSession': 'legacy-loses',
          'profileId': 'profile-1',
        });

        expect(shortcut.sessionRef, 'neutral-wins');
      },
    );
  });

  group('Round-trip: shortcut written by the pre-migration app version', () {
    // Captured VERBATIM from the pre-migration ProjectShortcut class — NOT
    // hand-written. Constructed two ProjectShortcut instances with the
    // CURRENT (unmodified, commit ea6f7e1) class, called the real
    // .toJson(), and copied the exact resulting jsonEncode() output below,
    // via a temporary capture test file deleted immediately after use —
    // before touching project_shortcut.dart in any way. See the apply
    // report for the exact capture script.
    //
    // Unlike ConnectionProfile's round-trip fixtures, there is no
    // "without session" variant here: tmuxSession is `required String`,
    // not nullable, so every real ProjectShortcut instance always carries
    // one. FIXTURE_A uses the default command/sortOrder; FIXTURE_B uses
    // non-default values for both, for coverage.
    //
    // If a future change makes either fixture below fail to load, the
    // correct response is to fix project_shortcut.dart, never to edit
    // these two strings — they are the shape of data that is actually
    // sitting in SharedPreferences on real devices right now.
    const preMigrationJsonA =
        '{"id":"shortcut-abc","name":"Metalpren",'
        '"projectPath":"/home/gian/proyectos/metalpren",'
        '"tmuxSession":"metalpren","command":"","profileId":"profile-1",'
        '"sortOrder":0}';
    const preMigrationJsonB =
        '{"id":"shortcut-def","name":"Helm",'
        '"projectPath":"/home/deployer/helm","tmuxSession":"helm-dev",'
        '"command":"opencode","profileId":"profile-2","sortOrder":3}';

    test(
      'FIXTURE_A loads with every field intact and the session name '
      'available under sessionRef',
      () {
        final shortcut = ProjectShortcut.fromJson(
          jsonDecode(preMigrationJsonA) as Map<String, dynamic>,
        );

        expect(shortcut.id, 'shortcut-abc');
        expect(shortcut.name, 'Metalpren');
        expect(shortcut.projectPath, '/home/gian/proyectos/metalpren');
        expect(shortcut.tmuxSession, 'metalpren');
        expect(shortcut.sessionRef, 'metalpren');
        expect(shortcut.command, '');
        expect(shortcut.profileId, 'profile-1');
        expect(shortcut.sortOrder, 0);
      },
    );

    test(
      'FIXTURE_B loads with every field intact and the session name '
      'available under sessionRef',
      () {
        final shortcut = ProjectShortcut.fromJson(
          jsonDecode(preMigrationJsonB) as Map<String, dynamic>,
        );

        expect(shortcut.id, 'shortcut-def');
        expect(shortcut.name, 'Helm');
        expect(shortcut.projectPath, '/home/deployer/helm');
        expect(shortcut.tmuxSession, 'helm-dev');
        expect(shortcut.sessionRef, 'helm-dev');
        expect(shortcut.command, 'opencode');
        expect(shortcut.profileId, 'profile-2');
        expect(shortcut.sortOrder, 3);
      },
    );

    test(
      'loading then re-saving a pre-migration shortcut keeps every '
      'original field value and adds the neutral key alongside the '
      'untouched legacy key',
      () {
        final shortcut = ProjectShortcut.fromJson(
          jsonDecode(preMigrationJsonB) as Map<String, dynamic>,
        );

        final resaved = shortcut.toJson();

        expect(resaved['id'], 'shortcut-def');
        expect(resaved['name'], 'Helm');
        expect(resaved['projectPath'], '/home/deployer/helm');
        expect(resaved['command'], 'opencode');
        expect(resaved['profileId'], 'profile-2');
        expect(resaved['sortOrder'], 3);
        expect(resaved['tmuxSession'], 'helm-dev');
        expect(resaved['sessionRef'], 'helm-dev');
      },
    );
  });
}
