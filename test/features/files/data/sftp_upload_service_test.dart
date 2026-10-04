// Tests for the SFTP upload engine.
//
// The assertion this file exists for is the mirror image of the download
// test's: a CANCELLED upload and a COMPLETED one must never be reported as
// the same thing, and — the half of this that is specific to uploading —
// an existing destination must be refused before a single local byte is
// read, because the finalizing rename this service performs on success
// overwrites SILENTLY on OpenSSH (measured 2026-10-03 against
// `sftp -D /usr/libexec/sftp-server`). Relying on that rename to fail
// instead of checking first would destroy a file the user never named.
import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/files/data/sftp_upload_service.dart';
import 'package:helm/features/files/domain/upload_outcome.dart';

import '../../../helpers/fake_sftp_session.dart';

/// A scripted [UploadSource], so a test can provoke a local read failure
/// deterministically — the thing a real [File] cannot be made to do on
/// demand. See [UploadSource]'s own doc comment for why this seam exists
/// at all.
class _FakeUploadSource implements UploadSource {
  _FakeUploadSource(
    this.chunks, {
    int? declaredLength,
    this.lengthError,
    this.errorAfterChunk,
    this.readError,
  }) : declaredLength =
           declaredLength ?? chunks.fold(0, (sum, c) => sum + c.length);

  final List<List<int>> chunks;
  final int declaredLength;
  final Object? lengthError;

  /// Throws [readError] (or a generic exception) right after yielding
  /// the chunk at this 1-based position — the local-source mirror of
  /// [FakeRemoteFile.readError], which fails a DOWNLOAD mid-stream
  /// instead of an upload.
  final int? errorAfterChunk;
  final Object? readError;

  @override
  Future<int> length() async {
    final error = lengthError;
    if (error != null) throw error;
    return declaredLength;
  }

  @override
  Stream<List<int>> openRead() async* {
    for (var i = 0; i < chunks.length; i++) {
      yield chunks[i];
      if (errorAfterChunk != null && i + 1 == errorAfterChunk) {
        throw readError ?? Exception('local source failed');
      }
    }
  }
}

List<int> _bytes(int length) => List<int>.generate(length, (i) => i % 251);

/// Splits [bytes] into [count] roughly equal chunks, so a test can assert
/// on progress and offsets across a real multi-chunk transfer.
List<List<int>> _chunked(List<int> bytes, int count) {
  final size = (bytes.length / count).ceil();
  return [
    for (var start = 0; start < bytes.length; start += size)
      bytes.sublist(start, (start + size).clamp(0, bytes.length)),
  ];
}

