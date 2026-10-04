import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/core/theme/app_theme.dart';
import 'package:helm/features/connection/data/known_hosts_service.dart';

/// Asks the user to authorize a host key algorithm their server has not
/// presented before.
///
/// ### Why this exists as its own surface
///
/// It sits between the two cards it must not be mistaken for, and each
/// would misreport it. `HostKeyMigrationCard` explains a Helm upgrade that
/// made a stored value unreadable — true of a migration, and a false
/// accusation here, where the stored values are perfectly readable and the
/// server is the thing that changed. The man-in-the-middle warning is
/// wronger still: no pinned fingerprint has been contradicted, and firing
/// the interception alarm at an administrator who added an Ed25519 key
/// beside an ageing RSA one is how a user learns to click past it. See
/// [HostKeyVerdict.unpinnedKeyType].
///
/// The accent is therefore the same informational blue the migration card
/// and the reconnect affordance use, not the red reserved for failure.
///
/// It is equally not a `HostAdvisory`. `HostAdvisoryCard` documents that it
/// "decides nothing" and gives every row a dismiss button; this is an
/// authorization gate whose answer is written to the trust store, and a
/// security decision must not be dismissible.
///
/// ### Why cancel is the primary button
///
/// Inverted from every other button pair in this app, and shared
/// deliberately with `HostKeyMigrationCard`: the other action grants trust
/// to a key the user may not have checked yet, so the safe choice is the
/// one a distracted thumb lands on. The two cards are separate widgets
/// rather than one parameterised card because their copy has almost
/// nothing in common — but this inversion is a property they must never
/// diverge on, so each pins it with its own test.
///
/// ### Why the known key types are named
///
/// [HostKeyTypeAuthorizationRequiredException.knownKeyTypes] is the fact
/// that makes the question answerable. "This server has always presented
/// ssh-ed25519 and is now offering ecdsa-sha2-nistp256" is something a
/// user can take to their administrator; a bare fingerprint with no
/// context is something they can only guess at.
///
/// Their FINGERPRINTS are deliberately absent. Those belong to different
/// keys, and printing them beside the new one would stage a before/after
/// comparison between values that are supposed to differ — the same trap
/// the migration card keeps its superseded value behind a disclosure to
/// avoid.
///
/// Purely presentational: which fingerprint is shown, whether it may be
/// trusted, and what happens when it is, are all settled in
/// `KnownHostsService` and `TerminalSession`, where they are testable
/// without a widget.
class HostKeyTypeCard extends StatelessWidget {
  const HostKeyTypeCard({
    super.key,
    required this.authorization,
    required this.username,
    required this.onTrust,
    required this.onCancel,
  });

  final HostKeyTypeAuthorizationRequiredException authorization;

  /// The account this profile connects as. Comes from the profile rather
  /// than from [authorization] because it is a Helm-side fact, not
  /// something the host key says — but the user needs it to know which
  /// server they are being asked to authorize.
  final String username;

  /// The user accepted the fingerprint. Reported, never acted on here.
  final VoidCallback onTrust;

  /// The user declined. Nothing is written to the trust store.
  final VoidCallback onCancel;

  static const _accent = AppTheme.primary;
  static const _primaryText = AppTheme.onBackground;
  static const _bodyText = AppTheme.onSurface;
  static const _mutedText = AppTheme.onSurfaceMuted;

  @override
  Widget build(BuildContext context) {
    final command = hostKeyVerificationCommand(authorization.keyType);
    final known = authorization.knownKeyTypes.join(', ');

    return Semantics(
      identifier: TerminalSemantics.hostKeyTypeAuthorization,
      container: true,
      explicitChildNodes: true,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 24),
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.surfaceVariant,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.key_outlined, color: _accent, size: 20),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Confirm a new host key type',
                    style: TextStyle(
                      color: _primaryText,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              // States the contrast first, because it is the reason the
              // question is being asked, then both readings of it. The
              // benign one leads: it is the far more common cause, and a
              // card that opened on the attack would be the interception
              // warning wearing a different colour.
              'This server is already trusted for $known, and has now '
              'presented a ${authorization.keyType} key that Helm has never '
              'seen for it. That is often legitimate - a re-keyed server, '
              'or an administrator adding a newer algorithm. It can also be '
              'someone on the network offering an algorithm your server '
              'does not use, so their key looks new rather than wrong.',
              style: const TextStyle(
                color: _bodyText,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            _label('Server'),
            Text(
              '$username@${authorization.host}:${authorization.port}',
              style: const TextStyle(
                color: _primaryText,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 12),
            _label('Already trusted for'),
            Text(
              known,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: _bodyText,
              ),
            ),
            const SizedBox(height: 12),
            _label('New ${authorization.keyType} fingerprint'),
            _codeBlock(
              child: SelectableText(
                authorization.receivedFingerprint,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: _bodyText,
                  height: 1.5,
                ),
              ),
            ),
            _copyButton(
              label: 'Copy fingerprint',
              value: authorization.receivedFingerprint,
            ),
            if (command != null) ...[
              const SizedBox(height: 8),
              _label('Check it on the server'),
              _codeBlock(
                child: Text(
                  command,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: _bodyText,
                    height: 1.5,
                  ),
                ),
              ),
              _copyButton(label: 'Copy command', value: command),
            ],
            const SizedBox(height: 4),
            const Text(
              // Removes the strongest reason to refuse a legitimate key.
              // A user who thinks confirming will overwrite the key they
              // already trust is being asked to choose between two things
              // they want, when in fact they keep both.
              'Confirming adds this key type. It does not replace the keys '
              'already trusted for this server.',
              style: TextStyle(color: _mutedText, fontSize: 11, height: 1.4),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                // Secondary on purpose. See the class doc: this is the
                // action that grants trust, so it must be chosen, not
                // landed on.
                Expanded(
                  child: TextButton(
                    onPressed: onTrust,
                    style: TextButton.styleFrom(
                      foregroundColor: _bodyText,
                      minimumSize: const Size(48, 48),
                    ),
                    child: const Text(
                      'Trust and reconnect',
                      style: TextStyle(fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: onCancel,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: AppTheme.background,
                      minimumSize: const Size(48, 48),
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: const TextStyle(
        color: _mutedText,
        fontSize: 11,
        fontWeight: FontWeight.w500,
      ),
    ),
  );

  Widget _codeBlock({required Widget child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: AppTheme.background,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppTheme.divider),
    ),
    child: child,
  );

  Widget _copyButton({required String label, required String value}) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      // Copies the value BYTE FOR BYTE. Trimming, re-wrapping or
      // re-prefixing here would hand the user something that does not
      // equal what the server prints, which is the whole point of the
      // comparison they are about to make.
      onPressed: () => Clipboard.setData(ClipboardData(text: value)),
      icon: const Icon(Icons.copy, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: TextButton.styleFrom(
        foregroundColor: _accent,
        minimumSize: const Size(48, 40),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
    ),
  );
}
