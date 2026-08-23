import 'package:flutter/material.dart';
import 'package:helm/core/host/agent_snapshot.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';

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
    Color(0xFFD29922),
    Icons.priority_high,
  );
  static const _working = AgentStateStyle._(
    Color(0xFF58A6FF),
    Icons.autorenew,
  );
  static const _done = AgentStateStyle._(Color(0xFF3FB950), Icons.check);
  static const _idle = AgentStateStyle._(
    Color(0xFF6E7681),
    Icons.pause_rounded,
  );
  static const _unknown = AgentStateStyle._(
    Color(0xFF6E7681),
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
          color: isUrgent ? const Color(0xFF0D1117) : style.color,
        ),
      ),
    );
  }
}

/// Full-width row for the drawer: icon, agent label, and the state in
/// words. Unlike [AgentBadge] there is room here for the real wording, so
/// nothing is left to a tooltip.
class AgentRow extends StatelessWidget {
  const AgentRow({super.key, required this.agent});

  final AgentStatus agent;

  @override
  Widget build(BuildContext context) {
    final style = AgentStateStyle.of(agent.state);
    final isUrgent = agent.state == AgentState.blocked;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF21262D),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            // The one that needs a human is the one the eye should land on
            // first when the drawer opens.
            color: isUrgent ? style.color : const Color(0xFF30363D),
            width: isUrgent ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(style.icon, size: 14, color: style.color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                agent.label,
                style: const TextStyle(
                  color: Color(0xFFE6EDF3),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
    );
  }
}
