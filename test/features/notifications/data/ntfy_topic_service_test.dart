import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/notifications/data/ntfy_topic_service.dart';

import '../../../helpers/fake_secure_storage.dart';

/// Records the iOS options every call carried.
class _RecordingStorage extends FakeSecureStorage {
  final List<AppleOptions?> writeOptions = [];
  final List<AppleOptions?> readOptions = [];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    writeOptions.add(iOptions);
    return super.write(key: key, value: value, iOptions: iOptions);
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    readOptions.add(iOptions);
    return super.read(key: key, iOptions: iOptions);
  }
}

void main() {
  test('generates a topic once and reuses it', () async {
    final storage = FakeSecureStorage();
    final first = await NtfyTopicService(storage: storage).topic();
    // A fresh service over the same storage models an app restart.
    final second = await NtfyTopicService(storage: storage).topic();

    expect(second, first);
    expect(storage.values.values, [first]);
  });

  test('concurrent first calls agree on one topic', () async {
    final service = NtfyTopicService(storage: FakeSecureStorage());
    final topics = await Future.wait([service.topic(), service.topic()]);
    expect(topics[0], topics[1]);
  });

  test('two devices get different topics', () async {
    final a = await NtfyTopicService(storage: FakeSecureStorage()).topic();
    final b = await NtfyTopicService(storage: FakeSecureStorage()).topic();
    expect(a, isNot(b));
  });

  test('has the helm- prefix, a safe alphabet and a bounded length', () async {
    final topic = await NtfyTopicService(storage: FakeSecureStorage()).topic();

    expect(topic, startsWith('helm-'));
    expect(topic.length, inInclusiveRange(29, 64));
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(topic), isTrue);
    expect(NtfyTopicService.isValidTopic(topic), isTrue);
  });

  test('draws from the injected Random, with 24+ random chars', () {
    final topic = NtfyTopicService.generate(Random(1));
    expect(topic.length - 'helm-'.length, greaterThanOrEqualTo(24));
  });

  test('is stored with first_unlock_this_device on every access', () async {
    final storage = _RecordingStorage();
    final service = NtfyTopicService(storage: storage);
    await service.topic();
    await NtfyTopicService(storage: storage).topic();

    expect(storage.writeOptions, isNotEmpty);
    for (final options in [...storage.writeOptions, ...storage.readOptions]) {
      expect(options, isA<IOSOptions>());
      expect(
        options!.toMap()['accessibility'],
        KeychainAccessibility.first_unlock_this_device.name,
      );
    }
  });

  test('replaces a stored value that is not a valid topic', () async {
    final storage = FakeSecureStorage({kNtfyTopicStorageKey: 'bad topic/..'});
    final topic = await NtfyTopicService(storage: storage).topic();

    expect(NtfyTopicService.isValidTopic(topic), isTrue);
    expect(storage.values[kNtfyTopicStorageKey], topic);
  });

  test('isValidTopic rejects anything outside the ntfy-safe alphabet', () {
    for (final bad in [
      '',
      'short',
      'helm-has space-aaaaaaaaaaaaaaaa',
      'helm-new\nline-aaaaaaaaaaaaaaaa',
      'helm-slash/aaaaaaaaaaaaaaaaaaa',
      "helm-quote'aaaaaaaaaaaaaaaaaaa",
      'helm-${'a' * 80}',
    ]) {
      expect(NtfyTopicService.isValidTopic(bad), isFalse, reason: bad);
    }
  });
}
