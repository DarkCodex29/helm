import 'package:flutter/material.dart';
import 'package:helm/core/host/host_advisory.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/core/theme/terminal_theme.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/presentation/widgets/host_advisory_card.dart';
import 'package:xterm/xterm.dart';

class HelmTerminalView extends StatefulWidget {
  const HelmTerminalView({
    super.key,
    required this.session,
    this.isActive = false,
  });

  final TerminalSession session;
  final bool isActive;

  @override
  State<HelmTerminalView> createState() => _HelmTerminalViewState();
}

class _HelmTerminalViewState extends State<HelmTerminalView> {
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    if (widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(HelmTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _focusNode.requestFocus();
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            const double charWidth = 7.8;
            const double charHeight = 16.0;
            final cols = (constraints.maxWidth / charWidth).floor().clamp(
              20,
              300,
            );
            final rows = (constraints.maxHeight / charHeight).floor().clamp(
              5,
              200,
            );

            WidgetsBinding.instance.addPostFrameCallback((_) {
              widget.session.onResize(cols, rows);
            });

            return TerminalView(
              widget.session.terminal,
              theme: HelmTerminalTheme.monokai,
              textStyle: const TerminalStyle(
                fontFamily: 'JetBrainsMono',
                fontFamilyFallback: [
                  'Menlo',
                  'Monaco',
                  'Courier New',
                  'monospace',
                ],
                fontSize: 13,
              ),
              hardwareKeyboardOnly: true,
              focusNode: _focusNode,
              autofocus: widget.isActive,
              keyboardType: TextInputType.visiblePassword,
              keyboardAppearance: Brightness.dark,
              deleteDetection: true,
              backgroundOpacity: 1.0,
              simulateScroll: true,
              readOnly: false,
            );
          },
        ),
        ValueListenableBuilder(
          valueListenable: widget.session.statusNotifier,
          builder: (context, status, _) {
            if (widget.session.isConnected) return const SizedBox.shrink();

            final isConnecting = status == ConnectionStatus.connecting;

            return Positioned.fill(
              // `explicitChildNodes` keeps the reconnect button a node of
              // its own instead of being folded into this overlay node,
              // so both identifiers stay addressable at the same time.
              child: Semantics(
                identifier: TerminalSemantics.connectionStatusOverlay,
                container: true,
                explicitChildNodes: true,
                child: GestureDetector(
                  onTap: isConnecting ? null : () => widget.session.reconnect(),
                  child: Container(
                    decoration: const BoxDecoration(color: Color(0xCC0D1117)),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isConnecting) ...[
                            const SizedBox(
                              width: 36,
                              height: 36,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF58A6FF),
                              ),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'Connecting…',
                              style: TextStyle(
                                color: Color(0xFF58A6FF),
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ] else ...[
                            Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                color: const Color(0xFF21262D),
                                border: Border.all(
                                  color: const Color(
                                    0xFFF85149,
                                  ).withValues(alpha: 0.4),
                                ),
                              ),
                              child: const Icon(
                                Icons.wifi_off,
                                color: Color(0xFFF85149),
                                size: 32,
                              ),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'Connection lost',
                              style: TextStyle(
                                color: Color(0xFFE6EDF3),
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Tap to reconnect',
                              style: TextStyle(
                                color: Color(0xFF8B949E),
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 24),
                            // `container` is required here. Without it the
                            // identifier is absorbed by the overlay's own
                            // tappable node, which also swallows the two
                            // status Texts, leaving the real button as an
                            // unnamed sibling.
                            Semantics(
                              identifier: TerminalSemantics.reconnectButton,
                              container: true,
                              child: ElevatedButton.icon(
                                onPressed: () => widget.session.reconnect(),
                                icon: const Icon(Icons.refresh, size: 16),
                                label: const Text('Reconnect'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF58A6FF),
                                  foregroundColor: const Color(0xFF0D1117),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 10,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                              ),
                            ),
                            // What the host probe and diagnostics found,
                            // rendered here rather than on a surface of
                            // its own: these findings exist to explain
                            // the failure the user is already looking at.
                            // Absent entirely when there is nothing to
                            // report, which is the healthy case.
                            ValueListenableBuilder<List<HostAdvisory>>(
                              valueListenable:
                                  widget.session.advisoriesNotifier,
                              builder: (context, advisories, _) {
                                if (advisories.isEmpty) {
                                  return const SizedBox.shrink();
                                }
                                return Padding(
                                  padding: const EdgeInsets.only(top: 24),
                                  child: HostAdvisoryCard(
                                    advisories: advisories,
                                  ),
                                );
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
