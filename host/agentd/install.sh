#!/bin/sh
# Install helm-agentd as a per-user LaunchAgent bound to the Tailscale IP.
#
#   install.sh [--dry-run] [--load] [--host IP] [--allow-non-tailnet]
#              [--port N] [--pi PATH] [--base-dir DIR] [--plist-dir DIR]
#              [--label LABEL]
#
# Compiles the daemon (dart compile exe) into BASE/bin, renders the plist
# and prints the `launchctl bootstrap` command; it only RUNS it with --load.
# Listens on the Tailscale IPv4 (`tailscale ip -4`, must be in 100.64.0.0/10)
# or --host; 0.0.0.0 is always refused. Pi is resolved from PATH or --pi and
# written as an absolute path. Never creates, reads or prints the token, and
# never unloads an existing agent. Idempotent. BASE defaults to
# ~/.helm-agentd (or HELM_AGENTD_DIR).
set -eu

SRC=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SRC/../.." && pwd)
BASE_DIR=${HELM_AGENTD_DIR:-$HOME/.helm-agentd}
LABEL=dev.helm.agentd
PLIST_DIR=$HOME/Library/LaunchAgents
HOST=
HOST_SET=0
PORT=7480
PI=
DRY=0
LOAD=0
ALLOW_NON_TAILNET=0

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

need() { [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 64; }; }

while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY=1 ;;
    --load) LOAD=1 ;;
    --allow-non-tailnet) ALLOW_NON_TAILNET=1 ;;
    --host) need "$@"; HOST=$2; HOST_SET=1; shift ;;
    --port) need "$@"; PORT=$2; shift ;;
    --pi) need "$@"; PI=$2; shift ;;
    --base-dir) need "$@"; BASE_DIR=$2; shift ;;
    --plist-dir) need "$@"; PLIST_DIR=$2; shift ;;
    --label) need "$@"; LABEL=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done

die() { echo "$*" >&2; exit "${2:-64}"; }

case $PORT in
  ''|*[!0-9]*) die "--port needs a number from 1 to 65535" ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "--port needs a number from 1 to 65535"

# --- bind address -----------------------------------------------------------
if [ "$HOST_SET" -eq 1 ] && [ -z "$HOST" ]; then
  die "--host needs an IPv4 address (empty value given)"
fi
if [ -z "$HOST" ]; then
  command -v tailscale >/dev/null 2>&1 ||
    die "tailscale not found on PATH: install it, or pass --host IP" 69
  HOST=$(tailscale ip -4 2>/dev/null | sed -n '1p') || HOST=
  [ -n "$HOST" ] ||
    die "tailscale gave no IPv4 address: is it connected? (or pass --host IP)" 69
fi

# Canonical dotted decimal only: 4 octets, each 0 or 1-255 without leading
# zeros, no whitespace, no leading/trailing dot. The case filter runs first so
# a newline can never slip past the line-oriented grep.
bad_ip() { die "invalid IPv4 address (need canonical a.b.c.d): $(printf '%s' "$HOST" | tr -c '0-9a-zA-Z.:' '?')"; }
case $HOST in
  ''|*[!0-9.]*|.*|*.) bad_ip ;;
esac
printf '%s\n' "$HOST" |
  grep -Eq '^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$' || bad_ip
