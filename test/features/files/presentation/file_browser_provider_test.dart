import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/files/data/sftp_file_service.dart';
import 'package:helm/features/files/domain/remote_listing.dart';
import 'package:helm/features/files/domain/remote_write_outcome.dart';
import 'package:helm/features/files/presentation/providers/file_browser_provider.dart';

import '../../../helpers/fake_sftp_session.dart';

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  FileBrowserNotifier notifier() =>
      container.read(fileBrowserProvider.notifier);
  FileBrowserState state() => container.read(fileBrowserProvider);

  _staleRefreshGroup(notifier, state);

  group('open', () {
    test(
      'starts at the directory the server resolves for this session',
      () async {
        final service = _service(
          home: '/home/gian',
          directories: {'/home/gian': const []},
        );

        await notifier().open(service);

        expect(state().path, '/home/gian');
        expect(state().status, FileBrowserStatus.ready);
      },
    );

    test(
      'honours an explicit starting directory over the resolved one',
      () async {
        final service = _service(
          home: '/home/gian',
          directories: {'/srv': const []},
        );

        await notifier().open(service, startingDirectory: '/srv');

        expect(state().path, '/srv');
      },
    );

    test(
      'falls back to the root when the server will not resolve a path',
      () async {
        final service = _service(
          absoluteError: SftpAbortError('SFTP channel closed'),
          directories: {'/': const []},
        );

        await notifier().open(service);

        expect(state().path, '/');
      },
    );
  });

  group('listing outcomes', () {
    test('an empty directory is ready-with-nothing, never failed', () async {
      final service = _service(directories: {'/home/gian': const []});

      await notifier().open(service);

      expect(state().status, FileBrowserStatus.ready);
      expect(state().entries, isEmpty);
      expect(state().failure, isNull);
    });

    test(
      'permission denied is failed-with-a-reason, never ready-and-empty',
      () async {
        final service = _service(deniedPaths: const {'/root'});

        await notifier().open(service, startingDirectory: '/root');

        expect(state().status, FileBrowserStatus.failed);
        expect(state().failure, RemoteListingFailure.permissionDenied);
        expect(state().entries, isEmpty);
      },
    );

    test('a failed listing still records where the attempt was made', () async {
      final service = _service(deniedPaths: const {'/root'});

      await notifier().open(service, startingDirectory: '/root');

      expect(state().path, '/root');
    });
  });

  group('enter', () {
    test('navigating into a directory appends exactly one segment', () async {
      final service = _service(
        directories: {
          '/home/gian': [
            fakeSftpName('projects', mode: FakeSftpModes.directory),
          ],
          '/home/gian/projects': const [],
        },
      );
      await notifier().open(service, startingDirectory: '/home/gian');

      await notifier().enter(state().entries.single);

      expect(state().path, '/home/gian/projects');
      expect(state().status, FileBrowserStatus.ready);
    });

    test('a file is not a destination and leaves the path alone', () async {
      final service = _service(
        directories: {
          '/home/gian': [fakeSftpName('notes.md', mode: FakeSftpModes.file)],
        },
      );
      await notifier().open(service, startingDirectory: '/home/gian');

      await notifier().enter(state().entries.single);

      expect(state().path, '/home/gian');
    });

    test('a symlink resolving to a directory is a destination', () async {
      final service = _service(
        directories: {
          '/srv': [fakeSftpName('current', mode: FakeSftpModes.symlink)],
          '/srv/current': const [],
        },
        stats: {
          '/srv/current': SftpFileAttrs(
            mode: SftpFileMode.value(FakeSftpModes.directory),
          ),
        },
      );
      await notifier().open(service, startingDirectory: '/srv');

      await notifier().enter(state().entries.single);

      expect(state().path, '/srv/current');
    });

    test(
      'a symlink whose target never resolved is not a destination',
      () async {
        final service = _service(
          directories: {
            '/srv': [fakeSftpName('broken', mode: FakeSftpModes.symlink)],
          },
        );
        await notifier().open(service, startingDirectory: '/srv');

        await notifier().enter(state().entries.single);

        expect(state().path, '/srv');
      },
    );
  });

  group('goUp', () {
    test(
      'from a nested directory, lands on the directory containing it',
      () async {
        final service = _service(
          directories: {
            '/home/gian/projects': const [],
            '/home/gian': const [],
          },
        );
        await notifier().open(
          service,
          startingDirectory: '/home/gian/projects',
        );

        await notifier().goUp();

        expect(state().path, '/home/gian');
      },
    );

    test('at the filesystem root, going up stays at the root', () async {
      final service = _service(directories: {'/': const []});
      await notifier().open(service, startingDirectory: '/');

      await notifier().goUp();

      expect(state().path, '/');
    });

    test('at the root it does not re-list, because nothing moved', () async {
      final session = FakeSftpSession(directories: {'/': const []});
      final service = SftpFileService.withOpener(() async => session);
      await notifier().open(service, startingDirectory: '/');

      await notifier().goUp();

      expect(session.listedPaths, ['/']);
    });

    test('recovers out of a directory that refused to be listed', () async {
      final service = _service(
        directories: {'/home': const []},
        deniedPaths: const {'/home/private'},
      );
      await notifier().open(service, startingDirectory: '/home/private');
      expect(state().status, FileBrowserStatus.failed);

      await notifier().goUp();

      expect(state().path, '/home');
      expect(state().status, FileBrowserStatus.ready);
      expect(state().failure, isNull);
    });
  });

  group('canGoUp', () {
    test('is false at the root, where up has nowhere to go', () async {
      final service = _service(directories: {'/': const []});

      await notifier().open(service, startingDirectory: '/');

      expect(state().canGoUp, isFalse);
    });

    test('is true anywhere below the root', () async {
      final service = _service(directories: {'/home': const []});

      await notifier().open(service, startingDirectory: '/home');

      expect(state().canGoUp, isTrue);
    });
  });

  group('reset', () {
    test('clears the browser so a later session starts from nothing', () async {
      final service = _service(directories: {'/home/gian': const []});
      await notifier().open(service, startingDirectory: '/home/gian');

      notifier().reset();

      expect(state().path, isNull);
      expect(state().status, FileBrowserStatus.idle);
      expect(state().entries, isEmpty);
    });
  });

  group('createFolder', () {
    test('creates a folder and refreshes the listing to show it', () async {
      final session = FakeSftpSession(directories: {'/home/gian': const []});
      final service = SftpFileService.withOpener(() async => session);
      await notifier().open(service, startingDirectory: '/home/gian');

      final outcome = await notifier().createFolder('new-folder');

      expect(outcome, isA<MkdirCreated>());
      expect(state().entries.map((e) => e.name), contains('new-folder'));
    });

    test('does not refresh when the name is rejected locally', () async {
      final session = FakeSftpSession(directories: {'/home/gian': const []});
      final service = SftpFileService.withOpener(() async => session);
      await notifier().open(service, startingDirectory: '/home/gian');

      final outcome = await notifier().createFolder('a/b');

      expect(outcome, isA<MkdirInvalidName>());
      expect(session.mkdirPaths, isEmpty);
      expect(state().entries, isEmpty);
    });

    test('does not refresh when the server refuses', () async {
      final session = FakeSftpSession(
        directories: {'/home/gian': const []},
        deniedPaths: const {'/home/gian/locked'},
      );
      final service = SftpFileService.withOpener(() async => session);
      await notifier().open(service, startingDirectory: '/home/gian');

      final outcome = await notifier().createFolder('locked');

      expect(outcome, isA<MkdirFailed>());
      expect(session.listedPaths, ['/home/gian']);
    });
  });

  group('renameEntry', () {
    test('renames and refreshes the listing with the new name', () async {
      final session = FakeSftpSession(
        directories: {
          '/home/gian': [fakeSftpName('old.txt', mode: FakeSftpModes.file)],
        },
      );
      final service = SftpFileService.withOpener(() async => session);
      await notifier().open(service, startingDirectory: '/home/gian');

      final outcome = await notifier().renameEntry(
        state().entries.single,
        'new.txt',
      );

      expect(outcome, isA<RenameCompleted>());
      expect(state().entries.map((e) => e.name), ['new.txt']);
    });

    test('does not refresh when the name is unchanged', () async {
      final session = FakeSftpSession(
        directories: {
          '/home/gian': [fakeSftpName('old.txt', mode: FakeSftpModes.file)],
        },
      );
      final service = SftpFileService.withOpener(() async => session);
      await notifier().open(service, startingDirectory: '/home/gian');

      final outcome = await notifier().renameEntry(
        state().entries.single,
        'old.txt',
      );

      expect(outcome, isA<RenameUnchanged>());
      expect(session.listedPaths, ['/home/gian']);
    });
  });

  group('deleteEntry', () {
    test('deletes and refreshes the listing without the entry', () async {
      final session = FakeSftpSession(
        directories: {
          '/home/gian': [fakeSftpName('notes.md', mode: FakeSftpModes.file)],
        },
      );
      final service = SftpFileService.withOpener(() async => session);
      await notifier().open(service, startingDirectory: '/home/gian');

      final outcome = await notifier().deleteEntry(state().entries.single);

      expect(outcome, isA<DeleteCompleted>());
      expect(state().entries, isEmpty);
    });

    test('does not refresh a non-empty directory delete refusal', () async {
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
      final service = SftpFileService.withOpener(() async => session);
      await notifier().open(service, startingDirectory: '/home/gian');

      final outcome = await notifier().deleteEntry(state().entries.single);

      expect(outcome, isA<DeleteDirectoryNotEmpty>());
      expect(state().entries.map((e) => e.name), ['full-dir']);
    });
  });
}

