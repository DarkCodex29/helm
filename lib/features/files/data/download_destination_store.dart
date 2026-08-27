import 'dart:convert';

import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:helm/features/files/domain/download_destination.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers the folder the user chose for downloads.
///
/// ### Why `shared_preferences` and not `flutter_secure_storage`
///
/// This app already keeps both, and the line between them is what the
/// value IS, not how much it matters: connection profiles — hostnames,
/// usernames, ports — live in `shared_preferences`
/// (`ConnectionProfileRepository`), while private keys live in secure
/// storage (`SSHKeyService`). A folder URI belongs on the profiles side of
/// that line, for a reason specific to how the grant works.
///
/// A SAF tree URI IS NOT A SECRET AND IS NOT A CREDENTIAL. It is a name
/// for a permission the OS recorded against this package: the authority to
/// write there lives in the system's persisted-permission table, not in
/// the string. Another app reading this value gains nothing, because the
/// same URI in its hands resolves to no grant at all. Encrypting it would
/// buy no security and cost a Keystore round-trip on the path of every
/// download.
///
/// It is also a PREFERENCE in the ordinary sense — the user set it, the
/// user can change it, and it should be as easy to inspect and clear as
/// any other setting. Putting it behind Keystore would make it the one
/// setting nobody can see.
class DownloadDestinationStore {
  static final _log = HelmLogger('DownloadDestinationStore');

  /// The chosen folder, or null if there is not one.
  ///
  /// Never throws. A value that will not parse is treated as no folder
  /// rather than surfaced, because there is exactly one useful response to
  /// a destination this app cannot read — ask the user for a new one — and
  /// that is what "no folder" already means. See [_decode].
  Future<DownloadDestination?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(AppConstants.downloadDestinationKey);
    if (raw == null) return null;
    return _decode(raw);
  }

  Future<void> write(DownloadDestination destination) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      AppConstants.downloadDestinationKey,
      jsonEncode({'uri': destination.uri, 'name': destination.name}),
    );
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppConstants.downloadDestinationKey);
  }

  /// [raw] as a destination, or null if it is not one.
  ///
  /// A record with no `uri` is rejected rather than repaired: the URI is
  /// the only part that can address anything, so a destination without one
  /// could be shown in the UI and never written to — the exact dishonesty
  /// the rest of this feature is built to avoid.
  static DownloadDestination? _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final uri = decoded['uri'];
      if (uri is! String || uri.isEmpty) return null;
      final name = decoded['name'];
      return DownloadDestination(
        uri: uri,
        // A missing name is survivable in a way a missing URI is not: it
        // costs a good label, not the ability to save anything.
        name: name is String && name.isNotEmpty ? name : 'Selected folder',
      );
    } catch (error) {
      _log.w('Stored download destination could not be read: $error');
      return null;
    }
  }
}
