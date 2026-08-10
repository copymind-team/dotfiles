#!/usr/bin/env bash
# tmux/claude-save.sh must turn Claude's session registry into a map keyed by
# coordinates tmux-resurrect will recreate, and tmux/claude-restore.sh must turn
# that map back into the right `claude` invocation -- or refuse to, which is the
# half worth testing. A wrong id here silently reopens somebody else's
# conversation, so every guard gets a case.
#
# claude-restore.sh is exercised through a stub `claude` on PATH that records its
# arguments instead of running: the script's whole job is to decide those
# arguments and then exec, so the arguments are the observable behaviour. The stub
# also stands in for tmux, since the script asks it for the pane coordinates and
# the test has no tmux server to ask.
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: Claude session restore${RESET}\n"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SAVE="$ROOT/tmux/claude-save.sh"
RESTORE="$ROOT/tmux/claude-restore.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

TAB=$'\t'

# ── claude-save.sh ────────────────────────────────────────────────────
#
# Faked at both inputs: a registry directory of JSON files, and a `tmux` on PATH
# that answers `list-panes` from a fixture. Nothing here needs a server.

mkdir -p "$TMP/bin" "$TMP/sessions"
cat > "$TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
# Only list-panes is asked for, and only with the one format.
[ "${1:-}" = "list-panes" ] && cat "$FAKE_PANES"
EOF
chmod +x "$TMP/bin/tmux"

# <name> <sessionId> <cwd> <tmux field> [pid]
# pid 1 stands in for "still running": it is on every machine, and is owned by
# somebody else, which is the case `kill -0` cannot tell apart from gone.
registry_entry() {
  printf '{"pid":%s,"sessionId":"%s","cwd":"%s","tmux":"%s"}\n' "${5:-1}" "$2" "$3" "$4" \
    > "$TMP/sessions/$1.json"
}

run_save() {
  PATH="$TMP/bin:$PATH" \
  FAKE_PANES="$TMP/panes" \
  TMUX="/tmp/sock,1,0" \
  CLAUDE_SESSION_DIR="$TMP/sessions" \
  CLAUDE_RESURRECT_MAP="$TMP/map" \
    bash "$SAVE"
}

cat > "$TMP/panes" <<'EOF'
%10 dotfiles:1.1
%11 dotfiles:2.1
%20 article:1.1
%21 article:1.2
EOF

