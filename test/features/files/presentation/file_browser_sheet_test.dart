// Widget tests for the remote file browser.
//
// The assertion this file exists for is the two-sided one in "listing
// outcomes": an empty directory and a refused directory look identical if
// you only check that no rows are on screen, and the browser must never
// let the second read as the first. Every case below therefore asserts
// both the panel that MUST be present and, explicitly, that the other one
// is absent.
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/features/files/data/external_viewer.dart';
import 'package:helm/features/files/data/sftp_download_service.dart';
import 'package:helm/features/files/data/sftp_file_service.dart';
import 'package:helm/features/files/data/sftp_upload_service.dart';
import 'package:helm/features/files/domain/download_outcome.dart';
import 'package:helm/features/files/domain/remote_entry.dart';
import 'package:helm/features/files/presentation/file_browser_sheet.dart';
import 'package:helm/features/files/presentation/providers/file_download_provider.dart';

import '../../../helpers/fake_sftp_session.dart';

Finder _byId(String identifier) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.identifier == identifier,
);

/// Where a downloading test's bytes land. Replaced per test.
late Directory _staging;

/// What the platform viewer answers. Replaced per test; the real one goes
/// over a method channel that does not exist here.
late ExternalViewer _viewer;

/// Pumps the sheet and returns the container driving it, so a test can
/// reach the download notifier directly.
///
/// That reach-in is needed for the TERMINAL download states and only for
/// them. `pumpAndSettle` advances the binding's fake clock, which never
/// completes a real `dart:io` write — so a test that taps a row and then
/// settles asserts on a transfer still in flight. See [_runDownload].
Future<ProviderContainer> _pumpSheet(
  WidgetTester tester,
  SftpFileService service, {
  SftpDownloadService? downloadService,
}) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container
      .read(fileDownloadProvider.notifier)
      .debugUseViewer((file) => _viewer(file));

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: FileBrowserSheet(
            service: service,
            downloadService: downloadService ?? _downloadService(),
            uploadService: _uploadService(),
          ),
        ),
      ),
    ),
  );
  // One pump for the post-frame `open`, one for the listing it awaits.
  await tester.pumpAndSettle();
  return container;
}

/// Runs a download to COMPLETION against the real filesystem, then paints.
///
/// [WidgetTester.runAsync] is the only place a widget test may await real
/// I/O: outside it the binding's clock is fake, so `openWrite`, `close`
/// and `rename` never finish and the sheet stays stuck on "downloading".
Future<void> _runDownload(
  WidgetTester tester,
  ProviderContainer container,
  SftpDownloadService service,
  RemoteEntry entry,
) async {
  await tester.runAsync(
    () => container.read(fileDownloadProvider.notifier).start(service, entry),
  );
  await tester.pumpAndSettle();
}

/// The entry a listing would produce for a plain file at [path].
RemoteEntry _fileEntry(String path) => RemoteEntry(
  name: path.split('/').last,
  path: path,
  kind: RemoteEntryKind.file,
);

SftpFileService _service({
  Map<String, List<SftpName>> directories = const {},
  Map<String, SftpFileAttrs> stats = const {},
  Set<String> deniedPaths = const {},
  Object? listError,
  String home = '/home/gian',
}) {
  return SftpFileService.withOpener(
    () async => FakeSftpSession(
      directories: directories,
      stats: stats,
      deniedPaths: deniedPaths,
      listError: listError,
      home: home,
    ),
  );
}

SftpDownloadService _downloadService({
  Map<String, FakeRemoteFile> files = const {},
  Set<String> deniedPaths = const {},
  Duration idleTimeout = const Duration(seconds: 30),
}) {
  return SftpDownloadService.withOpener(
    () async => FakeSftpSession(files: files, deniedPaths: deniedPaths),
    directory: () async => _staging,
    idleTimeout: idleTimeout,
  );
}

