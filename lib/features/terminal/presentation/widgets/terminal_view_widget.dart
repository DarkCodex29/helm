import 'package:flutter/material.dart';
import 'package:helm/core/host/host_advisory.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/core/theme/app_theme.dart';
import 'package:helm/core/theme/terminal_theme.dart';
import 'package:helm/features/connection/data/known_hosts_service.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/domain/advisory_surface_bounds.dart';
import 'package:helm/features/terminal/presentation/widgets/host_advisory_card.dart';
import 'package:helm/features/terminal/presentation/widgets/host_key_migration_card.dart';
import 'package:helm/features/terminal/presentation/widgets/host_key_type_card.dart';
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
    // No attachViewport() here on purpose.
    //
    // The window it would cover — "a size is not known yet, so wait for
    // one" — opens when the session is CREATED, which is before this
    // widget exists: TabsNotifier.addTab only schedules the rebuild that
    // mounts this view, then dials immediately. addTab therefore owns the
    // announcement (see the comment there), and by the time initState runs
    // a size is either already recorded or about to be, so a second
    // announcement here would change nothing that any test could observe.
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
    // Releases a connect() still parked waiting for this view's first
    // size — a tab closed mid-connect must not leave one waiting.
    widget.session.detachViewport();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The Stack's own height is what bounds the advisory surface, and a
    // Positioned child cannot see it — its vertical constraint is
    // unbounded, which is precisely how the card grew to 931pt unnoticed.
    // Reading it here is what makes the cap a real number.
    return LayoutBuilder(
      builder: (context, constraints) =>
          _buildStack(context, constraints.maxHeight),
    );
  }

  /// The advisory surface, wired to the session that owns both the
  /// findings and the record of which ones the user dismissed.
  ///
  /// Shared by both call sites deliberately. They render in different
  /// places — one over a live terminal, one inside the failure overlay —
  /// but they are the same surface showing the same findings, and a
  /// dismissal on either must mean the same thing. Two hand-wired copies
  /// is how they would drift.
  Widget _advisorySurface({required double maxHeight}) {
    return ValueListenableBuilder<List<HostAdvisory>>(
      valueListenable: widget.session.advisoriesNotifier,
      builder: (context, advisories, _) {
        if (advisories.isEmpty) return const SizedBox.shrink();
        return ValueListenableBuilder<Set<String>>(
          valueListenable: widget.session.dismissedAdvisoriesNotifier,
          builder: (context, dismissed, _) => HostAdvisoryCard(
            advisories: advisories,
            dismissed: dismissed,
            maxHeight: maxHeight,
            onDismiss: widget.session.dismissAdvisory,
          ),
        );
      },
    );
  }

  Widget _buildStack(BuildContext context, double areaHeight) {
    return Stack(
      children: [
        // No LayoutBuilder, and no hand-computed column/row count.
        //
        // This used to divide the incoming constraints by a hardcoded
        // 7.8x16.0 cell and push THAT at the session. It was a second,
        // disagreeing source of truth: measured on an iPhone 17 Pro it
        // produced 51x31 while xterm — laying the same area out with the
        // real font metrics it actually renders with — produced 51x29. Two
        // rows of the remote's output had nowhere to go.
        //
        // TerminalView already resizes the Terminal from those real
        // metrics during layout, and TerminalSession now listens to that
        // from its constructor, so the size the renderer computed is the
        // size the remote is told. One source of truth, no estimate.
        TerminalView(
          widget.session.terminal,
          theme: HelmTerminalTheme.monokai,
          // Named fonts only, and every one of them resolvable at first
          // paint. There is no `fontFamily: 'JetBrainsMono'` here any more:
          // it was declared for two years against a `pubspec.yaml` with no
          // `fonts:` section and no `assets/` directory, so it resolved to
          // nothing and fell silently through to this same list. The app
          // was already running on Menlo/Monaco/monospace; only the code
          // claimed otherwise.
          //
          // Runtime-fetching it through `google_fonts` — which is already a
          // dependency and does exactly that for Inter — is NOT the fix
          // here, and the asymmetry is deliberate. Inter dresses UI text,
          // where a late swap reflows a label. This font is measured:
          // TerminalView derives the cell from it and the session pushes
          // those dimensions at the remote PTY (see the comment above this
          // widget). A font arriving after first paint would resize the
          // remote mid-session, which is the failure 62565f3 exists to
          // prevent.
          //
          // Bundling the real face is a legitimate upgrade — it just has to
          // be an asset, so the metrics are right on the first frame rather
          // than the first successful download.
          textStyle: const TerminalStyle(
            fontFamilyFallback: ['Menlo', 'Monaco', 'Courier New', 'monospace'],
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
        ),
        // Host findings on a session that is otherwise working.
        //
        // Shown here rather than only in the failure overlay below,
        // because that overlay exists only while disconnected. A
        // substitution on a session that connects fine would otherwise
        // never be seen: it is written to the terminal too, but the
        // multiplexer clears the screen as it attaches — verified against
        // a real tmux host.
        //
        // Anchored to the BOTTOM, not the top, and that is a fix rather
        // than a preference. herdr draws its own status bar on the
        // terminal's first two rows — captured from the live host: row 1
        // is the workspace/tab line and row 2 reads `1 blocked` when an
        // agent is blocked, which `pane list` corroborates by reporting 18
        // viewport rows out of 20. `top: 8` therefore put this card
        // squarely over the agent state helm exists to surface. The shell
        // itself flows downward from row 3, so the bottom edge is the one
        // place a fixed overlay covers least at rest.
        Positioned(
          left: 0,
          right: 0,
          bottom: 8,
          child: ValueListenableBuilder<ConnectionStatus>(
            valueListenable: widget.session.statusNotifier,
            builder: (context, status, _) {
              if (status != ConnectionStatus.connected) {
                return const SizedBox.shrink();
              }
              return _advisorySurface(
                maxHeight: advisorySurfaceMaxHeight(areaHeight),
              );
            },
          ),
        ),
        ValueListenableBuilder(
          valueListenable: widget.session.statusNotifier,
          builder: (context, status, _) {
            if (widget.session.isConnected) return const SizedBox.shrink();

            final isConnecting = status == ConnectionStatus.connecting;

            return ValueListenableBuilder<
              HostKeyAuthorizationRequiredException?
            >(
              valueListenable: widget.session.hostKeyAuthorizationNotifier,
              builder: (context, authorization, _) {
                // A host key waiting to be authorized takes this overlay
                // over completely — see the `authorization != null` branch
                // below for why it replaces the reconnect block rather than
                // sitting beside it.
                final awaitingTrustDecision = authorization != null;

                return Positioned.fill(
                  // `explicitChildNodes` keeps the reconnect button a node of
                  // its own instead of being folded into this overlay node,
                  // so both identifiers stay addressable at the same time.
                  child: Semantics(
                    identifier: TerminalSemantics.connectionStatusOverlay,
                    container: true,
                    explicitChildNodes: true,
                    child: GestureDetector(
                      // Tap-to-reconnect is suppressed while a trust decision
                      // is open. It would dial straight back into the same
                      // refusal, and — worse — would let an accidental touch
                      // stand in for an answer to a security question.
                      onTap: isConnecting || awaitingTrustDecision
                          ? null
                          : () => widget.session.reconnect(),
                      child: Container(
                        decoration: const BoxDecoration(color: AppTheme.scrim),
                        // The overlay fills the terminal area, and that area
                        // is not always tall enough for this column: the
                        // on-screen keyboard, a small device, or landscape can
                        // all leave it well under the ~200px the disconnected
                        // layout wants. Overflow paints yellow-and-black
                        // stripes over the message explaining the failure,
                        // which is the opposite of degrading quietly.
                        //
                        // A scroll view rather than a clip because the message
                        // must stay READABLE when it does not fit, not merely
                        // stop complaining. `shrinkWrap`-like behaviour is
                        // implicit: with room to spare the Center still
                        // centers the intrinsic-height column, so the layout
                        // is byte-for-byte unchanged in the common case.
                        //
                        // A SingleChildScrollView claims the drag gesture, not
                        // the tap, so the tap-to-reconnect GestureDetector
                        // wrapping this still fires — pinned by a test.
                        child: SingleChildScrollView(
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
                                      color: AppTheme.primary,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  const Text(
                                    'Connecting…',
                                    style: TextStyle(
                                      color: AppTheme.primary,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ] else if (authorization != null) ...[
                                  // Shown INSTEAD of the reconnect block, not
                                  // above it. Reconnecting without answering
                                  // fails on the very check this prompt exists
                                  // to settle, so offering both would put a
                                  // button next to the question that quietly
                                  // ignores it.
                                  //
                                  // The switch is over a sealed hierarchy, so
                                  // a gate added later cannot reach this
                                  // overlay without being given copy of its
                                  // own — the compiler refuses to let it
                                  // inherit someone else's explanation.
                                  switch (authorization) {
                                    HostKeyMigrationRequiredException() =>
                                      HostKeyMigrationCard(
                                        migration: authorization,
                                        username:
                                            widget.session.profile.username,
                                        onTrust: () => widget.session
                                            .trustHostKeyAndReconnect(),
                                        onCancel: widget
                                            .session
                                            .declineHostKeyAuthorization,
                                      ),
                                    HostKeyTypeAuthorizationRequiredException() =>
                                      HostKeyTypeCard(
                                        authorization: authorization,
                                        username:
                                            widget.session.profile.username,
                                        onTrust: () => widget.session
                                            .trustHostKeyAndReconnect(),
                                        onCancel: widget
                                            .session
                                            .declineHostKeyAuthorization,
                                      ),
                                  },
                                ] else ...[
                                  Container(
                                    width: 64,
                                    height: 64,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(16),
                                      color: AppTheme.surfaceVariant,
                                      border: Border.all(
                                        color: AppTheme.error.withValues(
                                          alpha: 0.4,
                                        ),
                                      ),
                                    ),
                                    child: const Icon(
                                      Icons.wifi_off,
                                      color: AppTheme.error,
                                      size: 32,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  const Text(
                                    'Connection lost',
                                    style: TextStyle(
                                      color: AppTheme.onBackground,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  // WHICH host, then WHY. Without the first
                                  // line a user cannot tell a failing server
                                  // from a profile pointing somewhere that
                                  // stopped existing — the two look identical
                                  // from here, and one of them has already
                                  // cost an evening of blaming a working VPN.
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 320,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 24,
                                      ),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            '${widget.session.profile.username}'
                                            '@${widget.session.profile.host}'
                                            ':${widget.session.profile.port}',
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                              color: AppTheme.onSurface,
                                              fontSize: 12,
                                              fontFamily: 'monospace',
                                            ),
                                          ),
                                          ValueListenableBuilder<String?>(
                                            valueListenable: widget
                                                .session
                                                .lastFailureNotifier,
                                            builder: (context, failure, _) {
                                              // Absent rather than blank when
                                              // nothing is known: an empty
                                              // line under the host reads as
                                              // a reason that failed to load.
                                              if (failure == null) {
                                                return const SizedBox.shrink();
                                              }
                                              return Padding(
                                                padding: const EdgeInsets.only(
                                                  top: 8,
                                                ),
                                                child: Text(
                                                  failure,
                                                  textAlign: TextAlign.center,
                                                  style: const TextStyle(
                                                    color:
                                                        AppTheme.onSurfaceMuted,
                                                    fontSize: 13,
                                                    height: 1.4,
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  const Text(
                                    'Tap to reconnect',
                                    style: TextStyle(
                                      color: AppTheme.onSurfaceFaint,
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
                                    identifier:
                                        TerminalSemantics.reconnectButton,
                                    container: true,
                                    child: ElevatedButton.icon(
                                      onPressed: () =>
                                          widget.session.reconnect(),
                                      icon: const Icon(Icons.refresh, size: 16),
                                      label: const Text('Reconnect'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppTheme.primary,
                                        foregroundColor: AppTheme.background,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 20,
                                          vertical: 10,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
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
                                  Padding(
                                    padding: const EdgeInsets.only(top: 24),
                                    // Bounded by the same rule as the
                                    // connected surface. This one already sits
                                    // in a scroll view, so it cannot clip —
                                    // but an uncapped card here would push the
                                    // reconnect button off the top of a short
                                    // terminal, which is the same failure
                                    // wearing a different hat.
                                    child: _advisorySurface(
                                      maxHeight: advisorySurfaceMaxHeight(
                                        areaHeight,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ],
    );
  }
}
