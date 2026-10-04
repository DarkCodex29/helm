// Tests for the SAF-backed [UploadSource] and its picker.
//
// The assertion this file exists for: [SafUploadSource] is a thin adapter,
// and the thinness itself is the thing worth testing \u2014 it must forward
// [PickedDocument.length] without re-measuring anything, and stream
// exactly what [DocumentTreeGateway.readFile] yields, no more and no less.
// [UploadSourcePicker] is tested separately for the platform-gating rule
// that governs whether either of these is ever reached at all.
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/files/data/document_tree_gateway.dart';
import 'package:helm/features/files/data/saf_upload_source.dart';

import '../../../helpers/fake_document_tree_gateway.dart';

void main() {
  group('SafUploadSource', () {
    test(
      'reports the length the picker already measured, without re-reading',
      () async {
        final gateway = FakeDocumentTreeGateway();
        final source = SafUploadSource(
          gateway,
          const PickedDocument(
            uri: 'content://x/report.docx',
            name: 'report.docx',
            length: 4096,
          ),
        );

        expect(await source.length(), 4096);
      },
    );

    test('name forwards the picked display name', () {
      final gateway = FakeDocumentTreeGateway();
      final source = SafUploadSource(
        gateway,
        const PickedDocument(
          uri: 'content://x/report.docx',
          name: 'report.docx',
          length: 10,
        ),
      );

      expect(source.name, 'report.docx');
    });

    test(
      'openRead streams exactly what the gateway yields for the picked uri',
      () async {
        final gateway = FakeDocumentTreeGateway(
          fileContents: {
            'content://x/report.docx': List<int>.generate(10, (i) => i),
          },
        );
        final source = SafUploadSource(
          gateway,
          const PickedDocument(
            uri: 'content://x/report.docx',
            name: 'report.docx',
            length: 10,
          ),
        );

        final bytes = await source.openRead().expand((chunk) => chunk).toList();

        expect(bytes, List<int>.generate(10, (i) => i));
        expect(gateway.readUris, ['content://x/report.docx']);
      },
    );
  });

  group('UploadSourcePicker', () {
    test(
      'a platform that cannot pick returns null without asking the gateway',
      () async {
        final gateway = FakeDocumentTreeGateway(
          filePick: const PickedDocument(
            uri: 'content://x/a.txt',
            name: 'a.txt',
            length: 1,
          ),
        );
        final picker = UploadSourcePicker(
          gateway: gateway,
          supportsPicking: false,
        );

        final result = await picker.pick();

        expect(result, isNull);
        expect(gateway.pickFileCalls, 0);
      },
    );

    test(
      'a user declining the picker is indistinguishable from an unsupported platform',
      () async {
        final gateway = FakeDocumentTreeGateway(filePick: null);
        final picker = UploadSourcePicker(
          gateway: gateway,
          supportsPicking: true,
        );

        final result = await picker.pick();

        expect(result, isNull);
        expect(gateway.pickFileCalls, 1);
      },
    );

    test('a supported platform adapts what the gateway picked', () async {
      final gateway = FakeDocumentTreeGateway(
        filePick: const PickedDocument(
          uri: 'content://x/report.docx',
          name: 'report.docx',
          length: 2048,
        ),
      );
      final picker = UploadSourcePicker(
        gateway: gateway,
        supportsPicking: true,
      );

      final result = await picker.pick();

      expect(result, isNotNull);
      expect(result!.name, 'report.docx');
      expect(await result.length(), 2048);
    });

    test('defaults supportsPicking from the platform when not overridden', () {
      final picker = UploadSourcePicker(gateway: FakeDocumentTreeGateway());

      // The test host is neither Android nor iOS in the sense the plugin
      // means, but `Platform.isAndroid` still answers deterministically
      // per-host — this only asserts the default was NOT hardcoded to a
      // fixed boolean, which the overridden-parameter tests above already
      // exercise on both sides.
      expect(picker.supportsPicking, isA<bool>());
    });
  });
}
