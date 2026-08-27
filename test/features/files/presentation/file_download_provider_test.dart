// Tests for the download/open orchestration behind the file browser.
//
// The two assertions this file exists for:
//
//  * a CANCELLED transfer never reaches [FileDownloadStatus.opened], and
//  * "nothing on this phone can open a .docx" is its OWN state, not an
//    error and not a silent success.
//
// The second is the one most likely to regress into a dead end, because
// the download genuinely succeeded and only the last step had nothing to
// hand the file to.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/files/data/external_viewer.dart';
import 'package:helm/features/files/data/sftp_download_service.dart';
import 'package:helm/features/files/domain/download_outcome.dart';
import 'package:helm/features/files/domain/remote_entry.dart';
import 'package:helm/features/files/presentation/providers/file_download_provider.dart';

import '../../../helpers/fake_sftp_session.dart';

RemoteEntry _entry(String path) => RemoteEntry(
  name: path.split('/').last,
  path: path,
  kind: RemoteEntryKind.file,
);

void main() {
  late Directory destination;
  late ProviderContainer container;

  setUp(() {
    destination = Directory.systemTemp.createTempSync('helm_download_provider');
    container = ProviderContainer();
  });

  tearDown(() {
    container.dispose();
    if (destination.existsSync()) destination.deleteSync(recursive: true);
  });

  SftpDownloadService serviceFor(FakeSftpSession session) =>
      SftpDownloadService.withOpener(
        () async => session,
        directory: () async => destination,
        idleTimeout: const Duration(milliseconds: 200),
      );

  FileDownloadNotifier notifierWith(ExternalViewer viewer) {
    final notifier = container.read(fileDownloadProvider.notifier);
    return notifier..debugUseViewer(viewer);
  }

  FakeSftpSession sessionWith(String path, {int size = 4096}) => FakeSftpSession(
    files: {path: FakeRemoteFile(List<int>.filled(size, 7))},
  );

  group('a download that is opened', () {
    test('ends in opened, having handed over the downloaded file', () async {
      File? handed;
      final notifier = notifierWith((file) async {
        handed = file;
        return ViewerOutcome.opened;
      });

      await notifier.start(
        serviceFor(sessionWith('/home/gian/report.docx')),
        _entry('/home/gian/report.docx'),
      );

      expect(notifier.state.status, FileDownloadStatus.opened);
      expect(handed, isNotNull);
      expect(handed!.existsSync(), isTrue);
      expect(handed!.lengthSync(), 4096);
    });

    test('reports progress while it runs, and ends at 100', () async {
      final notifier = notifierWith((_) async => ViewerOutcome.opened);
      final seen = <int>[];
      container.listen(
        fileDownloadProvider,
        (_, next) => seen.add(next.percent),
        fireImmediately: false,
      );

      await notifier.start(
        serviceFor(
          sessionWith(
            '/home/gian/big.bin',
            size: 8 * SftpDownloadService.chunkSize,
          ),
        ),
        _entry('/home/gian/big.bin'),
      );

      expect(seen, contains(100));
      expect(notifier.state.percent, 100);
    });

    test('names the entry it is working on while downloading', () async {
      final notifier = notifierWith((_) async => ViewerOutcome.opened);
      final names = <String?>[];
      container.listen(
        fileDownloadProvider,
        (_, next) => names.add(next.entry?.name),
        fireImmediately: false,
      );

      await notifier.start(
        serviceFor(sessionWith('/home/gian/report.docx')),
        _entry('/home/gian/report.docx'),
      );

      expect(names, contains('report.docx'));
    });
  });

  group('no viewer available', () {
    test('is its OWN state, not a failure and not a success', () async {
      final notifier = notifierWith((_) async => ViewerOutcome.noViewer);

      await notifier.start(
        serviceFor(sessionWith('/home/gian/report.docx')),
        _entry('/home/gian/report.docx'),
      );

      expect(notifier.state.status, FileDownloadStatus.noViewer);
      expect(notifier.state.status, isNot(FileDownloadStatus.opened));
      expect(notifier.state.status, isNot(FileDownloadStatus.failed));
    });

    test('keeps the downloaded file so the user is not at a dead end', () async {
      final notifier = notifierWith((_) async => ViewerOutcome.noViewer);

      await notifier.start(
        serviceFor(sessionWith('/home/gian/report.docx')),
        _entry('/home/gian/report.docx'),
      );

      expect(notifier.state.file, isNotNull);
      expect(notifier.state.file!.existsSync(), isTrue);
    });

    test('a viewer that fails outright is a failure, NOT noViewer', () async {
      final notifier = notifierWith((_) async => ViewerOutcome.failed);

      await notifier.start(
        serviceFor(sessionWith('/home/gian/report.docx')),
        _entry('/home/gian/report.docx'),
      );

      expect(notifier.state.status, FileDownloadStatus.failed);
      expect(notifier.state.status, isNot(FileDownloadStatus.noViewer));
    });
  });

  group('cancellation', () {
    test('ends cancelled, and never opens anything', () async {
      var viewerCalls = 0;
      final notifier = notifierWith((_) async {
        viewerCalls++;
        return ViewerOutcome.opened;
      });
      final session = FakeSftpSession(
        files: {
          '/home/gian/big.bin': FakeRemoteFile(
            List<int>.filled(8 * SftpDownloadService.chunkSize, 7),
            chunkGap: const Duration(milliseconds: 5),
          ),
        },
      );

      container.listen(fileDownloadProvider, (_, next) {
        if (next.status == FileDownloadStatus.downloading) notifier.cancel();
      });

      await notifier.start(serviceFor(session), _entry('/home/gian/big.bin'));

      expect(notifier.state.status, FileDownloadStatus.cancelled);
      expect(notifier.state.status, isNot(FileDownloadStatus.opened));
      expect(viewerCalls, 0);
    });
  });

  group('failures', () {
    test('a refused file surfaces the reason it was refused', () async {
      final notifier = notifierWith((_) async => ViewerOutcome.opened);
      final session = FakeSftpSession(
        files: {'/root/secret.txt': FakeRemoteFile(const [1, 2, 3])},
        deniedPaths: {'/root/secret.txt'},
      );

      await notifier.start(serviceFor(session), _entry('/root/secret.txt'));

      expect(notifier.state.status, FileDownloadStatus.failed);
      expect(notifier.state.failure, DownloadFailure.permissionDenied);
    });

    test('a second download replaces the first attempt cleanly', () async {
      final notifier = notifierWith((_) async => ViewerOutcome.opened);

      await notifier.start(
        serviceFor(FakeSftpSession()),
        _entry('/home/gian/gone.txt'),
      );
      expect(notifier.state.status, FileDownloadStatus.failed);

      await notifier.start(
        serviceFor(sessionWith('/home/gian/report.docx')),
        _entry('/home/gian/report.docx'),
      );

      expect(notifier.state.status, FileDownloadStatus.opened);
      expect(notifier.state.failure, isNull);
    });

    test('dismiss returns the notifier to idle', () async {
      final notifier = notifierWith((_) async => ViewerOutcome.opened);

      await notifier.start(
        serviceFor(FakeSftpSession()),
        _entry('/home/gian/gone.txt'),
      );
      notifier.dismiss();

      expect(notifier.state.status, FileDownloadStatus.idle);
      expect(notifier.state.entry, isNull);
      expect(notifier.state.failure, isNull);
    });
  });
}
