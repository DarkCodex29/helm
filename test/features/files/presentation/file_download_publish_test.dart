// Tests for the seam between a finished download and the user's folder.
//
// The assertion this whole file exists for, stated once: A PUBLISH FAILURE
// IS NOT A DOWNLOAD FAILURE. The bytes are on the device and openable by
// the time publishing is even attempted, so no outcome here may turn
// [FileDownloadStatus.opened] into [FileDownloadStatus.failed]. Everything
// else — the collision naming, the revoked grant, the platform split — is
// a specific way of not breaking that.
//
// Slice 2a's test for this pair is `file_download_provider_test.dart`,
// which guards the download/viewer seam. This one guards the
// download/storage seam, and the two are kept in separate files for the
// same reason the states are kept in separate fields.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/files/data/download_destination_service.dart';
import 'package:helm/features/files/data/download_destination_store.dart';
import 'package:helm/features/files/data/external_viewer.dart';
import 'package:helm/features/files/data/sftp_download_service.dart';
import 'package:helm/features/files/domain/download_destination.dart';
import 'package:helm/features/files/domain/remote_entry.dart';
import 'package:helm/features/files/presentation/providers/download_destination_provider.dart';
import 'package:helm/features/files/presentation/providers/file_download_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fake_document_tree_gateway.dart';
import '../../../helpers/fake_sftp_session.dart';

const _folder = DownloadDestination(
  uri: 'content://com.android.externalstorage.documents/tree/primary%3ADownload%2FHelm',
  name: 'Helm',
);

