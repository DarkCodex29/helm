import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/core/theme/app_theme.dart';
import 'package:helm/features/connection/data/known_hosts_service.dart';

/// Asks the user to confirm a host key once, after the update that changed
/// how Helm computes fingerprints.
///
/// ### Why this is not the mismatch surface, and not an advisory
///
/// It deliberately shares no wording, no colour and no icon with the
/// man-in-the-middle warning. Every host Helm already trusted reaches this
/// state exactly once on the first launch after the upgrade, and dressing
/// that as an interception would fire the loudest warning the app has at a
/// whole fleet of servers whose keys never changed — which is precisely how
/// a user learns that Helm's security warnings mean nothing. The accent is
/// the same informational blue the reconnect affordance uses, not the red
/// reserved for failure.
///
/// It is equally not a [HostAdvisory]. `HostAdvisoryCard` documents that it
/// "decides nothing" and gives every row a dismiss button; this is an
/// authorization gate whose answer is written to the trust store. A
/// security decision must not be dismissible.
///
/// ### Why cancel is the primary button
///
/// Inverted from every other button pair in this app, `SessionRecoveryBanner`
/// included. The other action grants trust to a key the user may not have
/// checked yet, so the safe choice is the one a distracted thumb lands on.
///
/// ### Why the superseded value is hidden
///
/// [HostKeyMigrationRequiredException.legacyFingerprint] is
/// `SHA256(MD5(host key))` — it matches nothing the server can be asked to
/// print. Shown beside the new value it would read as a before/after pair
/// and invite exactly the comparison that cannot mean anything. It is
/// available behind a disclosure, labelled for what it is.
///
/// Purely presentational apart from that disclosure: which fingerprint is
/// shown, whether it may be trusted, and what happens when it is, are all
/// settled in `KnownHostsService` and `TerminalSession`, where they are
/// testable without a widget. The same split `host_advisory_card.dart` and
/// `session_reference.dart` use.
///
/// No `maxHeight`, unlike `HostAdvisoryCard`. That cap exists because the
/// advisory surface also renders over a LIVE terminal, where an unbounded
/// Positioned child clipped its own dismiss buttons out of reach. This card
/// only ever renders inside the failure overlay's scroll view, and it
/// replaces the reconnect block rather than sitting under it, so there is
/// nothing for it to push off screen.
class HostKeyMigrationCard extends StatefulWidget {
  const HostKeyMigrationCard({
    super.key,
    required this.migration,
    required this.username,
    required this.onTrust,
    required this.onCancel,
  });

  final HostKeyMigrationRequiredException migration;

  /// The account this profile connects as. Comes from the profile rather
  /// than from [migration] because it is a Helm-side fact, not something
  /// the host key says — but the user needs it to know which server they
  /// are being asked to authorize.
  final String username;

  /// The user accepted the fingerprint. Reported, never acted on here.
  final VoidCallback onTrust;

  /// The user declined. Nothing is written to the trust store.
  final VoidCallback onCancel;

  @override
  State<HostKeyMigrationCard> createState() => _HostKeyMigrationCardState();
}

class _HostKeyMigrationCardState extends State<HostKeyMigrationCard> {
  static const _accent = AppTheme.primary;
  static const _primaryText = AppTheme.onBackground;
  static const _bodyText = AppTheme.onSurface;
  static const _mutedText = AppTheme.onSurfaceMuted;

  bool _showSupersededValue = false;

  @override
  Widget build(BuildContext context) {
    final migration = widget.migration;
    final command = hostKeyVerificationCommand(migration.keyType);

    return Semantics(
      identifier: TerminalSemantics.hostKeyMigration,
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
                    'Confirm this host key',
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
            const Text(
              'This update changed how Helm computes host key '
              'fingerprints, so the value stored for this server can no '
              'longer be compared — this is not necessarily a sign that '
              'the key changed.',
              style: TextStyle(color: _bodyText, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 14),
            _label('Server'),
            Text(
              '${widget.username}@${migration.host}:${migration.port}',
              style: const TextStyle(
                color: _primaryText,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 12),
            _label('${migration.keyType} fingerprint'),
            _codeBlock(
              child: SelectableText(
                migration.receivedFingerprint,
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
              value: migration.receivedFingerprint,
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
            _disclosure(migration.legacyFingerprint),
            const SizedBox(height: 12),
            Row(
              children: [
                // Secondary on purpose. See the class doc: this is the
                // action that grants trust, so it must be chosen, not
                // landed on.
                Expanded(
                  child: TextButton(
                    onPressed: widget.onTrust,
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
                    onPressed: widget.onCancel,
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

  Widget _disclosure(String legacyFingerprint) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: () =>
              setState(() => _showSupersededValue = !_showSupersededValue),
          style: TextButton.styleFrom(
            foregroundColor: _mutedText,
            minimumSize: const Size(48, 40),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: const Text(
            'What was stored before?',
            style: TextStyle(fontSize: 12),
          ),
        ),
      ),
      if (_showSupersededValue) ...[
        const Text(
          'The previous value used an older format and cannot be compared '
          'with anything this server reports. It is shown only for the '
          'record — do not read it as a before-and-after pair.',
          style: TextStyle(color: _mutedText, fontSize: 11, height: 1.4),
        ),
        const SizedBox(height: 6),
        _codeBlock(
          child: Text(
            legacyFingerprint,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: _mutedText,
              height: 1.5,
            ),
          ),
        ),
      ],
    ],
  );
}
