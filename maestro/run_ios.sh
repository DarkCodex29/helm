#!/usr/bin/env bash
# Run the Maestro suite against an iOS simulator.
#
# ## Why this script exists at all
#
# On Android, `maestro test maestro/flows` is the whole story: every flow
# opens with `launchApp: clearState: true`, which is enough to put the
# app back to first launch.
#
# On iOS it is NOT enough, and the gap is not cosmetic. `reach_home`
# reaches the Setup screen only while the app holds no SSH key, and that
# key lives in the Keychain. The Keychain survives `clearState`, AND it
# survives `xcrun simctl uninstall` — both measured, each failing the
# same way: the app lands on Home, and the suite then reports a missing
# `helm.setup.public_key_text` while saying nothing about why. Only
# `xcrun simctl erase` actually clears it.
#
# `erase` is device-level, so Maestro cannot express it from inside a
# flow. That is the entire reason for this wrapper.
#
# ## And it has to happen ONCE PER FLOW, not once per run
#
# Erasing before the suite is not enough, which is also measured: the
# first flow completes setup and leaves a key behind, so flows two and
# three land on Home and fail on `helm.setup.public_key_text` exactly as
# if the erase had never happened. Every flow here starts from first
# launch, so every flow gets its own clean device.
#
# The app is built ONCE and reinstalled after each erase, because the
# build is the slow part and it does not change between flows.
#
# ## Usage
#
#   maestro/run_ios.sh                      # whole suite, booted simulator
#   maestro/run_ios.sh <udid>               # whole suite, named simulator
#   maestro/run_ios.sh <udid> flows/02_settings_reachable.yaml
#
# The app is REBUILT before running, because `erase` removes it along
# with everything else.

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

udid="${1:-}"
target="${2:-maestro/flows}"

if [[ -z "$udid" ]]; then
  # The currently booted simulator, when there is exactly one. Resolved
  # rather than defaulted so the erase below can never be aimed at a
  # device the caller did not mean.
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
  echo "Pass a UDID: maestro/run_ios.sh <udid>" >&2
  echo "List them with: xcrun simctl list devices" >&2
  exit 1
fi

echo "==> Target simulator: $udid"

echo "==> Building the app once"
flutter build ios --simulator --debug

# Expand a directory into its flows so each can get its own clean
# device. A single file is just a one-element list.
if [[ -d "$target" ]]; then
  flows=()
  while IFS= read -r flow; do flows+=("$flow"); done \
    < <(find "$target" -maxdepth 1 -name '*.yaml' | sort)
else
  flows=("$target")
fi

if [[ ${#flows[@]} -eq 0 ]]; then
  echo "No flows found under $target" >&2
  exit 1
fi

# Every failure is reported, and the suite still runs to the end —
# matching `continueOnFailure: true` in `maestro/config.yaml`, which
# this script bypasses by invoking flows one at a time.
failed=()

for flow in "${flows[@]}"; do
  echo
  echo "============================================================="
  echo "==> $flow"
  echo "============================================================="

  # ERASES THE SIMULATOR. Safe because a simulator is disposable
  # scratch state, and necessary because nothing short of this clears
  # the Keychain — see the header. Never aim this at anything but a
  # simulator UDID.
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl erase "$udid"
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl install "$udid" build/ios/iphonesimulator/Runner.app

  if ! maestro --device "$udid" test "$flow"; then
    failed+=("$flow")
  fi
done

echo
if [[ ${#failed[@]} -gt 0 ]]; then
  echo "FAILED ${#failed[@]}/${#flows[@]}:"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi

echo "All ${#flows[@]} flows passed."
