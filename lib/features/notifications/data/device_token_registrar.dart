import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/utils/logger.dart';

/// How a registration attempt ended.
///
/// Four outcomes rather than a `bool` because they are answers to
/// different questions, and the caller logs them differently:
/// [rejectedLocally] means this app refused to send, [hostRefused] means
/// the Mac ran the script and it failed, and [transportFailed] means the
/// script never arrived. Collapsing them would make "the token is
/// malformed" and "the Wi-Fi dropped" indistinguishable in a log.
enum TokenRegistrationOutcome {
  /// The Mac merged this token into `~/helm-notifier/device-tokens.json`.
  registered,

  /// The token failed validation here. NOTHING was sent to the host.
  rejectedLocally,

  /// The host ran the script and it did not succeed — no `python3`, a
  /// read-only home directory, or a script that timed out.
  hostRefused,

  /// The command never completed: the transport threw.
  transportFailed,
}

/// The heredoc delimiter carrying the token to the host.
///
/// Exported because the test suite asserts a token can never contain a
/// line equal to it — see [DeviceTokenRegistrar] for why that is the one
/// thing that matters about this string. The random-looking suffix is not
/// security, it is collision avoidance: it must not appear in ordinary
/// shell output either.
const String kTokenHeredocDelimiter = 'HELM_DEVICE_TOKEN_9F41C7';

/// The delimiter carrying the merge program.
const String kMergeHeredocDelimiter = 'HELM_TOKEN_MERGE_9F41C7';

/// The longest token this app will forward.
///
/// A real FCM registration token is around 163 characters. This is a
/// generous ceiling on that, not a measurement of it — its job is to stop
/// an unbounded string being written into a file on someone's Mac, not to
/// validate FCM's format.
const int kMaxDeviceTokenLength = 4096;

/// Every character an FCM registration token is made of.
///
/// FCM tokens are URL-safe base64 with a `:` separating the instance-ID
/// half from the rest, so this allowlist is a superset of the real shape
/// and still excludes every shell metacharacter — critically including
/// the newline, which is the ONLY character that can end the heredoc.
final RegExp _tokenShape = RegExp(r'^[A-Za-z0-9_:.-]+$');

/// How long the host gets to merge the token before we give up on it.
///
/// The registration runs on the connect path, so an unbounded wait would
/// let a wedged host hold up the thing the user actually asked for. Ten
/// seconds is far more than a `mkdir` plus a small JSON rewrite needs.
const Duration kTokenRegistrationTimeout = Duration(seconds: 10);

/// Teaches the Mac which device to push to, over the SSH connection that
/// is already open.
///
/// ## Why this goes over `runScript` and not `run`
///
/// The token is a string this app received from Google and is about to
/// put into a shell on someone's machine. [HostCommandRunner.run] builds
/// a command LINE, so anything placed in it is parsed by the remote
/// shell; [HostCommandRunner.runScript] writes bytes to the stdin of a
/// fixed `/bin/sh -s` and never requests a PTY, which is the seam
/// `ssh_host_command_runner.dart:27-29` exists to provide.
///
/// That is necessary and NOT sufficient, because the script itself is
/// still shell code — putting the token in it as `TOKEN='...'` would
/// simply move the injection one layer in. So the token crosses as the
/// body of a heredoc whose delimiter is QUOTED, which performs no
/// expansion of any kind.
///
/// Measured against `/bin/sh` on macOS, with the token delivered exactly
/// as below: `'`, `"`, `` ` ``, `$(whoami)` and `;` all land in the file
/// byte-for-byte, unexecuted.
///
/// ## Why there is an allowlist as well
///
/// A quoted heredoc has exactly one exit: a line consisting of the
/// delimiter. That is not theoretical — it was reproduced against
/// `/bin/sh`, where a token containing
/// `"benign\n$kTokenHeredocDelimiter\necho pwned"` ran `echo pwned`. A
/// newline in the token is the only way to author that line, so
/// [_tokenShape] excludes it, and everything else that is not in a real
/// token, before a single byte is sent.
///
/// Two independent layers, deliberately: the heredoc means a token that
/// slips the allowlist is still inert, and the allowlist means a future
/// change to the delivery mechanism cannot quietly re-arm the metacharacters.
///
/// ## Why nothing here can fail a connection
///
/// Every path returns a [TokenRegistrationOutcome]; none throws. A push
/// registration that breaks terminal attach is strictly worse than no
/// push at all — the user opened helm to reach their Mac, not to receive
/// notifications about it.
class DeviceTokenRegistrar {
  const DeviceTokenRegistrar();

  static final _log = HelmLogger('DeviceTokenRegistrar');

