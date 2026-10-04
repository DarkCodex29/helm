import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/files/data/document_tree_gateway.dart';
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart';

// Scripted plugin boundary: these tests run the gateway's decisions, not
// Android's method channel, permissions, or picker UI.
class FakeMediaUtil extends SafUtil {
  List<SafDocumentFile>? media;
  Object? mediaError;
  int mediaCalls = 0;
  bool? mediaMultiple;
  String? mediaMode;
  List<SafDocumentFile>? files;
  Object? filesError;
  int filesCalls = 0;
  bool? filesMultiple;
  List<String>? filesMimeTypes;

  @override
  Future<List<SafDocumentFile>?> pickFiles({
    String? initialUri,
    List<String>? mimeTypes,
    multiple = true,
  }) async {
    filesCalls++;
    filesMultiple = multiple;
    filesMimeTypes = mimeTypes;
    final error = filesError;
    if (error != null) throw error;
    return files;
  }

  @override
  Future<List<SafDocumentFile>?> pickMedia({
    bool multiple = true,
    String mode = 'all',
  }) async {
    mediaCalls++;
    mediaMultiple = multiple;
    mediaMode = mode;
    final error = mediaError;
    if (error != null) throw error;
    return media;
  }
}

SafDocumentFile mediaFile(String name, int length) => SafDocumentFile(
  uri: 'content://media/$name',
  name: name,
  isDir: false,
  length: length,
  lastModified: 0,
);

void main() {
  test(
    'media selects multiple photos and videos and preserves metadata',
    () async {
      final util = FakeMediaUtil()
        ..media = [mediaFile('camera.jpg', 12), mediaFile('clip.mp4', 34)];
      final DocumentTreeGateway gateway = SafDocumentTreeGateway(util: util);

      final picked = await gateway.pickMedia();

      expect(util.mediaCalls, 1);
      expect(util.mediaMultiple, isTrue);
      expect(util.mediaMode, 'all');
      expect(util.filesCalls, 0);
      expect(picked!.map((file) => file.uri), [
        'content://media/camera.jpg',
        'content://media/clip.mp4',
      ]);
      expect(picked.map((file) => file.name), ['camera.jpg', 'clip.mp4']);
      expect(picked.map((file) => file.length), [12, 34]);
    },
  );

  test('declining the native media picker returns null', () async {
    final util = FakeMediaUtil();
    final gateway = SafDocumentTreeGateway(util: util);

    expect(await gateway.pickMedia(), isNull);
    expect(util.filesCalls, 0);
  });

  test('NOT_SUPPORTED falls back to multiple image/video documents', () async {
    final util = FakeMediaUtil()
      ..mediaError = PlatformException(code: 'NOT_SUPPORTED')
      ..files = [mediaFile('old.jpg', 56), mediaFile('old.mp4', 78)];
    final gateway = SafDocumentTreeGateway(util: util);

    final picked = await gateway.pickMedia();

    expect(util.mediaCalls, 1);
    expect(util.filesCalls, 1);
    expect(util.filesMultiple, isTrue);
    expect(util.filesMimeTypes, ['image/*', 'video/*']);
    expect(picked!.map((file) => file.uri), [
      'content://media/old.jpg',
      'content://media/old.mp4',
    ]);
    expect(picked.map((file) => file.name), ['old.jpg', 'old.mp4']);
    expect(picked.map((file) => file.length), [56, 78]);
  });

  test('declining the fallback returns null', () async {
    final util = FakeMediaUtil()
      ..mediaError = PlatformException(code: 'NOT_SUPPORTED');
    final gateway = SafDocumentTreeGateway(util: util);

    expect(await gateway.pickMedia(), isNull);
    expect(util.filesCalls, 1);
  });

  for (final code in [
    'NO_ACTIVITY',
    'ALREADY_PICKING',
    'INVALID_ARGUMENT',
    'PluginError',
  ]) {
    test('$code propagates without opening a fallback picker', () async {
      final error = PlatformException(code: code);
      final util = FakeMediaUtil()..mediaError = error;
      final gateway = SafDocumentTreeGateway(util: util);

      await expectLater(gateway.pickMedia(), throwsA(same(error)));
      expect(util.filesCalls, 0);
    });
  }

  test('non-platform errors propagate without fallback', () async {
    final error = StateError('broken plugin');
    final util = FakeMediaUtil()..mediaError = error;
    final gateway = SafDocumentTreeGateway(util: util);

    await expectLater(gateway.pickMedia(), throwsA(same(error)));
    expect(util.filesCalls, 0);
  });

  test('fallback errors propagate without retry', () async {
    final error = PlatformException(code: 'NOT_SUPPORTED');
    final util = FakeMediaUtil()
      ..mediaError = PlatformException(code: 'NOT_SUPPORTED')
      ..filesError = error;
    final gateway = SafDocumentTreeGateway(util: util);

    await expectLater(gateway.pickMedia(), throwsA(same(error)));
    expect(util.mediaCalls, 1);
    expect(util.filesCalls, 1);
  });
}