set -f
oldifs=$IFS; IFS=.
set -- $HOST
IFS=$oldifs
[ $# -eq 4 ] || bad_ip
for octet in "$@"; do
  [ "$octet" -le 255 ] || bad_ip
done
# expr exits 1 when the result is 0, which set -e would turn into a silent death.
A=$(expr "$1" + 0 || true)
B=$(expr "$2" + 0 || true)
[ "$HOST" != "0.0.0.0" ] && [ "$A" -ne 0 ] ||
  die "refusing $HOST: the daemon must never listen on all interfaces"
if [ "$A" -eq 100 ] && [ "$B" -ge 64 ] && [ "$B" -le 127 ]; then
  :  # Tailscale CGNAT range 100.64.0.0/10
elif [ "$A" -eq 127 ]; then
  :  # loopback
elif [ "$ALLOW_NON_TAILNET" -eq 1 ]; then
  :
else
  die "refusing $HOST: not in the Tailscale range 100.64.0.0/10 (use --allow-non-tailnet to override)"
fi

# --- pi ---------------------------------------------------------------------
if [ -z "$PI" ]; then
  PI=$(command -v pi 2>/dev/null) || PI=
  [ -n "$PI" ] || die "pi not found on PATH: install it, or pass --pi PATH" 69
fi
case $PI in
  /*) ;;
  *) die "--pi must be an absolute path: $PI" ;;
esac
[ -f "$PI" ] && [ -x "$PI" ] || die "pi is not an executable file: $PI" 69
PI_DIR=$(dirname "$PI")
AGENT_PATH="$PI_DIR:/usr/bin:/bin:/usr/sbin:/sbin"

INSTALL_DIR=$BASE_DIR/bin
BINARY=$INSTALL_DIR/helm-agentd
SESSION_DIR=$BASE_DIR/sessions
TOKEN_FILE=$BASE_DIR/token
PLIST="$PLIST_DIR/$LABEL.plist"

# Values end up inside sed and XML: refuse the characters that would break it,
# including newlines and any control character.
for value in "$BASE_DIR" "$LABEL" "$PI" "$PLIST_DIR" "$HOST"; do
  case $value in
    *[[:cntrl:]]*)
      die "refusing value with control characters (newline, tab, ...)" ;;
    *'|'*|*'&'*|*'<'*|*'>'*|*'\'*|*'"'*)
      die "refusing value with special characters: $value" ;;
  esac
done

COMPILE="dart compile exe $REPO/packages/helm_agentd/bin/helm_agentd.dart -o $BINARY"

render() {
  sed -e "s|__LABEL__|$LABEL|g" \
      -e "s|__BINARY__|$BINARY|g" \
      -e "s|__HOST__|$HOST|g" \
      -e "s|__PORT__|$PORT|g" \
      -e "s|__PI__|$PI|g" \
      -e "s|__SESSION_DIR__|$SESSION_DIR|g" \
      -e "s|__TOKEN_FILE__|$TOKEN_FILE|g" \
      -e "s|__BASE_DIR__|$BASE_DIR|g" \
      -e "s|__PATH__|$AGENT_PATH|g" \
      "$SRC/helm-agentd.plist.template"
}

say() { printf '%s\n' "$*"; }

if [ "$DRY" -eq 1 ]; then
  say "dry-run: nothing will be written"
  say "listen on $HOST:$PORT"
  say "pi: $PI"
  say "mkdir -p $BASE_DIR $INSTALL_DIR $SESSION_DIR (mode 0700)"
  say "$COMPILE   # then chmod 0700"
  say "render $SRC/helm-agentd.plist.template -> $PLIST (mode 0644)"
  say "pre-create $BASE_DIR/agentd.out and agentd.err (mode 0600)"
  say "token file: $TOKEN_FILE (created by the daemon on first run, never printed)"
  say "launchctl bootstrap gui/\$(id -u) \"$PLIST\"   # run only with --load"
  exit 0
fi

[ -f "$SRC/helm-agentd.plist.template" ] || die "missing plist template" 66
command -v dart >/dev/null 2>&1 || die "dart not found on PATH: needed to compile the daemon" 69

umask 077
mkdir -p "$BASE_DIR" "$INSTALL_DIR" "$SESSION_DIR"
chmod 0700 "$BASE_DIR" "$INSTALL_DIR" "$SESSION_DIR"

dart compile exe "$REPO/packages/helm_agentd/bin/helm_agentd.dart" -o "$BINARY.tmp" >&2 ||
  die "dart compile failed" 70
chmod 0700 "$BINARY.tmp"
mv "$BINARY.tmp" "$BINARY"

for f in agentd.out agentd.err; do
  : >> "$BASE_DIR/$f"
  chmod 0600 "$BASE_DIR/$f"
done

mkdir -p "$PLIST_DIR"
render > "$PLIST.tmp"
chmod 0644 "$PLIST.tmp"
mv "$PLIST.tmp" "$PLIST"

say "compiled $BINARY"
say "wrote $PLIST"
say "will listen on $HOST:$PORT"
say "token file: $TOKEN_FILE (created by the daemon on first run; never printed)"
SHOWN="launchctl bootstrap gui/$(id -u) \"$PLIST\""   # display only
if [ "$LOAD" -eq 1 ]; then
  say "running: $SHOWN"
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
else
  say "to start it, run:"
  say "  $SHOWN"
fi
