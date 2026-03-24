import 'package:flutter/material.dart';
import 'package:helm/features/terminal/domain/terminal_tab.dart';

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
            Container(
              width: 7,
              height: 7,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: tab.isConnected ? _connectedColor : _disconnectedColor,
                boxShadow: tab.isConnected
                    ? [
                        BoxShadow(
                          color: _connectedColor.withValues(alpha: 0.5),
                          blurRadius: 4,
                          spreadRadius: 0,
                        ),
                      ]
                    : null,
              ),
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
