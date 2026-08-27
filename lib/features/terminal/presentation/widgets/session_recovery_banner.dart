import 'package:flutter/material.dart';
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
        color: const Color(0xFF21262D),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.bolt, color: Color(0xFF58A6FF), size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Previous session found',
                  style: TextStyle(
                    color: Color(0xFFE6EDF3),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'You had open: $profileNames',
                  style: const TextStyle(
                    color: Color(0xFFB1BAC4),
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Both buttons carry a full 48dp tap target.
          //
          // They previously combined `minimumSize: Size.zero` with
          // `MaterialTapTargetSize.shrinkWrap`, which strips the padding
          // Material adds for exactly this reason and left the hit area at
          // the text's own height — measured on a Galaxy S22 Ultra, roughly
          // 24dp, half the documented minimum. These are the two buttons a
          // user meets on a cold start, one of which discards recovered
          // work, so a mis-tap here is expensive.
          TextButton(
            onPressed: onDiscard,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFB1BAC4),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(48, 48),
            ),
            child: const Text('Discard', style: TextStyle(fontSize: 13)),
          ),
          const SizedBox(width: 4),
          ElevatedButton(
            onPressed: onRecover,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF58A6FF),
              foregroundColor: const Color(0xFF0D1117),
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
      ),
    );
  }
}
