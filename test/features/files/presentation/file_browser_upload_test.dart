// Widget tests for the upload half of the browser sheet.
//
// The assertion this file exists for is the one the task's own acceptance
// criteria name: every [UploadOutcome] variant must render its OWN
// message, [UploadDestinationExists] must read as something the user can
// act on rather than a generic failure, a completed upload must refresh
// the listing, cancellation must reach the service, and a platform without
// a picker must degrade to no control at all rather than a dead one.
import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/features/files/data/document_tree_gateway.dart';
import 'package:helm/features/files/data/saf_upload_source.dart';
import 'package:helm/features/files/data/sftp_download_service.dart';
import 'package:helm/features/files/data/sftp_file_service.dart';
import 'package:helm/features/files/data/sftp_upload_service.dart';
import 'package:helm/features/files/domain/upload_outcome.dart';
import 'package:helm/features/files/presentation/file_browser_sheet.dart';
import 'package:helm/features/files/presentation/providers/file_upload_provider.dart';

import '../../../helpers/fake_document_tree_gateway.dart';
import '../../../helpers/fake_sftp_session.dart';

Finder _byId(String identifier) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.identifier == identifier,
);

late Directory _staging;

class _SnapshotUploads extends FileUploadNotifier {
  _SnapshotUploads(this.initial);
  final FileUploadState initial;

  @override
  FileUploadState build() => initial;
}

SftpFileService _serviceWith(FakeSftpSession session) =>
    SftpFileService.withOpener(() async => session);

SftpDownloadService _downloadService() => SftpDownloadService.withOpener(
  () async => FakeSftpSession(),
  directory: () async => _staging,
  idleTimeout: const Duration(milliseconds: 200),
);

