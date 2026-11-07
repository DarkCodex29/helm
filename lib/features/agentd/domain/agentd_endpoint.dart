/// Where a `helm-agentd` daemon listens (a Tailscale or loopback address).
class AgentdEndpoint {
  const AgentdEndpoint({required this.host, this.port = defaultPort});

  /// The daemon's default port (`helm-agentd --port`).
  static const defaultPort = 7480;

  final String host;
  final int port;

  /// `ws://host:port` (an IPv6 literal is bracketed by [Uri]).
  Uri get uri => Uri(scheme: 'ws', host: host, port: port);

  @override
  bool operator ==(Object other) =>
      other is AgentdEndpoint && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => 'AgentdEndpoint($host:$port)';
}
