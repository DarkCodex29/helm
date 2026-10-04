// Tests for the upload orchestration behind the file browser.
//
// The assertion this file exists for: every [UploadOutcome] variant must
// render as its OWN [FileUploadStatus], none of them folded into a generic
// failure \u2014 see [UploadOutcome]'s own doc comment for why
// [UploadDestinationExists] in particular is not a failure the user can
// only read about.
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/files/data/document_tree_gateway.dart';
import 'package:helm/features/files/data/saf_upload_source.dart';
import 'package:helm/features/files/data/sftp_upload_service.dart';
import 'package:helm/features/files/domain/upload_outcome.dart';
import 'package:helm/features/files/presentation/providers/file_upload_provider.dart';

import '../../../helpers/fake_document_tree_gateway.dart';
import '../../../helpers/fake_sftp_session.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
  });

  tearDown(() => container.dispose());

  SftpUploadService serviceFor(FakeSftpSession session) =>
      SftpUploadService.withOpener(
        () async => session,
        idleTimeout: const Duration(milliseconds: 200),
      );

  SafUploadSource sourceFor(String name, List<int> bytes) {
    final gateway = FakeDocumentTreeGateway(
      fileContents: {'content://x/$name': bytes},
    );
    return SafUploadSource(
      gateway,
      PickedDocument(
        uri: 'content://x/$name',
        name: name,
        length: bytes.length,
      ),
    );
  }

  FileUploadNotifier notifier() => container.read(fileUploadProvider.notifier);

  group('a successful upload', () {
    test('ends in completed, and reports true to its caller', () async {
      final completed = await notifier().start(
        serviceFor(FakeSftpSession()),
        '/home/gian/report.docx',
        sourceFor('report.docx', List<int>.filled(1024, 7)),
      );

      expect(completed, isTrue);
      expect(
        container.read(fileUploadProvider).status,
        FileUploadStatus.completed,
      );
    });

    test('reports progress while it runs, and ends at 100', () async {
      final seen = <int>[];
      container.listen(
        fileUploadProvider,
        (_, next) => seen.add(next.percent),
        fireImmediately: false,
      );

      await notifier().start(
        serviceFor(FakeSftpSession()),
        '/home/gian/big.bin',
        sourceFor('big.bin', List<int>.filled(500_000, 1)),
      );

      expect(seen, contains(100));
      expect(container.read(fileUploadProvider).percent, 100);
    });

    test('names the file it is working on', () async {
      await notifier().start(
        serviceFor(FakeSftpSession()),
        '/home/gian/report.docx',
        sourceFor('report.docx', const [1, 2, 3]),
      );

      expect(container.read(fileUploadProvider).name, 'report.docx');
    });
  });

  group('a destination that already exists', () {
    test(
      'is its OWN state, distinct from a generic failure, and reports false',
      () async {
        final session = FakeSftpSession(
          stats: {'/home/gian/report.docx': SftpFileAttrs()},
        );

        final completed = await notifier().start(
          serviceFor(session),
          '/home/gian/report.docx',
          sourceFor('report.docx', const [1, 2, 3]),
        );

        expect(completed, isFalse);
        expect(
          container.read(fileUploadProvider).status,
          FileUploadStatus.destinationExists,
        );
        expect(
          container.read(fileUploadProvider).status,
          isNot(FileUploadStatus.failed),
        );
      },
    );
  });

  group('cancellation', () {
    test('ends cancelled, reports false, and is never completed', () async {
      final session = FakeSftpSession();
      final gateway = FakeDocumentTreeGateway(
        fileContents: {'content://x/big.bin': List<int>.filled(500_000, 1)},
      );
      final source = SafUploadSource(
        gateway,
        const PickedDocument(
          uri: 'content://x/big.bin',
          name: 'big.bin',
          length: 500000,
        ),
      );

      final uploadNotifier = notifier();
      container.listen(fileUploadProvider, (_, next) {
        if (next.status == FileUploadStatus.uploading) uploadNotifier.cancel();
      });

      final completed = await uploadNotifier.start(
        serviceFor(session),
        '/home/gian/big.bin',
        source,
      );

      expect(completed, isFalse);
      expect(
        container.read(fileUploadProvider).status,
        FileUploadStatus.cancelled,
      );
      expect(
        container.read(fileUploadProvider).status,
        isNot(FileUploadStatus.completed),
      );
    });
  });

  group('failures', () {
    test('a refused destination surfaces the reason it was refused', () async {
      final session = FakeSftpSession(
        openWriteError: SftpStatusError(
          SftpStatusCode.permissionDenied,
          'Permission denied',
        ),
      );

      final completed = await notifier().start(
        serviceFor(session),
        '/root/secret.txt',
        sourceFor('secret.txt', const [1, 2, 3]),
      );

      expect(completed, isFalse);
      expect(
        container.read(fileUploadProvider).status,
        FileUploadStatus.failed,
      );
      expect(
        container.read(fileUploadProvider).failure,
        UploadFailure.permissionDenied,
      );
    });

    test('dismiss returns the notifier to idle', () async {
      final session = FakeSftpSession(
        openWriteError: SftpStatusError(
          SftpStatusCode.permissionDenied,
          'Permission denied',
        ),
      );
      final uploadNotifier = notifier();
      await uploadNotifier.start(
        serviceFor(session),
        '/root/secret.txt',
        sourceFor('secret.txt', const [1, 2, 3]),
      );

      uploadNotifier.dismiss();

      expect(container.read(fileUploadProvider).status, FileUploadStatus.idle);
      expect(container.read(fileUploadProvider).name, isNull);
      expect(container.read(fileUploadProvider).failure, isNull);
    });
  });
}
