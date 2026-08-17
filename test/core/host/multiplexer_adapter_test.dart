import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/adapters/tmux_adapter.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';

import '../../helpers/fake_host_command_runner.dart';

/// Minimal test double proving [AgentSupport.resolve]'s non-null branch —
/// no real agent-aware adapter exists yet (herdr lands in slice 4).
class _FakeAgentAwareMultiplexer implements AgentAwareMultiplexer {
  @override
  Future<List<AgentStatus>> listAgents() async => const [];

  @override
  Future<AgentStatus?> waitForAgent(
    String target, {
    required Set<AgentState> until,
    Duration? timeout,
  }) async => null;
}

class _FakeAgentCapableAdapter implements MultiplexerAdapter {
  final _agentsImpl = _FakeAgentAwareMultiplexer();

  @override
  MultiplexerId get id => MultiplexerId.herdr;

  @override
  Set<MuxCapability> get capabilities => const {MuxCapability.agentState};

  @override
  AgentAwareMultiplexer? get agents => _agentsImpl;

  @override
  Future<MuxDetection> detect() async => const MuxDetection.notInstalled();

  @override
  Future<MuxSessionsResult> listSessions() async =>
      const MuxServerNotRunning();

  @override
  Future<bool> hasSession(String name) async => false;

  @override
  String attachCommand(String sessionName) => '';
}

void main() {
  group('MuxDetection', () {
    test('installed reports the absolute path and version', () {
      const detection = MuxDetection.installed(
        absPath: '/opt/homebrew/bin/tmux',
        version: 'tmux 3.6a',
      );

      expect(detection.installed, isTrue);
      expect(detection.absPath, '/opt/homebrew/bin/tmux');
      expect(detection.version, 'tmux 3.6a');
    });

    test('notInstalled reports no path and no version', () {
      const detection = MuxDetection.notInstalled();

      expect(detection.installed, isFalse);
      expect(detection.absPath, isNull);
      expect(detection.version, isNull);
    });
  });

  group('AgentSupport.resolve', () {
    test(
      'returns typed unsupported carrying the multiplexer id when agents is null',
      () {
        final adapter = TmuxAdapter(FakeHostCommandRunner());

        final support = AgentSupport.resolve(adapter);

        expect(support, isA<AgentSupportUnsupported>());
        expect(
          (support as AgentSupportUnsupported).muxId,
          MultiplexerId.tmux,
        );
      },
    );

    test('returns available wrapping the non-null agents when supported', () {
      final adapter = _FakeAgentCapableAdapter();

      final support = AgentSupport.resolve(adapter);

      expect(support, isA<AgentSupportAvailable>());
      expect((support as AgentSupportAvailable).agents, adapter.agents);
    });
  });
}
