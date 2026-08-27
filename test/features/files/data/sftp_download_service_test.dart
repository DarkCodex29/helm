// Tests for the SFTP download engine.
//
// The assertion this file exists for is the one dartssh2 cannot make for
// us: a CANCELLED transfer and a COMPLETED one must never be reported as
// the same thing. The library has no cancellation on the read path at all
// — `abort()` is on the upload half (`sftp_stream_io.dart:74`) — so
// "stopped consuming the stream" is all the evidence there is, and it is
// identical in both cases. Every ending below therefore asserts the exact
// outcome CLASS, never merely that a file does or does not exist.
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/files/data/sftp_download_service.dart';
import 'package:helm/features/files/domain/download_outcome.dart';
import 'package:helm/features/files/domain/remote_entry.dart';

import '../../../helpers/fake_sftp_session.dart';

/// A file entry as the browser would hand one over.
RemoteEntry _entry(String path) => RemoteEntry(
  name: path.split('/').last,
  path: path,
  kind: RemoteEntryKind.file,
);

Uint8List _bytes(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => i % 251));

void main() {
  late Directory destination;

  setUp(() {
    destination = Directory.systemTemp.createTempSync('helm_download_test');
  });

  tearDown(() {
    if (destination.existsSync()) destination.deleteSync(recursive: true);
  });

  SftpDownloadService serviceFor(
    FakeSftpSession session, {
    Duration idleTimeout = const Duration(seconds: 30),
  }) {
    return SftpDownloadService.withOpener(
      () async => session,
      directory: () async => destination,
      idleTimeout: idleTimeout,
    );
  }

  /// Everything the service wrote, so a test can assert on leftovers as
  /// well as on the file it was asked for.
  List<String> filesOnDisk() => destination
      .listSync(recursive: true)
      .whereType<File>()
      .map((f) => f.path.split('/').last)
      .toList()
    ..sort();

  group('a successful download', () {
    test('writes the exact bytes the server sent', () async {
      final payload = _bytes(5000);
      final session = FakeSftpSession(
        files: {'/home/gian/report.docx': FakeRemoteFile(payload)},
      );

      final outcome = await serviceFor(
        session,
      ).download(_entry('/home/gian/report.docx'));

      expect(outcome, isA<DownloadCompleted>());
      final completed = outcome as DownloadCompleted;
      expect(completed.bytes, 5000);
      expect(completed.file.readAsBytesSync(), payload);
      expect(completed.file.path.endsWith('report.docx'), isTrue);
    });

    test('leaves no partial file behind once it is done', () async {
      final session = FakeSftpSession(
        files: {'/home/gian/report.docx': FakeRemoteFile(_bytes(5000))},
      );

      await serviceFor(session).download(_entry('/home/gian/report.docx'));

      expect(filesOnDisk(), ['report.docx']);
    });

    test('closes the transfer session and the file handle', () async {
      final session = FakeSftpSession(
        files: {'/home/gian/report.docx': FakeRemoteFile(_bytes(100))},
      );

      await serviceFor(session).download(_entry('/home/gian/report.docx'));

      expect(session.closed, isTrue);
      expect(session.openedHandles.single.closed, isTrue);
    });

    test('holds far less in flight than the library would by default', () async {
      final session = FakeSftpSession(
        files: {'/home/gian/report.docx': FakeRemoteFile(_bytes(100))},
      );

      await serviceFor(session).download(_entry('/home/gian/report.docx'));

      final handle = session.openedHandles.single;
      final inFlight =
          handle.requestedChunkSize! * handle.requestedMaxPendingRequests!;
      // dartssh2's own download defaults are 64 KiB x 128 = 8 MiB
      // (`sftp_client.dart:32-33`).
      expect(inFlight, lessThanOrEqualTo(512 * 1024));
      expect(inFlight, SftpDownloadService.pipelineBytesInFlight);
    });
  });

  group('progress', () {
    // Eight chunks at the service's own 64 KiB request size, so these
    // exercise a real multi-chunk transfer rather than a single yield.
    const eightChunks = 8 * SftpDownloadService.chunkSize;

    test('is reported as a percentage that reaches 100', () async {
      final session = FakeSftpSession(
        files: {'/home/gian/big.bin': FakeRemoteFile(_bytes(eightChunks))},
      );
      final seen = <int>[];

      await serviceFor(
        session,
      ).download(_entry('/home/gian/big.bin'), onProgress: seen.add);

      expect(seen, [12, 25, 37, 50, 62, 75, 87, 100]);
    });

    test('is throttled to whole percent CHANGES, not one event per chunk', () async {
      // 400 chunks over a file big enough that most of them do not move
      // the percentage at all. An unthrottled callback fires 400 times to
      // redraw a bar with 101 distinct states; a throttled one cannot
      // exceed 100 events, and never repeats a number.
      final session = FakeSftpSession(
        files: {
          '/home/gian/huge.bin': FakeRemoteFile(
            _bytes(400 * SftpDownloadService.chunkSize),
          ),
        },
      );
      final seen = <int>[];

      await serviceFor(
        session,
      ).download(_entry('/home/gian/huge.bin'), onProgress: seen.add);

      expect(seen.length, lessThan(400), reason: 'fewer events than chunks');
      expect(seen.toSet().length, seen.length, reason: 'no percentage repeats');
      expect(seen, orderedEquals(List<int>.from(seen)..sort()));
      expect(seen.last, 100);
    });
  });

  group('cancellation', () {
    test('reports cancelled, and NEVER completed', () async {
      final session = FakeSftpSession(
        files: {
          '/home/gian/big.bin': FakeRemoteFile(
            _bytes(200 * 1024),
            chunkGap: const Duration(milliseconds: 5),
          ),
        },
      );
      final cancellation = DownloadCancellation();

      final running = serviceFor(session).download(
        _entry('/home/gian/big.bin'),
        cancellation: cancellation,
        onProgress: (_) => cancellation.cancel(),
      );

      final outcome = await running;

      expect(outcome, isA<DownloadCancelled>());
      expect(outcome, isNot(isA<DownloadCompleted>()));
      expect(outcome, isNot(isA<DownloadFailed>()));
    });

    test('leaves nothing on disk that could be mistaken for the file', () async {
      final session = FakeSftpSession(
        files: {
          '/home/gian/big.bin': FakeRemoteFile(
            _bytes(200 * 1024),
            chunkGap: const Duration(milliseconds: 5),
          ),
        },
      );
      final cancellation = DownloadCancellation();

      await serviceFor(session).download(
        _entry('/home/gian/big.bin'),
        cancellation: cancellation,
        onProgress: (_) => cancellation.cancel(),
      );

      expect(filesOnDisk(), isEmpty);
    });

    test('still closes the transfer session and the handle', () async {
      final session = FakeSftpSession(
        files: {
          '/home/gian/big.bin': FakeRemoteFile(
            _bytes(200 * 1024),
            chunkGap: const Duration(milliseconds: 5),
          ),
        },
      );
      final cancellation = DownloadCancellation();

      await serviceFor(session).download(
        _entry('/home/gian/big.bin'),
        cancellation: cancellation,
        onProgress: (_) => cancellation.cancel(),
      );

      expect(session.closed, isTrue);
      expect(session.openedHandles.single.closed, isTrue);
    });

    test('a download cancelled before it starts never opens a handle', () async {
      final session = FakeSftpSession(
        files: {'/home/gian/big.bin': FakeRemoteFile(_bytes(1000))},
      );
      final cancellation = DownloadCancellation()..cancel();

      final outcome = await serviceFor(session).download(
        _entry('/home/gian/big.bin'),
        cancellation: cancellation,
      );

      expect(outcome, isA<DownloadCancelled>());
      expect(session.openedPaths, isEmpty);
      expect(session.closed, isTrue);
    });
  });

  group('the completeness check', () {
    test('fails loudly when the byte count misses the declared size', () async {
      final session = FakeSftpSession(
        files: {
          '/home/gian/report.docx': FakeRemoteFile(
            _bytes(500),
            declaredSize: 5000,
          ),
        },
      );

      final outcome = await serviceFor(
        session,
      ).download(_entry('/home/gian/report.docx'));

      expect(outcome, isA<DownloadFailed>());
      expect((outcome as DownloadFailed).reason, DownloadFailure.sizeMismatch);
    });

    test('a short download is deleted, not left looking complete', () async {
      final session = FakeSftpSession(
        files: {
          '/home/gian/report.docx': FakeRemoteFile(
            _bytes(500),
            declaredSize: 5000,
          ),
        },
      );

      await serviceFor(session).download(_entry('/home/gian/report.docx'));

      expect(filesOnDisk(), isEmpty);
    });

    test('refuses to transfer a file whose size the server withholds', () async {
      final session = FakeSftpSession(
        files: {
          '/home/gian/report.docx': FakeRemoteFile(
            _bytes(500),
            sizeIsUnknown: true,
          ),
        },
      );

      final outcome = await serviceFor(
        session,
      ).download(_entry('/home/gian/report.docx'));

      expect(outcome, isA<DownloadFailed>());
      expect((outcome as DownloadFailed).reason, DownloadFailure.unknownSize);
      expect(session.openedHandles.single.closed, isTrue);
    });

    test('an empty file is a completed download, not a failure', () async {
      final session = FakeSftpSession(
        files: {'/home/gian/empty.txt': FakeRemoteFile(const [])},
      );

      final outcome = await serviceFor(
        session,
      ).download(_entry('/home/gian/empty.txt'));

      expect(outcome, isA<DownloadCompleted>());
      expect((outcome as DownloadCompleted).bytes, 0);
      expect(filesOnDisk(), ['empty.txt']);
    });
  });

  group('the idle watchdog', () {
    test('fires when a transfer goes silent without ending', () async {
      final session = FakeSftpSession(
        files: {
          '/home/gian/big.bin': FakeRemoteFile(
            _bytes(200 * 1024),
            stallAfterChunk: 1,
          ),
        },
      );

      final outcome = await serviceFor(
        session,
        idleTimeout: const Duration(milliseconds: 120),
      ).download(_entry('/home/gian/big.bin'));

      expect(outcome, isA<DownloadFailed>());
      expect((outcome as DownloadFailed).reason, DownloadFailure.stalled);
    });

    test('does NOT fire on a transfer that is slow but still moving', () async {
      // Twelve chunks 40 ms apart is ~480 ms of transfer against a 150 ms
      // watchdog — more than three times the deadline, in total. A
      // whole-operation timeout would kill this download; an idle one must
      // not, because no single GAP ever reaches 150 ms. That gap between
      // "total elapsed" and "time since the last byte" is the whole
      // distinction this test exists to pin down.
      final session = FakeSftpSession(
        files: {
          '/home/gian/slow.bin': FakeRemoteFile(
            _bytes(12 * SftpDownloadService.chunkSize),
            chunkGap: const Duration(milliseconds: 40),
          ),
        },
      );

      final outcome = await serviceFor(
        session,
        idleTimeout: const Duration(milliseconds: 150),
      ).download(_entry('/home/gian/slow.bin'));

      expect(outcome, isA<DownloadCompleted>());
    });

    test('a stalled transfer leaves nothing on disk, and closes up', () async {
      final session = FakeSftpSession(
        files: {
          '/home/gian/big.bin': FakeRemoteFile(
            _bytes(200 * 1024),
            stallAfterChunk: 1,
          ),
        },
      );

      await serviceFor(
        session,
        idleTimeout: const Duration(milliseconds: 120),
      ).download(_entry('/home/gian/big.bin'));

      expect(filesOnDisk(), isEmpty);
      expect(session.closed, isTrue);
      expect(session.openedHandles.single.closed, isTrue);
    });
  });

  group('failures', () {
    test('a refused open reports permissionDenied', () async {
      final session = FakeSftpSession(
        files: {'/root/secret.txt': FakeRemoteFile(_bytes(10))},
        deniedPaths: {'/root/secret.txt'},
      );

      final outcome = await serviceFor(
        session,
      ).download(_entry('/root/secret.txt'));

      expect((outcome as DownloadFailed).reason, DownloadFailure.permissionDenied);
    });

    test('a missing file reports notFound', () async {
      final session = FakeSftpSession();

      final outcome = await serviceFor(session).download(_entry('/gone.txt'));

      expect((outcome as DownloadFailed).reason, DownloadFailure.notFound);
    });

    test('a session that cannot be opened reports disconnected', () async {
      final service = SftpDownloadService.withOpener(
        () async => throw SftpAbortError('SFTP channel closed'),
        directory: () async => destination,
      );

      final outcome = await service.download(_entry('/home/gian/report.docx'));

      expect((outcome as DownloadFailed).reason, DownloadFailure.disconnected);
    });

    test('a stream that dies mid-transfer reports disconnected', () async {
      final session = FakeSftpSession(
        files: {
          '/home/gian/big.bin': FakeRemoteFile(
            _bytes(200 * 1024),
            readError: SftpAbortError('SFTP channel closed'),
          ),
        },
      );

      final outcome = await serviceFor(
        session,
      ).download(_entry('/home/gian/big.bin'));

      expect((outcome as DownloadFailed).reason, DownloadFailure.disconnected);
      expect(filesOnDisk(), isEmpty);
      expect(session.closed, isTrue);
    });

    test('a destination it cannot write to reports storage', () async {
      // A regular FILE where the staging directory should be. Every
      // create/open under it fails at the OS, which is the closest a test
      // can get to a full disk without one.
      final blocked = File('${destination.path}/not_a_directory')
        ..writeAsStringSync('x');
      final service = SftpDownloadService.withOpener(
        () async => FakeSftpSession(
          files: {'/home/gian/report.docx': FakeRemoteFile(_bytes(100))},
        ),
        directory: () async => Directory(blocked.path),
      );

      final outcome = await service.download(_entry('/home/gian/report.docx'));

      expect(outcome, isA<DownloadFailed>());
      expect((outcome as DownloadFailed).reason, DownloadFailure.storage);
    });

    test('every failure still closes the transfer session', () async {
      final session = FakeSftpSession(
        files: {'/root/secret.txt': FakeRemoteFile(_bytes(10))},
        deniedPaths: {'/root/secret.txt'},
      );

      await serviceFor(session).download(_entry('/root/secret.txt'));

      expect(session.closed, isTrue);
    });
  });

  group('the staging directory', () {
    test('sweeps files older than the retention window', () async {
      final stale = File('${destination.path}/old.bin')
        ..writeAsBytesSync(_bytes(10))
        ..setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 3)),
        );
      final session = FakeSftpSession(
        files: {'/home/gian/report.docx': FakeRemoteFile(_bytes(100))},
      );

      await serviceFor(session).download(_entry('/home/gian/report.docx'));

      expect(stale.existsSync(), isFalse);
      expect(filesOnDisk(), ['report.docx']);
    });

    test('keeps a file that is still inside the retention window', () async {
      final fresh = File('${destination.path}/recent.bin')
        ..writeAsBytesSync(_bytes(10));
      final session = FakeSftpSession(
        files: {'/home/gian/report.docx': FakeRemoteFile(_bytes(100))},
      );

      await serviceFor(session).download(_entry('/home/gian/report.docx'));

      expect(fresh.existsSync(), isTrue);
    });
  });
}