/// Two refreshes of one directory: the newest reply must win.
///
/// Found by an adversarial review — see odd/reviews/queue-and-strip.md.
/// Each successful upload starts a refresh without waiting for the one
/// before it, and the notifier accepted any reply whose path matched the
/// current path. Upload A and B into the same directory: A's refresh
/// stalls (the service resolves symlinks asynchronously per entry, with
/// no serialization), B's refresh returns both files, then A's lands and
/// overwrites it. The user gets two success receipts and a listing that
/// omits B.
void _staleRefreshGroup(
  FileBrowserNotifier Function() notifier,
  FileBrowserState Function() state,
) {
  group('two listings for the same directory', () {
    test('the newest reply wins, even when an older one lands later', () async {
      final session = _GatedSession(directories: {'/home/gian': const []});
      final service = SftpFileService.withOpener(() async => session);

      final opened = notifier().open(service);
      await pumpEventQueue();
      session.gates[0].complete();
      await opened;

      // Both refreshes in flight at once, which is exactly what two
      // completing uploads produce.
      // Deliberately DIFFERENT contents per call: if both replies carried
      // the same listing the test would pass by coincidence and prove
      // nothing about which one won.
      session.listings[1] = [fakeSftpName('a.txt', mode: FakeSftpModes.file)];
      session.listings[2] = [
        fakeSftpName('a.txt', mode: FakeSftpModes.file),
        fakeSftpName('b.txt', mode: FakeSftpModes.file),
      ];
      final first = notifier().refresh();
      await pumpEventQueue();
      final second = notifier().refresh();
      await pumpEventQueue();
      expect(session.gates.length, 3, reason: 'both refreshes are in flight');

      // The NEWER one answers first, then the older one lands late.
      session.gates[2].complete();
      await pumpEventQueue();
      session.gates[1].complete();
      await Future.wait([first, second]);

      expect(
        state().entries.map((e) => e.name),
        containsAll(<String>['a.txt', 'b.txt']),
        reason: 'a stale reply must not drop the newer listing',
      );
    });
  });
}

