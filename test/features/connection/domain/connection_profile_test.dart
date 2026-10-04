// Tests for the session-reference storage migration (spec.md:
// session-reference-storage). See openspec/changes/host-session-contract/
// specs/session-reference-storage/spec.md for the normative requirements
// these groups are named after.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';

void main() {
  group('Legacy Field Still Readable', () {
    test('a record containing only the legacy tmuxSession key loads with its '
        'value available under the new sessionRef field', () {
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
    });

    test('a legacy-only record with no session name at all loads with a null '
        'sessionRef, never an invented default', () {
      final profile = ConnectionProfile.fromJson({
        'id': 'def-456',
        'name': 'Contabo VPS',
        'host': '158.220.106.131',
        'username': 'deployer',
      });

      expect(profile.sessionRef, isNull);
    });
  });

  group('Legacy Key Is Not Deleted', () {
    test('saving a record loaded from a legacy-only JSON emits both the '
        'tmuxSession and sessionRef keys', () {
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
    });

    test('saving a newly created record (constructed directly, sessionRef '
        'set) still emits both keys', () {
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
    });
  });

  group('Neutral Field Takes Precedence When Both Are Present', () {
    test('when tmuxSession and sessionRef hold different values, the resolved '
        'sessionRef equals the neutral field\'s own value', () {
      final profile = ConnectionProfile.fromJson({
        'id': 'abc-123',
        'name': 'Mac Studio',
        'host': '192.168.1.10',
        'username': 'gian',
        'tmuxSession': 'old-legacy-name',
        'sessionRef': 'new-neutral-name',
      });

      expect(profile.sessionRef, 'new-neutral-name');
    });

    test('precedence holds regardless of key order in the source map', () {
      final profile = ConnectionProfile.fromJson({
        'id': 'abc-123',
        'name': 'Mac Studio',
        'host': '192.168.1.10',
        'username': 'gian',
        'sessionRef': 'neutral-wins',
        'tmuxSession': 'legacy-loses',
      });

      expect(profile.sessionRef, 'neutral-wins');
    });
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

    test('a pre-migration profile WITH a tmux session name loads with every '
        'field intact and the session name available under sessionRef', () {
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
    });

    test('a pre-migration profile WITHOUT a tmux session name loads with '
        'every field intact and a null sessionRef, never an invented '
        'default', () {
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
    });

    test('loading then re-saving a pre-migration profile keeps every original '
        'field value and adds the neutral key alongside the untouched '
        'legacy key', () {
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
    });
  });

  group('Background hold is chosen, never inherited', () {
    // Captured VERBATIM from the app as it stood BEFORE holdInBackground
    // existed (commit 831c33c): two ConnectionProfile instances were built
    // with the unmodified class, .toJson() was called on each, and the
    // jsonEncode() output was copied here before connection_profile.dart
    // was touched at all.
    //
    // These are the shape of records sitting in SharedPreferences on real
    // devices right now. If a future change makes either fail to load, fix
    // the class — never these strings.
    const preFieldJsonConfigured =
        '{"id":"abc-123","name":"Mac Studio","host":"192.168.1.10","port":22,'
        '"username":"gian","tmuxSession":"work","sessionRef":"work",'
        '"multiplexer":"herdr","isDefault":true}';
    const preFieldJsonBare =
        '{"id":"def-456","name":"Contabo VPS","host":"158.220.106.131",'
        '"port":22,"username":"deployer","tmuxSession":null,'
        '"sessionRef":null,"multiplexer":null,"isDefault":false}';

    test('a profile saved before the field existed loads with the hold OFF - '
        'installing an update must never start a foreground service the user '
        'was never asked about', () {
      final profile = ConnectionProfile.fromJson(
        jsonDecode(preFieldJsonConfigured) as Map<String, dynamic>,
      );

      expect(profile.holdInBackground, isFalse);
      // And every field it did carry is still intact.
      expect(profile.id, 'abc-123');
      expect(profile.sessionRef, 'work');
      expect(profile.multiplexer, 'herdr');
      expect(profile.isDefault, isTrue);
    });

    test('the same is true of a bare profile, including the one that would be '
        'auto-connected on launch', () {
      final profile = ConnectionProfile.fromJson(
        jsonDecode(preFieldJsonBare) as Map<String, dynamic>,
      );

      expect(profile.holdInBackground, isFalse);
      expect(profile.username, 'deployer');
    });

    test('a profile constructed without an opinion defaults to OFF', () {
      const profile = ConnectionProfile(
        id: 'new-1',
        name: 'New Profile',
        host: '10.0.0.5',
        username: 'gian',
      );

      expect(profile.holdInBackground, isFalse);
    });

    test('turning the switch on survives a save and a load - the whole point '
        'of the preference is that it is chosen once', () {
      const profile = ConnectionProfile(
        id: 'held-1',
        name: 'Mac Studio',
        host: '192.168.1.10',
        username: 'gian',
        holdInBackground: true,
      );

      final reloaded = ConnectionProfile.fromJson(
        jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>,
      );

      expect(reloaded.holdInBackground, isTrue);
    });

    test('turning it back off survives the same round trip', () {
      const profile = ConnectionProfile(
        id: 'held-1',
        name: 'Mac Studio',
        host: '192.168.1.10',
        username: 'gian',
        holdInBackground: false,
      );

      final reloaded = ConnectionProfile.fromJson(
        jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>,
      );

      expect(reloaded.holdInBackground, isFalse);
      // Written out explicitly rather than omitted, so a record on disk
      // says what it means instead of relying on a reader's default.
      expect(profile.toJson().containsKey('holdInBackground'), isTrue);
    });
  });

  group('Font size is chosen, never inherited', () {
    // Captured VERBATIM from the app as it stood BEFORE fontSize existed
    // (this task's own starting commit, 389c69b): two ConnectionProfile
    // instances were built with the unmodified class, .toJson() was
    // called on each, and the jsonEncode() output was copied here before
    // connection_profile.dart was touched at all.
    //
    // These are the shape of records sitting in SharedPreferences on real
    // devices right now. If a future change makes either fail to load,
    // fix the class — never these strings.
    const preFieldJsonConfigured =
        '{"id":"abc-123","name":"Mac Studio","host":"192.168.1.10","port":22,'
        '"username":"gian","tmuxSession":"work","sessionRef":"work",'
        '"multiplexer":"herdr","isDefault":true,"holdInBackground":true}';
    const preFieldJsonBare =
        '{"id":"def-456","name":"Contabo VPS","host":"158.220.106.131",'
        '"port":22,"username":"deployer","tmuxSession":null,'
        '"sessionRef":null,"multiplexer":null,"isDefault":false,'
        '"holdInBackground":false}';

    test('a profile saved before the field existed loads at the exact point '
        'size that was hardcoded before this field existed, never a '
        'surprise resize on upgrade', () {
      final profile = ConnectionProfile.fromJson(
        jsonDecode(preFieldJsonConfigured) as Map<String, dynamic>,
      );

      expect(profile.fontSize, AppConstants.defaultTerminalFontSize);
      // And every field it did carry is still intact.
      expect(profile.id, 'abc-123');
      expect(profile.holdInBackground, isTrue);
    });

    test('the same is true of a bare profile, including the one that would be '
        'auto-connected on launch', () {
      final profile = ConnectionProfile.fromJson(
        jsonDecode(preFieldJsonBare) as Map<String, dynamic>,
      );

      expect(profile.fontSize, AppConstants.defaultTerminalFontSize);
      expect(profile.username, 'deployer');
    });

    test('a profile constructed without an opinion defaults to the documented '
        'point size', () {
      const profile = ConnectionProfile(
        id: 'new-1',
        name: 'New Profile',
        host: '10.0.0.5',
        username: 'gian',
      );

      expect(profile.fontSize, AppConstants.defaultTerminalFontSize);
    });

    test('choosing a smaller point size survives a save and a load - the '
        'whole point of the preference is that it is chosen once per '
        'profile', () {
      const profile = ConnectionProfile(
        id: 'sized-1',
        name: 'Agent Host',
        host: '192.168.1.10',
        username: 'gian',
        fontSize: 9,
      );

      final reloaded = ConnectionProfile.fromJson(
        jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>,
      );

      expect(reloaded.fontSize, 9);
    });

    test(
      'reverting to the default point size survives the same round trip',
      () {
        const profile = ConnectionProfile(
          id: 'sized-1',
          name: 'Agent Host',
          host: '192.168.1.10',
          username: 'gian',
          fontSize: AppConstants.defaultTerminalFontSize,
        );

        final reloaded = ConnectionProfile.fromJson(
          jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>,
        );

        expect(reloaded.fontSize, AppConstants.defaultTerminalFontSize);
        // Written out explicitly rather than omitted, so a record on disk
        // says what it means instead of relying on a reader's default.
        expect(profile.toJson().containsKey('fontSize'), isTrue);
      },
    );
  });
}
