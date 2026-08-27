// Tests for where the user's chosen download folder is remembered.
//
// The assertion this file exists for: a folder chosen once is still there
// on the next launch, and clearing it really clears it. Everything else in
// slice 2b is built on that persistence holding, because a grant the app
// forgets is a grant the user is asked for again.
//
// Storage is `shared_preferences`, NOT `flutter_secure_storage`, and that
// is a decision rather than a default — see [DownloadDestinationStore].
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/files/data/download_destination_store.dart';
import 'package:helm/features/files/domain/download_destination.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _destination = DownloadDestination(
  uri: 'content://com.android.externalstorage.documents/tree/primary%3ADownload%2FHelm',
  name: 'Helm',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('with nothing chosen yet', () {
    test('reads back null rather than an empty destination', () async {
      expect(await DownloadDestinationStore().read(), isNull);
    });

    test('clearing is harmless when there is nothing to clear', () async {
      final store = DownloadDestinationStore();
      await store.clear();
      expect(await store.read(), isNull);
    });
  });

  group('after a folder is chosen', () {
    test('reads back the same uri and name', () async {
      final store = DownloadDestinationStore();
      await store.write(_destination);

      final read = await store.read();
      expect(read, isNotNull);
      expect(read!.uri, _destination.uri);
      expect(read.name, 'Helm');
    });

    test('a second choice replaces the first', () async {
      final store = DownloadDestinationStore();
      await store.write(_destination);
      await store.write(
        const DownloadDestination(uri: 'content://other/tree', name: 'Papers'),
      );

      final read = await store.read();
      expect(read!.name, 'Papers');
      expect(read.uri, 'content://other/tree');
    });

    test('clearing returns it to the no-folder state', () async {
      final store = DownloadDestinationStore();
      await store.write(_destination);
      await store.clear();

      expect(await store.read(), isNull);
    });

    test('a separate instance sees it, so it survives a restart', () async {
      await DownloadDestinationStore().write(_destination);

      expect(await DownloadDestinationStore().read(), _destination);
    });
  });

  group('corrupt stored value', () {
    test('is treated as no folder rather than thrown at the caller', () async {
      SharedPreferences.setMockInitialValues({
        'helm_download_destination': 'not json at all',
      });

      expect(await DownloadDestinationStore().read(), isNull);
    });

    test('a record missing its uri is treated as no folder', () async {
      SharedPreferences.setMockInitialValues({
        'helm_download_destination': '{"name":"Helm"}',
      });

      expect(await DownloadDestinationStore().read(), isNull);
    });
  });
}
