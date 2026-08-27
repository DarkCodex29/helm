import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/files/data/sftp_file_service.dart';
import 'package:helm/features/files/domain/remote_listing.dart';
import 'package:helm/features/files/presentation/providers/file_browser_provider.dart';

import '../../../helpers/fake_sftp_session.dart';

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  FileBrowserNotifier notifier() => container.read(fileBrowserProvider.notifier);
  FileBrowserState state() => container.read(fileBrowserProvider);

  group('open', () {
    test('starts at the directory the server resolves for this session', () async {
      final service = _service(
        home: '/home/gian',
        directories: {'/home/gian': const []},
      );

      await notifier().open(service);

      expect(state().path, '/home/gian');
      expect(state().status, FileBrowserStatus.ready);
    });

    test('honours an explicit starting directory over the resolved one', () async {
      final service = _service(
        home: '/home/gian',
        directories: {'/srv': const []},
      );

      await notifier().open(service, startingDirectory: '/srv');

      expect(state().path, '/srv');
    });

    test('falls back to the root when the server will not resolve a path', () async {
      final service = _service(
        absoluteError: SftpAbortError('SFTP channel closed'),
        directories: {'/': const []},
      );

      await notifier().open(service);

      expect(state().path, '/');
    });
  });

  group('listing outcomes', () {
    test('an empty directory is ready-with-nothing, never failed', () async {
      final service = _service(directories: {'/home/gian': const []});

      await notifier().open(service);

      expect(state().status, FileBrowserStatus.ready);
      expect(state().entries, isEmpty);
      expect(state().failure, isNull);
    });

    test('permission denied is failed-with-a-reason, never ready-and-empty', () async {
      final service = _service(deniedPaths: const {'/root'});

      await notifier().open(service, startingDirectory: '/root');

      expect(state().status, FileBrowserStatus.failed);
      expect(state().failure, RemoteListingFailure.permissionDenied);
      expect(state().entries, isEmpty);
    });

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

    test('a symlink whose target never resolved is not a destination', () async {
      final service = _service(
        directories: {
          '/srv': [fakeSftpName('broken', mode: FakeSftpModes.symlink)],
        },
      );
      await notifier().open(service, startingDirectory: '/srv');

      await notifier().enter(state().entries.single);

      expect(state().path, '/srv');
    });
  });

  group('goUp', () {
    test('from a nested directory, lands on the directory containing it', () async {
      final service = _service(
        directories: {'/home/gian/projects': const [], '/home/gian': const []},
      );
      await notifier().open(service, startingDirectory: '/home/gian/projects');

      await notifier().goUp();

      expect(state().path, '/home/gian');
    });

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
