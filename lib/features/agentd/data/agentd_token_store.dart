import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:helm/features/files/data/sftp_session.dart';

/// Result of copying the daemon token from the host. Carries NO token text
/// and no free-form error text, so no outcome can leak the secret through
/// `toString()` or a log line.
sealed class TokenProvisionOutcome {
  const TokenProvisionOutcome();
}

/// Read, validated and stored.
class TokenStored extends TokenProvisionOutcome {
  const TokenStored();
  @override
  String toString() => 'TokenStored()';
}

/// `~/.helm-agentd/token` does not exist (daemon never started there).
class TokenNotFound extends TokenProvisionOutcome {
  const TokenNotFound();
  @override
  String toString() => 'TokenNotFound()';
}

/// The file exists but does not look like a daemon token.
class TokenInvalid extends TokenProvisionOutcome {
  const TokenInvalid();
  @override
  String toString() => 'TokenInvalid()';
}

/// Transport or storage failure. [cause] is only the error's TYPE name.
class TokenProvisionFailed extends TokenProvisionOutcome {
  const TokenProvisionFailed(this.cause);
  final String cause;
  @override
  String toString() => 'TokenProvisionFailed($cause)';
}

enum AgentdTokenStoreFailure { read, write, delete }

/// The keystore failed. Only says which operation: never the original error
/// (its text may hold the token), never a cause.
class AgentdTokenStoreException implements Exception {
  const AgentdTokenStoreException(this.kind);
  final AgentdTokenStoreFailure kind;
  @override
  String toString() => 'AgentdTokenStoreException(${kind.name})';
}

/// The daemon token, in the platform keystore, one item per profile.
///
/// The token is only ever handed to the `hello` frame: it is never logged,
/// never shown, and never part of an exception message.
class AgentdTokenStore {
  AgentdTokenStore({
    FlutterSecureStorage? storage,
    void Function(String profileId)? onChanged,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _onChanged = onChanged;

  final FlutterSecureStorage _storage;

  /// Called after a token was written or deleted (so a client built from the
  /// old value can be rebuilt). Gets the profile id only.
  final void Function(String profileId)? _onChanged;

  /// New items are not migrated from anything, so they use the stricter
  /// class: readable after the first unlock, never moved to another device.
  /// Passed on every call (not only at construction) so an injected storage
  /// cannot silently drop it.
  static const iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );

  /// Path of the token on the host, relative to the home directory.
  static const hostTokenPath = '.helm-agentd/token';

  static const _maxFileBytes = 256;
  static final _shape = RegExp(r'^[A-Za-z0-9_-]{43}$');

  static String storageKey(String profileId) => 'agentd_token_$profileId';

  /// Whether [token] has the daemon's token shape (32 bytes, base64url, no
  /// padding = 43 characters).
  static bool looksLikeToken(String token) => _shape.hasMatch(token);

  Future<String?> read(String profileId) async {
    try {
      return await _storage.read(
        key: storageKey(profileId),
        iOptions: iosOptions,
      );
    } catch (_) {
      throw const AgentdTokenStoreException(AgentdTokenStoreFailure.read);
    }
  }

  /// Throws a [FormatException] (without the value) when [token] is not
  /// token-shaped.
  Future<void> write(String profileId, String token) async {
    if (!looksLikeToken(token)) {
      throw const FormatException('not a helm-agentd token');
    }
    try {
      await _storage.write(
        key: storageKey(profileId),
        value: token,
        iOptions: iosOptions,
      );
    } catch (_) {
      throw const AgentdTokenStoreException(AgentdTokenStoreFailure.write);
    }
    _onChanged?.call(profileId);
  }

  Future<void> delete(String profileId) async {
    try {
      await _storage.delete(key: storageKey(profileId), iOptions: iosOptions);
    } catch (_) {
      throw const AgentdTokenStoreException(AgentdTokenStoreFailure.delete);
    }
    _onChanged?.call(profileId);
  }

  /// Copies the token ONCE over [sftp] from `~/.helm-agentd/token`.
  Future<TokenProvisionOutcome> provisionFromHost(
    SftpSession sftp,
    String profileId,
  ) async {
    final String text;
    try {
      final home = await sftp.absolute('.');
      final path = '${home.endsWith('/') ? home : '$home/'}$hostTokenPath';
      final bytes = await _readCapped(sftp, path);
      if (bytes == null) return const TokenInvalid();
      try {
        text = utf8.decode(bytes).trim();
      } on FormatException {
        return const TokenInvalid();
      }
    } on SftpStatusError catch (e) {
      return e.code == SftpStatusCode.noSuchFile
          ? const TokenNotFound()
          : TokenProvisionFailed(e.runtimeType.toString());
    } catch (e) {
      return TokenProvisionFailed(e.runtimeType.toString());
    }
    if (!looksLikeToken(text)) return const TokenInvalid();
    try {
      await write(profileId, text);
    } catch (e) {
      return TokenProvisionFailed(e.runtimeType.toString());
    }
    return const TokenStored();
  }

  /// The file's bytes, or null when it is larger than any token can be.
  Future<List<int>?> _readCapped(SftpSession sftp, String path) async {
    final handle = await sftp.openRead(path);
    try {
      final out = <int>[];
      await for (final chunk in handle.read(
        chunkSize: 1024,
        maxPendingRequests: 1,
      )) {
        out.addAll(chunk);
        if (out.length > _maxFileBytes) return null;
      }
      return out;
    } finally {
      await handle.close();
    }
  }
}
