import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// In-memory [FlutterSecureStorage] stand-in for unit tests.
///
/// Subclassing the real type keeps the production constructor injection
/// honest: services under test still depend on [FlutterSecureStorage], and no
/// platform channel is ever touched.
class FakeSecureStorage extends FlutterSecureStorage {
  FakeSecureStorage([Map<String, String>? initialValues])
    : values = {...?initialValues};

  /// Backing store, exposed so tests can assert on what was persisted.
  final Map<String, String> values;

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
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
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
  }) async => values[key];

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values.containsKey(key);

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }
}