/// A session whose directory listings finish only when the test says so.
///
/// The staleness guard the notifier shipped with compared only PATHS, so
/// two refreshes of the SAME directory both passed it and whichever
/// finished last won — not the newest. Proving that needs the first reply
/// to land AFTER the second, which real timing will not reliably produce,
/// so each `listdir` parks on a completer this test releases by hand.
class _GatedSession extends FakeSftpSession {
  _GatedSession({required super.directories});

  /// One completer per `listdir` call, in call order.
  final gates = <Completer<void>>[];

  /// What the Nth call should see, keyed by call index, so an older reply
  /// can carry an older listing rather than merely arriving late with
  /// identical contents. A map rather than a list: an indexed list has to
  /// be grown with nulls it cannot hold.
  final listings = <int, List<SftpName>>{};

  @override
  Future<List<SftpName>> listdir(String path) async {
    final index = gates.length;
    final gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    return listings[index] ?? await super.listdir(path);
  }
}

SftpFileService _service({
  Map<String, List<SftpName>> directories = const {},
  Map<String, SftpFileAttrs> stats = const {},
  Object? absoluteError,
  Set<String> deniedPaths = const {},
  String home = '/home/gian',
}) {
  return SftpFileService.withOpener(
    () async => FakeSftpSession(
      directories: directories,
      stats: stats,
      absoluteError: absoluteError,
      deniedPaths: deniedPaths,
      home: home,
    ),
  );
}
