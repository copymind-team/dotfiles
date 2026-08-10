#!/usr/bin/env bash
# Re-enters the Claude Code session this pane was running, in the directory it was
# running it in. Sent into the pane by tmux-resurrect's process restore -- see
# @resurrect-processes in .tmux.conf -- after resurrect has recreated the pane.
#
# exec, never a plain call: the pane's shell has to end up with claude as its
# direct child. resurrect works out what a pane was running by asking ps for the
# shell's child, so a wrapper left sitting in between would be recorded as the
# process next time round, stop matching "claude", and the pane would restore
# exactly once and never again.
#
# Every path out of here ends in an exec of claude, so a pane that cannot be
# resolved still comes back as claude -- just at a fresh conversation rather than
# the one it had.
#
# The directory comes from the map, not from the pane. resurrect recreates a pane
# in whatever path it recorded, and that path is a guess: it is read off the pane's
# process at save time, it survives a directory that has since been deleted only
# by falling back to the home directory, and once wrong it stays wrong, because
# the next save records the wrong answer again. The map instead carries the cwd
# claude itself reported. Trusting it turns a pane that came back in the wrong
# place from a session opened against the wrong project into one that is merely
# drawn in the wrong pane.
set -uo pipefail

MAP=${CLAUDE_RESURRECT_MAP:-$HOME/.claude/resurrect-map}
PROJECTS=${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}

# This pane's directory under both spellings. The map holds what claude reported,
# which has symlinks resolved; a shell that was cd'd through a symlink carries the
# link in $PWD, and the same directory under two spellings would read as a miss.
HERE=$PWD
HERE_REAL=$(pwd -P 2>/dev/null) || HERE_REAL=$PWD

# The transcript for a session id, if it is still on disk. Globbed across every
# project directory rather than derived from the cwd: the mapping from a path to
# its project directory is Claude's own slugification, and a session may have been
# started somewhere other than where its transcript now lives.
transcript_exists() { # <session-id>
  local f
  for f in "$PROJECTS"/*/"$1".jsonl; do
    [ -f "$f" ] && return 0
  done
  return 1
}

# Whether a directory has any conversation at all, which is the only thing that
# makes --continue meaningful. This one does reimplement the slugification --
# every character outside [A-Za-z0-9] becomes a dash -- because the question is
# about a directory rather than an id, and there is nothing to glob for. A version
# bump that changes the scheme costs a fresh conversation here, never a wrong one:
# a slug that no longer resolves reads as "no conversation", and the fallback
# below it is a plain claude.
has_conversation() { # <dir>
  local slug f
  slug=$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-')
  for f in "$PROJECTS/$slug"/*.jsonl; do
    [ -f "$f" ] && return 0
  done
  return 1
}

# The record for this pane, as "<cwd>\t<session id>", or non-zero if there isn't
# one to be had -- which is the common case for a pane whose claude started after
# the last save.
recorded() {
  [ -n "${TMUX:-}" ] || return 1
  [ -r "$MAP" ] || return 1

  local coords line rest cwd sid socket
  coords=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null) || return 1
  [ -n "$coords" ] || return 1

  line=$(awk -F'\t' -v c="$coords" '$1 == c { print; exit }' "$MAP") || return 1
  [ -n "$line" ] || return 1

  # Split by hand rather than with read: tab is IFS whitespace, so `read` would
  # collapse an empty field and hand back the wrong one. The padding lets one
  # expression read both a record written before the socket field existed and one
  # written after.
  rest=$line$'\t\t\t'
  rest=${rest#*$'\t'}
  cwd=${rest%%$'\t'*};    rest=${rest#*$'\t'}
  sid=${rest%%$'\t'*};    rest=${rest#*$'\t'}
  socket=${rest%%$'\t'*}

  # Coordinates alone are not proof of ownership. They are per-server, so a second
  # tmux server on this machine writes records that look exactly like this one's.
  # The socket is what tells them apart; a record from before the socket was
  # written down has to be taken on faith.
  if [ -n "$socket" ] && [ -n "${TMUX%%,*}" ] && [ "$socket" != "${TMUX%%,*}" ]; then
    return 1
  fi

  # A session id reaches exec as an argument, so it is quoted either way -- but a
  # value that is not a plain id means the map has been corrupted, and resuming
  # something arbitrary from a corrupt map is worse than starting fresh.
  case $sid in
    ''|*[!A-Za-z0-9-]*) return 1 ;;
  esac

  printf '%s\t%s\n' "$cwd" "$sid"
}

# Whether --continue is unambiguous here: nothing in the map claims this
# directory, so the newest conversation in it cannot belong to another pane.
#
# This is the fallback for a pane with no record of its own, which is ordinary --
# a claude started after the last save is invisible to the map, and its
# conversation is almost always the newest one in the directory.
#
# When two panes do share a directory -- one project, two conversations, which the
# fleet makes easy to end up with -- both would --continue into the same session
# and show you the same conversation twice, with the second one's edits going
# somewhere you are not looking. A fresh conversation is the safer answer.
sole_claim_on_cwd() {
  [ -r "$MAP" ] || return 0
  local n
  n=$(awk -F'\t' -v d="$HERE" -v r="$HERE_REAL" \
        '$2 == d || $2 == r { c++ } END { print c + 0 }' "$MAP") || return 1
  [ "$n" -eq 0 ]
}

if record=$(recorded); then
  cwd=${record%$'\t'*}
  sid=${record##*$'\t'}

  # Where claude ran beats where the pane landed. Only when the directory is still
  # there: a project deleted since the save leaves the pane where resurrect put
  # it, which is at least somewhere that exists.
  if [ -d "$cwd" ] && [ "$cwd" != "$HERE" ] && [ "$cwd" != "$HERE_REAL" ]; then
    cd "$cwd" 2>/dev/null || true
  fi

  if transcript_exists "$sid"; then
    exec claude --resume "$sid" "$@"
  fi
  exec claude "$@"
fi

# --continue only where there is something to continue. A pane that came back in
# the wrong directory lands here with everything looking normal, and in a home
# directory that has ever had a claude in it, --continue would reopen a
# conversation belonging to no project in particular. It also fails outright where
# there is no conversation at all, which would exit the shell rather than leave a
# window open.
if sole_claim_on_cwd && { has_conversation "$HERE" || has_conversation "$HERE_REAL"; }; then
  exec claude --continue "$@"
fi

exec claude "$@"
