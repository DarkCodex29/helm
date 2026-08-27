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
///
/// ### Why [maxHeight] is required, and dismissal is not held here
///
/// Both are fixes for a defect measured on a real device. Two advisories
/// co-occur on the verified host — a substitution plus the substituted-in
/// binary being off the login PATH — and at 320pt wide that content is
/// 931pt tall against the 509.78pt of terminal an iPhone 17 Pro has with
/// the keyboard shown. With no cap and no scroll, the surplus painted past
/// the terminal Stack and was silently CLIPPED: the lower rows and their
/// dismiss buttons were unreachable, so the user could not get rid of the
/// thing covering their terminal.
///
/// [maxHeight] is therefore required rather than optional. An unbounded
/// advisory surface is not a configuration this widget offers, so no
/// future call site can reintroduce that layout by omission.
///
/// Dismissal is likewise NOT state here. This widget used to own a
/// `Set<HostAdvisoryId> _dismissed`, and it unmounts on every reconnect —
/// `TerminalSession.connect()` clears `advisoriesNotifier` and
/// `_resolveMultiplexer` repopulates it — so each drop resurrected every
/// advisory the user had already dealt with. [dismissed] and [onDismiss]
/// hand that decision to something that outlives the widget; see
/// `TerminalSession.dismissedAdvisoriesNotifier`. That also makes the
/// class doc above literally true again: it now decides nothing.
class HostAdvisoryCard extends StatelessWidget {
  const HostAdvisoryCard({
    super.key,
    required this.advisories,
    required this.dismissed,
    required this.onDismiss,
    required this.maxHeight,
  });

  /// Every finding the host reported, dismissed or not. Filtering is done
  /// here against [dismissed] rather than by the caller so both advisory
  /// surfaces cannot disagree about what "dismissed" means.
  final List<HostAdvisory> advisories;

  /// [HostAdvisory.dismissalKey]s the user has already dismissed.
  final Set<String> dismissed;

  /// Reports that the user dismissed an advisory. This widget does not act
  /// on it — the next build reflects it only once it appears in
  /// [dismissed], so the store stays the single source of truth.
  final ValueChanged<HostAdvisory> onDismiss;

  /// Hard ceiling on this card's height. Content taller than this scrolls
  /// inside it; nothing is ever clipped out of reach.
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final visible = advisories
        .where((a) => !dismissed.contains(a.dismissalKey))
        .toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    return Semantics(
      identifier: TerminalSemantics.hostAdvisory,
      container: true,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 24),
        // maxHeight caps the box; the scroll view inside still sizes to
        // its content when the content is shorter, so a lone one-line
        // finding is capped, never padded out to fill the ceiling.
        constraints: BoxConstraints(maxWidth: 420, maxHeight: maxHeight),
        decoration: BoxDecoration(
          color: const Color(0xFF21262D),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        // Clips the rows to the rounded border, so a mid-scroll row does
        // not paint over the card's own edge.
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final advisory in visible)
                _AdvisoryRow(
                  advisory: advisory,
                  onDismiss: () => onDismiss(advisory),
                ),
            ],
          ),
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
