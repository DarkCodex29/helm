import 'package:flutter/material.dart';
import 'package:helm/core/theme/app_theme.dart';
import 'package:helm/features/terminal/data/session_snapshot_repository.dart';

/// Banner shown on HomeScreen when a previous session is waiting to be
/// recovered (an earlier crash, detected through the dirty flag).
///
/// Purely presentational — it takes callbacks and reaches for no provider
/// of its own.
class SessionRecoveryBanner extends StatelessWidget {
  const SessionRecoveryBanner({
    super.key,
    required this.snapshots,
    required this.onRecover,
    required this.onDiscard,
  });

  final List<TabSnapshot> snapshots;
  final VoidCallback onRecover;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final profileNames = snapshots.map((s) => s.profileName).join(', ');

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.divider),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final message = Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(Icons.bolt, color: AppTheme.primary, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Previous session found',
                      style: TextStyle(
                        color: AppTheme.onBackground,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'You had open: $profileNames',
                      style: const TextStyle(
                        color: AppTheme.onSurface,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          );
          // Both buttons carry a full 48dp tap target. Keep them on a second
          // line when the measured width cannot hold the scaled labels and
          // the message without a RenderFlex overflow.
          final actions = Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            runSpacing: 4,
            children: [
              TextButton(
                onPressed: onDiscard,
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.onSurface,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(48, 48),
                ),
                child: const Text('Discard', style: TextStyle(fontSize: 13)),
              ),
              ElevatedButton(
                onPressed: onRecover,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: AppTheme.background,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  minimumSize: const Size(64, 48),
                  textStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: const Text('Resume'),
              ),
            ],
          );

          if (constraints.maxWidth < 420) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [message, const SizedBox(height: 4), actions],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: message),
              const SizedBox(width: 8),
              actions,
            ],
          );
        },
      ),
    );
  }
}
