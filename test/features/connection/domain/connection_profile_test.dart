// Tests for the session-reference storage migration (spec.md:
// session-reference-storage). See openspec/changes/host-session-contract/
// specs/session-reference-storage/spec.md for the normative requirements
// these groups are named after.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';

void main() {
  group('Legacy Field Still Readable', () {
    test(
      'a record containing only the legacy tmuxSession key loads with its '
      'value available under the new sessionRef field',
      () {
        final profile = ConnectionProfile.fromJson({
          'id': 'abc-123',
          'name': 'Mac Studio',
          'host': '192.168.1.10',
          'port': 22,
          'username': 'gian',
          'tmuxSession': 'helm',
          'isDefault': false,
        });

        expect(profile.sessionRef, 'helm');
      },
    );

    test(
      'a legacy-only record with no session name at all loads with a null '
      'sessionRef, never an invented default',
      () {
        final profile = ConnectionProfile.fromJson({
          'id': 'def-456',
          'name': 'Contabo VPS',
          'host': '158.220.106.131',
          'username': 'deployer',
        });

        expect(profile.sessionRef, isNull);
      },
    );
  });

  group('Legacy Key Is Not Deleted', () {
    test(
      'saving a record loaded from a legacy-only JSON emits both the '
      'tmuxSession and sessionRef keys',
      () {
        final profile = ConnectionProfile.fromJson({
          'id': 'abc-123',
          'name': 'Mac Studio',
          'host': '192.168.1.10',
          'username': 'gian',
          'tmuxSession': 'helm',
        });

        final json = profile.toJson();

        expect(json.containsKey('tmuxSession'), isTrue);
        expect(json.containsKey('sessionRef'), isTrue);
      },
    );

    test(
      'saving a newly created record (constructed directly, sessionRef '
      'set) still emits both keys',
      () {
        const profile = ConnectionProfile(
          id: 'new-1',
          name: 'New Profile',
          host: '10.0.0.5',
          username: 'gian',
          sessionRef: 'work',
        );

        final json = profile.toJson();

        expect(json.containsKey('tmuxSession'), isTrue);
        expect(json.containsKey('sessionRef'), isTrue);
        expect(json['sessionRef'], 'work');
      },
    );
  });

  group('Neutral Field Takes Precedence When Both Are Present', () {
    test(
      'when tmuxSession and sessionRef hold different values, the resolved '
      'sessionRef equals the neutral field\'s own value',
      () {
        final profile = ConnectionProfile.fromJson({
          'id': 'abc-123',
          'name': 'Mac Studio',
          'host': '192.168.1.10',
          'username': 'gian',
          'tmuxSession': 'old-legacy-name',
          'sessionRef': 'new-neutral-name',
        });

        expect(profile.sessionRef, 'new-neutral-name');
      },
    );

    test(
      'precedence holds regardless of key order in the source map',
      () {
        final profile = ConnectionProfile.fromJson({
          'id': 'abc-123',
          'name': 'Mac Studio',
          'host': '192.168.1.10',
          'username': 'gian',
          'sessionRef': 'neutral-wins',
          'tmuxSession': 'legacy-loses',
        });

        expect(profile.sessionRef, 'neutral-wins');
      },
    );
  });

  group('Round-trip: profile written by the pre-migration app version', () {
    // Captured VERBATIM from the pre-migration ConnectionProfile class —
    // NOT hand-written. Constructed two ConnectionProfile instances with
    // the CURRENT (unmodified, commit e274fa9) class, called the real
    // .toJson(), and copied the exact resulting jsonEncode() output below,
    // before touching connection_profile.dart in any way. See the apply
    // report for the exact capture script.
    //
    // If a future change makes either fixture below fail to load, the
    // correct response is to fix connection_profile.dart, never to edit
    // these two strings — they are the shape of data that is actually
    // sitting in SharedPreferences on real devices right now.
    const preMigrationJsonWithSession =
        '{"id":"abc-123","name":"Mac Studio","host":"192.168.1.10",'
        '"port":22,"username":"gian","tmuxSession":"work",'
        '"isDefault":true}';
    const preMigrationJsonWithoutSession =
        '{"id":"def-456","name":"Contabo VPS","host":"158.220.106.131",'
        '"port":22,"username":"deployer","tmuxSession":null,'
        '"isDefault":false}';

    test(
      'a pre-migration profile WITH a tmux session name loads with every '
      'field intact and the session name available under sessionRef',
      () {
        final profile = ConnectionProfile.fromJson(
          jsonDecode(preMigrationJsonWithSession) as Map<String, dynamic>,
        );

        expect(profile.id, 'abc-123');
        expect(profile.name, 'Mac Studio');
        expect(profile.host, '192.168.1.10');
        expect(profile.port, 22);
        expect(profile.username, 'gian');
        expect(profile.tmuxSession, 'work');
        expect(profile.sessionRef, 'work');
        expect(profile.isDefault, isTrue);
      },
    );

    test(
      'a pre-migration profile WITHOUT a tmux session name loads with '
      'every field intact and a null sessionRef, never an invented '
      'default',
      () {
        final profile = ConnectionProfile.fromJson(
          jsonDecode(preMigrationJsonWithoutSession) as Map<String, dynamic>,
        );

        expect(profile.id, 'def-456');
        expect(profile.name, 'Contabo VPS');
        expect(profile.host, '158.220.106.131');
        expect(profile.port, 22);
        expect(profile.username, 'deployer');
        expect(profile.tmuxSession, isNull);
        expect(profile.sessionRef, isNull);
        expect(profile.isDefault, isFalse);
      },
    );

    test(
      'loading then re-saving a pre-migration profile keeps every original '
      'field value and adds the neutral key alongside the untouched '
      'legacy key',
      () {
        final profile = ConnectionProfile.fromJson(
          jsonDecode(preMigrationJsonWithSession) as Map<String, dynamic>,
        );

        final resaved = profile.toJson();

        expect(resaved['id'], 'abc-123');
        expect(resaved['name'], 'Mac Studio');
        expect(resaved['host'], '192.168.1.10');
        expect(resaved['port'], 22);
        expect(resaved['username'], 'gian');
        expect(resaved['isDefault'], isTrue);
        expect(resaved['tmuxSession'], 'work');
        expect(resaved['sessionRef'], 'work');
      },
    );
  });
}