header "claude-save.sh writes one line per live session"
rm -f "$TMP/sessions"/*.json
registry_entry a aaaa-1 /home/u/dotfiles "dotfiles:@1.%10"
registry_entry b bbbb-2 /home/u/article  "article:@9.%20"
run_save
assert_eq "dotfiles pane resolved to its coordinates" \
  "dotfiles:1.1${TAB}/home/u/dotfiles${TAB}aaaa-1${TAB}/tmp/sock" \
  "$(grep '^dotfiles:' "$TMP/map")"
assert_eq "article pane resolved to its coordinates" \
  "article:1.1${TAB}/home/u/article${TAB}bbbb-2${TAB}/tmp/sock" \
  "$(grep '^article:' "$TMP/map")"

# Coordinates are per-server and collide between them, so the socket is the only
# field that says whose record this is.
header "claude-save.sh records which server the coordinates belong to"
assert_eq "the socket is written down" 2 "$(grep -c "${TAB}/tmp/sock\$" "$TMP/map")"

# A claude killed rather than asked to leave can leave its registry file behind.
# The pane it names has moved on, and often to a newer claude, whose record the
# dead one would outrank -- only the first line for a pane is ever read.
header "claude-save.sh ignores a session whose process is gone"
rm -f "$TMP/sessions"/*.json
registry_entry dead  dead-id  /home/u/dotfiles "dotfiles:@1.%10" 999999
registry_entry alive alive-id /home/u/dotfiles "dotfiles:@1.%10"
run_save
assert_eq "only the running session is mapped" 1 "$(grep -c . "$TMP/map")"
assert_contains "and it is the live one" "alive-id" "$(cat "$TMP/map")"

# The case `claude --continue` cannot express, and the reason the map exists at
# all: two conversations, one directory, two panes.
header "two sessions in one directory stay distinct"
rm -f "$TMP/sessions"/*.json
registry_entry a first-id  /home/u/article "article:@9.%20"
registry_entry b second-id /home/u/article "article:@9.%21"
run_save
assert_eq "both panes recorded" 2 "$(grep -c '^article:' "$TMP/map")"
assert_eq "pane 1 keeps its own id" "first-id"  "$(awk -F'\t' '$1=="article:1.1"{print $3}' "$TMP/map")"
assert_eq "pane 2 keeps its own id" "second-id" "$(awk -F'\t' '$1=="article:1.2"{print $3}' "$TMP/map")"

header "claude-save.sh drops what it cannot place"
rm -f "$TMP/sessions"/*.json
registry_entry gone    id-gone    /home/u/x "x:@1.%99"       # pane not on this server
registry_entry nopane  id-nopane  /home/u/x ""               # no tmux field at all
registry_entry nocwd   id-nocwd   ""        "dotfiles:@1.%10"
registry_entry garbage id-garbage /home/u/x "dotfiles:@1.abc" # not a pane id
registry_entry good    id-good    /home/u/dotfiles "dotfiles:@1.%10"
run_save
assert_eq "only the placeable session survives" 1 "$(grep -c . "$TMP/map")"
assert_contains "and it is the right one" "id-good" "$(cat "$TMP/map")"

header "claude-save.sh replaces the map rather than appending"
rm -f "$TMP/sessions"/*.json
registry_entry a aaaa-1 /home/u/dotfiles "dotfiles:@1.%10"
run_save; run_save
assert_eq "two runs leave one line" 1 "$(grep -c . "$TMP/map")"
assert "no temp file left behind" bash -c "! ls '$TMP'/map.* >/dev/null 2>&1"

header "claude-save.sh survives an empty registry"
rm -f "$TMP/sessions"/*.json
run_save
assert_eq "map is emptied, not stale" 0 "$(grep -c . "$TMP/map" || true)"

# ── claude-restore.sh ─────────────────────────────────────────────────

mkdir -p "$TMP/rbin" "$TMP/projects/proj"
cat > "$TMP/rbin/claude" <<'EOF'
#!/usr/bin/env bash
# Both halves of the decision are observable here: what claude was asked to open,
# and where it was standing when asked.
printf '%s\n' "$*" > "$CLAUDE_ARGS_LOG"
pwd -P > "$CLAUDE_ARGS_LOG.cwd"
EOF
chmod +x "$TMP/rbin/claude"

# The script asks tmux for its own coordinates and nothing else.
cat > "$TMP/rbin/tmux" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "display-message" ] && printf '%s\n' "$FAKE_COORDS"
EOF
chmod +x "$TMP/rbin/tmux"

transcript() { : > "$TMP/projects/proj/$1.jsonl"; }

# A conversation belonging to a directory, filed where Claude files it: the path
# with every character outside [A-Za-z0-9] replaced by a dash. Written under both
# spellings of the path, since the test root is reached through a symlink on
# macOS and the script checks the directory it is standing in either way.
conversation_in() { # <dir>
  local d slug
  for d in "$1" "$(cd "$1" && pwd -P)"; do
    slug=$(printf '%s' "$d" | tr -c 'A-Za-z0-9' '-')
    mkdir -p "$TMP/projects/$slug"
    : > "$TMP/projects/$slug/some-conversation.jsonl"
  done
}

# <coords> <cwd> -> the arguments claude was given
restore_in() {
  ( cd "$2" && \
    PATH="$TMP/rbin:$PATH" \
    TMUX="${FAKE_SOCKET:-/tmp/sock},1,0" \
    FAKE_COORDS="$1" \
    CLAUDE_ARGS_LOG="$TMP/args" \
    CLAUDE_RESURRECT_MAP="$TMP/rmap" \
    CLAUDE_PROJECTS_DIR="$TMP/projects" \
      bash "$RESTORE" )
  cat "$TMP/args"
}

# Where the claude that restore_in started was standing.
restored_cwd() { cat "$TMP/args.cwd"; }

mkdir -p "$TMP/w/dotfiles" "$TMP/w/article" "$TMP/w/elsewhere" \
         "$TMP/w/unmapped" "$TMP/w/unclaimed" "$TMP/w/empty"
transcript live-id
conversation_in "$TMP/w/unclaimed"
conversation_in "$TMP/w/dotfiles"
{
  printf 'dotfiles:1.1\t%s\tlive-id\t/tmp/sock\n'     "$TMP/w/dotfiles"
  printf 'article:1.1\t%s\tarticle-one\t/tmp/sock\n'  "$TMP/w/article"
  printf 'article:1.2\t%s\tarticle-two\t/tmp/sock\n'  "$TMP/w/article"
  printf 'stale:1.1\t%s\tdeleted-id\t/tmp/sock\n'     "$TMP/w/elsewhere"
} > "$TMP/rmap"

header "claude-restore.sh resumes the session its pane had"
assert_eq "coordinates + directory agree -> resume by id" \
  "--resume live-id" "$(restore_in dotfiles:1.1 "$TMP/w/dotfiles")"

# The case this exists for: resurrect recreates a pane wherever its own save says,
# which is a guess -- and a pane that comes back in the wrong place would
# otherwise open the right conversation against the wrong project, or the wrong
# conversation entirely.
header "claude-restore.sh opens the session where it was running"
assert_eq "pane landed elsewhere -> still resumed" \
  "--resume live-id" "$(restore_in dotfiles:1.1 "$TMP/w/unmapped")"
assert_eq "and moved to the recorded directory first" \
  "$(cd "$TMP/w/dotfiles" && pwd -P)" "$(restored_cwd)"
printf 'gone:1.1\t%s/deleted\tlive-id\t/tmp/sock\n' "$TMP/w" >> "$TMP/rmap"
assert_eq "recorded directory is gone -> stay where the pane is" \
  "$(cd "$TMP/w/unmapped" && pwd -P)" \
  "$(restore_in gone:1.1 "$TMP/w/unmapped" >/dev/null; restored_cwd)"

header "claude-restore.sh refuses an id it cannot stand behind"
assert_eq "recorded id whose transcript is gone -> fresh" \
  "" "$(restore_in stale:1.1 "$TMP/w/elsewhere")"
# Pane coordinates repeat across tmux servers. A record written by the other one
# describes a pane that only looks like this one.
assert_eq "record from another server -> not that id" \
  "" "$(FAKE_SOCKET=/tmp/other restore_in dotfiles:1.1 "$TMP/w/empty")"

header "claude-restore.sh falls back on an unrecorded pane"
assert_eq "nothing claims this directory -> continue the newest" \
  "--continue" "$(restore_in new:1.1 "$TMP/w/unclaimed")"
assert_eq "another pane claims this directory -> fresh, not a duplicate" \
  "" "$(restore_in new:1.1 "$TMP/w/article")"
# --continue in a directory with no conversation is not a fresh start, it is an
# error: claude exits, and with it the shell it was exec'd over, closing the pane.
assert_eq "no conversation here -> fresh, not a failed continue" \
  "" "$(restore_in new:1.1 "$TMP/w/empty")"

header "claude-restore.sh degrades to a plain claude"
rm -f "$TMP/rmap"
assert_eq "no map at all -> continue" "--continue" "$(restore_in any:1.1 "$TMP/w/dotfiles")"
printf 'bad:1.1\t%s\tid;rm -rf /\t/tmp/sock\n' "$TMP/w/dotfiles" > "$TMP/rmap"
assert_eq "id carrying shell metacharacters is not resumed" \
  "" "$(restore_in bad:1.1 "$TMP/w/dotfiles")"
# A map written before the socket field existed still has to be readable, or the
# first restore after an upgrade quietly forgets every session.
printf 'old:1.1\t%s\tlive-id\n' "$TMP/w/dotfiles" > "$TMP/rmap"
assert_eq "a record without a socket is still honoured" \
  "--resume live-id" "$(restore_in old:1.1 "$TMP/w/dotfiles")"

# ── claude-snapshot.sh ────────────────────────────────────────────────
#
# The decision is the whole script: whether this event means the saved snapshot is
# now a lie. Saving too eagerly is not a harmless extra write -- a snapshot taken
# while a machine is shutting down, or halfway through a restore, is the one that
# gets restored from.

SNAPSHOT="$ROOT/tmux/claude-snapshot.sh"
mkdir -p "$TMP/sbin"

# Stands in for resurrect's save, and records that it ran.
cat > "$TMP/sbin/save.sh" <<'EOF'
#!/usr/bin/env bash
echo "saved" >> "$SAVE_LOG"
EOF
chmod +x "$TMP/sbin/save.sh"

# Only two things are asked of tmux: read the restore marker, and set it.
cat > "$TMP/sbin/tmux" <<'EOF'
#!/usr/bin/env bash
case ${1:-} in
  show-option) cat "$MARKER" 2>/dev/null ;;
  set) printf '%s\n' "${4:-}" > "$MARKER" ;;
esac
EOF
chmod +x "$TMP/sbin/tmux"

# <event> <reason> -> how many times a save happened, in total
hook() {
  printf '{"hook_event_name":"%s","reason":"%s","session_id":"probe-id"}' "$1" "$2" |
    PATH="$TMP/sbin:$PATH" \
    TMUX_PANE="%1" \
    CLAUDE_SNAPSHOT_SYNC=1 \
    CLAUDE_RESURRECT_SAVE="$TMP/sbin/save.sh" \
    CLAUDE_SESSION_DIR="$TMP/nosessions" \
    CLAUDE_SNAPSHOT_STAMP="$TMP/stamp" \
    CLAUDE_SNAPSHOT_WAIT=1 \
    CLAUDE_SNAPSHOT_SETTLE=0 \
    CLAUDE_SNAPSHOT_DEBOUNCE="${DEBOUNCE:-0}" \
    SAVE_LOG="$TMP/saves" \
    MARKER="$TMP/marker" \
      bash "$SNAPSHOT"
  wc -l < "$TMP/saves" | tr -d ' '
}

: > "$TMP/saves"; : > "$TMP/marker"; rm -f "$TMP/stamp"

header "claude-snapshot.sh saves when a session appears"
assert_eq "a session that started is not in the last save -> save now" \
  1 "$(hook SessionStart "")"

# The one the whole exit half exists for. /exit and ^D both report this.
header "claude-snapshot.sh saves once a session is deliberately quit"
assert_eq "prompt_input_exit -> save, so the pane comes back as a shell" \
  2 "$(hook SessionEnd prompt_input_exit)"
assert_eq "logout -> also a decision" 3 "$(hook SessionEnd logout)"

# The one that must not save. A reboot signals claude like any other process, and
# saving after that is saving a screenful of empty shells over the layout.
header "claude-snapshot.sh leaves an interrupted session alone"
assert_eq "reason other -> no save" 3 "$(hook SessionEnd other)"
assert_eq "/clear ends a session id, not a pane -> no save" \
  3 "$(hook SessionEnd clear)"
assert_eq "an unrelated event -> no save" 3 "$(hook Stop "")"

header "claude-snapshot.sh stays out of a restore"
MARKER="$TMP/marker" PATH="$TMP/sbin:$PATH" bash "$SNAPSHOT" restore-begin
assert_eq "a restore in flight -> the sessions it starts do not trigger saves" \
  3 "$(hook SessionStart "")"
MARKER="$TMP/marker" PATH="$TMP/sbin:$PATH" bash "$SNAPSHOT" restore-end
assert_eq "and a restore just finished still counts as in flight" \
  3 "$(hook SessionStart "")"
: > "$TMP/marker"

header "claude-snapshot.sh collapses a burst of starts"
assert_eq "first start of the burst saves" 4 "$(hook SessionStart "")"
assert_eq "the next one, seconds later, does not" \
  4 "$(DEBOUNCE=3600 hook SessionStart "")"
# An exit is a state change nothing else will record, so it is never debounced.
assert_eq "an exit in the same window still saves" \
  5 "$(DEBOUNCE=3600 hook SessionEnd prompt_input_exit)"

header "claude-snapshot.sh does nothing outside tmux"
assert_eq "no pane, no layout to save" 5 \
  "$(printf '{"hook_event_name":"SessionStart"}' |
       env -u TMUX_PANE CLAUDE_SNAPSHOT_SYNC=1 CLAUDE_RESURRECT_SAVE="$TMP/sbin/save.sh" \
         SAVE_LOG="$TMP/saves" bash "$SNAPSHOT" >/dev/null 2>&1
     grep -c . "$TMP/saves")"

# ── The wiring the two halves depend on ──────────────────────────────
#
# Both scripts are useless unless resurrect is told to call them, and the option
# has to survive resurrect's `eval set` -- so this asserts the exact string
# rather than merely that something is set.

header ".tmux.conf wires both hooks into resurrect"
CONF="$ROOT/tmux/.tmux.conf"
assert_contains "claude is on the restore list, matched loosely" \
  "@resurrect-processes '\"~claude->~/.tmux/claude-restore.sh\"'" "$(cat "$CONF")"
assert_contains "the map is written from the post-save hook" \
  "@resurrect-hook-post-save-all '~/.tmux/claude-save.sh'" "$(cat "$CONF")"
# Continuum's auto-restore fires during tpm's run, and would otherwise restore
# against the default process list.
assert "options are set before tpm loads" bash -c \
  "[ \$(grep -n '@resurrect-processes' '$CONF' | cut -d: -f1) -lt \
     \$(grep -n \"run '~/.tmux/plugins/tpm/tpm'\" '$CONF' | cut -d: -f1) ]"
assert_contains "a restore announces itself, so no save lands mid-flight" \
  "@resurrect-hook-pre-restore-all  '~/.tmux/claude-snapshot.sh restore-begin'" "$(cat "$CONF")"
assert_contains "and announces that it is done" \
  "@resurrect-hook-post-restore-all '~/.tmux/claude-snapshot.sh restore-end'" "$(cat "$CONF")"

header "claude-snapshot.sh is wired into Claude's own hooks"
# It only ever hears about a session starting or ending if Claude tells it, and
# the shared settings are the only place that says so.
SETTINGS="$ROOT/claude/settings.json"
assert_eq "SessionStart calls it" "true" \
  "$(jq '[.hooks.SessionStart[].hooks[].command] | any(. == "~/.tmux/claude-snapshot.sh")' "$SETTINGS")"
assert_eq "SessionEnd calls it" "true" \
  "$(jq '[.hooks.SessionEnd[].hooks[].command] | any(. == "~/.tmux/claude-snapshot.sh")' "$SETTINGS")"
assert_eq "and the session monitor still gets both too" "true" \
  "$(jq '[.hooks.SessionStart[].hooks[].command, .hooks.SessionEnd[].hooks[].command]
         | map(select(. == "~/.claude/monitor-hook.sh")) | length == 2' "$SETTINGS")"

header "install.sh links all three scripts"
assert_contains "claude-save.sh"     "tmux/claude-save.sh"     "$(cat "$ROOT/install.sh")"
assert_contains "claude-restore.sh"  "tmux/claude-restore.sh"  "$(cat "$ROOT/install.sh")"
assert_contains "claude-snapshot.sh" "tmux/claude-snapshot.sh" "$(cat "$ROOT/install.sh")"

# ── exec, which is the one thing that cannot regress quietly ─────────
#
# resurrect works out what a pane was running by asking ps for the shell's child.
# If claude-restore.sh ever calls claude instead of exec'ing it, the wrapper stays
# in between, the next save records the wrapper's name, "~claude" stops matching,
# and every pane restores exactly once and never again -- with nothing broken
# anywhere a test would normally look.

header "claude-restore.sh always execs"
# Every line that runs claude as a command, minus the ones that exec it. Anything
# left is the regression.
runs=$(grep -cE '^[[:space:]]*claude([[:space:]]|$)|^[[:space:]]*exec[[:space:]]+claude([[:space:]]|$)' "$RESTORE" || true)
execs=$(grep -cE '^[[:space:]]*exec[[:space:]]+claude([[:space:]]|$)' "$RESTORE" || true)
assert_eq "no invocation of claude without exec" "$runs" "$execs"
assert "and there is at least one" bash -c "[ '$execs' -gt 0 ]"

print_results