/// An upload service nothing in this file's scenarios exercises — this
/// file's tests are entirely about the LISTING and DOWNLOAD halves of the
/// sheet, so the fake session behind it needs no scripted behaviour beyond
/// existing. The upload affordance itself is covered in
/// `file_browser_upload_test.dart`.
SftpUploadService _uploadService() =>
    SftpUploadService.withOpener(() async => FakeSftpSession());

void main() {
  setUp(() {
    _staging = Directory.systemTemp.createTempSync('helm_sheet_test');
    _viewer = (_) async => ViewerOutcome.opened;
  });

  tearDown(() {
    if (_staging.existsSync()) _staging.deleteSync(recursive: true);
  });

  group('listing outcomes', () {
    testWidgets('an empty directory says so, and shows no error', (
      tester,
    ) async {
      await _pumpSheet(tester, _service(directories: {'/home/gian': const []}));

      expect(_byId(FilesSemantics.emptyDirectory), findsOneWidget);
      expect(_byId(FilesSemantics.listingError), findsNothing);
      expect(find.text('This directory is empty'), findsOneWidget);
    });

    testWidgets(
      'a refused directory shows an error, and never the empty panel',
      (tester) async {
        await _pumpSheet(
          tester,
          _service(deniedPaths: const {'/home/gian'}, home: '/home/gian'),
        );

        expect(_byId(FilesSemantics.listingError), findsOneWidget);
        expect(_byId(FilesSemantics.emptyDirectory), findsNothing);
      },
    );

    testWidgets('permission denied names permission, not a generic failure', (
      tester,
    ) async {
      await _pumpSheet(tester, _service(deniedPaths: const {'/home/gian'}));

      expect(
        find.text('You do not have permission to read this directory.'),
        findsOneWidget,
      );
    });

    testWidgets('a path that vanished says so in its own words', (
      tester,
    ) async {
      await _pumpSheet(tester, _service(directories: const {}));

      expect(
        find.text('This directory no longer exists on the host.'),
        findsOneWidget,
      );
    });

    testWidgets('a dropped connection says so in its own words', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        _service(listError: SftpAbortError('SFTP channel closed')),
      );

      expect(
        find.text(
          'The connection dropped before this directory could be read.',
        ),
        findsOneWidget,
      );
    });
  });

  group('entries', () {
    testWidgets('renders one row per entry, directories first', (tester) async {
      await _pumpSheet(
        tester,
        _service(
          directories: {
            '/home/gian': [
              fakeSftpName('notes.md', mode: FakeSftpModes.file, size: 2048),
              fakeSftpName('projects', mode: FakeSftpModes.directory),
            ],
          },
        ),
      );

      final titles = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => (t.title! as Text).data)
          .toList();
      expect(titles, ['projects', 'notes.md']);
    });

    testWidgets('a file row states its kind and human-readable size', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        _service(
          directories: {
            '/home/gian': [
              fakeSftpName('notes.md', mode: FakeSftpModes.file, size: 2048),
            ],
          },
        ),
      );

      expect(find.text('File · 2.0 KB'), findsOneWidget);
    });

    testWidgets('tapping a directory navigates into it', (tester) async {
      await _pumpSheet(
        tester,
        _service(
          directories: {
            '/home/gian': [
              fakeSftpName('projects', mode: FakeSftpModes.directory),
            ],
            '/home/gian/projects': const [],
          },
        ),
      );

      await tester.tap(find.text('projects'));
      await tester.pumpAndSettle();

      expect(find.text('/home/gian/projects'), findsOneWidget);
      expect(_byId(FilesSemantics.emptyDirectory), findsOneWidget);
    });

    testWidgets('tapping a file does not navigate, since nothing opens yet', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        _service(
          directories: {
            '/home/gian': [fakeSftpName('notes.md', mode: FakeSftpModes.file)],
          },
        ),
      );

      await tester.tap(find.text('notes.md'));
      await tester.pumpAndSettle();

      expect(find.text('/home/gian'), findsOneWidget);
      expect(find.text('notes.md'), findsOneWidget);
    });
  });

  group('path bar', () {
    testWidgets('names the directory currently shown', (tester) async {
      await _pumpSheet(tester, _service(directories: {'/home/gian': const []}));

      expect(_byId(FilesSemantics.pathBar), findsOneWidget);
      expect(find.text('/home/gian'), findsOneWidget);
    });

    testWidgets('at the root, the up action is present but disabled', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        _service(directories: {'/': const []}, home: '/'),
      );

      expect(_byId(FilesSemantics.upButton), findsOneWidget);
      final up = tester.widget<IconButton>(
        find.descendant(
          of: _byId(FilesSemantics.upButton),
          matching: find.byType(IconButton),
        ),
      );
      expect(up.onPressed, isNull);
    });

    testWidgets('below the root, the up action moves to the parent', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        _service(directories: {'/home/gian': const [], '/home': const []}),
      );

      await tester.tap(
        find.descendant(
          of: _byId(FilesSemantics.upButton),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('/home'), findsOneWidget);
    });
  });

  group('formatByteSize', () {
    test('reports bytes verbatim below one kibibyte', () {
      expect(formatByteSize(0), '0 B');
      expect(formatByteSize(1023), '1023 B');
    });

    test('keeps one decimal while the value is small enough to matter', () {
      expect(formatByteSize(1024), '1.0 KB');
      expect(formatByteSize(1536), '1.5 KB');
    });

    test('drops the decimal once it is noise', () {
      expect(formatByteSize(1024 * 512), '512 KB');
    });

    test('climbs units rather than printing an unreadable number', () {
      expect(formatByteSize(1024 * 1024), '1.0 MB');
      expect(formatByteSize(1024 * 1024 * 1024), '1.0 GB');
    });
  });

  group('formatRemoteDate', () {
    test('is ISO-ordered so a column of dates lines up', () {
      expect(
        formatRemoteDate(DateTime(2026, 8, 27, 14, 5)),
        '2026-08-27 14:05',
      );
    });
  });

  group('describeRemoteEntry', () {
    test('omits a size the server never sent, rather than printing 0 B', () {
      const entry = RemoteEntry(
        name: 'notes.md',
        path: '/notes.md',
        kind: RemoteEntryKind.file,
      );

      expect(describeRemoteEntry(entry), 'File');
    });

    test(
      'reports a real zero-byte file as 0 B, which is not the same thing',
      () {
        const entry = RemoteEntry(
          name: 'empty',
          path: '/empty',
          kind: RemoteEntryKind.file,
          size: 0,
        );

        expect(describeRemoteEntry(entry), 'File · 0 B');
      },
    );

    test('names what a symlink resolves to', () {
      const entry = RemoteEntry(
        name: 'current',
        path: '/current',
        kind: RemoteEntryKind.symlink,
        linkTarget: RemoteEntryKind.directory,
      );

      expect(describeRemoteEntry(entry), 'Link to directory');
    });

    test('does not claim a target for a link it could not follow', () {
      const entry = RemoteEntry(
        name: 'broken',
        path: '/broken',
        kind: RemoteEntryKind.symlink,
      );

      expect(describeRemoteEntry(entry), 'Link');
    });
  });

  group('downloading a file', () {
    /// A directory holding one tappable file, plus the transfer service
    /// that serves its bytes.
    SftpFileService browserWithOneFile() => _service(
      directories: {
        '/home/gian': [
          fakeSftpName('report.docx', mode: FakeSftpModes.file, size: 4096),
        ],
      },
    );

    testWidgets('tapping a file starts a transfer and shows its progress', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        browserWithOneFile(),
        downloadService: _downloadService(
          files: {
            '/home/gian/report.docx': FakeRemoteFile(
              List<int>.filled(8 * SftpDownloadService.chunkSize, 7),
              chunkGap: const Duration(milliseconds: 20),
            ),
          },
        ),
      );

      await tester.tap(find.text('report.docx'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));

      expect(_byId(FilesSemantics.downloadStatus), findsOneWidget);
      expect(find.textContaining('Downloading report.docx'), findsOneWidget);
      expect(_byId(FilesSemantics.downloadCancelButton), findsOneWidget);

      await tester.pumpAndSettle();
    });

    testWidgets('the strip is absent until something is downloaded', (
      tester,
    ) async {
      await _pumpSheet(tester, browserWithOneFile());

      expect(_byId(FilesSemantics.downloadStatus), findsNothing);
    });

    testWidgets('cancelling reports it as cancelled, never as finished', (
      tester,
    ) async {
      final service = _downloadService(
        files: {
          '/home/gian/report.docx': FakeRemoteFile(
            List<int>.filled(20 * SftpDownloadService.chunkSize, 7),
            chunkGap: const Duration(milliseconds: 10),
          ),
        },
      );
      final container = await _pumpSheet(
        tester,
        browserWithOneFile(),
        downloadService: service,
      );
      final downloads = container.read(fileDownloadProvider.notifier);

      // Cancelled from the SAME callback the UI would cancel from — the
      // progress tick that first tells the user there is a transfer to
      // stop.
      await tester.runAsync(() async {
        container.listen(fileDownloadProvider, (_, next) {
          if (next.percent > 0) downloads.cancel();
        });
        await downloads.start(service, _fileEntry('/home/gian/report.docx'));
      });
      await tester.pumpAndSettle();

      expect(find.text('Download cancelled.'), findsOneWidget);
      expect(_byId(FilesSemantics.downloadNoViewer), findsNothing);
      expect(find.textContaining('Downloading'), findsNothing);
    });

    testWidgets('a refused file explains why, and offers a way out', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        browserWithOneFile(),
        downloadService: _downloadService(
          files: {
            '/home/gian/report.docx': FakeRemoteFile(const [1, 2, 3]),
          },
          deniedPaths: {'/home/gian/report.docx'},
        ),
      );

      await tester.tap(find.text('report.docx'));
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to read this file.'),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      expect(_byId(FilesSemantics.downloadStatus), findsNothing);
    });

    testWidgets('"no app can open this" is its own panel, not an error', (
      tester,
    ) async {
      _viewer = (_) async => ViewerOutcome.noViewer;
      final service = _downloadService(
        files: {
          '/home/gian/report.docx': FakeRemoteFile(List<int>.filled(4096, 7)),
        },
      );
      final container = await _pumpSheet(
        tester,
        browserWithOneFile(),
        downloadService: service,
      );

      await _runDownload(
        tester,
        container,
        service,
        _fileEntry('/home/gian/report.docx'),
      );

      expect(_byId(FilesSemantics.downloadNoViewer), findsOneWidget);
      expect(
        find.textContaining('no app on this device can open it'),
        findsOneWidget,
      );
      // The user is told where to go next rather than left at a dead end.
      expect(find.textContaining('saved on the device'), findsOneWidget);
    });

    testWidgets('a download that opens leaves no strip to dismiss', (
      tester,
    ) async {
      final service = _downloadService(
        files: {
          '/home/gian/report.docx': FakeRemoteFile(List<int>.filled(4096, 7)),
        },
      );
      final container = await _pumpSheet(
        tester,
        browserWithOneFile(),
        downloadService: service,
      );

      await _runDownload(
        tester,
        container,
        service,
        _fileEntry('/home/gian/report.docx'),
      );

      // The viewer is on screen in front of the user; a banner saying
      // "done" would be a second receipt for the same event.
      expect(_byId(FilesSemantics.downloadStatus), findsNothing);
      expect(
        container.read(fileDownloadProvider).status,
        FileDownloadStatus.opened,
      );
    });

    testWidgets('a socket is neither entered nor downloaded', (tester) async {
      await _pumpSheet(
        tester,
        _service(
          directories: {
            '/home/gian': [
              fakeSftpName('daemon.sock', mode: FakeSftpModes.socket),
            ],
          },
        ),
      );

      await tester.tap(find.text('daemon.sock'));
      await tester.pumpAndSettle();

      expect(_byId(FilesSemantics.downloadStatus), findsNothing);
    });
  });

  group('describeDownloadFailure', () {
    test('never reports a stall as a generic failure', () {
      expect(
        describeDownloadFailure(DownloadFailure.stalled),
        'The download stopped receiving data and was abandoned.',
      );
    });

    test('has a sentence for a reason that never arrived', () {
      expect(describeDownloadFailure(null), contains('did not say why'));
    });
  });

  group('creating a folder', () {
    testWidgets('creates a folder, reports it, and the listing shows it', (
      tester,
    ) async {
      final session = FakeSftpSession(directories: {'/home/gian': const []});
      await _pumpSheet(tester, SftpFileService.withOpener(() async => session));

      await tester.tap(find.byTooltip('New folder'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'new-folder');
      await tester.tap(_byId(FilesSemantics.createFolderConfirmButton));
      await tester.pumpAndSettle();

      expect(find.text('new-folder'), findsOneWidget);
      expect(find.textContaining('Created'), findsOneWidget);
    });

    testWidgets('cancelling the dialog creates nothing', (tester) async {
      final session = FakeSftpSession(directories: {'/home/gian': const []});
      await _pumpSheet(tester, SftpFileService.withOpener(() async => session));

      await tester.tap(find.byTooltip('New folder'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'new-folder');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(session.mkdirPaths, isEmpty);
      expect(_byId(FilesSemantics.emptyDirectory), findsOneWidget);
    });

    testWidgets('rejects an invalid name without a round trip', (tester) async {
      final session = FakeSftpSession(directories: {'/home/gian': const []});
      await _pumpSheet(tester, SftpFileService.withOpener(() async => session));

      await tester.tap(find.byTooltip('New folder'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'a/b');
      await tester.tap(_byId(FilesSemantics.createFolderConfirmButton));
      await tester.pumpAndSettle();

      expect(session.mkdirPaths, isEmpty);
      expect(find.textContaining('cannot contain'), findsOneWidget);
    });
  });

  group('renaming an entry', () {
    testWidgets('renames, reports it, and the listing shows the new name', (
      tester,
    ) async {
      final session = FakeSftpSession(
        directories: {
          '/home/gian': [fakeSftpName('old.txt', mode: FakeSftpModes.file)],
        },
      );
      await _pumpSheet(tester, SftpFileService.withOpener(() async => session));

      await tester.tap(
        find.descendant(
          of: _byId(FilesSemantics.entryMenuButton('/home/gian/old.txt')),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(_byId(FilesSemantics.renameMenuItem));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'new.txt');
      await tester.tap(_byId(FilesSemantics.renameConfirmButton));
      await tester.pumpAndSettle();

      expect(find.text('new.txt'), findsOneWidget);
      expect(find.text('old.txt'), findsNothing);
      expect(find.textContaining('Renamed'), findsOneWidget);
    });

    testWidgets('the rename field starts pre-filled with the current name', (
      tester,
    ) async {
      final session = FakeSftpSession(
        directories: {
          '/home/gian': [fakeSftpName('old.txt', mode: FakeSftpModes.file)],
        },
      );
      await _pumpSheet(tester, SftpFileService.withOpener(() async => session));

      await tester.tap(
        find.descendant(
          of: _byId(FilesSemantics.entryMenuButton('/home/gian/old.txt')),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(_byId(FilesSemantics.renameMenuItem));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'old.txt');
    });
  });

  group('deleting an entry', () {
    testWidgets('requires confirmation before anything is deleted', (
      tester,
    ) async {
      final session = FakeSftpSession(
        directories: {
          '/home/gian': [fakeSftpName('notes.md', mode: FakeSftpModes.file)],
        },
      );
      await _pumpSheet(tester, SftpFileService.withOpener(() async => session));

      await tester.tap(
        find.descendant(
          of: _byId(FilesSemantics.entryMenuButton('/home/gian/notes.md')),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(_byId(FilesSemantics.deleteMenuItem));
      await tester.pumpAndSettle();

      // The confirmation is on screen, and nothing was sent yet.
      expect(_byId(FilesSemantics.deleteConfirmButton), findsOneWidget);
      expect(session.removedPaths, isEmpty);
    });

    testWidgets('names the file being destroyed in the confirmation copy', (
      tester,
    ) async {
      final session = FakeSftpSession(
        directories: {
          '/home/gian': [fakeSftpName('notes.md', mode: FakeSftpModes.file)],
        },
      );
      await _pumpSheet(tester, SftpFileService.withOpener(() async => session));

      await tester.tap(
        find.descendant(
          of: _byId(FilesSemantics.entryMenuButton('/home/gian/notes.md')),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(_byId(FilesSemantics.deleteMenuItem));
      await tester.pumpAndSettle();

      expect(find.text('Delete this file?'), findsOneWidget);
      expect(find.textContaining('"notes.md"'), findsOneWidget);
    });

    testWidgets('names the directory being destroyed, distinctly from a file', (
      tester,
    ) async {
      final session = FakeSftpSession(
        directories: {
          '/home/gian': [
            fakeSftpName('empty-dir', mode: FakeSftpModes.directory),
          ],
          '/home/gian/empty-dir': const [],
        },
      );
      await _pumpSheet(tester, SftpFileService.withOpener(() async => session));

      await tester.tap(
        find.descendant(
          of: _byId(FilesSemantics.entryMenuButton('/home/gian/empty-dir')),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(_byId(FilesSemantics.deleteMenuItem));
      await tester.pumpAndSettle();

      expect(find.text('Delete this folder?'), findsOneWidget);
      expect(find.textContaining('"empty-dir"'), findsOneWidget);
    });

    testWidgets('cancelling the confirmation deletes nothing', (tester) async {
      final session = FakeSftpSession(
        directories: {
          '/home/gian': [fakeSftpName('notes.md', mode: FakeSftpModes.file)],
        },
      );
      await _pumpSheet(tester, SftpFileService.withOpener(() async => session));

      await tester.tap(
        find.descendant(
          of: _byId(FilesSemantics.entryMenuButton('/home/gian/notes.md')),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(_byId(FilesSemantics.deleteMenuItem));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(session.removedPaths, isEmpty);
      expect(find.text('notes.md'), findsOneWidget);
    });

    testWidgets('confirming deletes, reports it, and refreshes the listing', (
      tester,
    ) async {
      final session = FakeSftpSession(
        directories: {
          '/home/gian': [fakeSftpName('notes.md', mode: FakeSftpModes.file)],
        },
      );
      await _pumpSheet(tester, SftpFileService.withOpener(() async => session));

      await tester.tap(
        find.descendant(
          of: _byId(FilesSemantics.entryMenuButton('/home/gian/notes.md')),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(_byId(FilesSemantics.deleteMenuItem));
      await tester.pumpAndSettle();
      await tester.tap(_byId(FilesSemantics.deleteConfirmButton));
      await tester.pumpAndSettle();

      expect(session.removedPaths, ['/home/gian/notes.md']);
      expect(find.text('notes.md'), findsNothing);
      expect(_byId(FilesSemantics.emptyDirectory), findsOneWidget);
      expect(find.textContaining('Deleted'), findsOneWidget);
    });

    testWidgets('a non-empty directory is refused, with its own message', (
      tester,
    ) async {
      final session = FakeSftpSession(
        directories: {
          '/home/gian': [
            fakeSftpName('full-dir', mode: FakeSftpModes.directory),
          ],
          '/home/gian/full-dir': [
            fakeSftpName('child.txt', mode: FakeSftpModes.file),
          ],
        },
      );
      await _pumpSheet(tester, SftpFileService.withOpener(() async => session));

      await tester.tap(
        find.descendant(
          of: _byId(FilesSemantics.entryMenuButton('/home/gian/full-dir')),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(_byId(FilesSemantics.deleteMenuItem));
      await tester.pumpAndSettle();
      await tester.tap(_byId(FilesSemantics.deleteConfirmButton));
      await tester.pumpAndSettle();

      expect(session.rmdirPaths, isEmpty);
      expect(find.text('full-dir'), findsOneWidget);
      expect(find.textContaining('not empty'), findsOneWidget);
    });
  });
}
