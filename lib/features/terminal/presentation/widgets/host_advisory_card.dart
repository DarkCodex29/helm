import 'package:flutter/material.dart';
import 'package:helm/core/host/host_advisory.dart';
import 'package:helm/core/testing/semantic_ids.dart';

/// Compact, dismissible summary of what is wrong with the connected host.
///
/// Purely presentational — it decides nothing. Which findings exist, how
/// they are worded, and how they are ordered is settled in
/// `lib/core/host/host_advisory.dart` and `host_advisor.dart`, where it is
/// unit-testable without a widget. This is the same split
/// `session_reference.dart` uses for the mirroring policy: the rule lives
/// in one testable place, and the widgets stay thin enough that they
/// cannot drift from it.
///
/// Rendered inside the existing connection-failure overlay rather than on
/// a surface of its own: these findings explain a failure, so they belong
/// where the user already is when they hit one.
///
/// [HostAdvisory.remediationCopy] is shown as text and NEVER executed —
/// the display-only rule this inherits from `HostDiagnostics`, which
/// matters most for the Tailscale case, where the remediation would cut
/// the very connection it ran over.
class HostAdvisoryCard extends StatefulWidget {
  const HostAdvisoryCard({super.key, required this.advisories});

  final List<HostAdvisory> advisories;

  @override
  State<HostAdvisoryCard> createState() => _HostAdvisoryCardState();
}

class _HostAdvisoryCardState extends State<HostAdvisoryCard> {
  /// Ids the user has dismissed. Keyed by id rather than by a single flag
  /// so a later, different finding is not hidden by an earlier dismissal.
  final Set<HostAdvisoryId> _dismissed = {};

  @override
  Widget build(BuildContext context) {
    final visible = widget.advisories
        .where((a) => !_dismissed.contains(a.id))
        .toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    return Semantics(
      identifier: TerminalSemantics.hostAdvisory,
      container: true,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 24),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: const Color(0xFF21262D),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final advisory in visible)
              _AdvisoryRow(
                advisory: advisory,
                onDismiss: () =>
                    setState(() => _dismissed.add(advisory.id)),
              ),
          ],
        ),
      ),
    );
  }
}

class _AdvisoryRow extends StatelessWidget {
  const _AdvisoryRow({required this.advisory, required this.onDismiss});

  final HostAdvisory advisory;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final isWarning = advisory.severity == HostAdvisorySeverity.warning;
    final accent = isWarning
        ? const Color(0xFFD29922)
        : const Color(0xFF8B949E);
    final remediation = advisory.remediationCopy;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isWarning ? Icons.warning_amber_rounded : Icons.info_outline,
            color: accent,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  advisory.title,
                  style: TextStyle(
                    color: accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  advisory.detail,
                  style: const TextStyle(
                    color: Color(0xFFB1BAC4),
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
                if (remediation != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    remediation,
                    style: const TextStyle(
                      color: Color(0xFF8B949E),
                      fontSize: 12,
                      height: 1.35,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            color: const Color(0xFF8B949E),
            tooltip: 'Dismiss',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
