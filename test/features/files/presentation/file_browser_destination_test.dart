// Widget tests for the download-folder half of the browser sheet.
//
// The assertion this file exists for is the one the strip is shaped
// around: A DOWNLOAD THAT OPENED AND FAILED TO PUBLISH MUST SAY BOTH
// THINGS. The two facts are independent, they can be true at once, and a
// strip that could only show one of them would have to pick — which in
// practice means telling the user their download failed when they are
// looking at the document it produced.
//
// Complements `file_browser_sheet_test.dart`, which covers the listing and
// the transfer itself. That file drives the sheet with no destination
// override, so it exercises the platform-files-them-itself path by
// default; this one overrides the service to reach the Android path.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/features/files/data/download_destination_service.dart';
import 'package:helm/features/files/data/download_destination_store.dart';
import 'package:helm/features/files/data/external_viewer.dart';
import 'package:helm/features/files/data/sftp_download_service.dart';
import 'package:helm/features/files/data/sftp_file_service.dart';
import 'package:helm/features/files/domain/download_destination.dart';
import 'package:helm/features/files/domain/remote_entry.dart';
import 'package:helm/features/files/presentation/file_browser_sheet.dart';
import 'package:helm/features/files/presentation/providers/download_destination_provider.dart';
import 'package:helm/features/files/presentation/providers/file_download_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fake_document_tree_gateway.dart';
import '../../../helpers/fake_sftp_session.dart';

const _folder = DownloadDestination(
  uri: 'content://com.android.externalstorage.documents/tree/primary%3ADownload%2FHelm',
  name: 'Helm',
);

Finder _byId(String identifier) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.identifier == identifier,
);

late Directory _staging;
late DownloadDestinationStore _store;

RemoteEntry _fileEntry(String path) => RemoteEntry(
  name: path.split('/').last,
  path: path,
  kind: RemoteEntryKind.file,
);

SftpFileService _emptyService() => SftpFileService.withOpener(
  () async => FakeSftpSession(directories: const {'/home/gian': []}),
);

SftpDownloadService _downloadService(String path) =>
    SftpDownloadService.withOpener(
      () async => FakeSftpSession(
        files: {path: FakeRemoteFile(List<int>.filled(1024, 7))},
      ),
      directory: () async => _staging,
      idleTimeout: const Duration(milliseconds: 200),
    );

