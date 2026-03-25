import 'package:flutter/material.dart';
import 'package:helm/features/terminal/data/session_snapshot_repository.dart';

/// Banner que se muestra en HomeScreen cuando hay una sesión pendiente
/// de recuperar (crash anterior detectado via flag dirty).
///
/// Es un widget puramente presentacional — recibe callbacks y no accede
/// directamente a ningún provider.
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
          // Ícono bolt
          const Icon(Icons.bolt, color: Color(0xFF58A6FF), size: 22),
          const SizedBox(width: 12),
          // Textos
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Sesión anterior encontrada',
                  style: TextStyle(
                    color: Color(0xFFE6EDF3),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Tenías abierto: $profileNames',
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
          // Botones
          TextButton(
            onPressed: onDiscard,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFB1BAC4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Descartar', style: TextStyle(fontSize: 13)),
          ),
          const SizedBox(width: 4),
          ElevatedButton(
            onPressed: onRecover,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF58A6FF),
              foregroundColor: const Color(0xFF0D1117),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: const Text('Retomar'),
          ),
        ],
      ),
    );
  }
}
