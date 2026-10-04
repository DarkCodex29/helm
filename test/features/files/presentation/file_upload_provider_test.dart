import 'dart:async';

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
  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  FileUploadNotifier notifier() => container.read(fileUploadProvider.notifier);
  FileUploadState state() => container.read(fileUploadProvider);
  SafUploadSource sourceFor(String name) => SafUploadSource(
    FakeDocumentTreeGateway(
      fileContents: {
        'content://x/$name': [1, 2, 3],
      },
    ),
    PickedDocument(uri: 'content://x/$name', name: name, length: 3),
  );
  SftpUploadService serviceFor(FakeSftpSession session) =>
      SftpUploadService.withOpener(() async => session);

  // Gate the existing fake session's opener, not a new upload engine: the
  // real service still exercises cancellation, outcomes and session cleanup.
  test(
    'append while draining preserves identity and FIFO completion',
    () async {
      final gate = Completer<FakeSftpSession>();
      final first = FakeSftpSession();
      final second = FakeSftpSession();
      final completionOrder = <int>[];
      container.listen(fileUploadProvider, (previous, next) {
        for (final item in next.items) {
          if (item.isTerminal &&
              !(previous?.items.any(
                    (old) => old.id == item.id && old.isTerminal,
                  ) ??
                  false)) {
            completionOrder.add(item.id);
          }
        }
      });
      final a = notifier().enqueue(
        SftpUploadService.withOpener(() => gate.future),
        '/a',
        sourceFor('same'),
      );
      final b = notifier().enqueue(serviceFor(second), '/b', sourceFor('same'));
      expect(a, isNot(b));
      expect(state().items.map((item) => item.id), [a, b]);
      expect(state().items.last.status, FileUploadStatus.pending);
      expect(second.closed, isFalse);
      gate.complete(first);
      await pumpEventQueue();
      expect(completionOrder, [a, b]);
      expect(first.closed, isTrue);
      expect(second.closed, isTrue);
      expect(state().items.map((item) => item.destinationPath), ['/a', '/b']);
      expect(state().items.map((item) => item.name), ['same', 'same']);
    },
  );

  test('exactly one session at a time across twenty items', () async {
    final gate = Completer<FakeSftpSession>();
    final sessions = List.generate(20, (_) => FakeSftpSession());
    var opened = 0;
    for (var i = 0; i < 20; i++) {
      notifier().enqueue(
        SftpUploadService.withOpener(() async {
          if (i > 0) expect(sessions[i - 1].closed, isTrue);
          opened++;
          return i == 0 ? gate.future : sessions[i];
        }),
        '/$i',
        sourceFor('$i'),
      );
    }
    expect(opened, 1);
    gate.complete(sessions.first);
    await pumpEventQueue();
    expect(opened, 20);
    expect(state().doneCount, 20);
  });

  test('cancel in-flight item continues with next after cleanup', () async {
    final gate = Completer<FakeSftpSession>();
    final first = FakeSftpSession();
    final a = notifier().enqueue(
      SftpUploadService.withOpener(() => gate.future),
      '/a',
      sourceFor('a'),
    );
    notifier().enqueue(serviceFor(FakeSftpSession()), '/b', sourceFor('b'));
    notifier().cancelItem(a);
    expect(state().isRunning, isTrue);
    gate.complete(first);
    await pumpEventQueue();
    expect(state().items.first.status, FileUploadStatus.cancelled);
    expect(state().items.last.status, FileUploadStatus.completed);
    expect(first.openedWritePaths, isEmpty);
  });

  test('cancel pending item never opens its session', () async {
    final gate = Completer<FakeSftpSession>();
    notifier().enqueue(
      SftpUploadService.withOpener(() => gate.future),
      '/a',
      sourceFor('a'),
    );
    var opened = false;
    final b = notifier().enqueue(
      SftpUploadService.withOpener(() async {
        opened = true;
        return FakeSftpSession();
      }),
      '/b',
      sourceFor('b'),
    );
    notifier().cancelItem(b);
    notifier().cancelItem(-1); // Unknown and already terminal IDs are harmless.
    notifier().cancelItem(b);
    expect(state().items.last.status, FileUploadStatus.cancelled);
    gate.complete(FakeSftpSession());
    await pumpEventQueue();
    expect(opened, isFalse);
    expect(state().doneCount, 2);
  });

  test('cancel whole queue stops active and skips all pending items', () async {
    final gate = Completer<FakeSftpSession>();
    notifier().enqueue(
      SftpUploadService.withOpener(() => gate.future),
      '/a',
      sourceFor('a'),
    );
    final pending = FakeSftpSession();
    notifier().enqueue(serviceFor(pending), '/b', sourceFor('b'));
    notifier().cancelAll();
    expect(state().items.last.status, FileUploadStatus.cancelled);
    gate.complete(FakeSftpSession());
    await pumpEventQueue();
    expect(
      state().items.every((item) => item.status == FileUploadStatus.cancelled),
      isTrue,
    );
    expect(pending.statedPaths, isEmpty);
    expect(state().isRunning, isFalse);
    // Cancel-all is a snapshot, not a permanent ban on future uploads.
    notifier().enqueue(serviceFor(FakeSftpSession()), '/c', sourceFor('c'));
    await pumpEventQueue();
    expect(state().items.last.status, FileUploadStatus.completed);
  });

  test(
    'failure and destination-exists retain outcomes without aborting rest',
    () async {
      notifier().enqueue(
        serviceFor(
          FakeSftpSession(
            openWriteError: SftpStatusError(
              SftpStatusCode.permissionDenied,
              'Denied',
            ),
          ),
        ),
        '/a',
        sourceFor('a'),
      );
      notifier().enqueue(
        serviceFor(
          FakeSftpSession(
            stats: {
              // Destination-exists now means all bounded candidates are taken.
              for (var i = 0; i < 100; i++)
                '/b${i == 0 ? '' : '($i)'}': SftpFileAttrs(),
            },
          ),
        ),
        '/b',
        sourceFor('b'),
      );
      notifier().enqueue(serviceFor(FakeSftpSession()), '/c', sourceFor('c'));
      await pumpEventQueue();
      expect(state().items.map((item) => item.status), [
        FileUploadStatus.failed,
        FileUploadStatus.destinationExists,
        FileUploadStatus.completed,
      ]);
      expect(state().items.first.failure, UploadFailure.permissionDenied);
      expect(state().items.first.outcome, isA<UploadFailed>());
      expect(state().items.last.outcome, isA<UploadCompleted>());
    },
  );

  test('aggregate counts are correct mid-drain and at rest', () async {
    final gate = Completer<FakeSftpSession>();
    notifier().enqueue(serviceFor(FakeSftpSession()), '/a', sourceFor('a'));
    notifier().enqueue(
      SftpUploadService.withOpener(() => gate.future),
      '/b',
      sourceFor('b'),
    );
    notifier().enqueue(serviceFor(FakeSftpSession()), '/c', sourceFor('c'));
    await pumpEventQueue();
    expect(state().doneCount, 1);
    expect(state().remainingCount, 2);
    expect(state().isRunning, isTrue);
    gate.complete(FakeSftpSession());
    await pumpEventQueue();
    expect(state().doneCount, 3);
    expect(state().remainingCount, 0);
    expect(state().isRunning, isFalse);
    notifier().dismiss();
    expect(state().items, isEmpty);
  });

  test(
    'late progress cannot mutate completed history or the next item',
    () async {
      final service = _ProgressCapturingService(FakeSftpSession());
      notifier().enqueue(service, '/a', sourceFor('a'));
      final gate = Completer<FakeSftpSession>();
      notifier().enqueue(
        SftpUploadService.withOpener(() => gate.future),
        '/b',
        sourceFor('b'),
      );
      await pumpEventQueue();
      final before = state();
      service.progress!(17);
      expect(state(), same(before));
      expect(state().items.first.percent, 100);
      expect(state().items.last.percent, 0);
      gate.complete(FakeSftpSession());
      await pumpEventQueue();
    },
  );

  test(
    'cancel during byte progress cleans partial and continues FIFO',
    () async {
      final first = FakeSftpSession();
      final service = _ProgressCapturingService(first);
      final uploadNotifier = notifier();
      container.listen(fileUploadProvider, (_, next) {
        final item = next.items.first;
        if (item.status == FileUploadStatus.uploading && item.percent > 0) {
          uploadNotifier.cancelItem(item.id);
        }
      });
      uploadNotifier.enqueue(service, '/a', sourceFor('a'));
      uploadNotifier.enqueue(
        serviceFor(FakeSftpSession()),
        '/b',
        sourceFor('b'),
      );
      await pumpEventQueue();
      expect(state().items.first.status, FileUploadStatus.cancelled);
      expect(first.removedPaths, ['/a.helmpart']);
      expect(first.closed, isTrue);
      expect(state().items.last.status, FileUploadStatus.completed);
      service.progress!(9);
      expect(state().items.last.percent, 100);
    },
  );

  test(
    'provider rebuild waits for old transfer cleanup before new drain',
    () async {
      final first = FakeSftpSession();
      final gate = Completer<FakeSftpSession>();
      final service = _ProgressCapturingService(first, gate: gate);
      notifier().enqueue(service, '/a', sourceFor('a'));
      container.invalidate(fileUploadProvider);
      final second = FakeSftpSession();
      notifier().enqueue(serviceFor(second), '/b', sourceFor('b'));
      await pumpEventQueue();
      expect(second.statedPaths, isEmpty);
      service.progress!(75);
      expect(state().items.single.percent, 0);
      gate.complete(first);
      await pumpEventQueue();
      expect(first.closed, isTrue);
      expect(state().items.single.destinationPath, '/b');
      expect(state().items.single.status, FileUploadStatus.completed);
    },
  );

  test('disposal cancels active work and ignores late callbacks', () async {
    final first = FakeSftpSession();
    final gate = Completer<FakeSftpSession>();
    final service = _ProgressCapturingService(first, gate: gate);
    notifier().enqueue(service, '/a', sourceFor('a'));
    final pending = FakeSftpSession();
    notifier().enqueue(serviceFor(pending), '/b', sourceFor('b'));
    container.dispose();
    service.progress!(70);
    gate.complete(first);
    await pumpEventQueue();
    expect(first.closed, isTrue);
    expect(first.openedWritePaths, isEmpty);
    expect(pending.statedPaths, isEmpty);
    // Supply a fresh container for the shared tearDown.
    container = ProviderContainer();
  });

  test(
    'progress belongs only to its item and dismiss preserves active work',
    () async {
      final gate = Completer<FakeSftpSession>();
      final snapshots = <FileUploadState>[];
      container.listen(fileUploadProvider, (_, next) => snapshots.add(next));
      notifier().enqueue(serviceFor(FakeSftpSession()), '/a', sourceFor('a'));
      notifier().enqueue(
        SftpUploadService.withOpener(() => gate.future),
        '/b',
        sourceFor('b'),
      );
      await pumpEventQueue();
      expect(
        snapshots.any((snapshot) => snapshot.items.first.percent == 100),
        isTrue,
      );
      expect(state().items.first.percent, 100);
      expect(state().items.last.percent, 0);
      notifier().dismiss();
      expect(state().items.length, 1);
      expect(state().items.single.status, FileUploadStatus.uploading);
      gate.complete(FakeSftpSession());
      await pumpEventQueue();
      expect(state().items.single.percent, 100);
    },
  );
}

// Still uses the real upload primitive and existing fake session. Retaining
// its callback lets us replay a late echo that a synchronous fake cannot emit.
class _ProgressCapturingService extends SftpUploadService {
  _ProgressCapturingService(
    FakeSftpSession session, {
    Completer<FakeSftpSession>? gate,
  }) : super.withOpener(() async => gate == null ? session : await gate.future);

  void Function(int)? progress;

  @override
  Future<UploadOutcome> upload(
    UploadSource source,
    String destinationPath, {
    void Function(int percent)? onProgress,
    UploadCancellation? cancellation,
  }) {
    progress = onProgress;
    return super.upload(
      source,
      destinationPath,
      onProgress: onProgress,
      cancellation: cancellation,
    );
  }
}
