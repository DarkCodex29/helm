import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/core/theme/app_theme.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/settings/presentation/settings_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profilesAsync = ref.watch(profilesProvider);
    final publicKeyAsync = ref.watch(sshPublicKeyProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: ListView(
        children: [
          _sectionHeader(context, 'Connection Profiles'),
          profilesAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(16),
              child: _ErrorCard(message: 'Error: $e'),
            ),
            data: (profiles) => profiles.isEmpty
                ? _EmptyProfilesState(
                    onAdd: () => context.push('/settings/profile'),
                  )
                : _ProfilesList(
                    profiles: profiles,
                    onTap: (id) => context.push('/settings/profile/$id'),
                    onDelete: (id) =>
                        ref.read(profilesProvider.notifier).delete(id),
                  ),
          ),
          _sectionHeader(context, 'SSH Public Key'),
          publicKeyAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(16),
              child: _ErrorCard(message: 'Error loading key: $e'),
            ),
            data: (publicKey) => publicKey == null
                ? Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.key_off,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.4,
                          ),
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'No SSH key generated',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : _SshKeyCard(
                    publicKey: publicKey,
                    onCopy: () {
                      Clipboard.setData(ClipboardData(text: publicKey));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Public key copied to clipboard'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                  ),
          ),
          _sectionHeader(context, 'About'),
          ListTile(
            title: const Text('Version'),
            trailing: Text(
              AppConstants.appVersion,
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                fontSize: 13,
              ),
            ),
          ),
          ListTile(
            title: const Text('App'),
            trailing: Text(
              AppConstants.appName,
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(height: 48),
        ],
      ),
      floatingActionButton: Semantics(
        identifier: SettingsSemantics.addProfileButton,
        child: FloatingActionButton(
          onPressed: () => context.push('/settings/profile'),
          tooltip: 'Add profile',
          child: const Icon(Icons.add),
        ),
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.primary.withValues(alpha: 0.8),
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: theme.colorScheme.error, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyProfilesState extends StatelessWidget {
  const _EmptyProfilesState({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(
            Icons.computer_outlined,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            size: 20,
          ),
          const SizedBox(width: 12),
          Text(
            'No profiles yet — tap + to add one',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfilesList extends StatelessWidget {
  const _ProfilesList({
    required this.profiles,
    required this.onTap,
    required this.onDelete,
  });

  final List<ConnectionProfile> profiles;
  final void Function(String id) onTap;
  final void Function(String id) onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: profiles.map((p) {
        return Dismissible(
          key: Key(p.id),
          direction: DismissDirection.endToStart,
          background: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.error,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.centerRight,
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            padding: const EdgeInsets.only(right: 20),
            child: const Icon(Icons.delete_outline, color: Colors.white),
          ),
          onDismissed: (_) => onDelete(p.id),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: theme.colorScheme.outline),
              ),
              child: Icon(
                Icons.computer,
                color: p.isDefault
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                size: 20,
              ),
            ),
            title: Text(
              p.name,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Text(
              '${p.username}@${p.host}:${p.port}',
              style: theme.textTheme.bodySmall,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (p.isDefault)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: const Icon(
                      Icons.star,
                      color: AppTheme.defaultMarker,
                      size: 16,
                    ),
                  ),
                Icon(
                  Icons.chevron_right,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                  size: 20,
                ),
              ],
            ),
            onTap: () => onTap(p.id),
          ),
        );
      }).toList(),
    );
  }
}

class _SshKeyCard extends StatelessWidget {
  const _SshKeyCard({required this.publicKey, required this.onCopy});
  final String publicKey;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.background,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: theme.colorScheme.outline),
            ),
            child: SelectableText(
              publicKey,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: AppTheme.onSurface,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: onCopy,
            icon: const Icon(Icons.copy, size: 15),
            label: const Text('Copy Public Key'),
          ),
        ],
      ),
    );
  }
}
