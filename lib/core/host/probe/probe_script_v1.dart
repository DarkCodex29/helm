/// The `helm-probe/1` POSIX `sh` script, delivered per AD-1: fed to
/// `/bin/sh -s` over stdin, no pseudo-terminal, zero host footprint.
///
/// Structurally supports the full wire grammar in
/// `docs/host-contract/v1.md`, but this v1 script emits only `env`, `mux`,
/// `session`, and `end` records. See the apply-progress notes for why
/// `agent`/`diag`/`err` emission and zellij/herdr session enumeration are
/// deferred to their own slices (4, 7, 3b/4) rather than guessed here.
const String probeScriptV1 = r'''
echo 'helm-probe/1'

_START_S=$(date +%s 2>/dev/null || echo 0)
_TAB=$(printf '\t')
_CR=$(printf '\r')
_SOH=$(printf '\001')

_esc() {
  printf '%s' "$1" \
    | tr '\n' "$_SOH" \
    | sed -e 's/\\/\\\\/g' \
          -e "s/${_TAB}/\\\\t/g" \
          -e "s/${_CR}/\\\\r/g" \
          -e "s/${_SOH}/\\\\n/g"
}

_emit() {
  _kind=$1
  shift
  _line=$_kind
  for _f in "$@"; do
    _line="${_line}${_TAB}$(_esc "$_f")"
  done
  printf '%s\n' "$_line"
}

PATH_INHERITED="$PATH"
PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin:$HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH

_emit env path_inherited "$PATH_INHERITED"
_emit env path_repaired "$PATH"
_emit env uname "$(uname -a 2>/dev/null)"
_emit env shell "$SHELL"
_emit env user "$USER"
_emit env home "$HOME"

_on_inherited_path() {
  ( PATH="$PATH_INHERITED"; command -v "$1" >/dev/null 2>&1 )
}

MUX_FOUND=0
MUX_ABS=""

_probe_mux() {
  _id=$1
  _bin=$2
  _abs=$(command -v "$_bin" 2>/dev/null || true)
  if [ -n "$_abs" ]; then
    _found=1
    _ver=$("$_abs" --version 2>/dev/null | head -1 || true)
    if _on_inherited_path "$_bin"; then
      _oip=1
    else
      _oip=0
    fi
  else
    _found=0
    _abs=""
    _ver=""
    _oip=0
  fi
  _emit mux "$_id" "$_found" "$_abs" "$_ver" "$_oip"
  MUX_FOUND=$_found
  MUX_ABS=$_abs
}

_probe_mux herdr herdr
_probe_mux tmux tmux
TMUX_FOUND=$MUX_FOUND
TMUX_ABS=$MUX_ABS
_probe_mux zellij zellij

if [ "$TMUX_FOUND" = "1" ]; then
  "$TMUX_ABS" list-sessions -F "#{session_name}${_TAB}#{session_attached}" 2>/dev/null | \
    while IFS= read -r _sline; do
      _sname=${_sline%%"${_TAB}"*}
      _satt=${_sline#*"${_TAB}"}
      _emit session tmux "$_sname" active "$_satt"
    done
fi

_ELAPSED_S=$(date +%s 2>/dev/null || echo 0)
_ELAPSED_MS=$(( (_ELAPSED_S - _START_S) * 1000 ))
_emit end ok "$_ELAPSED_MS"
''';
