#!/usr/bin/env bash
# The session picker (prefix+S) and the monitor (prefix+M) both read one key at a
# time and both treat a bare esc as "leave", so every arrow key has to be
# recognised as an arrow -- an escape sequence they fail to place reads as esc and
# closes the list under the user.
#
# Both readers are exercised by piping the bytes a terminal would send and
# checking which of hjkl comes back. Piped input is not a terminal, which is
# exactly what makes this testable: `read -rsn1` does not care.
#
# The two functions are duplicated between the scripts on purpose (the picker and
# the monitor share no library), so both copies get the same cases run against
# them, from one table.
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: arrow keys in the session lists${RESET}\n"

PICKER="$DOTFILES_DIR/tmux/session-select.sh"
MONITOR="$DOTFILES_DIR/tmux/monitor.sh"

ESC=$'\033'
BEL=$'\a'   # K_NONE: a sequence with no key bound to it

# Reads $2 (bytes as a terminal would send them) through the key reader of $1,
# and prints what came back, one key per line, escaped so an esc or a BEL in the
# answer is visible rather than invisible.
#
# The reader is called in a subshell of a sourced script so the real dispatch at
# the bottom of each file does not run; both files guard it with a BASH_SOURCE
# check for this.
keys_via() {
  local script=$1 bytes=$2
  printf '%s' "$bytes" | bash -c '
    set -uo pipefail
    source "$1" >/dev/null 2>&1
    # Whichever of the two the sourced file brought with it.
    if declare -F picker_key >/dev/null; then reader=picker_key; else reader=monitor_key; fi
    # 5 is plenty for the sequences here, and it keeps a reader that somehow
    # stopped consuming from looping forever.
    for _ in 1 2 3 4 5; do
      k=$("$reader" 1) || break
      printf "%q\n" "$k"
    done
  ' _ "$script"
}

# One case run against both readers: $1 label, $2 bytes in, $3 expected keys out
# (one per line, already %q-escaped).
both() {
  local label=$1 bytes=$2 want=$3
  assert_eq "picker: $label"  "$want" "$(keys_via "$PICKER" "$bytes")"
  assert_eq "monitor: $label" "$want" "$(keys_via "$MONITOR" "$bytes")"
}

header "plain keys pass straight through"
both "j"       "j"  "j"
both "digit"   "3"  "3"
both "enter"   $'\n' "''"

header "CSI arrows -- the form tmux sends a pane in normal cursor keys mode"
both "up"    "$ESC[A" "k"
both "down"  "$ESC[B" "j"
both "right" "$ESC[C" "l"
both "left"  "$ESC[D" "h"

header "SS3 arrows -- the form once application cursor keys mode is on"
# This is the case that used to close the list: 'OA' matched no pattern, so the
# key came back as esc.
both "up"    "${ESC}OA" "k"
both "down"  "${ESC}OB" "j"
both "right" "${ESC}OC" "l"
both "left"  "${ESC}OD" "h"

header "modified arrows -- the parameters are read and dropped"
both "ctrl-up"    "$ESC[1;5A" "k"
both "shift-down" "$ESC[1;2B" "j"
both "alt-left"   "$ESC[1;3D" "h"

header "a run of arrows, as a held key sends them"
both "three downs" "$ESC[B$ESC[B$ESC[B" "$(printf 'j\nj\nj')"
both "mixed forms" "$ESC[B${ESC}OB$ESC[1;5B" "$(printf 'j\nj\nj')"
both "arrow then a plain key" "$ESC[Ax" "$(printf 'k\nx')"

header "esc alone still leaves"
both "bare esc" "$ESC" "$'\\E'"
# esc and then, within 50ms, a key that cannot start a sequence: esc wins and the
# key that followed it is spent finding that out. Handing it back would mean a
# pushback buffer surviving between calls, and the caller reads through
# `key=$(picker_key)` -- a subshell, where nothing survives. Both lists leave on
# esc anyway, so the swallowed key would have had nothing left to act on.
both "esc then j" "${ESC}j" "$'\\E'"

header "sequences with no key bound to them are ignored, not obeyed"
# Home, page up and F5. Each must come back as something that is neither esc --
# which would close the list -- nor empty, which reads as enter and would switch
# sessions.
both "home"    "$ESC[H"  "$(printf '%q' "$BEL")"
both "page up" "$ESC[5~" "$(printf '%q' "$BEL")"
both "F5"      "$ESC[15~" "$(printf '%q' "$BEL")"

header "an unbound sequence is not a jump key"
# $'\a' must not be found in the jump keys: were it, home would switch sessions.
assert "picker: K_NONE keys nothing" \
  bash -c 'source "$1" >/dev/null 2>&1; ROWKEYS=(1 2 M); [ "$(key_index "$2")" = -1 ]' \
  _ "$PICKER" "$BEL"
assert "monitor: K_NONE keys nothing" \
  bash -c 'source "$1" >/dev/null 2>&1; [ "$(key_index "$2")" = -1 ]' \
  _ "$MONITOR" "$BEL"

print_results
