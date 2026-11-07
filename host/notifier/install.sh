#!/bin/sh
# Install the helm notifier as a per-user LaunchAgent.
#
#   install.sh [--dry-run] [--load] [--install-dir DIR] [--label LABEL]
#              [--python PATH] [--plist-dir DIR]
#
# Copies the scripts to the install dir (dir 0700, files 0600), renders the
# plist template and prints the `launchctl bootstrap` command. It only RUNS
# that command with --load. Never touches credentials or device tokens, and
# never stops or unloads an existing agent: migrating is a manual step.
# Idempotent: running it twice leaves the same files.
set -eu

SRC=$(cd "$(dirname "$0")" && pwd)
INSTALL_DIR=${HELM_NOTIFIER_DIR:-$HOME/helm-notifier}
LABEL=dev.helm.notifier
PYTHON=/usr/bin/python3
PLIST_DIR=$HOME/Library/LaunchAgents
DRY=0
LOAD=0
FILES="notifier.py fcm.py hlog.py config.py provision_fcm.py"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY=1 ;;
    --load) LOAD=1 ;;
    --install-dir) [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 64; }; INSTALL_DIR=$2; shift ;;
    --label) [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 64; }; LABEL=$2; shift ;;
    --python) [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 64; }; PYTHON=$2; shift ;;
    --plist-dir) [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 64; }; PLIST_DIR=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done

# Values end up inside sed and XML: refuse the characters that would break it.
for value in "$INSTALL_DIR" "$LABEL" "$PYTHON"; do
  case $value in
    *'|'*|*'&'*|*'<'*|*'>'*|*'\'*|*'"'*)
      echo "refusing value with special characters: $value" >&2; exit 64 ;;
  esac
done

PLIST="$PLIST_DIR/$LABEL.plist"

render() {
  sed -e "s|__LABEL__|$LABEL|g" \
      -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
      -e "s|__PYTHON__|$PYTHON|g" \
      "$SRC/helm-notifier.plist.template"
}

say() { printf '%s\n' "$*"; }

if [ "$DRY" -eq 1 ]; then
  say "dry-run: nothing will be written"
  say "mkdir -p $INSTALL_DIR (mode 0700)"
  for f in $FILES; do
    say "install -m 0600 $SRC/$f $INSTALL_DIR/$f"
  done
  say "render $SRC/helm-notifier.plist.template -> $PLIST (mode 0644)"
  say "launchctl bootstrap gui/\$(id -u) $PLIST   # run only with --load"
  exit 0
fi

for f in $FILES helm-notifier.plist.template; do
  [ -f "$SRC/$f" ] || { echo "missing source file: $f" >&2; exit 66; }
done

umask 077
mkdir -p "$INSTALL_DIR"
chmod 0700 "$INSTALL_DIR"
for f in $FILES; do
  cp "$SRC/$f" "$INSTALL_DIR/$f"
  chmod 0600 "$INSTALL_DIR/$f"
done

mkdir -p "$PLIST_DIR"
render > "$PLIST.tmp"
chmod 0644 "$PLIST.tmp"
mv "$PLIST.tmp" "$PLIST"

say "installed scripts in $INSTALL_DIR"
say "wrote $PLIST"
say "device tokens and the FCM credential are NOT installed by this script."
CMD="launchctl bootstrap gui/$(id -u) $PLIST"
if [ "$LOAD" -eq 1 ]; then
  say "running: $CMD"
  $CMD
else
  say "to start it, run:"
  say "  $CMD"
fi