/// Pumps the sheet with a file-listing session and a picker the test
/// controls, wired to the SAME session so a completed upload's finalizing
/// rename is visible to a subsequent listing refresh.
Future<ProviderContainer> _pumpSheet(
  WidgetTester tester,
  FakeSftpSession session, {
  FakeDocumentTreeGateway? gateway,
  bool supportsPicking = true,
  FileUploadState? initialUploads,
}) async {
  final container = ProviderContainer(
    overrides: [
      if (initialUploads != null)
        fileUploadProvider.overrideWith(() => _SnapshotUploads(initialUploads)),
      uploadSourcePickerProvider.overrideWithValue(
        UploadSourcePicker(
          gateway: gateway ?? FakeDocumentTreeGateway(),
          supportsPicking: supportsPicking,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: FileBrowserSheet(
            service: _serviceWith(session),
            downloadService: _downloadService(),
            uploadService: SftpUploadService.withOpener(
              () async => session,
              idleTimeout: const Duration(milliseconds: 200),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// Runs an upload to COMPLETION against the real filesystem-shaped fake,
/// then paints — the same `runAsync` discipline
/// `file_browser_sheet_test.dart` documents for downloads: `pumpAndSettle`
/// alone never completes real `dart:io`-shaped async work.
Future<void> _tapUpload(WidgetTester tester, {bool media = false}) async {
  await tester.tap(_byId(FilesSemantics.uploadButton));
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    await tester.tap(find.text(media ? 'Photos and videos' : 'Documents'));
    // Let the picker, the upload, and every awaited step inside it run to
    // completion before control returns to the fake-clock pump below.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  if (media) {
    // Do not advance the fake clock through the delayed source stream.
    await tester.pump();
  } else {
    await tester.pumpAndSettle();
  }
}

void main() {
  setUp(() {
    _staging = Directory.systemTemp.createTempSync('helm_sheet_upload');
  });

  tearDown(() {
    if (_staging.existsSync()) _staging.deleteSync(recursive: true);
  });

  group('source choice and queue', () {
    testWidgets('offers exactly documents and photos/videos above the sheet', (
      tester,
    ) async {
      final gateway = FakeDocumentTreeGateway();
      await _pumpSheet(
        tester,
        FakeSftpSession(directories: {'/home/gian': []}),
        gateway: gateway,
      );
      await tester.tap(_byId(FilesSemantics.uploadButton));
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsOneWidget);
      expect(_byId(FilesSemantics.uploadSourceDialog), findsOneWidget);
      expect(_byId(FilesSemantics.uploadDocumentsOption), findsOneWidget);
      expect(_byId(FilesSemantics.uploadMediaOption), findsOneWidget);
      expect(find.byType(SimpleDialogOption), findsNWidgets(2));
      expect(find.text('Documents'), findsOneWidget);
      expect(find.text('Photos and videos'), findsOneWidget);
      expect(gateway.pickFileCalls, 0);
      expect(gateway.pickMediaCalls, 0);
    });

    testWidgets('declining the modal does nothing silently', (tester) async {
      final gateway = FakeDocumentTreeGateway();
      final container = await _pumpSheet(
        tester,
        FakeSftpSession(directories: {'/home/gian': []}),
        gateway: gateway,
      );
      await tester.tap(_byId(FilesSemantics.uploadButton));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(SimpleDialog))).pop();
      await tester.pumpAndSettle();
      expect(gateway.pickFileCalls, 0);
      expect(gateway.pickMediaCalls, 0);
      expect(container.read(fileUploadProvider).items, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets(
      'media selection enqueues every item and shows active plus counts',
      (tester) async {
        final gateway = FakeDocumentTreeGateway(
          mediaPick: const [
            PickedDocument(uri: 'content://a', name: 'a.jpg', length: 2),
            PickedDocument(uri: 'content://b', name: 'b.mp4', length: 2),
          ],
          fileContents: {
            'content://a': [1, 2],
            'content://b': [3, 4],
          },
          readChunkSize: 1,
          readChunkGap: const Duration(milliseconds: 200),
        );
        final container = await _pumpSheet(
          tester,
          FakeSftpSession(directories: {'/home/gian': []}),
          gateway: gateway,
        );
        await _tapUpload(tester, media: true);
        expect(container.read(fileUploadProvider).items.map((e) => e.name), [
          'a.jpg',
          'b.mp4',
        ]);
        expect(
          find.text(
            'Uploading a.jpg · ${container.read(fileUploadProvider).items.first.percent}%',
          ),
          findsOneWidget,
        );
        expect(find.text('0 done · 2 remaining'), findsOneWidget);
        expect(find.text('Cancel all'), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(_byId(FilesSemantics.uploadCancelButton));
          await Future<void>.delayed(const Duration(milliseconds: 250));
        });
        await tester.pumpAndSettle();
        expect(
          container
              .read(fileUploadProvider)
              .items
              .every((e) => e.status == FileUploadStatus.cancelled),
          isTrue,
        );
        expect(find.text('2 done · 0 remaining'), findsOneWidget);
        expect(find.byTooltip('Dismiss'), findsOneWidget);
        await tester.tap(find.byTooltip('Dismiss'));
        await tester.pumpAndSettle();
        expect(_byId(FilesSemantics.uploadStatus), findsNothing);
      },
    );

    testWidgets('declining the media picker is silent', (tester) async {
      final gateway = FakeDocumentTreeGateway();
      final container = await _pumpSheet(
        tester,
        FakeSftpSession(directories: {'/home/gian': []}),
        gateway: gateway,
      );
      await _tapUpload(tester, media: true);
      expect(gateway.pickMediaCalls, 1);
      expect(gateway.pickFileCalls, 0);
      expect(container.read(fileUploadProvider).items, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets(
      'media queue completes all picks and refreshes each owned ID once',
      (tester) async {
        final gateway = FakeDocumentTreeGateway(
          mediaPick: const [
            PickedDocument(uri: 'content://a', name: 'a.jpg', length: 1),
            PickedDocument(uri: 'content://b', name: 'b.mp4', length: 1),
          ],
          fileContents: {
            'content://a': [1],
            'content://b': [2],
          },
        );
        final session = FakeSftpSession(directories: {'/home/gian': []});
        final container = await _pumpSheet(tester, session, gateway: gateway);
        await _tapUpload(tester, media: true);
        await tester.pumpAndSettle();
        expect(container.read(fileUploadProvider).doneCount, 2);
        expect(container.read(fileUploadProvider).remainingCount, 0);
        expect(session.writtenBytes['/home/gian/a.jpg'], [1]);
        expect(session.writtenBytes['/home/gian/b.mp4'], [2]);
        expect(session.listedPaths.length, 3);
        expect(find.text('Uploaded a.jpg.'), findsOneWidget);
        expect(find.text('Uploaded b.mp4.'), findsOneWidget);
        await tester.pump();
        expect(session.listedPaths.length, 3);
      },
    );

    testWidgets(
      'completed history does not hide the active item or pending counts',
      (tester) async {
        final gateway = FakeDocumentTreeGateway();
        SafUploadSource source(String name) => SafUploadSource(
          gateway,
          PickedDocument(uri: 'content://$name', name: name, length: 1),
        );
        await _pumpSheet(
          tester,
          FakeSftpSession(directories: {'/home/gian': []}),
          initialUploads: FileUploadState(
            items: [
              FileUploadItem(
                id: 1,
                source: source('a.jpg'),
                destinationPath: '/a.jpg',
                status: FileUploadStatus.completed,
                percent: 100,
                outcome: const UploadCompleted('/a(1).jpg', bytes: 1),
              ),
              FileUploadItem(
                id: 2,
                source: source('b.mp4'),
                destinationPath: '/b.mp4',
                status: FileUploadStatus.uploading,
                percent: 37,
              ),
              FileUploadItem(
                id: 3,
                source: source('c.jpg'),
                destinationPath: '/c.jpg',
              ),
            ],
          ),
        );
        expect(find.text('Uploading b.mp4 · 37%'), findsOneWidget);
        expect(find.text('1 done · 2 remaining'), findsOneWidget);
        expect(find.text('Uploaded a.jpg as a(1).jpg.'), findsOneWidget);
        expect(find.textContaining('c.jpg'), findsNothing);
        expect(_byId(FilesSemantics.uploadCancelButton), findsOneWidget);
        expect(find.byTooltip('Dismiss'), findsNothing);
      },
    );

    testWidgets('pending-only queue remains actionable', (tester) async {
      final source = SafUploadSource(
        FakeDocumentTreeGateway(),
        const PickedDocument(uri: 'content://a', name: 'a.jpg', length: 1),
      );
      await _pumpSheet(
        tester,
        FakeSftpSession(directories: {'/home/gian': []}),
        initialUploads: FileUploadState(
          items: [
            FileUploadItem(id: 1, source: source, destinationPath: '/a.jpg'),
          ],
        ),
      );
      expect(find.text('Waiting to upload a.jpg.'), findsOneWidget);
      expect(find.text('0 done · 1 remaining'), findsOneWidget);
      expect(find.text('Cancel all'), findsOneWidget);
      await tester.tap(_byId(FilesSemantics.uploadCancelButton));
      await tester.pumpAndSettle();
      // NAMES the file. Success and exhaustion receipts already did;
      // cancellation and failure did not, so once the active line moved
      // on the user could not tell WHICH file was cancelled, and several
      // cancellations rendered as indistinguishable receipts with nothing
      // to retry from. Found by an adversarial review — see
      // odd/reviews/queue-and-strip.md.
      expect(find.text('Cancelled a.jpg.'), findsOneWidget);
      expect(find.byTooltip('Dismiss'), findsOneWidget);
    });

    testWidgets('a resolved collision reports the saved name', (tester) async {
      final gateway = FakeDocumentTreeGateway(
        filePick: const PickedDocument(
          uri: 'content://a',
          name: 'a.jpg',
          length: 1,
        ),
        fileContents: {
          'content://a': [1],
        },
      );
      final session = FakeSftpSession(
        directories: {'/home/gian': []},
        stats: {'/home/gian/a.jpg': SftpFileAttrs()},
      );
      await _pumpSheet(tester, session, gateway: gateway);
      await _tapUpload(tester);
      expect(find.text('Uploaded a.jpg as a(1).jpg.'), findsOneWidget);
      expect(session.writtenBytes['/home/gian/a(1).jpg'], [1]);
    });
  });

  group('the upload button', () {
    testWidgets('is offered when this platform can pick a file', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        FakeSftpSession(directories: const {'/home/gian': []}),
      );

      expect(_byId(FilesSemantics.uploadButton), findsOneWidget);
    });

    testWidgets(
      'is absent on a platform with no picker, never a disabled control',
      (tester) async {
        await _pumpSheet(
          tester,
          FakeSftpSession(directories: const {'/home/gian': []}),
          supportsPicking: false,
        );

        // Absent entirely, not merely disabled: a control that always
        // fails is worse than none, which is the whole reason
        // [UploadSourcePicker.supportsPicking] exists as a gate here
        // rather than a `Platform.isAndroid` left to fail loudly at tap
        // time.
        expect(_byId(FilesSemantics.uploadButton), findsNothing);
      },
    );
  });

  group('a declined pick', () {
    testWidgets('starts nothing, and shows no status strip', (tester) async {
      await _pumpSheet(
        tester,
        FakeSftpSession(directories: const {'/home/gian': []}),
        gateway: FakeDocumentTreeGateway(filePick: null),
      );

      await _tapUpload(tester);

      expect(_byId(FilesSemantics.uploadStatus), findsNothing);
    });
  });

  group('a successful upload', () {
    testWidgets('reports completion, and refreshes the listing', (
      tester,
    ) async {
      final session = FakeSftpSession(directories: {'/home/gian': []});
      final gateway = FakeDocumentTreeGateway(
        filePick: const PickedDocument(
          uri: 'content://x/report.docx',
          name: 'report.docx',
          length: 11,
        ),
        fileContents: {'content://x/report.docx': 'hello world'.codeUnits},
      );

      final container = await _pumpSheet(tester, session, gateway: gateway);
      await _tapUpload(tester);

      expect(gateway.pickFileCalls, 1);
      expect(gateway.pickMediaCalls, 0);
      expect(
        container.read(fileUploadProvider).items.single.status,
        FileUploadStatus.completed,
      );
      expect(session.listedPaths, ['/home/gian', '/home/gian']);
      expect(find.textContaining('Uploaded report.docx'), findsOneWidget);
      // The finalizing rename landed the bytes under the real name, so a
      // listing that still omitted it would tell the user their upload
      // did nothing when it worked — the refresh-on-success rule every
      // other write in this sheet already follows.
      expect(
        session.writtenBytes['/home/gian/report.docx'],
        'hello world'.codeUnits,
      );
      // ...and the listing is what the USER sees. Asserting only on
      // `writtenBytes` let this test pass against a still-empty
      // directory, which is exactly the outcome the comment above calls
      // dishonest. An adversarial review caught that; see
      // odd/reviews/queue-and-strip.md.
      expect(find.text('report.docx'), findsOneWidget);
      expect(_byId(FilesSemantics.emptyDirectory), findsNothing);
    });
  });

  group('exhausted destination candidates', () {
    testWidgets('reads as something to act on, not a generic failure', (
      tester,
    ) async {
      final session = FakeSftpSession(
        directories: {'/home/gian': []},
        stats: {
          for (var i = 0; i < 100; i++)
            '/home/gian/report${i == 0 ? '' : '($i)'}.docx': SftpFileAttrs(),
        },
      );
      final gateway = FakeDocumentTreeGateway(
        filePick: const PickedDocument(
          uri: 'content://x/report.docx',
          name: 'report.docx',
          length: 3,
        ),
        fileContents: {
          'content://x/report.docx': const [1, 2, 3],
        },
      );

      await _pumpSheet(tester, session, gateway: gateway);
      await _tapUpload(tester);

      expect(
        find.text(
          'Could not find a free name for report.docx after checking 100 names. Try a different name.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('could not be uploaded'), findsNothing);
    });

    testWidgets('a failure receipt names the file that failed', (tester) async {
      final gateway = FakeDocumentTreeGateway(
        fileContents: {'content://x/secret.txt': 'nope'.codeUnits},
        filePick: const PickedDocument(
          uri: 'content://x/secret.txt',
          name: 'secret.txt',
          length: 4,
        ),
      );
      final session = FakeSftpSession(
        directories: {'/home/gian': const []},
        openWriteError: SftpStatusError(
          SftpStatusCode.permissionDenied,
          'Permission denied',
        ),
      );
      await _pumpSheet(tester, session, gateway: gateway);
      await _tapUpload(tester);

      // Same rule as the cancellation receipt: with several failures in a
      // queue, a receipt carrying only the reason leaves the user unable
      // to tell which file it belongs to.
      expect(find.textContaining('secret.txt'), findsOneWidget);
    });
  });

  group('a server refusal', () {
    testWidgets('names the reason it was refused', (tester) async {
      final session = FakeSftpSession(
        directories: {'/home/gian': []},
        openWriteError: SftpStatusError(
          SftpStatusCode.permissionDenied,
          'Permission denied',
        ),
      );
      final gateway = FakeDocumentTreeGateway(
        filePick: const PickedDocument(
          uri: 'content://x/report.docx',
          name: 'report.docx',
          length: 3,
        ),
        fileContents: {
          'content://x/report.docx': const [1, 2, 3],
        },
      );

      await _pumpSheet(tester, session, gateway: gateway);
      await _tapUpload(tester);

      expect(
        find.text('You do not have permission to write to this directory.'),
        findsOneWidget,
      );
    });
  });

  group('cancellation', () {
    testWidgets('reaches the service, and ends cancelled', (tester) async {
      final session = FakeSftpSession(directories: {'/home/gian': []});
      final gateway = FakeDocumentTreeGateway(
        filePick: const PickedDocument(
          uri: 'content://x/big.bin',
          name: 'big.bin',
          length: 500000,
        ),
        fileContents: {'content://x/big.bin': List<int>.filled(500000, 1)},
        // Chunked with a gap between them, mirroring the download
        // cancellation test's shape: cancellation must land BETWEEN
        // chunks, so the source has to keep yielding slowly rather than
        // handing over everything at once.
        readChunkSize: 50000,
        readChunkGap: const Duration(milliseconds: 20),
      );

      final container = await _pumpSheet(tester, session, gateway: gateway);

      await tester.tap(_byId(FilesSemantics.uploadButton));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        // Starts the upload without awaiting its completion, mirroring
        // the download cancellation test's shape: the cancel tap must
        // land while bytes are still moving.
        unawaited(tester.tap(find.text('Documents')));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();

      expect(container.read(fileUploadProvider).isRunning, isTrue);

      await tester.runAsync(() async {
        await tester.tap(_byId(FilesSemantics.uploadCancelButton));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(
        container.read(fileUploadProvider).items.single.status,
        FileUploadStatus.cancelled,
      );
      expect(find.text('Cancelled big.bin.'), findsOneWidget);
    });
  });
}