  /// Merges [token] into the Mac's device list over [runner].
  ///
  /// Idempotent by construction: the merge program adds the token only
  /// when it is not already present, so re-registering on every reconnect
  /// costs one round trip and changes nothing.
  Future<TokenRegistrationOutcome> register({
    required String token,
    required HostCommandRunner runner,
  }) async {
    if (!isRegisterableToken(token)) {
      // Deliberately does not log the token. It is a device credential:
      // anyone holding it can push notifications to this phone.
      _log.w('Refusing to register a token that failed validation');
      return TokenRegistrationOutcome.rejectedLocally;
    }

    try {
      final result = await runner.runScript(
        buildTokenRegistrationScript(token),
        timeout: kTokenRegistrationTimeout,
      );

      // A timed-out result carries a null exit code. Reading "not
      // non-zero" as success would claim a registration that may never
      // have run at all.
      if (result.timedOut || result.exitCode != 0) {
        _log.w(
          'Host refused device token registration '
          '(exit ${result.exitCode}, timedOut ${result.timedOut}): '
          '${result.stderr.trim()}',
        );
        return TokenRegistrationOutcome.hostRefused;
      }

      _log.i('Device token registered with the host');
      return TokenRegistrationOutcome.registered;
    } catch (e) {
      _log.w('Device token registration failed on the transport: $e');
      return TokenRegistrationOutcome.transportFailed;
    }
  }

  /// Whether [token] is safe and plausible enough to send.
  ///
  /// The delimiter check is not redundant with [_tokenShape], and that is
  /// worth stating because it looks like it should be. Both delimiters are
  /// made only of `[A-Za-z0-9_]`, so a token equal to one PASSES the
  /// allowlist. It would then close its own heredoc on the first body
  /// line: the token file is written empty, the next line is parsed as a
  /// command, and `set -eu` aborts. Not an injection — the shell never
  /// receives anything the sender chose — but a registration that reports
  /// a host failure for a reason nobody could find. Cheaper to exclude.
  static bool isRegisterableToken(String token) =>
      token.isNotEmpty &&
      token.length <= kMaxDeviceTokenLength &&
      _tokenShape.hasMatch(token) &&
      !token.contains(kTokenHeredocDelimiter) &&
      !token.contains(kMergeHeredocDelimiter);
}

/// The script that merges [token] into `~/helm-notifier/device-tokens.json`.
///
/// Built as a separate function so the test suite can run the real thing
/// through a real `/bin/sh` against a throwaway `HOME`. Asserting on this
/// string would only be testing a string; the behaviour that matters —
/// that another device's token survives, that the same token does not
/// duplicate — lives in the program below, not in Dart.
///
/// ### Why the merge is Python and not shell
///
/// The file is JSON, and `fcm.py` reads it with `json.load`. Rewriting
/// JSON with `sed` would work until a token or a path contained something
/// the pattern did not expect. `python3` is already a hard dependency of
/// the thing being configured: `~/helm-notifier/fcm.py` runs under
/// `/usr/bin/python3` from its LaunchAgent. A host without it returns
/// [TokenRegistrationOutcome.hostRefused], which is the honest answer —
/// that host cannot run the notifier either.
///
/// ### Why the token reaches Python through a file
///
/// Python's own stdin is taken by the program text (`python3 -`), and
/// passing the token as an argument would put it back on a shell command
/// line — the exact thing this whole design avoids. So it crosses in a
/// quoted heredoc to a temp file, and Python reads that path. The temp
/// file is removed by an `EXIT` trap rather than a trailing `rm`, so a
/// failure part-way through cannot leave a device credential on disk.
///
/// ### The write is atomic, the read-modify-write is not
///
/// `os.replace` means a reader never sees a half-written file. Two
/// devices registering in the same instant could still lose one token,
/// and that is accepted: the loser re-registers on its next connect or
/// token refresh, and locking a file to protect a list of at most a few
/// strings would cost more than the failure does.
String buildTokenRegistrationScript(String token) {
  return '''
set -eu
dir="\$HOME/helm-notifier"
mkdir -p "\$dir"
tmp="\$dir/.helm-device-token.\$\$"
trap 'rm -f "\$tmp"' EXIT
cat > "\$tmp" <<'$kTokenHeredocDelimiter'
$token
$kTokenHeredocDelimiter
python3 - "\$dir/device-tokens.json" "\$tmp" <<'$kMergeHeredocDelimiter'
import json, os, sys

target, token_file = sys.argv[1], sys.argv[2]

with open(token_file) as handle:
    token = handle.read().strip()

# An unreadable file is repaired rather than obeyed. Refusing to write
# would wedge registration permanently on bytes nobody can use, and the
# token in hand is worth more than a file that no longer parses.
tokens = []
if os.path.exists(target):
    try:
        with open(target) as handle:
            loaded = json.load(handle)
        if isinstance(loaded, dict):
            tokens = [t for t in loaded.get("tokens", []) if isinstance(t, str)]
    except (ValueError, OSError):
        tokens = []

if token and token not in tokens:
    tokens.append(token)

staging = target + ".helm-new"
with open(staging, "w") as handle:
    json.dump({"tokens": tokens}, handle)
os.replace(staging, target)
$kMergeHeredocDelimiter
''';
}
