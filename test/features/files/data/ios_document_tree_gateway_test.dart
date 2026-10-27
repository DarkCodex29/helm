// Tests for the iOS [DocumentTreeGateway], over a scripted method channel.
//
// What this file asserts, and why: [IosDocumentTreeGateway] has to behave
// exactly like [SafDocumentTreeGateway] for the two operations
// [UploadSourcePicker] actually calls on iOS (`pickFile`, `pickMedia`,
// `readFile`), and it has to REFUSE — loudly, with [UnsupportedError], not
// a fake success — every folder operation that `supportsFolderChoice`
// already keeps iOS away from. A silent fake there would let a future
// caller believe a file was published when it never was.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/files/data/document_tree_gateway.dart';
import 'package:helm/features/files/data/ios_document_tree_gateway.dart';
import 'package:helm/features/files/data/saf_upload_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('helm/document_picker');

  void setHandler(Future<Object?> Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  tearDown(() => setHandler(null));

  group('pickFile', () {
    test('maps a scripted reply to a PickedDocument', () async {
      setHandler((call) async {
        expect(call.method, 'pickFile');
        return {'path': '/tmp/pick/report.docx', 'name': 'report.docx', 'length': 2048};
      });
      final gateway = IosDocumentTreeGateway(channel: channel);

      final picked = await gateway.pickFile();

      expect(picked, isNotNull);
      expect(picked!.uri, '/tmp/pick/report.docx');
      expect(picked.name, 'report.docx');
      expect(picked.length, 2048);
    });

    test('returns null when the user cancels', () async {
      setHandler((call) async => null);
      final gateway = IosDocumentTreeGateway(channel: channel);

      expect(await gateway.pickFile(), isNull);
    });

    test('returns null, and does not throw, when no plugin answers', () async {
      // No handler installed at all: the binding replies with
      // MissingPluginException, exactly what a build without the native
      // side registered would do.
      final gateway = IosDocumentTreeGateway(channel: channel);

      expect(await gateway.pickFile(), isNull);
    });

    test('returns null on a PlatformException', () async {
      setHandler((call) async => throw PlatformException(code: 'ALREADY_PICKING'));
      final gateway = IosDocumentTreeGateway(channel: channel);

      expect(await gateway.pickFile(), isNull);
    });
  });

  group('pickMedia', () {
    test('maps a scripted list reply', () async {
      setHandler((call) async {
        expect(call.method, 'pickMedia');
        return [
          {'path': '/tmp/pick/camera.jpg', 'name': 'camera.jpg', 'length': 12},
          {'path': '/tmp/pick/clip.mp4', 'name': 'clip.mp4', 'length': 34},
        ];
      });
      final gateway = IosDocumentTreeGateway(channel: channel);

      final picked = await gateway.pickMedia();

      expect(picked, isNotNull);
      expect(picked!.map((d) => d.uri), [
        '/tmp/pick/camera.jpg',
        '/tmp/pick/clip.mp4',
      ]);
      expect(picked.map((d) => d.name), ['camera.jpg', 'clip.mp4']);
      expect(picked.map((d) => d.length), [12, 34]);
    });

    test('returns null when the user cancels', () async {
      setHandler((call) async => null);
      final gateway = IosDocumentTreeGateway(channel: channel);

      expect(await gateway.pickMedia(), isNull);
    });

    test('returns null, and does not throw, when no plugin answers', () async {
      final gateway = IosDocumentTreeGateway(channel: channel);

      expect(await gateway.pickMedia(), isNull);
    });
  });

  group('readFile', () {
    test('streams the bytes of a real temporary file', () async {
      final dir = await Directory.systemTemp.createTemp('ios_gateway_test');
      final file = File('${dir.path}/content.bin');
      await file.writeAsBytes(List<int>.generate(10, (i) => i));
      final gateway = IosDocumentTreeGateway(channel: channel);

      final bytes = await gateway
          .readFile(file.path)
          .expand((chunk) => chunk)
          .toList();

      expect(bytes, List<int>.generate(10, (i) => i));
      await dir.delete(recursive: true);
    });
  });

  group('unreachable folder operations', () {
    test('pickFolder throws UnsupportedError', () {
      final gateway = IosDocumentTreeGateway(channel: channel);
      expect(() => gateway.pickFolder(), throwsUnsupportedError);
    });

    test('hasWriteGrant throws UnsupportedError', () {
      final gateway = IosDocumentTreeGateway(channel: channel);
      expect(() => gateway.hasWriteGrant('x'), throwsUnsupportedError);
    });

    test('folderExists throws UnsupportedError', () {
      final gateway = IosDocumentTreeGateway(channel: channel);
      expect(() => gateway.folderExists('x'), throwsUnsupportedError);
    });

    test('copyInto throws UnsupportedError', () {
      final gateway = IosDocumentTreeGateway(channel: channel);
      expect(
        () => gateway.copyInto(
          source: File('x'),
          treeUri: 'x',
          fileName: 'x',
        ),
        throwsUnsupportedError,
      );
    });

    test('releaseFolder throws UnsupportedError', () {
      final gateway = IosDocumentTreeGateway(channel: channel);
      expect(() => gateway.releaseFolder('x'), throwsUnsupportedError);
    });
  });

  test(
    'UploadSourcePicker over the iOS gateway adapts a scripted pick',
    () async {
      setHandler((call) async {
        return {'path': '/tmp/pick/report.docx', 'name': 'report.docx', 'length': 2048};
      });
      final DocumentTreeGateway gateway = IosDocumentTreeGateway(
        channel: channel,
      );
      final picker = UploadSourcePicker(
        gateway: gateway,
        supportsPicking: true,
      );

      final result = await picker.pick();

      expect(result, isNotNull);
      expect(result!.name, 'report.docx');
      expect(await result.length(), 2048);
    },
  );

  test(
    'UploadSourcePicker(supportsPicking: false).pick() still returns null '
    '(unchanged Android/iOS-off behaviour)',
    () async {
      final gateway = IosDocumentTreeGateway(channel: channel);
      final picker = UploadSourcePicker(
        gateway: gateway,
        supportsPicking: false,
      );

      expect(await picker.pick(), isNull);
    },
  );
}
