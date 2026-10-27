#!/usr/bin/env bash
# Reports every value helm's Setup / Edit Profile screen asks for, verifies the
# host side is actually reachable, and optionally authorizes the device's
# public key.
#
# The private key is NEVER created here: helm generates its own Ed25519 pair in
# the device Keychain on first run and shows the public half in Setup and in
# Settings. This script only consumes that public half.
#
# Usage:
#   scripts/host_setup_report.sh                  # report only
#   scripts/host_setup_report.sh --authorize      # report, then read a pasted
#                                                 # public key from stdin
#   scripts/host_setup_report.sh --from-clipboard # report, then take the key
#                                                 # straight off the clipboard,
#                                                 # so there is nothing to paste
set -o errexit
set -o nounset
set -o pipefail

AUTHORIZE=0
FROM_CLIPBOARD=0
case "${1:-}" in
  --authorize)      AUTHORIZE=1 ;;
  --from-clipboard) AUTHORIZE=1; FROM_CLIPBOARD=1 ;;
  "")               ;;
  *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
esac

AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
HERDR_BIN="$(command -v herdr || true)"
PORT=22

say() { printf '%s\n' "$*"; }
head2() { printf '\n== %s ==\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. The four fields the Setup screen asks for
# ---------------------------------------------------------------------------
head2 "Setup fields"

# The MagicDNS NAME, never an address. README.md > Setup explains why an
# address is the wrong answer: a LAN IP dies the moment the phone leaves
# the Wi-Fi, and a Tailscale IP is stable per NODE REGISTRATION rather
# than per machine, so a reinstall or a logout/login hands out a
# different one and the profile silently points at nothing. The symptom
# reads as a network problem and is not. The name follows the node.
TS_CLI="$(command -v tailscale \
  || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)"
MAGIC_DNS=""
if [[ -x "$TS_CLI" ]]; then
  # --peers=false so this cannot pick up another machine's name.
  MAGIC_DNS="$("$TS_CLI" status --peers=false --json 2>/dev/null \
    | /usr/bin/python3 -I -c '
import json, sys
try:
    status = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
name = (status.get("Self") or {}).get("DNSName", "")
print(name.rstrip("."))
' 2>/dev/null || true)"
fi

say "Profile Name : Mac (any label you like)"
say "Port         : $PORT"
say "Username     : $(id -un)"
if [[ -n "$MAGIC_DNS" ]]; then
  say "Host         : $MAGIC_DNS"
else
  say "Host         : NO MagicDNS NAME FOUND"
  say "  -> install Tailscale on the Mac and the phone, same account"
  say "  -> do NOT substitute an address; see README.md > Setup"
fi
say ""
say "The MagicDNS name is the answer on a simulator too, not only on a"
say "phone. 127.0.0.1 happens to reach this Mac from a simulator, but it"
say "is a different path from the one every real device takes, so a setup"
say "proven that way proves nothing about the VPN it will actually use."

# ---------------------------------------------------------------------------
# 2. Is the host side actually able to serve the app?
# ---------------------------------------------------------------------------
head2 "Host readiness"

# Probed at the MagicDNS name rather than at loopback, because loopback
# can answer while Tailscale is signed out, and then the app fails with
# a timeout this report had just called healthy.
# With no MagicDNS name there is nothing worth probing. Falling back to
# loopback here would be the exact trap this script exists to avoid: it
# answers while Tailscale is signed out, so the report would say healthy
# about a path the app cannot use.
if [[ -z "$MAGIC_DNS" ]]; then
  say "sshd                     : NOT CHECKED (no MagicDNS name)"
  say "  -> sign in to Tailscale first; see docs/HOST_SETUP.md"
elif nc -z -G 5 "$MAGIC_DNS" "$PORT" >/dev/null 2>&1; then
  say "sshd over Tailscale      : REACHABLE at $MAGIC_DNS:$PORT"
else
  say "sshd over Tailscale      : UNREACHABLE at $MAGIC_DNS:$PORT"
  say "  -> Remote Login on? System Settings > General > Sharing"
  say "  -> Tailscale connected? run: tailscale status"
fi

if [[ -z "$HERDR_BIN" ]]; then
  say "herdr binary             : NOT FOUND on PATH"
else
  say "herdr binary             : $HERDR_BIN"
  if SESSIONS="$("$HERDR_BIN" session list --json 2>/dev/null)"; then
    COUNT="$(printf '%s' "$SESSIONS" | /usr/bin/python3 -I -c \
      'import json,sys; print(len(json.load(sys.stdin).get("sessions",[])))' 2>/dev/null || echo '?')"
    say "herdr sessions visible   : $COUNT"
    printf '%s' "$SESSIONS" | /usr/bin/python3 -I -c '
import json, sys
for s in json.load(sys.stdin).get("sessions", []):
    state = "running" if s.get("running") else "stopped"
    mark = " (default)" if s.get("default") else ""
    print("  - {}{}: {}".format(s.get("name", "?"), mark, state))
' 2>/dev/null || true
  else
    say "herdr sessions visible   : query FAILED (is the server running?)"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Which device keys are already authorized
# ---------------------------------------------------------------------------
head2 "Authorized device keys"

if [[ ! -f "$AUTHORIZED_KEYS" ]]; then
  say "$AUTHORIZED_KEYS does not exist yet."
else
  say "$AUTHORIZED_KEYS holds $(grep -c . "$AUTHORIZED_KEYS" || true) key(s):"
  # Fingerprint each line so two keys with the same comment stay distinguishable.
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    fp="$(printf '%s\n' "$line" | ssh-keygen -lf /dev/stdin 2>/dev/null || echo 'unparseable')"
    say "  $fp"
  done < "$AUTHORIZED_KEYS"
fi

# ---------------------------------------------------------------------------
# 4. Optionally authorize the key the app is showing
# ---------------------------------------------------------------------------
if [[ "$AUTHORIZE" -eq 0 ]]; then
  head2 "Next step"
  say "In the app: Setup screen (first run) or Settings > SSH key > copy."
  say "Then run: scripts/host_setup_report.sh --from-clipboard"
  exit 0
fi

head2 "Authorize a public key"

if [[ "$FROM_CLIPBOARD" -eq 1 ]]; then
  PASTED="$(pbpaste 2>/dev/null | tr -d '\r' | grep -m1 -E '^(ssh|ecdsa)-' || true)"
  if [[ -z "$PASTED" ]]; then
    say "REFUSED: the clipboard holds no SSH public key line."
    say "  -> in the app, open Settings > SSH key and press copy, then rerun."
    say "  -> the clipboard currently starts with:"
    pbpaste 2>/dev/null | head -c 120 | sed 's/^/     /'
    printf '\n'
    exit 1
  fi
  say "Read from the clipboard: ${PASTED:0:28}..."
else
  say "Paste the public key the app shows, then press Enter:"
  IFS= read -r PASTED
  if [[ -z "$PASTED" ]]; then
    say "REFUSED: nothing was pasted. Nothing was written."
    say "  -> easier: press copy in the app, then run --from-clipboard instead."
    exit 1
  fi
fi

# Reject anything that is not a parseable public key before touching the file.
if ! printf '%s\n' "$PASTED" | ssh-keygen -lf /dev/stdin >/dev/null 2>&1; then
  say "REFUSED: that is not a parseable SSH public key. Nothing was written."
  exit 1
fi

FP="$(printf '%s\n' "$PASTED" | ssh-keygen -lf /dev/stdin | awk '{print $2}')"

if [[ -f "$AUTHORIZED_KEYS" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    existing="$(printf '%s\n' "$line" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}' || true)"
    if [[ -n "$existing" && "$existing" == "$FP" ]]; then
      say "Already authorized ($FP). Nothing to do."
      exit 0
    fi
  done < "$AUTHORIZED_KEYS"
fi

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
printf '%s\n' "$PASTED" >> "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"
say "Appended $FP to $AUTHORIZED_KEYS"

# Prove it: the app's own command, over a real SSH session, as the app's user.
head2 "Verification"
say "The app will run this exact command over SSH. Trying it locally as $(id -un):"
if [[ -n "$HERDR_BIN" ]]; then
  say "  \$ $HERDR_BIN session list --json"
  "$HERDR_BIN" session list --json || say "  FAILED"
fi
say ""
say "Now reconnect in the app. If it still fails, the saved profile is wrong,"
say "not the key — check Username and Host / IP against the values above."
