#!/usr/bin/env bash
# Takes a tmux-resurrect snapshot at the two moments a timer cannot see: when a
# Claude Code session starts, and once one has been quit on purpose. Wired to
# SessionStart and SessionEnd in claude/settings.json.
#
# What a pane comes back as is decided entirely by resurrect's saved snapshot, and
# continuum only takes one every few minutes. Everything that happens between two
# saves is invisible, which shows up as two complaints that look unrelated and are
# the same bug:
#
#   a session started since the last save is not in the snapshot, so its pane
#   comes back as a bare shell -- the conversation is on disk, but nothing reopens
#   it;
#
#   a session quit with /exit is still in the snapshot, so a pane that was
#   deliberately closed reopens on the next boot, resuming a conversation its
#   developer was finished with.
#
# Both close by snapshotting when the state changes instead of when the clock says
# so. The exit case has to wait for the process to actually go: SessionEnd fires
# while claude is still up, and a save taken then would record the very thing it
# is meant to forget.
#
# Only a deliberate exit counts. A session that ends because the machine is going
# down ends with reason "other" -- claude is signalled like everything else -- and
# taking that as "the developer is done here" would save a world of empty shells
# at the one moment the layout is most worth keeping. /exit and ^D report
# prompt_input_exit, /logout reports logout, and those are the only two that mean
# a person decided.
set -uo pipefail

# Through the guard rather than straight at save.sh: the saves taken here are the
# ones most likely to land in the same second as continuum's timer, and that
# collision deletes the file resurrect's "last" symlink points at. See
# resurrect-guard.sh.
SAVE=${CLAUDE_RESURRECT_SAVE:-$HOME/.tmux/resurrect-guard.sh}
SESSION_DIR=${CLAUDE_SESSION_DIR:-$HOME/.claude/sessions}
STAMP=${CLAUDE_SNAPSHOT_STAMP:-$HOME/.claude/resurrect-snapshot}

# A start is worth a snapshot; ten starts in the same minute are worth one. The
# floor is the whole protection against a fleet coming up at once, or against a
# script that opens claude in a loop.
DEBOUNCE=${CLAUDE_SNAPSHOT_DEBOUNCE:-30}

# How long after a restore to keep quiet. A restore brings panes up one at a time
# and sends each its command with send-keys, so for a while the layout is real but
# half of it is still a shell waiting for claude to appear. A snapshot taken then
# records those panes as shells and the next boot restores nothing.
COOLDOWN=${CLAUDE_SNAPSHOT_COOLDOWN:-120}

# How long to wait for a quitting claude to be gone before saving. Generous, since
# the cost of waiting is nothing and the cost of saving too early is the bug.
WAIT=${CLAUDE_SNAPSHOT_WAIT:-30}

# What to wait instead when there is no process to watch -- long enough for the
# pane to have fallen back to its shell.
SETTLE=${CLAUDE_SNAPSHOT_SETTLE:-2}

now() { date +%s; }

# The restore marker, set either side of resurrect's restore from
# @resurrect-hook-pre-restore-all and -post-restore-all. "0" means a restore is
# running and has not said otherwise; a timestamp means one finished then. The
# cooldown is measured from the end rather than the start so that a restore taking
# longer than the cooldown cannot age out from under itself.
case ${1:-hook} in
  restore-begin) tmux set -g @claude-restoring 0 2>/dev/null; exit 0 ;;
  restore-end)   tmux set -g @claude-restoring "$(now)" 2>/dev/null; exit 0 ;;
  hook) ;;
  *) exit 0 ;;
esac

restoring() {
  local marker
  marker=$(tmux show-option -gqv @claude-restoring 2>/dev/null) || return 1
  [ "$marker" = 0 ] && return 0
  case $marker in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ $(( $(now) - marker )) -lt "$COOLDOWN" ]
}

# Nothing here is worth doing outside tmux, and nothing here works without the
# pieces it drives.
[ -n "${TMUX_PANE:-}" ] || exit 0
[ -x "$SAVE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
event=$(printf '%s' "$payload" | jq -r '.hook_event_name // ""' 2>/dev/null) || exit 0
reason=$(printf '%s' "$payload" | jq -r '.reason // ""' 2>/dev/null) || exit 0
sid=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null) || exit 0

case $event in
  SessionStart)
    when=now
    restoring && exit 0
    if [ -f "$STAMP" ]; then
      last=$(date -r "$STAMP" +%s 2>/dev/null) || last=0
      [ $(( $(now) - last )) -lt "$DEBOUNCE" ] && exit 0
    fi
    ;;
  SessionEnd)
    # No debounce and no cooldown on the way out: an exit is a state change that
    # nothing else will record, and there is no burst of them to collapse.
    case $reason in
      prompt_input_exit|logout) when=after ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac

# The pid behind this session, so the wait can watch the process itself rather
# than the file naming it. The registry file is removed on the way out too, but
# only by a claude that got far enough to remove it.
session_pid() {
  local f pid
  # An empty id would match on nothing in particular, and waiting on the wrong
  # process is worse than not waiting.
  [ -n "$sid" ] || return 1
  for f in "$SESSION_DIR"/*.json; do
    [ -f "$f" ] || continue
    grep -qF "\"$sid\"" "$f" 2>/dev/null || continue
    pid=$(basename "$f" .json)
    case $pid in
      ''|*[!0-9]*) continue ;;
    esac
    printf '%s\n' "$pid"
    return 0
  done
  return 1
}

snapshot() {
  if [ "$when" = after ]; then
    local pid waited=0
    if pid=$(session_pid); then
      while ps -p "$pid" >/dev/null 2>&1; do
        [ "$waited" -ge "$WAIT" ] && return 0
        sleep 1
        waited=$((waited + 1))
      done
    else
      # No pid to watch: either the registry is gone already or this claude never
      # wrote one. A beat is enough for the pane to fall back to its shell.
      [ "$SETTLE" -gt 0 ] && sleep "$SETTLE"
    fi
  fi
  "$SAVE" quiet >/dev/null 2>&1
  : > "$STAMP" 2>/dev/null || true
}

# Detached, and deaf to the hangup that arrives when the session it was reporting
# on exits -- the whole point of the exit path is to still be here afterwards.
# A hook that blocked would also be a hook that delays every claude startup by as
# long as a save takes.
if [ -n "${CLAUDE_SNAPSHOT_SYNC:-}" ]; then
  snapshot
else
  ( trap '' HUP INT TERM; snapshot ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi
exit 0
