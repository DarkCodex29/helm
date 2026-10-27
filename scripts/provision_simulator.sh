#!/usr/bin/env bash
# One command that takes a clean iOS simulator to a terminal attached to
# this Mac's herdr session.
#
# It does the four things a person would otherwise do by hand:
#   1. erase + install, so the app reaches Setup at all
#   2. drive Setup with Maestro, using values read off this host
#   3. read the generated public key back out of the app and authorize it
#   4. relaunch and prove the session actually came up
#
# ## THIS ERASES THE SIMULATOR
#
# `xcrun simctl erase` is unavoidable here and is the whole reason this
# script exists: the app routes to Setup only while it holds no SSH key,
# and on iOS that key survives both `clearState` and `simctl uninstall`.
# Only `erase` clears it. A simulator is disposable scratch state, but
# anything you had configured in it is gone — including any previously
# authorized key, which is why step 3 authorizes the new one.
#
# Never aim this at anything but a simulator UDID.
#
# ## Usage
#
#   scripts/provision_simulator.sh            # the one booted simulator
#   scripts/provision_simulator.sh <udid>     # a named simulator
set -o errexit
set -o nounset
set -o pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

udid="${1:-}"
if [[ -z "$udid" ]]; then
  # Resolved rather than defaulted, so the erase below can never be
  # aimed at a device the caller did not mean.
  udid="$(xcrun simctl list devices booted -j |
    /usr/bin/python3 -I -c '
import json, sys
devices = [d for group in json.load(sys.stdin)["devices"].values() for d in group]
booted = [d["udid"] for d in devices if d.get("state") == "Booted"]
print(booted[0] if len(booted) == 1 else "")
')"
fi

if [[ -z "$udid" ]]; then
  echo "No simulator given and not exactly one booted." >&2
  echo "Pass a UDID: scripts/provision_simulator.sh <udid>" >&2
  echo "List them with: xcrun simctl list devices" >&2
  exit 1
fi

host_user="$(id -un)"
host_port="22"
profile_name="My Mac"

# The MagicDNS name, not 127.0.0.1, even though the simulator shares this
# Mac's network stack and the loopback address would connect. A simulator
# provisioned over loopback exercises a path no real device ever takes:
# every phone reaches the Mac over Tailscale, so proving the setup on
# loopback proves nothing about the connection it will actually use.
# Same reason README.md > Setup rejects LAN and Tailscale addresses.
TS_CLI="$(command -v tailscale \
  || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)"
host_addr=""
if [[ -x "$TS_CLI" ]]; then
  # --peers=false so this cannot pick up another machine's name.
  host_addr="$("$TS_CLI" status --peers=false --json 2>/dev/null \
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

if [[ -z "$host_addr" ]]; then
  echo "No Tailscale MagicDNS name for this Mac." >&2
  echo "Install Tailscale and sign in, then rerun:" >&2
  echo "  brew install --cask tailscale" >&2
  echo >&2
  echo "Do not substitute 127.0.0.1 or any address: see docs/HOST_SETUP.md." >&2
  exit 1
fi

echo "==> Target simulator: $udid"
echo "==> Profile to create: $profile_name ($host_user@$host_addr:$host_port)"

# ---------------------------------------------------------------------------
# Refuse early instead of failing three minutes in.
# ---------------------------------------------------------------------------
# Probed at the MagicDNS name the app will use, not at loopback: this is
# the one check that can catch Tailscale being installed but not routing.
if ! nc -z -G 5 "$host_addr" "$host_port" >/dev/null 2>&1; then
  echo >&2
  echo "Nothing answered on $host_addr:$host_port." >&2
  echo "Check both, in this order:" >&2
  echo "  1. Remote Login is on (System Settings > General > Sharing)" >&2
  echo "  2. Tailscale is connected on this Mac ('tailscale status')" >&2
  exit 1
fi

if ! command -v herdr >/dev/null 2>&1; then
  echo >&2
  echo "herdr is not on PATH. Install it before provisioning:" >&2
  echo "  brew install herdr" >&2
  exit 1
fi

if ! herdr session list --json >/dev/null 2>&1; then
  echo >&2
  echo "The herdr server is not answering. Start it, then rerun." >&2
  exit 1
fi

if ! command -v maestro >/dev/null 2>&1; then
  echo >&2
  echo "maestro is not on PATH. Install it from https://maestro.dev" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Build, erase, install.
# ---------------------------------------------------------------------------
echo "==> Building the app"
flutter build ios --simulator --debug

echo "==> Erasing and reinstalling (this clears the Keychain)"
xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
xcrun simctl erase "$udid"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
xcrun simctl install "$udid" build/ios/iphonesimulator/Runner.app

# ---------------------------------------------------------------------------
# 2. Drive Setup.
# ---------------------------------------------------------------------------
echo "==> Filling in the setup form"
maestro --device "$udid" test \
  -e HELM_HOST="$host_addr" \
  -e HELM_PORT="$host_port" \
  -e HELM_USERNAME="$host_user" \
  -e HELM_PROFILE_NAME="$profile_name" \
  maestro/provision/configure_profile.yaml

# ---------------------------------------------------------------------------
# 3. Read the key back out of the app and authorize it.
#
# The clipboard would also work, but reading the accessibility tree needs
# no copy button press and no pasteboard sync, so it cannot silently pick
# up whatever happened to be copied last.
# ---------------------------------------------------------------------------
echo "==> Reading the generated public key out of Settings"
maestro --device "$udid" test maestro/provision/open_settings.yaml

hierarchy="$(mktemp)"
trap 'rm -f "$hierarchy"' EXIT
maestro --device "$udid" hierarchy > "$hierarchy"

public_key="$(/usr/bin/python3 -I -c '
import json, sys

def walk(node):
    attributes = node.get("attributes", {})
    for field in ("text", "accessibilityText"):
        value = attributes.get(field, "")
        if value.startswith("ssh-ed25519 "):
            yield value
    for child in node.get("children", []):
        yield from walk(child)

keys = list(walk(json.load(open(sys.argv[1]))))
print(keys[0] if keys else "")
' "$hierarchy")"

if [[ -z "$public_key" ]]; then
  echo "Could not find the public key in the app's accessibility tree." >&2
  echo "The app may not have reached Settings. Hierarchy: $hierarchy" >&2
  trap - EXIT
  exit 1
fi

echo "==> Authorizing $(printf '%s\n' "$public_key" | ssh-keygen -lf /dev/stdin | awk '{print $2}')"
printf '%s\n' "$public_key" | pbcopy
./scripts/host_setup_report.sh --from-clipboard

# ---------------------------------------------------------------------------
# 4. Relaunch and prove the session came up.
#
# A relaunch is REQUIRED, not cosmetic: an already-open tab keeps the
# profile snapshot it was opened with, so the tab created during setup
# would keep retrying with the pre-authorization state.
# ---------------------------------------------------------------------------
echo "==> Relaunching and checking the connection"
maestro --device "$udid" test maestro/provision/verify_connected.yaml

echo
echo "Done. The simulator is attached to this Mac's herdr session."
