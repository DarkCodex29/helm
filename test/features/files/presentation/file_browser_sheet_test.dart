// Widget tests for the remote file browser.
//
// The assertion this file exists for is the two-sided one in "listing
// outcomes": an empty directory and a refused directory look identical if
// you only check that no rows are on screen, and the browser must never
// let the second read as the first. Every case below therefore asserts
// both the panel that MUST be present and, explicitly, that the other one
// is absent.
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/features/files/data/sftp_file_service.dart';
import 'package:helm/features/files/domain/remote_entry.dart';
import 'package:helm/features/files/presentation/file_browser_sheet.dart';

import '../../../helpers/fake_sftp_session.dart';

Finder _byId(String identifier) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.identifier == identifier,
);

Future<void> _pumpSheet(WidgetTester tester, SftpFileService service) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(home: Scaffold(body: FileBrowserSheet(service: service))),
    ),
  );
  // One pump for the post-frame `open`, one for the listing it awaits.
  await tester.pumpAndSettle();
}

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

void main() {
  group('listing outcomes', () {
    testWidgets('an empty directory says so, and shows no error', (tester) async {
      await _pumpSheet(tester, _service(directories: {'/home/gian': const []}));

      expect(_byId(FilesSemantics.emptyDirectory), findsOneWidget);
      expect(_byId(FilesSemantics.listingError), findsNothing);
      expect(find.text('This directory is empty'), findsOneWidget);
    });

    testWidgets('a refused directory shows an error, and never the empty panel', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        _service(deniedPaths: const {'/home/gian'}, home: '/home/gian'),
      );

      expect(_byId(FilesSemantics.listingError), findsOneWidget);
      expect(_byId(FilesSemantics.emptyDirectory), findsNothing);
    });

    testWidgets('permission denied names permission, not a generic failure', (
      tester,
    ) async {
      await _pumpSheet(tester, _service(deniedPaths: const {'/home/gian'}));

      expect(
        find.text('You do not have permission to read this directory.'),
        findsOneWidget,
      );
    });

    testWidgets('a path that vanished says so in its own words', (tester) async {
      await _pumpSheet(tester, _service(directories: const {}));

      expect(
        find.text('This directory no longer exists on the host.'),
        findsOneWidget,
      );
    });

    testWidgets('a dropped connection says so in its own words', (tester) async {
      await _pumpSheet(
        tester,
        _service(listError: SftpAbortError('SFTP channel closed')),
      );

      expect(
        find.text('The connection dropped before this directory could be read.'),
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

    testWidgets('a file row states its kind and human-readable size', (tester) async {
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

    testWidgets('at the root, the up action is present but disabled', (tester) async {
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

    testWidgets('below the root, the up action moves to the parent', (tester) async {
      await _pumpSheet(
        tester,
        _service(
          directories: {'/home/gian': const [], '/home': const []},
        ),
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

    test('reports a real zero-byte file as 0 B, which is not the same thing', () {
      const entry = RemoteEntry(
        name: 'empty',
        path: '/empty',
        kind: RemoteEntryKind.file,
        size: 0,
      );

      expect(describeRemoteEntry(entry), 'File · 0 B');
    });

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
}
