import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/features/connection/data/connection_profile_repository.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The background-hold preference, through the storage it actually lives in.
///
/// `connection_profile_test.dart` covers the same field at the model's own
/// JSON boundary. This file exists because the preference's whole promise
/// is "choose it once", and the only thing that can keep that promise is
/// the repository plus SharedPreferences — a model that serializes
/// correctly into a store that drops the value would still break it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ConnectionProfileRepository repo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repo = ConnectionProfileRepository();
  });

  test('a profile saved with the hold on comes back with it on', () async {
    await repo.create(
      const ConnectionProfile(
        id: 'p-1',
        name: 'Mac Studio',
        host: '192.168.1.10',
        username: 'gian',
        holdInBackground: true,
      ),
    );

    final reloaded = await repo.getById('p-1');

    expect(reloaded!.holdInBackground, isTrue);
  });

  test('editing an unrelated field does not silently drop the hold', () async {
    // The profile editor rebuilds the whole ConnectionProfile on every
    // save, so a field it forgot to carry would be erased by an edit to
    // the host name — silently turning the preference off between one
    // save and the next.
    await repo.create(
      const ConnectionProfile(
        id: 'p-1',
        name: 'Mac Studio',
        host: '192.168.1.10',
        username: 'gian',
        holdInBackground: true,
      ),
    );

    final loaded = await repo.getById('p-1');
    await repo.update(loaded!.copyWith(host: '192.168.1.11'));

    final reloaded = await repo.getById('p-1');
    expect(reloaded!.host, '192.168.1.11');
    expect(reloaded.holdInBackground, isTrue);
  });

  test('marking a profile default leaves its hold preference alone', () async {
    // `setDefault` rewrites every stored profile through copyWith. Two
    // switches sit side by side in the editor, and one must not move the
    // other.
    await repo.create(
      const ConnectionProfile(
        id: 'p-1',
        name: 'Mac Studio',
        host: '192.168.1.10',
        username: 'gian',
        holdInBackground: true,
      ),
    );
    await repo.create(
      const ConnectionProfile(
        id: 'p-2',
        name: 'Contabo VPS',
        host: '158.220.106.131',
        username: 'deployer',
      ),
    );

    await repo.setDefault('p-2');

    expect((await repo.getById('p-1'))!.holdInBackground, isTrue);
    expect((await repo.getById('p-1'))!.isDefault, isFalse);
    expect((await repo.getById('p-2'))!.holdInBackground, isFalse);
    expect((await repo.getById('p-2'))!.isDefault, isTrue);
  });

  test(
    'a store written by a version that had no such field loads with the '
    'hold off, for every profile in it',
    () async {
      // Read straight out of the store rather than round-tripped through
      // the model, because this is the upgrade path: the strings below are
      // what an existing install has on disk the moment it takes this
      // update.
      SharedPreferences.setMockInitialValues({
        AppConstants.profilesStorageKey: [
          '{"id":"abc-123","name":"Mac Studio","host":"192.168.1.10",'
              '"port":22,"username":"gian","tmuxSession":"work",'
              '"sessionRef":"work","multiplexer":"herdr","isDefault":true}',
          '{"id":"def-456","name":"Contabo VPS","host":"158.220.106.131",'
              '"port":22,"username":"deployer","tmuxSession":null,'
              '"sessionRef":null,"multiplexer":null,"isDefault":false}',
        ],
      });

      final all = await ConnectionProfileRepository().getAll();

      expect(all, hasLength(2));
      expect(all.every((p) => !p.holdInBackground), isTrue);
    },
  );

  test('the stored JSON carries the field explicitly once saved', () async {
    await repo.create(
      const ConnectionProfile(
        id: 'p-1',
        name: 'Mac Studio',
        host: '192.168.1.10',
        username: 'gian',
        holdInBackground: true,
      ),
    );

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(AppConstants.profilesStorageKey)!.single;
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['holdInBackground'], isTrue);
  });
}
