import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/features/connection/data/connection_profile_repository.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The per-profile terminal font size, through the storage it actually
/// lives in.
///
/// `connection_profile_test.dart` covers the same field at the model's own
/// JSON boundary. This file exists for the same reason
/// `connection_profile_repository_hold_test.dart` exists for
/// `holdInBackground`: the preference's whole promise is "choose it once
/// per profile", and only the repository plus SharedPreferences can keep
/// that promise — a model that serializes correctly into a store that
/// drops the value would still break it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ConnectionProfileRepository repo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repo = ConnectionProfileRepository();
  });

  test('a profile saved with a smaller font size comes back with that exact '
      'size', () async {
    await repo.create(
      const ConnectionProfile(
        id: 'p-1',
        name: 'Agent Host',
        host: '192.168.1.10',
        username: 'gian',
        fontSize: 9,
      ),
    );

    final reloaded = await repo.getById('p-1');

    expect(reloaded!.fontSize, 9);
  });

  test(
    'editing an unrelated field does not silently drop the font size',
    () async {
      // The profile editor rebuilds the whole ConnectionProfile on every
      // save, so a field it forgot to carry would be erased by an edit to
      // the host name — silently resetting a chosen size between one save
      // and the next.
      await repo.create(
        const ConnectionProfile(
          id: 'p-1',
          name: 'Agent Host',
          host: '192.168.1.10',
          username: 'gian',
          fontSize: 9,
        ),
      );

      final loaded = await repo.getById('p-1');
      await repo.update(loaded!.copyWith(host: '192.168.1.11'));

      final reloaded = await repo.getById('p-1');
      expect(reloaded!.host, '192.168.1.11');
      expect(reloaded.fontSize, 9);
    },
  );

  test('marking a profile default leaves its chosen font size alone', () async {
    // `setDefault` rewrites every stored profile through copyWith.
    await repo.create(
      const ConnectionProfile(
        id: 'p-1',
        name: 'Agent Host',
        host: '192.168.1.10',
        username: 'gian',
        fontSize: 9,
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

    expect((await repo.getById('p-1'))!.fontSize, 9);
    expect((await repo.getById('p-1'))!.isDefault, isFalse);
    expect(
      (await repo.getById('p-2'))!.fontSize,
      AppConstants.defaultTerminalFontSize,
    );
    expect((await repo.getById('p-2'))!.isDefault, isTrue);
  });

  test('a store written by a version that had no such field loads at the '
      'documented default size, for every profile in it', () async {
    // Read straight out of the store rather than round-tripped through
    // the model, because this is the upgrade path: the strings below
    // are what an existing install has on disk the moment it takes
    // this update.
    SharedPreferences.setMockInitialValues({
      AppConstants.profilesStorageKey: [
        '{"id":"abc-123","name":"Mac Studio","host":"192.168.1.10",'
            '"port":22,"username":"gian","tmuxSession":"work",'
            '"sessionRef":"work","multiplexer":"herdr","isDefault":true,'
            '"holdInBackground":true}',
        '{"id":"def-456","name":"Contabo VPS","host":"158.220.106.131",'
            '"port":22,"username":"deployer","tmuxSession":null,'
            '"sessionRef":null,"multiplexer":null,"isDefault":false,'
            '"holdInBackground":false}',
      ],
    });

    final all = await ConnectionProfileRepository().getAll();

    expect(all, hasLength(2));
    expect(
      all.every((p) => p.fontSize == AppConstants.defaultTerminalFontSize),
      isTrue,
    );
  });

  test('the stored JSON carries the field explicitly once saved', () async {
    await repo.create(
      const ConnectionProfile(
        id: 'p-1',
        name: 'Agent Host',
        host: '192.168.1.10',
        username: 'gian',
        fontSize: 9,
      ),
    );

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(AppConstants.profilesStorageKey)!.single;
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['fontSize'], 9);
  });
}