RemoteEntry _entry(String path) => RemoteEntry(
  name: path.split('/').last,
  path: path,
  kind: RemoteEntryKind.file,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory staging;
  late DownloadDestinationStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    staging = Directory.systemTemp.createTempSync('helm_download_publish');
    store = DownloadDestinationStore();
  });

  tearDown(() {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
  });

  ProviderContainer containerWith(
    FakeDocumentTreeGateway gateway, {
    bool supportsFolderChoice = true,
  }) => ProviderContainer(
    overrides: [
      downloadDestinationServiceProvider.overrideWithValue(
        DownloadDestinationService(
          store: store,
          gateway: gateway,
          supportsFolderChoice: supportsFolderChoice,
        ),
      ),
    ],
  );

  SftpDownloadService downloadOf(String path, {int size = 2048}) =>
      SftpDownloadService.withOpener(
        () async => FakeSftpSession(
          files: {path: FakeRemoteFile(List<int>.filled(size, 7))},
        ),
        directory: () async => staging,
        idleTimeout: const Duration(milliseconds: 200),
      );

  FileDownloadNotifier notifierIn(
    ProviderContainer container, {
    ViewerOutcome viewer = ViewerOutcome.opened,
  }) => container.read(fileDownloadProvider.notifier)
    ..debugUseViewer((_) async => viewer);

  group('with a folder chosen', () {
    test('the file is copied there and the state says where', () async {
      await store.write(_folder);
      final gateway = FakeDocumentTreeGateway();
      final container = containerWith(gateway);
      addTearDown(container.dispose);

      await notifierIn(container).start(
        downloadOf('/home/gian/report.docx'),
        _entry('/home/gian/report.docx'),
      );

      final state = container.read(fileDownloadProvider);
      expect(state.status, FileDownloadStatus.opened);
      expect(state.publish, isA<PublishedToFolder>());
      final published = state.publish! as PublishedToFolder;
      expect(published.folderName, 'Helm');
      expect(published.fileName, 'report.docx');
      expect(gateway.copiedNames, ['report.docx']);
    });

    test('a name already taken is saved beside it, under the real name', () async {
      await store.write(_folder);
      final gateway = FakeDocumentTreeGateway()
        ..existingNames.add('report.docx');
      final container = containerWith(gateway);
      addTearDown(container.dispose);

      await notifierIn(container).start(
        downloadOf('/home/gian/report.docx'),
        _entry('/home/gian/report.docx'),
      );

      final published =
          container.read(fileDownloadProvider).publish! as PublishedToFolder;
      expect(published.fileName, 'report(1).docx');
    });
  });

  group('with no folder chosen', () {
    test('the download still succeeds and still opens', () async {
      final container = containerWith(FakeDocumentTreeGateway());
      addTearDown(container.dispose);
      File? handed;
      final notifier = container.read(fileDownloadProvider.notifier)
        ..debugUseViewer((file) async {
          handed = file;
          return ViewerOutcome.opened;
        });

      await notifier.start(
        downloadOf('/home/gian/report.docx'),
        _entry('/home/gian/report.docx'),
      );

      final state = container.read(fileDownloadProvider);
      expect(state.status, FileDownloadStatus.opened);
      expect(handed, isNotNull);
      expect(handed!.existsSync(), isTrue);
    });

    test('the offer to choose one is carried, not an error', () async {
      final container = containerWith(FakeDocumentTreeGateway());
      addTearDown(container.dispose);

      await notifierIn(container).start(
        downloadOf('/home/gian/report.docx'),
        _entry('/home/gian/report.docx'),
      );

      final state = container.read(fileDownloadProvider);
      expect(state.publish, isA<PublishNotConfigured>());
      expect(state.publishNeedsReporting, isTrue);
      expect(state.status, isNot(FileDownloadStatus.failed));
    });
  });

  group('a publish that fails', () {
    test('does NOT turn a successful download into a failed one', () async {
      await store.write(_folder);
      final gateway = FakeDocumentTreeGateway()
        ..copyError = const FileSystemException('no space left on device');
      final container = containerWith(gateway);
      addTearDown(container.dispose);

      await notifierIn(container).start(
        downloadOf('/home/gian/report.docx'),
        _entry('/home/gian/report.docx'),
      );

      final state = container.read(fileDownloadProvider);
      // The whole point, in three lines.
      expect(state.status, FileDownloadStatus.opened);
      expect(state.status, isNot(FileDownloadStatus.failed));
      expect(state.publish, isA<PublishFailed>());
    });

    test('leaves the downloaded file in place and openable', () async {
      await store.write(_folder);
      final gateway = FakeDocumentTreeGateway()
        ..copyError = const FileSystemException('no space left on device');
      final container = containerWith(gateway);
      addTearDown(container.dispose);

      await notifierIn(container).start(
        downloadOf('/home/gian/report.docx'),
        _entry('/home/gian/report.docx'),
      );

      final state = container.read(fileDownloadProvider);
      expect(state.file, isNotNull);
      expect(state.file!.existsSync(), isTrue);
    });

    test('a lost grant is surfaced, never swallowed', () async {
      await store.write(_folder);
      final gateway = FakeDocumentTreeGateway()..writeGrant = false;
      final container = containerWith(gateway);
      addTearDown(container.dispose);

      await notifierIn(container).start(
        downloadOf('/home/gian/report.docx'),
        _entry('/home/gian/report.docx'),
      );

      final publish =
          container.read(fileDownloadProvider).publish! as PublishFailed;
      expect(publish.reason, PublishFailure.permissionLost);
    });

    test('a lost grant leaves no folder still being advertised', () async {
      await store.write(_folder);
      final gateway = FakeDocumentTreeGateway()..writeGrant = false;
      final container = containerWith(gateway);
      addTearDown(container.dispose);
      // Warm the destination state so there is something stale to correct.
      await container.read(downloadDestinationProvider.future);
      expect(container.read(downloadDestinationProvider).value, _folder);

      await notifierIn(container).start(
        downloadOf('/home/gian/report.docx'),
        _entry('/home/gian/report.docx'),
      );

      expect(container.read(downloadDestinationProvider).value, isNull);
    });
  });

  group('a download that never completed', () {
    test('is never published, and carries no publish outcome', () async {
      await store.write(_folder);
      final gateway = FakeDocumentTreeGateway();
      final container = containerWith(gateway);
      addTearDown(container.dispose);

      // A path the fake session does not hold answers no-such-file.
      await notifierIn(container).start(
        downloadOf('/home/gian/report.docx'),
        _entry('/home/gian/gone.txt'),
      );

      final state = container.read(fileDownloadProvider);
      expect(state.status, FileDownloadStatus.failed);
      expect(state.publish, isNull);
      expect(gateway.copiedNames, isEmpty);
    });
  });

  group('a platform that files downloads itself', () {
    test('publishes nothing and says nothing', () async {
      final gateway = FakeDocumentTreeGateway();
      final container = containerWith(gateway, supportsFolderChoice: false);
      addTearDown(container.dispose);

      await notifierIn(container).start(
        downloadOf('/home/gian/report.docx'),
        _entry('/home/gian/report.docx'),
      );

      final state = container.read(fileDownloadProvider);
      expect(state.publish, isA<PublishNotNeeded>());
      // Nothing to report means the strip stays out of the way, exactly as
      // it did before this slice existed.
      expect(state.publishNeedsReporting, isFalse);
      expect(state.needsAcknowledgement, isFalse);
      expect(gateway.copiedNames, isEmpty);
    });
  });

  group('dismiss', () {
    test('clears the publish outcome along with everything else', () async {
      await store.write(_folder);
      final container = containerWith(FakeDocumentTreeGateway());
      addTearDown(container.dispose);
      final notifier = notifierIn(container);

      await notifier.start(
        downloadOf('/home/gian/report.docx'),
        _entry('/home/gian/report.docx'),
      );
      expect(container.read(fileDownloadProvider).publish, isNotNull);

      notifier.dismiss();

      final state = container.read(fileDownloadProvider);
      expect(state.publish, isNull);
      expect(state.needsAcknowledgement, isFalse);
    });
  });
}
