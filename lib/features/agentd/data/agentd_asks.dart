import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/agentd/data/agentd_providers.dart';
import 'package:helm_protocol/helm_protocol.dart' as proto;

/// The `ask`s the agent of one profile has open right now, oldest first.
///
/// Folded from the client's message stream:
/// * `ask` adds (or replaces, by request id);
/// * `ask_resolved` removes (whoever answered, or the daemon cleared it);
/// * `ready` clears, because the daemon re-sends every still-open ask right
///   after `ready` on each new socket, so a reconnect never leaves ghosts
///   nor duplicates;
/// * everything else is ignored.
///
/// This provider never connects. It keeps [agentdClientStatesProvider]
/// alive, which owns the single connection of the profile, so listeners of
/// both still share one client and one socket.
final agentdAsksProvider = StreamProvider.autoDispose
    .family<List<proto.AskMessage>, String>((ref, profileId) {
      final out = StreamController<List<proto.AskMessage>>();
      ref.onDispose(out.close);
      ref.listen(agentdClientStatesProvider(profileId), (_, _) {});
      () async {
        final client = await ref.watch(agentdClientProvider(profileId).future);
        if (out.isClosed) return;
        if (client == null) {
          out.add(const []);
          return;
        }
        final open = <String, proto.AskMessage>{};
        void emit() {
          if (!out.isClosed) out.add(List.unmodifiable(open.values));
        }

        final sub = client.messages.listen((m) {
          switch (m) {
            case proto.ReadyMessage():
              if (open.isEmpty) return;
              open.clear();
            case proto.AskMessage():
              open[m.requestId] = m;
            case proto.AskResolvedMessage():
              if (open.remove(m.requestId) == null) return;
            default:
              return;
          }
          emit();
        });
        ref.onDispose(sub.cancel);
        emit();
      }().catchError((Object _) {
        if (!out.isClosed) out.add(const []);
      });
      return out.stream;
    });
