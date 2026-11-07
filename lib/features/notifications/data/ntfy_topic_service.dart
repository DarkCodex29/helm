import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Keychain/Keystore item holding this device's ntfy topic.
const String kNtfyTopicStorageKey = 'helm_ntfy_device_topic';

/// New secure-storage items are `first_unlock_this_device`: readable by a
/// background launch after the first unlock, and never restored onto another
/// device from a backup, so one phone's topic can't end up on a second one.
const IOSOptions kNtfyTopicIosOptions = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
);

const String _alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';
const String _prefix = 'helm-';
const int _randomChars = 24;

final RegExp _topicShape = RegExp(r'^[A-Za-z0-9_-]{8,64}$');

/// This device's own ntfy topic, for phones that cannot receive FCM.
///
/// An ntfy topic is a bearer secret: whoever knows it reads the alerts. So it
/// is random (`Random.secure()`), lives in the secure store, and is never
/// logged. It is generated once and reused on every attach.
class NtfyTopicService {
  NtfyTopicService({FlutterSecureStorage? storage, Random? random})
    : _storage = storage ?? const FlutterSecureStorage(),
      _random = random;

  final FlutterSecureStorage _storage;
  final Random? _random;
  Future<String>? _pending;

  /// The stored topic, creating it on first use.
  Future<String> topic() => _pending ??= _load().whenComplete(() {
    _pending = null;
  });

  Future<String> _load() async {
    final stored = await _storage.read(
      key: kNtfyTopicStorageKey,
      iOptions: kNtfyTopicIosOptions,
    );
    if (stored != null && isValidTopic(stored)) return stored;

    final created = generate(_random ?? Random.secure());
    await _storage.write(
      key: kNtfyTopicStorageKey,
      value: created,
      iOptions: kNtfyTopicIosOptions,
    );
    return created;
  }

  /// `helm-` plus 24 random chars: 144 bits, 29 chars in total.
  static String generate(Random random) {
    final chars = List.generate(
      _randomChars,
      (_) => _alphabet[random.nextInt(_alphabet.length)],
    );
    return '$_prefix${chars.join()}';
  }

  /// Whether [value] is a topic this app would ever have generated, or at
  /// least one that is safe in a URL path and in a shell heredoc.
  static bool isValidTopic(String value) => _topicShape.hasMatch(value);
}
