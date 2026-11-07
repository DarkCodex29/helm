import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/notifications/domain/notification_channel.dart';
import 'package:helm/features/notifications/presentation/push_notification_provider.dart';

/// "Notifications on this device": says which push channel this phone uses.
///
/// FCM needs nothing from the user. ntfy needs one step on the phone: add
/// this device's own topic in the ntfy app. There is deliberately no
/// "Open in ntfy" link: it needs `url_launcher` (not a dependency), and the
/// ntfy iOS app does not support `ntfy://` links (ntfy issue #450).
class NotificationsSection extends ConsumerWidget {
  const NotificationsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final channel = ref.watch(notificationChannelProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 28, 16, 8),
          child: Text(
            'NOTIFICATIONS ON THIS DEVICE',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary.withValues(alpha: 0.8),
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
              fontSize: 11,
            ),
          ),
        ),
        channel.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: LinearProgressIndicator(),
          ),
          error: (_, _) => const ListTile(
            title: Text('Could not determine the notification channel'),
          ),
          data: (value) => switch (value) {
            FcmChannel() => const ListTile(
              leading: Icon(Icons.notifications_active_outlined),
              title: Text('Push is delivered natively'),
              subtitle: Text('Nothing to set up on this device.'),
            ),
            NtfyChannel(:final topic) => _NtfyChannelTile(topic: topic),
          },
        ),
      ],
    );
  }
}

class _NtfyChannelTile extends StatefulWidget {
  const _NtfyChannelTile({required this.topic});

  final String topic;

  @override
  State<_NtfyChannelTile> createState() => _NtfyChannelTileState();
}

class _NtfyChannelTileState extends State<_NtfyChannelTile> {
  static const _maskedPrefixLength = 8;
  var _revealed = false;

  String get _shown => _revealed
      ? widget.topic
      : '${widget.topic.substring(0, _maskedPrefixLength)}…';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This device is notified through ntfy. Subscribe once:',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            '1. Install the ntfy app.\n'
            '2. Tap + and paste the topic below.\n'
            '3. Keep the server as ntfy.sh.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  _shown,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
              IconButton(
                tooltip: _revealed ? 'Hide topic' : 'Show topic',
                icon: Icon(
                  _revealed
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                onPressed: () => setState(() => _revealed = !_revealed),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy topic'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: widget.topic));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Topic copied'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Anyone with this topic can read your alerts. Keep it private.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
