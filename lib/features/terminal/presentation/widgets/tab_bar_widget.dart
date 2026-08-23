import 'package:flutter/material.dart';
import 'package:helm/core/host/agent_snapshot.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/terminal/domain/terminal_tab.dart';
import 'package:helm/features/terminal/presentation/widgets/agent_state_chip.dart';

class TerminalTabBar extends StatelessWidget {
  const TerminalTabBar({
    super.key,
    required this.tabs,
    required this.activeIndex,
    required this.onTabTap,
    required this.onTabClose,
    required this.onAddTab,
  });

  final List<TerminalTab> tabs;
  final int activeIndex;
  final void Function(int index) onTabTap;
  final void Function(String tabId) onTabClose;
  final VoidCallback onAddTab;

  static const _bgColor = Color(0xFF161B22);
  static const _activeTabColor = Color(0xFF21262D);
  static const _inactiveTabColor = Color(0xFF0D1117);
  static const _activeTextColor = Color(0xFFE6EDF3);
  static const _inactiveTextColor = Color(0xFF6E7681);
  static const _borderColor = Color(0xFF30363D);
  static const _connectedColor = Color(0xFF3FB950);
  static const _disconnectedColor = Color(0xFFF85149);
  static const _activeAccent = Color(0xFF58A6FF);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      decoration: const BoxDecoration(
        color: _bgColor,
        border: Border(bottom: BorderSide(color: _borderColor, width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: tabs.length,
              itemBuilder: (context, index) =>
                  _buildTab(context, tabs[index], index == activeIndex, index),
            ),
          ),
          _buildAddButton(),
        ],
      ),
    );
  }

  Widget _buildTab(
    BuildContext context,
    TerminalTab tab,
    bool isActive,
    int index,
  ) {
    return GestureDetector(
      onTap: () => onTabTap(index),
      child: Container(
        constraints: const BoxConstraints(minWidth: 90, maxWidth: 160),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isActive ? _activeTabColor : _inactiveTabColor,
          border: Border(
            right: const BorderSide(color: _borderColor, width: 1),
            top: BorderSide(
              color: isActive ? _activeAccent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Listening, not reading `tab.isConnected` during build.
            //
            // `TerminalTab.isConnected` is a snapshot of the session's
            // status at build time, and NOTHING rebuilds this strip when
            // that status changes: `tabsProvider` only emits when tabs are
            // added, removed or activated, so a tab that connected
            // successfully kept a red dot until some unrelated event
            // happened to rebuild it. A red dot on a working session is a
            // lie, and it was on screen for every single connect.
            //
            // Same shape as the agent badge below, for the same reason:
            // the value lives on the session, so the session is what has
            // to be listened to.
            ValueListenableBuilder<ConnectionStatus>(
              valueListenable: tab.session.statusNotifier,
              builder: (context, status, _) {
                // Only `connected` is a working session. `connecting` and
                // `error` must not read as one.
                final isConnected = status == ConnectionStatus.connected;
                return Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isConnected ? _connectedColor : _disconnectedColor,
                    boxShadow: isConnected
                        ? [
                            BoxShadow(
                              color: _connectedColor.withValues(alpha: 0.5),
                              blurRadius: 4,
                              spreadRadius: 0,
                            ),
                          ]
                        : null,
                  ),
                );
              },
            ),
            // Agent state, glanceable without opening the drawer — the
            // point of putting it here at all.
            //
            // Listening (rather than reading `tab.session` state during
            // build) is also what ARMS the session's agent poll: it only
            // queries the host while something is actually observing, so
            // this builder is both the consumer and the trigger. See
            // TerminalSession._syncAgentPolling.
            ValueListenableBuilder<AgentSnapshot>(
              valueListenable: tab.session.agentsNotifier,
              builder: (context, snapshot, _) {
                final state = mostUrgentAgentState(snapshot);
                // Null for every snapshot nobody measured — an unsupported
                // multiplexer, an unreachable agent server, or a session
                // that has not been asked yet. A badge is a positive claim
                // about the host; drawing one there would assert a state
                // helm does not have.
                if (state == null) return const SizedBox.shrink();
                return AgentBadge(state: state);
              },
            ),
            Flexible(
              child: Text(
                tab.title,
                style: TextStyle(
                  color: isActive ? _activeTextColor : _inactiveTextColor,
                  fontSize: 12,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            GestureDetector(
              onTap: () => onTabClose(tab.id),
              child: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(
                  Icons.close,
                  size: 12,
                  color: isActive
                      ? _inactiveTextColor.withValues(alpha: 0.8)
                      : _inactiveTextColor.withValues(alpha: 0.4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddButton() {
    return GestureDetector(
      onTap: onAddTab,
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        child: const Icon(Icons.add, size: 16, color: _inactiveTextColor),
      ),
    );
  }
}