void main() {
  SftpUploadService serviceFor(
    FakeSftpSession session, {
    Duration idleTimeout = const Duration(seconds: 30),
  }) {
    return SftpUploadService.withOpener(
      () async => session,
      idleTimeout: idleTimeout,
    );
  }

  group('a successful upload', () {
    test('writes the exact bytes and renames the partial into place', () async {
      final session = FakeSftpSession();
      final payload = _bytes(5000);

      final outcome = await serviceFor(session).upload(
        _FakeUploadSource(_chunked(payload, 4)),
        '/home/gian/report.docx',
      );

      expect(outcome, isA<UploadCompleted>());
      final completed = outcome as UploadCompleted;
      expect(completed.path, '/home/gian/report.docx');
      expect(completed.bytes, 5000);
      expect(session.writtenBytes['/home/gian/report.docx'], payload);
    });

    test(
      'opens the partial path, never the destination, for writing',
      () async {
        final session = FakeSftpSession();

        await serviceFor(session).upload(
          _FakeUploadSource(_chunked(_bytes(100), 2)),
          '/home/gian/report.docx',
        );

        expect(session.openedWritePaths, [
          '/home/gian/report.docx${SftpUploadService.partialSuffix}',
        ]);
      },
    );

    test('leaves no partial file behind once it is done', () async {
      final session = FakeSftpSession();

      await serviceFor(session).upload(
        _FakeUploadSource(_chunked(_bytes(100), 2)),
        '/home/gian/report.docx',
      );

      expect(
        session.writtenBytes.containsKey(
          '/home/gian/report.docx${SftpUploadService.partialSuffix}',
        ),
        isFalse,
      );
      expect(session.removedPaths, isEmpty);
    });

    test('closes the transfer session and the write handle', () async {
      final session = FakeSftpSession();

      await serviceFor(session).upload(
        _FakeUploadSource(_chunked(_bytes(100), 2)),
        '/home/gian/report.docx',
      );

      expect(session.closed, isTrue);
      expect(session.openedWriteHandles.single.closed, isTrue);
    });

    test('writes chunks at strictly increasing offsets', () async {
      final session = FakeSftpSession();

      await serviceFor(session).upload(
        _FakeUploadSource(_chunked(_bytes(5000), 4)),
        '/home/gian/report.docx',
      );

      final offsets = session.openedWriteHandles.single.offsetsSeen;
      expect(offsets, [0, 1250, 2500, 3750]);
    });

    test('an empty file is a completed upload, not a failure', () async {
      final session = FakeSftpSession();

      final outcome = await serviceFor(
        session,
      ).upload(_FakeUploadSource(const []), '/home/gian/empty.txt');

      expect(outcome, isA<UploadCompleted>());
      expect((outcome as UploadCompleted).bytes, 0);
    });
  });

  group('the destination guard', () {
    test('refuses when the destination already exists', () async {
      final session = FakeSftpSession(
        stats: {
          '/home/gian/report.docx': SftpFileAttrs(
            mode: SftpFileMode.value(FakeSftpModes.file),
          ),
        },
      );

      final outcome = await serviceFor(session).upload(
        _FakeUploadSource(_chunked(_bytes(100), 2)),
        '/home/gian/report.docx',
      );

      expect(outcome, isA<UploadDestinationExists>());
    });

    test('never reads the source or opens anything, when refused', () async {
      final session = FakeSftpSession(
        stats: {
          '/home/gian/report.docx': SftpFileAttrs(
            mode: SftpFileMode.value(FakeSftpModes.file),
          ),
        },
      );
      var sourceWasRead = false;
      final source = _FakeUploadSourceSpy(
        _chunked(_bytes(100), 2),
        onRead: () => sourceWasRead = true,
      );

      await serviceFor(session).upload(source, '/home/gian/report.docx');

      expect(sourceWasRead, isFalse);
      expect(session.openedWritePaths, isEmpty);
      expect(session.closed, isTrue);
    });
  });

  group('cancellation', () {
    test('reports cancelled, and NEVER completed', () async {
      final session = FakeSftpSession();
      final cancellation = UploadCancellation();

      final outcome = await serviceFor(session).upload(
        _FakeUploadSource(_chunked(_bytes(5000), 4)),
        '/home/gian/report.docx',
        cancellation: cancellation,
        onProgress: (_) => cancellation.cancel(),
      );

      expect(outcome, isA<UploadCancelled>());
      expect(outcome, isNot(isA<UploadCompleted>()));
      expect(outcome, isNot(isA<UploadFailed>()));
    });

    test('leaves no partial file behind on the server', () async {
      final session = FakeSftpSession();
      final cancellation = UploadCancellation();

      await serviceFor(session).upload(
        _FakeUploadSource(_chunked(_bytes(5000), 4)),
        '/home/gian/report.docx',
        cancellation: cancellation,
        onProgress: (_) => cancellation.cancel(),
      );

      expect(
        session.removedPaths,
        contains('/home/gian/report.docx${SftpUploadService.partialSuffix}'),
      );
    });

    test('cancelled before it starts never opens a write handle', () async {
      final session = FakeSftpSession();
      final cancellation = UploadCancellation()..cancel();

      final outcome = await serviceFor(session).upload(
        _FakeUploadSource(_chunked(_bytes(100), 2)),
        '/home/gian/report.docx',
        cancellation: cancellation,
      );

      expect(outcome, isA<UploadCancelled>());
      expect(session.openedWritePaths, isEmpty);
      expect(session.closed, isTrue);
    });
  });

  group('a source whose length cannot be read', () {
    test('reports sourceUnreadable without touching the server', () async {
      final session = FakeSftpSession();

      final outcome = await serviceFor(session).upload(
        _FakeUploadSource(
          _chunked(_bytes(100), 2),
          lengthError: Exception('stat failed'),
        ),
        '/home/gian/report.docx',
      );

      expect(outcome, isA<UploadFailed>());
      expect((outcome as UploadFailed).reason, UploadFailure.sourceUnreadable);
      expect(session.openedWritePaths, isEmpty);
    });
  });

  group('a source that fails mid-stream', () {
    test('reports sourceUnreadable', () async {
      final session = FakeSftpSession();

      final outcome = await serviceFor(session).upload(
        _FakeUploadSource(
          _chunked(_bytes(5000), 4),
          errorAfterChunk: 2,
          readError: Exception('disk yanked'),
        ),
        '/home/gian/report.docx',
      );

      expect(outcome, isA<UploadFailed>());
      expect((outcome as UploadFailed).reason, UploadFailure.sourceUnreadable);
    });

    test('cleans up the partial it had already started writing', () async {
      final session = FakeSftpSession();

      await serviceFor(session).upload(
        _FakeUploadSource(
          _chunked(_bytes(5000), 4),
          errorAfterChunk: 2,
          readError: Exception('disk yanked'),
        ),
        '/home/gian/report.docx',
      );

      expect(
        session.removedPaths,
        contains('/home/gian/report.docx${SftpUploadService.partialSuffix}'),
      );
    });
  });

  group('a server refusal', () {
    test('on open reports the classified reason', () async {
      final session = FakeSftpSession(
        openWriteError: SftpStatusError(
          SftpStatusCode.permissionDenied,
          'Permission denied',
        ),
      );

      final outcome = await serviceFor(session).upload(
        _FakeUploadSource(_chunked(_bytes(100), 2)),
        '/home/gian/report.docx',
      );

      expect(outcome, isA<UploadFailed>());
      expect((outcome as UploadFailed).reason, UploadFailure.permissionDenied);
    });

    test('mid-stream reports the classified reason and cleans up', () async {
      final session = FakeSftpSession();

      final outcome = await serviceFor(session).upload(
        _FakeUploadSource(_chunked(_bytes(5000), 4))
          ..attachWriteFailureVia(session, failFromChunk: 3),
        '/home/gian/report.docx',
      );

      expect(outcome, isA<UploadFailed>());
      expect(
        session.removedPaths,
        contains('/home/gian/report.docx${SftpUploadService.partialSuffix}'),
      );
    });
  });

  group('progress', () {
    test(
      'is reported as a percentage that reaches 100, monotonically',
      () async {
        final session = FakeSftpSession();
        final seen = <int>[];

        await serviceFor(session).upload(
          _FakeUploadSource(_chunked(_bytes(8000), 8)),
          '/home/gian/big.bin',
          onProgress: seen.add,
        );

        expect(seen, isNotEmpty);
        expect(seen, orderedEquals(List<int>.from(seen)..sort()));
        expect(
          seen.toSet().length,
          seen.length,
          reason: 'no percentage repeats',
        );
        expect(seen.last, 100);
      },
    );
  });

  group('the idle watchdog', () {
    test('fires when the server stops acknowledging writes', () async {
      final session = FakeSftpSession();

      final outcome =
          await serviceFor(
            session,
            idleTimeout: const Duration(milliseconds: 80),
          ).upload(
            _FakeUploadSource(_chunked(_bytes(5000), 4))
              ..attachStallVia(session, stallFromChunk: 2),
            '/home/gian/report.docx',
          );

      expect(outcome, isA<UploadFailed>());
      expect((outcome as UploadFailed).reason, UploadFailure.stalled);
    });
  });

  group('the completeness check', () {
    test('fails when fewer bytes were sent than the source declared', () async {
      final session = FakeSftpSession();

      final outcome = await serviceFor(session).upload(
        _FakeUploadSource(_chunked(_bytes(500), 2), declaredLength: 5000),
        '/home/gian/report.docx',
      );

      expect(outcome, isA<UploadFailed>());
      expect((outcome as UploadFailed).reason, UploadFailure.sizeMismatch);
    });
  });

  group('cleanup failures', () {
    test(
      'a partial that cannot be removed does not mask the real outcome',
      () async {
        final session = FakeSftpSession(
          removeError: SftpAbortError('cannot remove'),
        );
        final cancellation = UploadCancellation();

        final outcome = await serviceFor(session).upload(
          _FakeUploadSource(_chunked(_bytes(5000), 4)),
          '/home/gian/report.docx',
          cancellation: cancellation,
          onProgress: (_) => cancellation.cancel(),
        );

        expect(outcome, isA<UploadCancelled>());
      },
    );
  });

  group('failures', () {
    test('a session that cannot be opened reports disconnected', () async {
      final service = SftpUploadService.withOpener(
        () async => throw SftpAbortError('SFTP channel closed'),
      );

      final outcome = await service.upload(
        _FakeUploadSource(_chunked(_bytes(100), 2)),
        '/home/gian/report.docx',
      );

      expect((outcome as UploadFailed).reason, UploadFailure.disconnected);
    });

    test('every failure still closes the transfer session', () async {
      final session = FakeSftpSession(
        openWriteError: SftpAbortError('SFTP channel closed'),
      );

      await serviceFor(session).upload(
        _FakeUploadSource(_chunked(_bytes(100), 2)),
        '/home/gian/report.docx',
      );

      expect(session.closed, isTrue);
    });
  });
}

/// A [_FakeUploadSource] that records whether it was ever read from, for
/// asserting the destination guard short-circuits before touching the
/// source at all.
class _FakeUploadSourceSpy extends _FakeUploadSource {
  _FakeUploadSourceSpy(super.chunks, {required this.onRead});

  final void Function() onRead;

  @override
  Stream<List<int>> openRead() {
    onRead();
    return super.openRead();
  }
}

/// Small helpers that reach into the handle a [FakeSftpSession] will open
/// for a given upload, so a test can script a mid-stream remote failure
/// or stall without the service itself exposing a seam for it — the
/// handle is created lazily by [SftpSession.openWrite], not by the test,
/// so these attach to it indirectly through a wrapped [UploadSource] that
/// configures the handle on its first read.
extension on _FakeUploadSource {
  void attachWriteFailureVia(
    FakeSftpSession session, {
    required int failFromChunk,
  }) {
    session.pendingWriteHandleConfig = (handle) {
      handle.failFromChunk = failFromChunk;
    };
  }

  void attachStallVia(FakeSftpSession session, {required int stallFromChunk}) {
    session.pendingWriteHandleConfig = (handle) {
      handle.stallFromChunk = stallFromChunk;
    };
  }
}
