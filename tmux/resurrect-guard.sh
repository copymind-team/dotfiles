#!/usr/bin/env bash
# Stands in front of tmux-resurrect's save.sh, and repairs the "last" symlink it
# can be made to break. Wired to @resurrect-save-script-path, to the C-s binding,
# and -- as `resurrect-guard.sh repair` -- to a run-shell above the tpm line.
#
# resurrect names each save after the wall clock to the second, and decides at the
# end of save_all whether the snapshot it just took was worth keeping:
#
#     if files_differ "$resurrect_file_path" "$last_resurrect_file"; then
#         ln -fs "$(basename "$resurrect_file_path")" "$last_resurrect_file"
#     else
#         rm "$resurrect_file_path"
#     fi
#
# Two saves in the same second resolve to the same path, and the second one to
# arrive compares that path against a "last" the first has already pointed at it.
# A file is identical to itself, so it takes the rm branch and deletes the file
# the symlink names. The link survives its target, and restore.sh -- which only
# tests -f on "last" before anything else -- reports that there is no save file at
# all, standing in a directory holding a thousand of them.
#
# A stock setup takes one save every fifteen minutes and effectively never sees
# this. This one takes them on a five minute timer AND on every Claude Code
# SessionStart and SessionEnd, so a snapshot landing in the same second as a
# scheduled save is a matter of ordinary use rather than bad luck.
#
# Two guards, because they answer different halves of it. The lock serialises
# saves, which also fixes a quieter bug in the same lines: two saves that write
# different files can still finish out of order and leave "last" pointing at the
# older snapshot. The clock check is what actually prevents the collision --
# serialising alone would only make it deterministic, since the loser still writes
# the winner's path and still deletes it.
set -uo pipefail

REAL_SAVE=${CLAUDE_RESURRECT_REAL_SAVE:-$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh}

# How long to queue behind a save already running. Waiting rather than dropping
# because the two saves are not interchangeable: the one taken from SessionEnd has
# waited for claude to actually exit, and a timer save racing it may still see the
# session alive and record a pane that has since been closed on purpose. A save
# takes well under a second, so this is a ceiling, not a cost.
LOCK_WAIT=${CLAUDE_RESURRECT_LOCK_WAIT:-20}

# When to treat a lock as debris rather than as someone working. Only a save
# killed between mkdir and its trap can leave one behind, which needs a signal the
# trap does not catch -- rare, but it would otherwise wedge every later save.
LOCK_STALE=${CLAUDE_RESURRECT_LOCK_STALE:-120}

# How many seconds to let the clock tick past occupied ones before giving up. More
# than a couple means something is taking a save every second, and going ahead
# then is the one thing known to break the link.
CLOCK_TRIES=${CLAUDE_RESURRECT_CLOCK_TRIES:-5}

# Where resurrect keeps its saves, by resurrect's own rule: @resurrect-dir if set,
# with the same three expansions its helpers.sh does, and otherwise the legacy
# ~/.tmux/resurrect if that directory exists so an old install is not orphaned,
# falling through to the XDG location.
resurrect_dir() {
  local dir=''
  dir=$(tmux show-option -gqv @resurrect-dir 2>/dev/null) || dir=''
  if [ -n "$dir" ]; then
    dir=${dir//\$HOME/$HOME}
    dir=${dir//\~/$HOME}
    dir=${dir//\$HOSTNAME/$(hostname)}
  elif [ -d "$HOME/.tmux/resurrect" ]; then
    dir="$HOME/.tmux/resurrect"
  else
    dir="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
  fi
  printf '%s\n' "$dir"
}

DIR=${CLAUDE_RESURRECT_DIR:-$(resurrect_dir)}

# Point "last" at a save that exists. Called after every save through here, and on
# its own from the config file before tpm loads continuum, which is the only
# moment that matters on the way up: continuum's automatic restore fires during
# that load, and a dangling link at that point loses the whole session set.
#
# Deliberately quiet. It runs from a config file, where anything on stdout becomes
# a window tmux pops open in front of a developer who asked for a shell.
repair() {
  local last="$DIR/last" newest=''
  [ -d "$DIR" ] || return 0

  # -e follows the link, so this is true only when "last" names something real.
  # False covers both halves of the problem: a dangling link, and no link at all.
  [ -e "$last" ] && return 0

  # Nothing to point at is not a fault -- a resurrect directory with no saves in
  # it is what a fresh install looks like.
  newest=$(ls -t "$DIR"/tmux_resurrect_*.txt 2>/dev/null | head -1)
  [ -n "$newest" ] || return 0

  # Relative, as resurrect writes it, so the directory stays movable.
  ln -fs "$(basename "$newest")" "$last" 2>/dev/null
}

case ${1:-save} in
  repair) repair; exit 0 ;;
esac

[ -x "$REAL_SAVE" ] || exit 0
mkdir -p "$DIR" 2>/dev/null || exit 0

LOCK="$DIR/.save-lock"

# mkdir rather than flock: the atomic-create primitive that is actually on a mac
# without homebrew, and the one continuum reaches for in its own save path.
acquire() {
  local waited=0 born=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    born=$(date -r "$LOCK" +%s 2>/dev/null) || born=0
    if [ "$born" -gt 0 ] && [ $(( $(date +%s) - born )) -ge "$LOCK_STALE" ]; then
      rmdir "$LOCK" 2>/dev/null
    fi
    [ "$waited" -ge "$LOCK_WAIT" ] && return 1
    sleep 1
    waited=$((waited + 1))
  done
  return 0
}

# Nothing was written and nothing was linked, so there is nothing to undo but the
# lock itself.
acquire || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM HUP

# The collision this whole file exists for. Holding the lock is what makes the
# test trustworthy -- the file cannot appear between asking and handing off.
#
# A file sitting on this second means a save already claimed it and "last" already
# points there, since the only other outcome would have removed it. So wait for a
# second that no save owns.
tries=0
while [ -e "$DIR/tmux_resurrect_$(date +%Y%m%dT%H%M%S).txt" ]; do
  if [ "$tries" -ge "$CLOCK_TRIES" ]; then
    repair
    exit 0
  fi
  sleep 1
  tries=$((tries + 1))
done

# Arguments through as given: continuum passes "quiet", the key binding passes
# nothing and expects the "saved!" message it has always printed.
"$REAL_SAVE" "$@"
status=$?

# The safety net rather than the fix -- with the two guards above, save.sh should
# never leave the link dangling. It is here for the saves that do not come through
# this file at all, and to heal a directory that was already broken before any of
# this was installed.
repair

exit "$status"
