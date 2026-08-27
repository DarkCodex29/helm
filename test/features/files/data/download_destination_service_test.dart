// Tests for publishing a finished download into the folder the user chose.
//
// The assertions this file exists for:
//
//  * PUBLISHING IS NOT THE DOWNLOAD. Every ending here happens after the
//    bytes are already on the device, so none of them may be spelled in a
//    way a caller could mistake for a transfer that failed.
//  * The three ways "nothing was copied" happens stay apart: nowhere was
//    chosen, nowhere needed choosing, and somewhere was chosen that no
//    longer works.
//  * A grant that has gone away is DETECTED and the dead folder forgotten,
//    rather than swallowed while the app keeps claiming a destination it
//    cannot write to.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/files/data/download_destination_service.dart';
import 'package:helm/features/files/data/download_destination_store.dart';
import 'package:helm/features/files/domain/download_destination.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fake_document_tree_gateway.dart';

const _folder = DownloadDestination(
  uri: 'content://com.android.externalstorage.documents/tree/primary%3ADownload%2FHelm',
  name: 'Helm',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory staging;
  late DownloadDestinationStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    staging = Directory.systemTemp.createTempSync('helm_publish');
    store = DownloadDestinationStore();
  });

  tearDown(() {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
  });

  File staged(String name) =>
      File('${staging.path}/$name')..writeAsBytesSync(List<int>.filled(64, 7));

  DownloadDestinationService serviceWith(
    FakeDocumentTreeGateway gateway, {
    bool supportsFolderChoice = true,
  }) => DownloadDestinationService(
    store: store,
    gateway: gateway,
    supportsFolderChoice: supportsFolderChoice,
  );

  group('with a folder chosen', () {
    test('copies the file and says where it went', () async {
      await store.write(_folder);
      final gateway = FakeDocumentTreeGateway();

      final outcome = await serviceWith(
        gateway,
      ).publish(staged('report.docx'));

      expect(outcome, isA<PublishedToFolder>());
      final published = outcome as PublishedToFolder;
      expect(published.folderName, 'Helm');
      expect(published.fileName, 'report.docx');
      expect(gateway.copiedNames, ['report.docx']);
    });

    test('hands over the staged file itself, not a path it rebuilt', () async {
      await store.write(_folder);
      final gateway = FakeDocumentTreeGateway();
      final file = staged('report.docx');

      await serviceWith(gateway).publish(file);

      expect(gateway.copiedSources.single.path, file.path);
    });
  });

  group('name collision', () {
    test('keeps the existing file and reports the name it really got', () async {
      await store.write(_folder);
      final gateway = FakeDocumentTreeGateway()
        ..existingNames.add('report.docx');

      final outcome = await serviceWith(
        gateway,
      ).publish(staged('report.docx'));

      // The point of the assertion is the PAIR: nothing was overwritten,
      // and the user is told the new name rather than left looking for a
      // `report.docx` that is somebody else's file.
      expect(outcome, isA<PublishedToFolder>());
      expect((outcome as PublishedToFolder).fileName, 'report(1).docx');
    });
  });

  group('with no folder chosen', () {
    test('reports that nothing is configured, NOT a failure', () async {
      final outcome = await serviceWith(
        FakeDocumentTreeGateway(),
      ).publish(staged('report.docx'));

      expect(outcome, isA<PublishNotConfigured>());
      expect(outcome, isNot(isA<PublishFailed>()));
    });

    test('copies nothing and never asks the platform anything', () async {
      final gateway = FakeDocumentTreeGateway();

      await serviceWith(gateway).publish(staged('report.docx'));

      expect(gateway.copiedNames, isEmpty);
      expect(gateway.pickCalls, 0);
    });
  });

  group('a revoked grant', () {
    test('is reported as permissionLost, never silently swallowed', () async {
      await store.write(_folder);
      final gateway = FakeDocumentTreeGateway()..writeGrant = false;

      final outcome = await serviceWith(
        gateway,
      ).publish(staged('report.docx'));

      expect(outcome, isA<PublishFailed>());
      expect((outcome as PublishFailed).reason, PublishFailure.permissionLost);
    });

    test('does not attempt the copy', () async {
      await store.write(_folder);
      final gateway = FakeDocumentTreeGateway()..writeGrant = false;

      await serviceWith(gateway).publish(staged('report.docx'));

      expect(gateway.copiedNames, isEmpty);
    });

    test('forgets the dead folder, so the user is asked again', () async {
      await store.write(_folder);
      final gateway = FakeDocumentTreeGateway()..writeGrant = false;

      await serviceWith(gateway).publish(staged('report.docx'));

      expect(await store.read(), isNull);
    });

    test('does not try to hand back a grant that is already gone', () async {
      await store.write(_folder);
      final gateway = FakeDocumentTreeGateway()..writeGrant = false;

      await serviceWith(gateway).publish(staged('report.docx'));

      expect(gateway.releasedUris, isEmpty);
    });
  });

  group('a deleted destination', () {
    test('is told apart from a revoked grant', () async {
      await store.write(_folder);
      final gateway = FakeDocumentTreeGateway()
        ..folderPresent = false
        ..copyError = const FileSystemException('no such directory');

      final outcome = await serviceWith(
        gateway,
      ).publish(staged('report.docx'));

      expect(outcome, isA<PublishFailed>());
      final failed = outcome as PublishFailed;
      expect(failed.reason, PublishFailure.destinationMissing);
      expect(failed.reason, isNot(PublishFailure.permissionLost));
    });

    test('forgets the folder, because the uri now names nothing', () async {
      await store.write(_folder);
      final gateway = FakeDocumentTreeGateway()
        ..folderPresent = false
        ..copyError = const FileSystemException('no such directory');

      await serviceWith(gateway).publish(staged('report.docx'));

      expect(await store.read(), isNull);
    });
  });

  group('a copy that fails with the folder still there', () {
    test('is storage, and the folder is KEPT', () async {
      await store.write(_folder);
      final gateway = FakeDocumentTreeGateway()
        ..copyError = const FileSystemException('no space left on device');

      final outcome = await serviceWith(
        gateway,
      ).publish(staged('report.docx'));

      expect((outcome as PublishFailed).reason, PublishFailure.storage);
      // Kept on purpose: a full disk is not a reason to make the user
      // choose a folder again.
      expect(await store.read(), isNotNull);
    });
  });

  group('a platform with no folder to choose', () {
    test('reports notNeeded, which is not notConfigured', () async {
      final outcome = await serviceWith(
        FakeDocumentTreeGateway(),
        supportsFolderChoice: false,
      ).publish(staged('report.docx'));

      expect(outcome, isA<PublishNotNeeded>());
      expect(outcome, isNot(isA<PublishNotConfigured>()));
      expect(outcome, isNot(isA<PublishFailed>()));
    });

    test('never reaches the platform, even with a folder stored', () async {
      await store.write(_folder);
      final gateway = FakeDocumentTreeGateway();

      final service = serviceWith(gateway, supportsFolderChoice: false);
      await service.publish(staged('report.docx'));
      final chosen = await service.choose();

      expect(gateway.copiedNames, isEmpty);
      expect(gateway.pickCalls, 0);
      expect(chosen, isNull);
    });

    test('reports no current folder, so no UI offers to change one', () async {
      await store.write(_folder);

      final service = serviceWith(
        FakeDocumentTreeGateway(),
        supportsFolderChoice: false,
      );

      expect(await service.current(), isNull);
      expect(service.supportsFolderChoice, isFalse);
    });
  });

  group('choosing a folder', () {
    test('remembers what the picker returned', () async {
      final service = serviceWith(FakeDocumentTreeGateway(picks: _folder));

      final chosen = await service.choose();

      expect(chosen, _folder);
      expect(await store.read(), _folder);
    });

    test('opens the picker at Downloads, one step from a sensible answer', () async {
      final gateway = FakeDocumentTreeGateway(picks: _folder);

      await serviceWith(gateway).choose();

      // Null means "the gateway picks its own default", which is the
      // Downloads seed documented on SafDocumentTreeGateway.
      expect(gateway.pickedWith, [null]);
    });

    test('a declined picker leaves the previous choice untouched', () async {
      await store.write(_folder);
      final service = serviceWith(FakeDocumentTreeGateway());

      final chosen = await service.choose();

      expect(chosen, isNull);
      expect(await store.read(), _folder);
    });
  });

  group('forgetting a folder', () {
    test('returns to the no-folder state', () async {
      await store.write(_folder);
      final service = serviceWith(FakeDocumentTreeGateway());

      await service.forget();

      expect(await store.read(), isNull);
      expect(await service.current(), isNull);
    });

    test('hands the grant back, rather than holding it forever', () async {
      await store.write(_folder);
      final gateway = FakeDocumentTreeGateway();

      await serviceWith(gateway).forget();

      expect(gateway.releasedUris, [_folder.uri]);
    });

    test('forgets even when handing the grant back fails', () async {
      await store.write(_folder);
      final gateway = _ReleaseHostileGateway();

      await serviceWith(gateway).forget();

      // The user asked to forget it. A platform that will not take its
      // grant back must not leave them still pointed at that folder.
      expect(await store.read(), isNull);
    });

    test('after forgetting, a publish reports notConfigured again', () async {
      await store.write(_folder);
      final service = serviceWith(FakeDocumentTreeGateway());

      await service.forget();
      final outcome = await service.publish(staged('report.docx'));

      expect(outcome, isA<PublishNotConfigured>());
    });
  });
}

/// A gateway whose [releaseFolder] always throws, for the one test that
/// needs forgetting to survive the platform refusing its half of it.
class _ReleaseHostileGateway extends FakeDocumentTreeGateway {
  @override
  Future<void> releaseFolder(String uri) async =>
      throw const FileSystemException('permission table is busy');
}
