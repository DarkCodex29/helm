import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/agentd/data/agentd_providers.dart';
import 'package:helm_protocol/helm_protocol.dart' as proto;

/// The `ask`s the agent of one profile has open right now, oldest first.
///
/// The shared [AgentdClient] owns the snapshot (`ask` adds, `ask_resolved`
/// removes, `ready` clears because the daemon replays every open ask right
/// after it). This provider emits that snapshot immediately and then
/// follows its changes, so a banner mounted late (another tab was active
/// when the ask came) still lists it.
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
        final sub = client.openAsksChanges.listen((l) {
          if (!out.isClosed) out.add(l);
        });
        ref.onDispose(sub.cancel);
      }().catchError((Object _) {
        if (!out.isClosed) out.add(const []);
      });
      return out.stream;
    });