/// Pumps the sheet with a destination service the test controls.
Future<ProviderContainer> _pumpSheet(
  WidgetTester tester,
  FakeDocumentTreeGateway gateway, {
  bool supportsFolderChoice = true,
  ViewerOutcome viewer = ViewerOutcome.opened,
  String downloadPath = '/home/gian/report.docx',
}) async {
  final container = ProviderContainer(
    overrides: [
      downloadDestinationServiceProvider.overrideWithValue(
        DownloadDestinationService(
          store: _store,
          gateway: gateway,
          supportsFolderChoice: supportsFolderChoice,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(fileDownloadProvider.notifier).debugUseViewer(
    (_) async => viewer,
  );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: FileBrowserSheet(
            service: _emptyService(),
            downloadService: _downloadService(downloadPath),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// Runs a download to COMPLETION against the real filesystem, then paints.
///
/// [WidgetTester.runAsync] is the only place a widget test may await real
/// I/O: outside it the binding's clock is fake, so `openWrite`, `close`
/// and `rename` never finish and the sheet stays stuck on "downloading".
/// Slice 2a's sheet test carries the same note for the same reason.
Future<void> _runDownload(
  WidgetTester tester,
  ProviderContainer container, {
  String path = '/home/gian/report.docx',
}) async {
  await tester.runAsync(
    () => container
        .read(fileDownloadProvider.notifier)
        .start(_downloadService(path), _fileEntry(path)),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _staging = Directory.systemTemp.createTempSync('helm_sheet_destination');
    _store = DownloadDestinationStore();
  });

  tearDown(() {
    if (_staging.existsSync()) _staging.deleteSync(recursive: true);
  });

  group('the destination bar', () {
    testWidgets('says no folder is set, and offers to choose one', (
      tester,
    ) async {
      await _pumpSheet(tester, FakeDocumentTreeGateway(picks: _folder));

      expect(_byId(FilesSemantics.downloadFolderButton), findsOneWidget);
      expect(
        find.text('Downloads are not being saved to a folder'),
        findsOneWidget,
      );
      expect(find.text('Choose'), findsOneWidget);
    });

    testWidgets('names the folder once one is chosen', (tester) async {
      await _store.write(_folder);

      await _pumpSheet(tester, FakeDocumentTreeGateway());

      expect(find.text('Saving downloads to Helm'), findsOneWidget);
      // The offer is gone, because the question has been answered.
      expect(find.text('Choose'), findsNothing);
    });

    testWidgets('choosing a folder adopts it without a download', (
      tester,
    ) async {
      final gateway = FakeDocumentTreeGateway(picks: _folder);
      await _pumpSheet(tester, gateway);

      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();

      expect(gateway.pickCalls, 1);
      expect(find.text('Saving downloads to Helm'), findsOneWidget);
    });

    testWidgets('the folder can be cleared again from the sheet', (
      tester,
    ) async {
      await _store.write(_folder);
      final gateway = FakeDocumentTreeGateway();
      await _pumpSheet(tester, gateway);

      await tester.tap(find.byTooltip('Download folder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stop saving to a folder'));
      await tester.pumpAndSettle();

      expect(
        find.text('Downloads are not being saved to a folder'),
        findsOneWidget,
      );
      expect(gateway.releasedUris, [_folder.uri]);
    });

    testWidgets('is absent where there is no folder to choose', (tester) async {
      await _pumpSheet(
        tester,
        FakeDocumentTreeGateway(),
        supportsFolderChoice: false,
      );

      expect(_byId(FilesSemantics.downloadFolderButton), findsNothing);
    });
  });

  group('reporting where a download went', () {
    testWidgets('says the folder and the name it was saved under', (
      tester,
    ) async {
      await _store.write(_folder);
      final container = await _pumpSheet(tester, FakeDocumentTreeGateway());

      await _runDownload(tester, container);

      expect(_byId(FilesSemantics.downloadPublish), findsOneWidget);
      expect(find.text('Saved to Helm as report.docx.'), findsOneWidget);
    });

    testWidgets('reports the derived name after a collision, not the one '
        'that was asked for', (tester) async {
      await _store.write(_folder);
      final gateway = FakeDocumentTreeGateway()
        ..existingNames.add('report.docx');
      final container = await _pumpSheet(tester, gateway);

      await _runDownload(tester, container);

      expect(find.text('Saved to Helm as report(1).docx.'), findsOneWidget);
      expect(find.text('Saved to Helm as report.docx.'), findsNothing);
    });

    testWidgets('offers the choice when no folder is set, without calling '
        'the download a failure', (tester) async {
      final container = await _pumpSheet(
        tester,
        FakeDocumentTreeGateway(picks: _folder),
      );

      await _runDownload(tester, container);

      expect(_byId(FilesSemantics.downloadPublish), findsOneWidget);
      expect(find.text('Choose a folder'), findsOneWidget);
      expect(
        container.read(fileDownloadProvider).status,
        FileDownloadStatus.opened,
      );
    });

    testWidgets('says nothing at all where the platform files downloads '
        'itself', (tester) async {
      final container = await _pumpSheet(
        tester,
        FakeDocumentTreeGateway(),
        supportsFolderChoice: false,
      );

      await _runDownload(tester, container);

      // Exactly the behaviour slice 2a had: an opened download leaves no
      // strip behind.
      expect(_byId(FilesSemantics.downloadPublish), findsNothing);
      expect(_byId(FilesSemantics.downloadStatus), findsNothing);
    });
  });

  group('a publish that failed', () {
    testWidgets('is reported while the download still reads as opened', (
      tester,
    ) async {
      await _store.write(_folder);
      final gateway = FakeDocumentTreeGateway()..writeGrant = false;
      final container = await _pumpSheet(tester, gateway);

      await _runDownload(tester, container);

      expect(_byId(FilesSemantics.downloadPublish), findsOneWidget);
      expect(
        find.text(describePublishFailure(PublishFailure.permissionLost)),
        findsOneWidget,
      );
      // The download half of the strip stays silent, because the download
      // did not fail.
      expect(
        find.text(describeDownloadFailure(null)),
        findsNothing,
      );
      expect(
        container.read(fileDownloadProvider).status,
        FileDownloadStatus.opened,
      );
    });

    testWidgets('every message says the file is still on the device', (
      tester,
    ) async {
      // The one fact a publish failure is most likely to lose. Asserted
      // over the whole enum so a new reason cannot be added without it.
      for (final reason in PublishFailure.values) {
        expect(
          describePublishFailure(reason),
          contains('on this device'),
          reason: '$reason must not read as a lost file',
        );
      }
    });

    testWidgets('a lost grant offers the picker again and stops naming the '
        'dead folder', (tester) async {
      await _store.write(_folder);
      final gateway = FakeDocumentTreeGateway()..writeGrant = false;
      final container = await _pumpSheet(tester, gateway);

      await _runDownload(tester, container);

      expect(find.text('Choose a folder'), findsOneWidget);
      expect(
        find.text('Downloads are not being saved to a folder'),
        findsOneWidget,
      );
      expect(find.text('Saving downloads to Helm'), findsNothing);
    });

    testWidgets('a full disk keeps the folder, since it was not the problem', (
      tester,
    ) async {
      await _store.write(_folder);
      final gateway = FakeDocumentTreeGateway()
        ..copyError = const FileSystemException('no space left on device');
      final container = await _pumpSheet(tester, gateway);

      await _runDownload(tester, container);

      expect(
        find.text(describePublishFailure(PublishFailure.storage)),
        findsOneWidget,
      );
      expect(find.text('Saving downloads to Helm'), findsOneWidget);
      // No picker offered: the destination was never the problem.
      expect(find.text('Choose a folder'), findsNothing);
    });

    testWidgets('the whole strip dismisses with one tap', (tester) async {
      await _store.write(_folder);
      final gateway = FakeDocumentTreeGateway()..writeGrant = false;
      final container = await _pumpSheet(tester, gateway);
      await _runDownload(tester, container);

      // One and only one — two stacked close buttons would be an
      // interface asking which of two identical things you meant.
      expect(find.byTooltip('Dismiss'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();

      expect(_byId(FilesSemantics.downloadStatus), findsNothing);
      expect(_byId(FilesSemantics.downloadPublish), findsNothing);
    });
  });

  group('a download that failed outright', () {
    testWidgets('reports the transfer and never claims a folder outcome', (
      tester,
    ) async {
      await _store.write(_folder);
      final gateway = FakeDocumentTreeGateway();
      final container = await _pumpSheet(tester, gateway);

      // A service holding one file, asked for another: the open fails, so
      // there is never a file to publish.
      await tester.runAsync(
        () => container
            .read(fileDownloadProvider.notifier)
            .start(
              _downloadService('/home/gian/report.docx'),
              _fileEntry('/home/gian/missing.docx'),
            ),
      );
      await tester.pumpAndSettle();

      expect(
        container.read(fileDownloadProvider).status,
        FileDownloadStatus.failed,
      );
      expect(_byId(FilesSemantics.downloadStatus), findsOneWidget);
      expect(_byId(FilesSemantics.downloadPublish), findsNothing);
      expect(gateway.copiedNames, isEmpty);
    });
  });
}
