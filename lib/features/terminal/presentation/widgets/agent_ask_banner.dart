import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/core/theme/app_theme.dart';
import 'package:helm/features/agentd/data/agentd_asks.dart';
import 'package:helm/features/agentd/data/agentd_client.dart';
import 'package:helm/features/agentd/data/agentd_providers.dart';
import 'package:helm/features/agentd/domain/agentd_connection_state.dart';
import 'package:helm_protocol/helm_protocol.dart' as proto;

/// Lets the phone answer the agent's open `ask` (confirm / select).
///
/// Shows the FIRST open ask of [profileId] and a "+N more" count. `input`
/// and `editor` asks need a keyboard and a real editor, so they only say so
/// and offer Cancel: they are answered on the Mac.
///
/// First answer wins, decided by the daemon: if another device answered
/// first, the row simply disappears when its `ask_resolved` frame arrives
/// (no error is shown). Any other failure re-enables the buttons.
///
/// No timer here: the daemon owns the ask's lifetime and tells us when it
/// is over.
class AgentAskBanner extends ConsumerStatefulWidget {
  const AgentAskBanner({super.key, required this.profileId});

  final String profileId;

  @override
  ConsumerState<AgentAskBanner> createState() => _AgentAskBannerState();
}

class _AgentAskBannerState extends ConsumerState<AgentAskBanner> {
  /// Asks with an answer in flight: their buttons are disabled.
  final _sending = <String>{};

  /// Asks whose last send failed (not by `ask_resolved`).
  final _failed = <String>{};

  bool _isOpen(String id) {
    final asks = ref.read(agentdAsksProvider(widget.profileId)).valueOrNull;
    return asks != null && asks.any((a) => a.requestId == id);
  }

  Future<void> _answer(
    proto.AskMessage ask, {
    String? value,
    bool? confirmed,
    bool cancelled = false,
  }) async {
    final id = ask.requestId;
    if (!_sending.add(id)) return; // a double tap sends nothing more
    setState(() => _failed.remove(id));
    try {
      final client = await ref.read(
        agentdClientProvider(widget.profileId).future,
      );
      if (client == null) throw StateError('no agentd client');
      await client.answer(
        id,
        value: value,
        confirmed: confirmed,
        cancelled: cancelled,
      );
      if (!mounted) return;
      setState(() => _sending.remove(id));
    } on AgentdCommandException catch (e) {
      if (!mounted) return;
      // Someone else answered first: the ask_resolved frame removes the row.
      setState(() {
        _sending.remove(id);
        if (e.code != 'ask_resolved' && _isOpen(id)) _failed.add(id);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sending.remove(id);
        // A late failure for an ask that is gone must not leave state behind.
        if (_isOpen(id)) _failed.add(id);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected =
        ref.watch(agentdClientStatesProvider(widget.profileId)).valueOrNull
            is AgentdConnected;
    final asksValue = ref.watch(agentdAsksProvider(widget.profileId));
    final asks = asksValue.valueOrNull ?? const <proto.AskMessage>[];
    if (asksValue.hasValue) {
      // Forget marks of asks that are gone (derived state, no rebuild).
      final open = {for (final a in asks) a.requestId};
      _sending.removeWhere((id) => !open.contains(id));
      _failed.removeWhere((id) => !open.contains(id));
    }
    if (!connected || asks.isEmpty) return const SizedBox.shrink();

    final ask = asks.first;
    final busy = _sending.contains(ask.requestId);
    final macOnly = ask.method != 'confirm' && ask.method != 'select';

    return Semantics(
      identifier: AgentAskSemantics.banner,
      container: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: AppTheme.surfaceVariant,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.primary),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    identifier: AgentAskSemantics.header,
                    header: true,
                    child: const Text(
                      'Agent needs you',
                      style: TextStyle(
                        color: AppTheme.primary,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
                if (asks.length > 1)
                  Semantics(
                    identifier: AgentAskSemantics.more,
                    child: Text(
                      '+${asks.length - 1} more',
                      style: const TextStyle(
                        color: AppTheme.onSurface,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              ask.title,
              style: const TextStyle(
                color: AppTheme.onBackground,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
            if (ask.message != null && ask.message!.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                ask.message!,
                style: const TextStyle(color: AppTheme.onSurface, fontSize: 13),
              ),
            ],
            const SizedBox(height: 8),
            if (macOnly)
              Semantics(
                identifier: AgentAskSemantics.macHint,
                child: const Text(
                  'Answer this on the Mac',
                  style: TextStyle(color: AppTheme.onSurface, fontSize: 13),
                ),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (ask.method == 'confirm') ...[
                  _action(
                    AgentAskSemantics.confirmButton,
                    'Confirm',
                    busy ? null : () => _answer(ask, confirmed: true),
                    primary: true,
                  ),
                  _action(
                    AgentAskSemantics.declineButton,
                    'Decline',
                    busy ? null : () => _answer(ask, confirmed: false),
                  ),
                ],
                if (ask.method == 'select')
                  for (final (i, option) in (ask.options ?? const []).indexed)
                    _action(
                      AgentAskSemantics.option(i),
                      option,
                      busy ? null : () => _answer(ask, value: option),
                      primary: true,
                    ),
                _action(
                  AgentAskSemantics.cancelButton,
                  'Cancel',
                  busy ? null : () => _answer(ask, cancelled: true),
                ),
              ],
            ),
            if (_failed.contains(ask.requestId))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Semantics(
                  identifier: AgentAskSemantics.sendError,
                  liveRegion: true,
                  child: const Text(
                    'Could not send, try again',
                    style: TextStyle(color: AppTheme.error, fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _action(
    String id,
    String label,
    VoidCallback? onPressed, {
    bool primary = false,
  }) {
    return Semantics(
      identifier: id,
      child: primary
          ? ElevatedButton(
              onPressed: onPressed,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: AppTheme.background,
                minimumSize: const Size(64, 48),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: Text(label),
            )
          : TextButton(
              onPressed: onPressed,
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.onSurface,
                minimumSize: const Size(64, 48),
              ),
              child: Text(label, style: const TextStyle(fontSize: 13)),
            ),
    );
  }
}
