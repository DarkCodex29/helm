import 'package:flutter/material.dart';
import 'package:helm/core/host/agent_snapshot.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/theme/app_theme.dart';

/// Visual vocabulary for [AgentState], shared by the tab badge and the
/// drawer list so the two can never disagree about what a state looks like.
///
/// Covered by
/// `test/features/terminal/presentation/widgets/agent_state_chip_test.dart`.
///
/// Deliberately avoids the green/red already spent on the tab strip's
/// CONNECTION dot. A red agent badge sitting beside a red disconnected dot
/// would read as one compound failure rather than as two independent
/// facts, so `blocked` claims attention with amber instead — the only
/// colour on this surface reserved for "a human is needed here".
class AgentStateStyle {
  const AgentStateStyle._(this.color, this.icon);

  final Color color;
  final IconData icon;

  static const _blocked = AgentStateStyle._(
    AppTheme.warning,
    Icons.priority_high,
  );
  static const _working = AgentStateStyle._(AppTheme.primary, Icons.autorenew);
  static const _done = AgentStateStyle._(AppTheme.secondary, Icons.check);
  static const _idle = AgentStateStyle._(
    AppTheme.onSurfaceFaint,
    Icons.pause_rounded,
  );
  static const _unknown = AgentStateStyle._(
    AppTheme.onSurfaceFaint,
    Icons.question_mark,
  );

  static AgentStateStyle of(AgentState state) => switch (state) {
    AgentState.blocked => _blocked,
    AgentState.working => _working,
    AgentState.done => _done,
    AgentState.idle => _idle,
    AgentState.unknown => _unknown,
  };
}

/// Compact icon-only badge for the tab strip, where a tab is at most 160
/// logical pixels wide and already spends room on a status dot, a title and
/// a close button.
///
/// Only ever built for a state somebody measured — see
/// [mostUrgentAgentState], which returns null for every snapshot that is
/// not an authoritative, non-empty reading. The tooltip carries the wording
/// the icon cannot.
class AgentBadge extends StatelessWidget {
  const AgentBadge({super.key, required this.state});

  final AgentState state;

  @override
  Widget build(BuildContext context) {
    final style = AgentStateStyle.of(state);
    final isUrgent = state == AgentState.blocked;

    return Tooltip(
      message: agentStateLabel(state),
      child: Container(
        width: 14,
        height: 14,
        margin: const EdgeInsets.only(right: 5),
        decoration: BoxDecoration(
          color: style.color.withValues(alpha: isUrgent ? 1.0 : 0.18),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: style.color.withValues(alpha: 0.6)),
        ),
        child: Icon(
          style.icon,
          size: 9,
          // The urgent badge is filled, so its glyph has to invert to stay
          // legible against its own background.
          color: isUrgent ? AppTheme.background : style.color,
        ),
      ),
    );
  }
}

/// Full-width row for the drawer: icon, agent label, and the state in
/// words. Unlike [AgentBadge] there is room here for the real wording, so
/// nothing is left to a tooltip.
///
/// Tappable when [onTap] is given — which is how the user reaches the
/// agent rather than hunting for its pane by hand. Inert without one, so a
/// surface with nothing to act on cannot look pressable.
class AgentRow extends StatelessWidget {
  const AgentRow({
    super.key,
    required this.agent,
    this.contextLabel,
    this.onTap,
  });

  final AgentStatus agent;

  /// Where this agent is — see [agentContextLabel], which produces it.
  ///
  /// Null is the DEFAULT and the fallback in one: a row given nothing
  /// renders exactly as it did before context existed, because an agent
  /// helm cannot place is still a real agent the user may need to reach.
  /// Nothing is invented to fill the gap.
  ///
  /// Secondary on purpose. The agent's own name stays the primary line —
  /// this only breaks the tie between two rows that would otherwise read
  /// identically, so it borrows the muted treatment the drawer already
  /// spends on a project shortcut's path rather than introducing one.
  final String? contextLabel;

  /// Invoked when the row is tapped. Null makes the row inert.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final style = AgentStateStyle.of(agent.state);
    final isUrgent = agent.state == AgentState.blocked;

    return InkWell(
      // Wrapping the Padding rather than the Container, matching the
      // drawer's project tiles so the two rows respond identically.
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Container(
          // 48 on the CARD, not on the InkWell, so the guarantee survives
          // someone changing the padding above it. This is a phone held one
          // -handed and the row below belongs to a different agent; a
          // mis-hit sends the user to the wrong pane.
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppTheme.surfaceVariant,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              // The one that needs a human is the one the eye should land
              // on first when the drawer opens.
              color: isUrgent ? style.color : AppTheme.divider,
              width: isUrgent ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(style.icon, size: 14, color: style.color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  // Only as tall as it needs to be, so a row WITHOUT a
                  // context keeps the single-line height it always had
                  // and the two kinds of row still sit on one rhythm.
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      agent.label,
                      style: const TextStyle(
                        color: AppTheme.onBackground,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (contextLabel != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        contextLabel!,
                        style: const TextStyle(
                          color: AppTheme.onSurfaceMuted,
                          fontSize: 11,
                        ),
                        // The owner has a tab called "Facturación
                        // Electrónica"; on a 280dp drawer that line has to
                        // clip rather than push the state word off-screen.
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                agentStateLabel(agent.state),
                style: TextStyle(
                  color: style.color,
                  fontSize: 11,
                  fontWeight: isUrgent ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
