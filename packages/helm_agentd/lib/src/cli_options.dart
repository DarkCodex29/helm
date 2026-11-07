/// Command-line parsing for `helm_agentd`, kept out of `bin/` so it is
/// testable.
library;

import 'token_store.dart';

const usageText = '''
helm_agentd - drives Pi in RPC mode and serves the phone protocol.

Usage: helm_agentd [options]

  --host <addr>         Address to listen on. Default 127.0.0.1 (this machine
                        only). To reach it from your phone, pass this Mac's
                        Tailscale IP explicitly; never expose it on a public
                        interface.
  --port <n>            Port. Default 7480.
  --pi <binary>         Pi executable. Default: pi (from PATH).
  --session-dir <dir>   Directory for Pi's session files.
  --token-file <path>   Where the shared secret lives. Default
                        ~/.helm-agentd/token (created 0600 on first run; the
                        daemon refuses a file readable by group or others).
  -h, --help            Show this help.

The daemon prints the token FILE path, never the token itself.
''';

sealed class CliOptions {
  const CliOptions();
}

class CliRun extends CliOptions {
  const CliRun({
    required this.host,
    required this.port,
    required this.pi,
    required this.sessionDir,
    required this.tokenFile,
  });
  final String host;
  final int port;
  final String pi;
  final String? sessionDir;
  final String tokenFile;
}

class CliHelp extends CliOptions {
  const CliHelp();
}

class CliError extends CliOptions {
  const CliError(this.message);
  final String message;
}

CliOptions parseCliOptions(List<String> args) {
  var host = '127.0.0.1';
  var port = 7480;
  var pi = 'pi';
  String? sessionDir;
  String? tokenFile;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String? value() => i + 1 < args.length ? args[++i] : null;
    switch (a) {
      case '-h' || '--help':
        return const CliHelp();
      case '--host':
        final v = value();
        if (v == null || v.isEmpty) {
          return const CliError('--host needs a value');
        }
        host = v;
      case '--port':
        final n = int.tryParse(value() ?? '');
        if (n == null || n < 0 || n > 65535) {
          return const CliError('--port needs a number from 0 to 65535');
        }
        port = n;
      case '--pi':
        final v = value();
        if (v == null || v.isEmpty) return const CliError('--pi needs a value');
        pi = v;
      case '--session-dir':
        final v = value();
        if (v == null || v.isEmpty) {
          return const CliError('--session-dir needs a value');
        }
        sessionDir = v;
      case '--token-file':
        final v = value();
        if (v == null || v.isEmpty) {
          return const CliError('--token-file needs a value');
        }
        tokenFile = v;
      default:
        return CliError('unknown argument: $a');
    }
  }
  return CliRun(
    host: host,
    port: port,
    pi: pi,
    sessionDir: sessionDir,
    tokenFile: tokenFile ?? TokenStore.defaultPath(),
  );
}
