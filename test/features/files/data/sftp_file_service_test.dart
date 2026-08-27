import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/files/data/sftp_file_service.dart';
import 'package:helm/features/files/domain/remote_entry.dart';
import 'package:helm/features/files/domain/remote_listing.dart';

import '../../../helpers/fake_sftp_session.dart';

void main() {
  group('list', () {
    test('maps a directory listing into sorted domain entries', () async {
      final session = FakeSftpSession(
        directories: {
          '/home/gian': [
            fakeSftpName('notes.md', mode: FakeSftpModes.file),
            fakeSftpName('projects', mode: FakeSftpModes.directory),
          ],
        },
      );
      final service = SftpFileService.withOpener(() async => session);

      final listing = await service.list('/home/gian');

      expect(listing, isA<RemoteListingLoaded>());
      final entries = (listing as RemoteListingLoaded).entries;
      expect(entries.map((e) => e.name), ['projects', 'notes.md']);
      expect(entries.first.kind, RemoteEntryKind.directory);
      expect(entries.first.path, '/home/gian/projects');
      expect(entries.last.kind, RemoteEntryKind.file);
    });

    test('drops the self and parent entries wherever the server put them', () async {
      final session = FakeSftpSession(
        directories: {
          '/home/gian': [
            fakeSftpName('notes.md', mode: FakeSftpModes.file),
            fakeSftpName('.', mode: FakeSftpModes.directory),
            fakeSftpName('..', mode: FakeSftpModes.directory),
          ],
        },
      );
      final service = SftpFileService.withOpener(() async => session);

      final listing = await service.list('/home/gian') as RemoteListingLoaded;

      expect(listing.entries.map((e) => e.name), ['notes.md']);
    });

    test('keeps a dotfile that is not the self or parent entry', () async {
      final session = FakeSftpSession(
        directories: {
          '/home/gian': [fakeSftpName('.bashrc', mode: FakeSftpModes.file)],
        },
      );
      final service = SftpFileService.withOpener(() async => session);

      final listing = await service.list('/home/gian') as RemoteListingLoaded;

      expect(listing.entries.map((e) => e.name), ['.bashrc']);
    });

    test('an empty directory loads empty, and is not a failure', () async {
      final session = FakeSftpSession(directories: {'/empty': const []});
      final service = SftpFileService.withOpener(() async => session);

      final listing = await service.list('/empty');

      expect(listing, isA<RemoteListingLoaded>());
      expect((listing as RemoteListingLoaded).entries, isEmpty);
    });

    test('a directory holding only . and .. also loads empty, not failed', () async {
      final session = FakeSftpSession(
        directories: {
          '/empty': [
            fakeSftpName('.', mode: FakeSftpModes.directory),
            fakeSftpName('..', mode: FakeSftpModes.directory),
          ],
        },
      );
      final service = SftpFileService.withOpener(() async => session);

      final listing = await service.list('/empty');

      expect(listing, isA<RemoteListingLoaded>());
      expect((listing as RemoteListingLoaded).entries, isEmpty);
    });

    test('falls back to the longname when the server omitted permissions', () async {
      final session = FakeSftpSession(
        directories: {
          '/home/gian': [
            fakeSftpName(
              'projects',
              longname: 'drwxr-xr-x 2 gian staff 64 Jan  1 12:00 projects',
            ),
          ],
        },
      );
      final service = SftpFileService.withOpener(() async => session);

      final listing = await service.list('/home/gian') as RemoteListingLoaded;

      expect(listing.entries.single.kind, RemoteEntryKind.directory);
    });

    test('resolves a symlink target so tapping it can navigate', () async {
      final session = FakeSftpSession(
        directories: {
          '/srv': [fakeSftpName('current', mode: FakeSftpModes.symlink)],
        },
        stats: {
          '/srv/current': SftpFileAttrs(
            mode: SftpFileMode.value(FakeSftpModes.directory),
          ),
        },
      );
      final service = SftpFileService.withOpener(() async => session);

      final listing = await service.list('/srv') as RemoteListingLoaded;

      expect(session.statedPaths, ['/srv/current']);
      expect(listing.entries.single.kind, RemoteEntryKind.symlink);
      expect(listing.entries.single.linkTarget, RemoteEntryKind.directory);
      expect(listing.entries.single.isNavigable, isTrue);
    });

    test('a broken symlink leaves the rest of the listing intact', () async {
      final session = FakeSftpSession(
        directories: {
          '/srv': [
            fakeSftpName('broken', mode: FakeSftpModes.symlink),
            fakeSftpName('notes.md', mode: FakeSftpModes.file),
          ],
        },
      );
      final service = SftpFileService.withOpener(() async => session);

      final listing = await service.list('/srv') as RemoteListingLoaded;

      expect(listing.entries.map((e) => e.name), ['broken', 'notes.md']);
      expect(listing.entries.first.linkTarget, isNull);
      expect(listing.entries.first.isNavigable, isFalse);
    });

    test('does not stat anything when the listing holds no symlinks', () async {
      final session = FakeSftpSession(
        directories: {
          '/home/gian': [fakeSftpName('notes.md', mode: FakeSftpModes.file)],
        },
      );
      final service = SftpFileService.withOpener(() async => session);

      await service.list('/home/gian');

      expect(session.statedPaths, isEmpty);
    });
  });

  group('list failures', () {
    test('permission denied surfaces as its own reason, not as empty', () async {
      final service = SftpFileService.withOpener(
        () async => FakeSftpSession(deniedPaths: const {'/root'}),
      );

      final listing = await service.list('/root');

      expect(listing, isA<RemoteListingFailed>());
      expect(
        (listing as RemoteListingFailed).reason,
        RemoteListingFailure.permissionDenied,
      );
    });

    test('a path that vanished surfaces as not found', () async {
      final service = SftpFileService.withOpener(
        () async => FakeSftpSession(directories: const {}),
      );

      final listing = await service.list('/gone');

      expect(
        (listing as RemoteListingFailed).reason,
        RemoteListingFailure.notFound,
      );
    });

    test('a dropped channel surfaces as disconnected', () async {
      final service = SftpFileService.withOpener(
        () async =>
            FakeSftpSession(listError: SftpAbortError('SFTP channel closed')),
      );

      final listing = await service.list('/home/gian');

      expect(
        (listing as RemoteListingFailed).reason,
        RemoteListingFailure.disconnected,
      );
    });

    test('a failure to open the session at all is reported, never thrown', () async {
      final service = SftpFileService.withOpener(
        () async => throw StateError('no transport'),
      );

      final listing = await service.list('/home/gian');

      expect(listing, isA<RemoteListingFailed>());
      expect(
        (listing as RemoteListingFailed).reason,
        RemoteListingFailure.disconnected,
      );
    });

    test('carries the server own words alongside the reason', () async {
      final service = SftpFileService.withOpener(
        () async => FakeSftpSession(deniedPaths: const {'/root'}),
      );

      final listing = await service.list('/root') as RemoteListingFailed;

      expect(listing.detail, 'Permission denied');
    });
  });

  group('session lifetime', () {
    test('reuses one session across navigations instead of opening per call', () async {
      var opens = 0;
      final session = FakeSftpSession(
        directories: {'/a': const [], '/b': const []},
      );
      final service = SftpFileService.withOpener(() async {
        opens++;
        return session;
      });

      await service.list('/a');
      await service.list('/b');

      expect(opens, 1);
      expect(session.listedPaths, ['/a', '/b']);
    });

    test('opens exactly one session when two listings race', () async {
      final gate = Completer<void>();
      var opens = 0;
      final session = FakeSftpSession(
        directories: {'/a': const [], '/b': const []},
      );
      final service = SftpFileService.withOpener(() async {
        opens++;
        await gate.future;
        return session;
      });

      final first = service.list('/a');
      final second = service.list('/b');
      gate.complete();
      await Future.wait([first, second]);

      expect(opens, 1);
    });

    test('an ordinary SFTP status keeps the session, since the channel is fine', () async {
      var opens = 0;
      final session = FakeSftpSession(directories: {'/ok': const []});
      final service = SftpFileService.withOpener(() async {
        opens++;
        return session;
      });

      await service.list('/gone'); // notFound, an ordinary protocol status
      await service.list('/ok');

      expect(opens, 1);
    });

    test('a transport failure drops the session so the next call recovers', () async {
      var opens = 0;
      final sessions = [
        FakeSftpSession(listError: SftpAbortError('SFTP channel closed')),
        FakeSftpSession(directories: {'/home/gian': const []}),
      ];
      final service = SftpFileService.withOpener(() async => sessions[opens++]);

      final failed = await service.list('/home/gian');
      final recovered = await service.list('/home/gian');

      expect(failed, isA<RemoteListingFailed>());
      expect(recovered, isA<RemoteListingLoaded>());
      expect(opens, 2);
    });

    test('a failed open is not cached as the session', () async {
      var opens = 0;
      final service = SftpFileService.withOpener(() async {
        opens++;
        if (opens == 1) throw StateError('no transport');
        return FakeSftpSession(directories: {'/home/gian': const []});
      });

      await service.list('/home/gian');
      final recovered = await service.list('/home/gian');

      expect(recovered, isA<RemoteListingLoaded>());
      expect(opens, 2);
    });

    test('close ends the underlying session', () async {
      final session = FakeSftpSession(directories: {'/a': const []});
      final service = SftpFileService.withOpener(() async => session);
      await service.list('/a');

      await service.close();

      expect(session.closed, isTrue);
    });

    test('close without a session ever opened does not open one', () async {
      var opens = 0;
      final service = SftpFileService.withOpener(() async {
        opens++;
        return FakeSftpSession(directories: const {});
      });

      await service.close();

      expect(opens, 0);
    });

    test('close awaits an open that was still in flight, and ends it', () async {
      final gate = Completer<void>();
      final session = FakeSftpSession(directories: {'/a': const []});
      final service = SftpFileService.withOpener(() async {
        await gate.future;
        return session;
      });

      final pending = service.list('/a');
      final closing = service.close();
      gate.complete();
      await Future.wait([pending, closing]);

      expect(session.closed, isTrue);
    });

    test('a closed service refuses to reopen behind the caller back', () async {
      var opens = 0;
      final service = SftpFileService.withOpener(() async {
        opens++;
        return FakeSftpSession(directories: {'/a': const []});
      });
      await service.list('/a');
      await service.close();

      final listing = await service.list('/a');

      expect(opens, 1);
      expect(
        (listing as RemoteListingFailed).reason,
        RemoteListingFailure.disconnected,
      );
    });
  });

  group('startingDirectory', () {
    test('answers with the path the server resolves for the session', () async {
      final service = SftpFileService.withOpener(
        () async => FakeSftpSession(directories: const {}, home: '/home/gian'),
      );

      expect(await service.startingDirectory(), '/home/gian');
    });

    test('returns null rather than guessing when the server will not say', () async {
      final service = SftpFileService.withOpener(
        () async => FakeSftpSession(
          directories: const {},
          absoluteError: SftpAbortError('SFTP channel closed'),
        ),
      );

      expect(await service.startingDirectory(), isNull);
    });
  });
}
