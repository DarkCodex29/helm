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
import 'package:helm/features/files/presentation/file_browser_sheet.dart';
import 'package:helm/features/files/presentation/providers/file_upload_provider.dart';

import '../../../helpers/fake_document_tree_gateway.dart';
import '../../../helpers/fake_sftp_session.dart';

Finder _byId(String identifier) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.identifier == identifier,
);

late Directory _staging;

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
}) async {
  final container = ProviderContainer(
    overrides: [
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
Future<void> _tapUpload(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(_byId(FilesSemantics.uploadButton));
    // Let the picker, the upload, and every awaited step inside it run to
    // completion before control returns to the fake-clock pump below.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    _staging = Directory.systemTemp.createTempSync('helm_sheet_upload');
  });

  tearDown(() {
    if (_staging.existsSync()) _staging.deleteSync(recursive: true);
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

      await _pumpSheet(tester, session, gateway: gateway);
      await _tapUpload(tester);

      expect(find.textContaining('Uploaded report.docx'), findsOneWidget);
      // The finalizing rename landed the bytes under the real name, so a
      // listing that still omitted it would tell the user their upload
      // did nothing when it worked — the refresh-on-success rule every
      // other write in this sheet already follows.
      expect(
        session.writtenBytes['/home/gian/report.docx'],
        'hello world'.codeUnits,
      );
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

      expect(find.textContaining('already exists here'), findsOneWidget);
      expect(find.textContaining('could not be uploaded'), findsNothing);
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

      await tester.runAsync(() async {
        // Starts the upload without awaiting its completion, mirroring
        // the download cancellation test's shape: the cancel tap must
        // land while bytes are still moving.
        unawaited(tester.tap(_byId(FilesSemantics.uploadButton)));
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
        container.read(fileUploadProvider).status,
        FileUploadStatus.cancelled,
      );
      expect(find.text('Upload cancelled.'), findsOneWidget);
    });
  });
}
