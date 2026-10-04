import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/core/theme/app_theme.dart';
import 'package:helm/features/connection/data/known_hosts_service.dart';
import 'package:helm/features/settings/presentation/trusted_hosts_provider.dart';

/// Lists every host key helm has pinned, with an explicit per-host forget
/// action.
///
/// Lives under Settings rather than one tap away from the mismatch
/// warning on purpose. `SSHService.describeError` already tells the user,
/// for a [HostKeyMismatchException], to verify the new fingerprint on the
/// server through a channel they trust and only THEN forget the pin — see
/// `hostKeyVerificationCommand`. Putting a forget button beside that
/// alarm would train a user to tap through it without ever running that
/// check, which is the exact failure mode TOFU exists to prevent. This
/// screen is reachable only by deliberately opening Settings, which keeps
/// that friction intact while still giving the escape hatch
/// `KnownHostsService.removeHost` promises somewhere to live.
///
/// Placed in `settings/presentation` even though a pinned host key is a
/// connection concern, not a settings one — the same placement
/// `ProfileEditScreen` already uses for editing a connection profile. No
/// reason was found to diverge from that precedent.
class TrustedHostsScreen extends ConsumerWidget {
  const TrustedHostsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinsAsync = ref.watch(trustedHostsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Trusted Hosts')),
      body: Semantics(
        identifier: TrustedHostsSemantics.listing,
        child: pinsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          // A failed read is not the same claim as an empty list — see
          // `KnownHostsService.listPinnedHosts`'s doc comment for why it
          // is left unguarded. Rendering it here, rather than the empty
          // state below, is what keeps that distinction visible to the
          // user instead of collapsing it back into one screen.
          error: (error, _) => _ErrorState(error: error),
          data: (pins) =>
              pins.isEmpty ? const _EmptyState() : _PinsList(pins: pins),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        'No trusted hosts',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(AppTheme.errorIcon, color: theme.colorScheme.error, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Could not read the trusted hosts store: $error',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }
}

class _PinsList extends ConsumerWidget {
  const _PinsList({required this.pins});
  final List<PinnedHost> pins;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      children: pins
          .map(
            (pin) => _PinTile(
              pin: pin,
              onForget: () => _confirmForget(context, ref, pin),
            ),
          )
          .toList(),
    );
  }

  Future<void> _confirmForget(
    BuildContext context,
    WidgetRef ref,
    PinnedHost pin,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Forget this host?'),
        // Deliberately does not say forgetting is safe: it is the
        // correct action only after the check below has actually been
        // done, and the whole reason this screen is one tap further from
        // the mismatch alarm than a shortcut would be.
        content: Text(
          'Before forgetting ${pin.host}:${pin.port}, verify its current '
          'fingerprint on the server, through a channel you already '
          'trust - for example by running ssh-keygen on the host '
          'itself.\n\n'
          'Only forget this pin once you have confirmed the server\'s own '
          'key matches what you expect. Helm will trust whatever key the '
          'server presents next.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          Semantics(
            identifier: TrustedHostsSemantics.confirmForgetButton,
            child: TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(dialogContext).colorScheme.error,
              ),
              child: const Text('Forget'),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await forgetPinnedHost(
      ref,
      host: pin.host,
      port: pin.port,
      keyType: pin.keyType,
    );
  }
}

class _PinTile extends StatelessWidget {
  const _PinTile({required this.pin, required this.onForget});
  final PinnedHost pin;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      title: Text('${pin.host}:${pin.port}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            pin.isLegacy
                // No key type to show — see `PinnedHost.keyType`'s doc
                // comment for why there genuinely is none, not merely an
                // unread one.
                ? 'Pinned by an older version of Helm - key type unknown'
                : pin.keyType!,
            style: theme.textTheme.bodySmall,
          ),
          SelectableText(
            pin.fingerprint,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ],
      ),
      isThreeLine: true,
      trailing: Semantics(
        identifier: TrustedHostsSemantics.forgetButton(
          pin.host,
          pin.port,
          pin.keyType,
        ),
        child: IconButton(
          icon: Icon(Icons.delete_outline, color: AppTheme.onSurface),
          tooltip: 'Forget this host',
          onPressed: onForget,
        ),
      ),
    );
  }
}
