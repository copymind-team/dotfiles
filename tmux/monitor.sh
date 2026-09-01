#!/usr/bin/env bash
# Monitor for every tmux session: one line each, showing what its Claude window
# is doing, plus a key to jump straight to the one that wants you.
#
#   monitor.sh          open the monitor session (reuses it if up)
#   monitor.sh --run    run the monitor here, in the current pane
#
# Bound to prefix+M in .tmux.conf.
#
# Keys: 1-9 then a-z jump straight to that session. j/k (or the arrow keys) move
# the cursor and enter jumps to it; h and l do nothing, the list being one column.
# r refreshes now, q (or esc) closes the monitor and puts the client back on the
# session it came from.
#
# Under the rows, where the screen has room for it: the last month of spending as
# a small chart, dollars up the side and one column per day along the bottom.
#
# u opens that chart full size, with the whole history behind it. There h/l are a
# day and j/k a week, u goes back to the fleet, and q does too -- it only closes
# the monitor from the fleet screen.
#
# Every session is listed except the monitor itself. For each one it picks the
# pane to report on: a pane actually running Claude, else one in a window named
# $MONITOR_WINDOW, else the session's active pane.
#
# What each session is doing is read off its screen. Where claude/statusline.sh
# and claude/monitor-hook.sh are installed, they leave what the screen cannot
# show -- context and cost, how many subagents are in flight, and state straight
# from Claude's own events -- in $CLAUDE_MONITOR_DIR, and those are merged in.
# Sessions without them lose the extra columns and nothing else.
#
# The status line also keeps two ledgers there that outlive the sessions
# themselves: what every session has spent, day by day, which is where the day,
# week, month and all-time figures on the total line come from -- and every day
# of the chart on 'u' -- and each account's last usage reading,
# which is what keeps an account on screen after the fleet has switched off it.
#
# Tunables: MONITOR_INTERVAL (seconds, default 2), MONITOR_WINDOW (preferred
# window name, default "claude"), MONITOR_FILTER (regex; only sessions matching
# it are listed, default all), MONITOR_SESSION (default "monitor"),
# CLAUDE_MONITOR_DIR (default ~/.claude/monitor), MONITOR_STALE (seconds an
# exported state stays trusted, default 90), MONITOR_ACCT_KEEP (seconds an
# account with nothing live on it keeps its line, default 8 days),
# MONITOR_HISTORY_DAYS (days the usage chart reaches back, default 3660).
set -uo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
SELF="$SELF_DIR/$(basename "$0")"

MON=${MONITOR_SESSION:-monitor}
INTERVAL=${MONITOR_INTERVAL:-2}
MONITOR_WINDOW=${MONITOR_WINDOW:-claude}
MONITOR_FILTER=${MONITOR_FILTER:-}
MONITOR_DIR=${CLAUDE_MONITOR_DIR:-$HOME/.claude/monitor}
MONITOR_STALE=${MONITOR_STALE:-90}
# Claude's own session registry, one small JSON file per running session. Read
# only to follow parked jobs; see the parked jobs section.
SESSION_DIR=${CLAUDE_SESSION_DIR:-$HOME/.claude/sessions}

# Digits first (natural for the first handful), then letters. 'q' and 'r' are
# left out on purpose -- they are quit and refresh -- and so are hjkl, which move
# the cursor, and 'u', which opens the usage chart. 28 keys in total; past that,
# use the cursor.
KEYS="123456789abcdefgimnopstvwxyz"

# --- terminal control -------------------------------------------------------
# Kept as variables rather than printf escapes so the same strings work in sed
# replacements, where BSD sed would not expand \033.
ESC=$'\033'
T_HOME="${ESC}[H"        # cursor to top-left
T_EL="${ESC}[K"          # erase to end of line
T_ED="${ESC}[J"          # erase to end of screen
T_HIDE="${ESC}[?25l"
T_SHOW="${ESC}[?25h"
T_ALT_ON="${ESC}[?1049h" # alternate screen
T_ALT_OFF="${ESC}[?1049l"

if [ -t 1 ] || [ -n "${MONITOR_FORCE_COLOR:-}" ]; then
  C_RST=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_REV=$'\033[7m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYA=$'\033[36m'
else
  C_RST=; C_BOLD=; C_DIM=; C_REV=; C_RED=; C_GRN=; C_YEL=; C_CYA=
fi

# --- snapshot ---------------------------------------------------------------

# Braille frames Claude spins in the pane title while it works. Only used when
# perl is missing: the perl check in monitor_busy_titles covers the whole braille
# block, so it survives Claude picking frames that are not in this list.
BRAILLE_FRAMES='⠁⠂⠄⠈⠐⠠⡀⢀⠃⠆⠇⠋⠏⠙⠘⠸⠴⠦⠧⠹⠼⣀⣤⣶⣿'

# Claude Code reports its version as the process name ("2.1.222"), so treat a
# bare version and anything containing "claude" as Claude.
is_claude_cmd() {
  case $1 in
    *claude*) return 0 ;;
    [0-9]*.[0-9]*.[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# Runtimes Claude would surface as if it ever stopped renaming its process. On
# their own these prove nothing -- half the world runs node -- so a pane only
# counts as Claude this way when its title carries one of Claude's glyphs too.
is_claude_host() {
  case $1 in node|bun|deno|npm|npx) return 0 ;; *) return 1 ;; esac
}

# True when a title is one Claude wrote: "<braille frame> summary" while it
# works, "✳ summary" once it stops. Only used to recognise a Claude pane, never
# to decide busy -- monitor_busy_titles does that, and exactly. A title alone is
# never enough: it is set by whatever last wrote to the pane and outlives it, so
# shells sit there wearing Claude's last summary long after Claude has exited.
title_is_claude() {
  [ -n "${1:-}" ] || return 1
  case $1 in '✳'*) return 0 ;; esac
  case $BRAILLE_FRAMES in *"${1:0:1}"*) return 0 ;; esac
  return 1
}

# Everything tmux knows about every pane, in one call.
#
# This used to be three calls per session -- list-windows, capture-pane, then
# display-message for the title -- which cost a fork each and sampled each
# session a few milliseconds apart. One list-panes also reports panes that are
# not the active one, and that fixes a real blind spot: the old format could only
# ever show the active pane's command, so a split window with Claude in its other
# half read as a plain shell.
#
# cursor_x and cursor_y come along for free and are what the classifier leans on
# hardest -- see monitor_classify.
SNAP_SEP=$'\037'   # a control character cannot appear in a session name or title
SNAP_FMT="#{pid}${SNAP_SEP}#{session_name}${SNAP_SEP}#{window_active}${SNAP_SEP}#{pane_id}\
${SNAP_SEP}#{pane_active}${SNAP_SEP}#{cursor_x}${SNAP_SEP}#{cursor_y}\
${SNAP_SEP}#{pane_current_command}${SNAP_SEP}#{window_name}${SNAP_SEP}#{pane_title}"

# The tmux server's pid, which is half of the key the exporters file their state
# under. Pane numbering restarts with a new server, so without it a leftover file
# could be read as some unrelated pane's state.
SERVER_PID=0

P_PANE=()   # per session, same order as SESSIONS: the pane we report on
P_CMD=()
P_CX=()
P_CY=()
P_TITLE=()
P_RANK=()   # how we found it; see the scores below

# Fills SESSIONS and the P_* arrays from one list-panes.
monitor_snapshot() {
  local line spid sess wact pid pact cx cy cmd wname title i n rank
  local raw=()
  SESSIONS=(); P_PANE=(); P_CMD=(); P_CX=(); P_CY=(); P_TITLE=(); P_RANK=()

  while IFS= read -r line; do raw+=("$line"); done \
    < <(tmux list-panes -a -F "$SNAP_FMT" 2>/dev/null)
  [ ${#raw[@]} -gt 0 ] || return 0

  # Session list first, alphabetical and filtered, so rows keep a stable order
  # and the jump keys stay put between ticks.
  while IFS= read -r sess; do
    [ -n "$sess" ] || continue
    SESSIONS+=("$sess"); P_PANE+=(""); P_CMD+=(""); P_CX+=(0); P_CY+=(0)
    P_TITLE+=(""); P_RANK+=(-1)
  done < <(printf '%s\n' "${raw[@]}" |
             cut -d"$SNAP_SEP" -f2 |
             sort -u |
             grep -vx "$MON" |
             { if [ -n "$MONITOR_FILTER" ]; then grep -E "$MONITOR_FILTER"; else cat; fi })

  n=${#SESSIONS[@]}
  [ "$n" -gt 0 ] || return 0

  # Then the best pane for each. The running process is the truth -- automatic
  # rename means the window is often not called "claude" at all -- so a pane
  # running Claude outranks a pane merely sitting in a window named for it, and
  # among equals the active one wins.
  for line in "${raw[@]}"; do
    IFS="$SNAP_SEP" read -r spid sess wact pid pact cx cy cmd wname title <<<"$line"
    [ -n "$spid" ] && SERVER_PID=$spid
    i=0
    while [ "$i" -lt "$n" ]; do
      [ "${SESSIONS[$i]}" = "$sess" ] && break
      i=$((i + 1))
    done
    [ "$i" -lt "$n" ] || continue

    rank=0
    if is_claude_cmd "$cmd"; then rank=400
    elif is_claude_host "$cmd" && title_is_claude "$title"; then rank=300
    elif [ "$wname" = "$MONITOR_WINDOW" ]; then rank=200
    fi
    [ "$wact" = 1 ] && rank=$((rank + 20))
    [ "$pact" = 1 ] && rank=$((rank + 2))

    if [ "$rank" -gt "${P_RANK[$i]}" ]; then
      P_RANK[$i]=$rank; P_PANE[$i]=$pid; P_CMD[$i]=$cmd
      P_CX[$i]=$cx; P_CY[$i]=$cy; P_TITLE[$i]=$title
    fi
  done
}

P_BUSY=()   # per session: 1 when the title says Claude is mid-turn

# Decides, for every session at once, whether its title says Claude is working.
# Claude sets the title to "<braille frame> <task summary>" for the whole turn
# and swaps the frame for "✳" the moment it stops, so the leading glyph is the
# signal -- and the test is the whole braille block rather than a list of frames,
# so it survives Claude picking one we have not seen.
#
# One perl for all sessions, not one each: at twenty sessions that was twenty
# forks a tick, some 5ms apiece, to inspect one character.
monitor_busy_titles() {
  local i n=${#SESSIONS[@]} feed=""
  P_BUSY=()
  i=0
  while [ "$i" -lt "$n" ]; do P_BUSY+=(0); i=$((i + 1)); done
  [ "$n" -gt 0 ] || return 0

  if command -v perl >/dev/null 2>&1; then
    i=0
    while [ "$i" -lt "$n" ]; do
      feed+="$i	${P_TITLE[$i]}"$'\n'
      i=$((i + 1))
    done
    while IFS= read -r i; do
      [ -n "$i" ] && P_BUSY[$i]=1
    done < <(printf '%s' "$feed" | perl -CSD -ne '
               chomp;
               my ($i, $t) = split(/\t/, $_, 2);
               next unless defined $t && length $t;
               my $c = ord(substr($t, 0, 1));
               print "$i\n" if $c >= 0x2800 && $c <= 0x28FF;')
    return 0
  fi

  # No perl: the frames we know about, matched on the first character. bash
  # counts characters here only in a UTF-8 locale; elsewhere this degrades to
  # matching any Claude glyph, which reads a settled session as working.
  i=0
  while [ "$i" -lt "$n" ]; do
    case $BRAILLE_FRAMES in *"${P_TITLE[$i]:0:1}"*) P_BUSY[$i]=1 ;; esac
    i=$((i + 1))
  done
}

# There used to be an age column here, seconds since #{window_activity} formatted
# as 12d3h. It was dropped: a working session streams output constantly, so its
# activity timestamp keeps bumping and the column read 0s however long the turn
# had run -- the one number you actually want it to show.

# --- exported state ----------------------------------------------------------
#
# What claude/monitor-hook.sh and claude/statusline.sh leave behind, one pair of
# files per pane. Reading them costs no forks at all -- they are a handful of
# key=value lines each and bash reads them itself -- so this is nearly free next
# to the capture-pane the screen needs anyway.
#
# Everything here is advisory. A session on another machine, one started before
# the hooks were installed, or one whose Claude was killed before SessionEnd will
# have no file or a stale one, and the monitor falls back to what it can see.

X_STATE=()    # per session, same order as SESSIONS: state from Claude's events
X_DETAIL=()
X_CTX=()      # and the numbers the screen does not carry
X_COST=()
X_COSTF=()    # the same cost, rounded for the column, so the draw does no work
X_COST_ALL="" # every session's cost added up, for the line under the rows
X_ACCT=()     # per session: the account its export was written under
X_LIM5=""     # the fallback pair, for sessions whose account is not known; the
X_LIM7=""     # rest are per account, in the ACC_* table below
X_RST5=""     # already formatted for the header; see monitor_fmt_reset
X_RST7=""
X_AGENTS=()   # per session: subagents in flight; see monitor_count_agents
# A row's number and nothing more. The fleet-wide total used to ride in the
# header next to the cents its finished agents had accounted for, and neither
# said anything worth the width: the count is a sum over a column already on
# screen, and the spend was a breakout of a cost the rows were already showing.
# Spend is split by how the session is paying, because on a subscription the two
# mean completely different things. A subscription session's cost is notional --
# what those tokens would have cost at API rates -- and nothing is billed for it;
# the limits are the real constraint. An API-billed session's cost is money. A
# personal subscription never silently crosses over: hitting the limit stops the
# session and tells you to run /login for an API-billed account, so anything in
# the API column got there because someone chose it.
X_COST_SUB=""
X_COST_API=""
X_COST_OVER=""   # spend the exporter attributed to an exhausted window
X_NOTICE=""      # a limit notice read off some session's screen

# --- accounts -----------------------------------------------------------------
#
# The limits used to be treated as one pair for the whole screen, on the grounds
# that they are account-wide and every session therefore reports the same two
# numbers. That holds for exactly as long as there is one account.
#
# With more than one it is wrong in a way that is worse than useless, because the
# numbers still look right. Whichever session answered last wins the header, so a
# fleet split across two subscriptions shows one of them and calls it the total --
# and it changes which one behind your back, every time the other side answers.
# The same thing happens on a single config dir: /login rewrites it in place, and
# for a while afterwards half the fleet is still reporting the account you just
# left. That is the case worth catching, since nothing on the screen would
# otherwise say the reading had gone stale.
#
# So the readings are grouped by the account they were taken under, and each
# account gets its own line. Parallel arrays rather than a structure: bash 3.2 has
# no associative arrays, and there are only ever a handful of these.
#
# The key is the account's email address, except for two cases that have to be
# kept out of the subscription lines. An API-billed session is keyed "api": it has
# no rate limits at all, and grouping it under whichever address the config
# happens to hold would put a session that is not on the subscription onto the
# subscription's line. A session that has not said -- no exporter, or no answer
# yet -- is keyed empty, and its readings go to the X_LIM5/X_LIM7 fallback so an
# older setup keeps the header it had before this existed.
ACC_KEY=()    # the account, as the status line exported it
ACC_N=()      # live sessions signed in to it
ACC_LIM5=(); ACC_LIM7=()
ACC_RST5=(); ACC_RST7=()   # formatted, like X_RST5
ACC_TS=()     # write time of the reading held above, so the newest one wins
ACC_TAG=()    # short label for the session rows; see monitor_acc_tags
ACC_OFF=()    # nothing live on it: the line comes from the ledger below
ACC_SHOWN=0   # accounts with a line of their own, i.e. not "api" and not unknown
ACC_LIVE=0    # of those, the ones a session is actually reporting

# --- accounts with nothing live on them ---------------------------------------
#
# An account used to leave the screen the moment its last session did, which is
# the wrong moment. Switching away is exactly when its windows matter: you left
# because one of them was full, and what you want to see afterwards is how full,
# and when it comes back. Reading it off the sessions cannot survive that -- the
# export belongs to a pane, and a pane that has moved to another account, or has
# no Claude in it at all, has nothing left to say about the one you left.
#
# So the status line also files each reading under the account itself, in
# $MONITOR_DIR/limits/<address>, and those files outlive every session on them.
# This is where an account with no live session gets its line from. Same reading,
# same newest-wins rule, same test for whether it has been superseded -- the only
# difference is where it was read and that the line says nothing is running on it.
#
# Kept for a week and a day, which is one weekly window plus the day it resets
# on: past that the reading describes nothing current and the account has not
# been used since, so the line would be a name and two blanks. The files
# themselves are left alone -- one per account is not worth a delete, and the
# next reading rewrites it in place.
ACCT_DIR="$MONITOR_DIR/limits"
ACCT_KEEP=${MONITOR_ACCT_KEEP:-691200}

# The notices Claude Code puts up about limits and extra usage. These are matched
# rather than any field, because the field does not exist anywhere reachable:
# isUsingOverage lives only inside the process, and its own renderer returns
# nothing at all for the ordinary in-overage case -- a message appears only near
# the overage cap or once something has been refused. So this catches the loud
# half, and the exporter's arithmetic covers the quiet half.
#
# Matched as whole phrases, since the bottom of the screen also holds Claude's
# own prose and "you've reached your" is a sentence anyone might write.
LIMIT_NOTICES='close to your usage limit|close to your usage credit limit|out of extra usage|out of usage credits|hit your monthly spend limit|hit your usage limit|monthly spend limit|now using extra usage'

# Epoch -> local clock, remembered so this costs a fork only when the window
# actually rolls over. The header is rebuilt on every keystroke and must not
# fork; these are computed on the refresh tick instead.
#
# Cached by epoch and format together rather than in a slot per window: with two
# accounts on screen there are two of each window, all four are formatted every
# tick, and a two-slot memo would miss on every one of them. Keyed by format as
# well because the two windows are shown in different shapes.
FMT_OUT=""
FMTC_K=()
FMTC_V=()

# Whether a window's reset is still ahead of us, i.e. the reading that came with
# it describes the window we are in. An unreadable or absent epoch counts as
# pending: an old Claude that never sent one should not have all its numbers
# thrown away.
monitor_reset_pending() {
  case ${1:-} in
    ''|0|*[!0-9]*) return 0 ;;
    *) [ "$1" -ge "${2:-0}" ] ;;
  esac
}
monitor_fmt_reset() {
  # date -r takes an epoch on BSD and a filename on GNU, so the GNU spelling is
  # the fallback rather than the other way round.
  FMT_OUT=$(date -r "$1" "+$2" 2>/dev/null) ||
    FMT_OUT=$(date -d "@$1" "+$2" 2>/dev/null) ||
    FMT_OUT=""
}

# Reads one key=value file into KV_*. Values may contain "=" -- read gives the
# last variable the unsplit remainder -- but not newlines; the hook flattens
# those before writing for exactly this reason.
KV_STATE=""; KV_DETAIL=""; KV_TS=0
KV_CTX=""; KV_COST=""; KV_LIM5=""; KV_LIM7=""
KV_RST5=""; KV_RST7=""; KV_SUB=""; KV_SESSION=""; KV_ACCT=""
monitor_read_kv() {
  local f=$1 k v
  [ -r "$f" ] || return 1
  while IFS='=' read -r k v; do
    case $k in
      state)   KV_STATE=$v ;;
      detail)  KV_DETAIL=$v ;;
      ctx)     KV_CTX=$v ;;
      cost)    KV_COST=$v ;;
      over)    KV_OVER=$v ;;
      lim5)    KV_LIM5=$v ;;
      lim7)    KV_LIM7=$v ;;
      rst5)    KV_RST5=$v ;;
      rst7)    KV_RST7=$v ;;
      sub)     KV_SUB=$v ;;
      acct)    KV_ACCT=$v ;;
      session) KV_SESSION=$v ;;
      ts)      KV_TS=$v ;;
    esac
  done < "$f"
  return 0
}

# The tick's clock, read once and shared: bash 3.2 has no $EPOCHSECONDS, and both
# the age of an exported state and the ledger's idea of "today" need it. A fork
# per session -- or one per consumer -- would cost more than reading every file
# they look at.
MON_NOW=0
MON_DAY=""
monitor_clock() {
  local out
  out=$(date '+%s %F' 2>/dev/null) || return 1
  read -r MON_NOW MON_DAY <<<"$out"
  [ -n "$MON_NOW" ]
}

# --- parked jobs --------------------------------------------------------------
#
# What is in a pane is not always what is doing the work. Handed something long,
# Claude parks it: a background session is started under its daemon and the pane
# shows that session instead. The daemon does not pass $TMUX_PANE on, so the
# session actually working -- spending the money, running the agents -- has no
# pane to be keyed by, and the pane's own export freezes at the moment it parked.
# A row showing that export is not stale by a little: it is the wrong session.
#
# Claude keeps a registry that closes the gap, one small JSON file per running
# session in $SESSION_DIR. The session in the pane carries a parkedJobId, and the
# session doing the work carries the matching jobId along with its own session id
# -- which is the key its exports are filed under. So: pane -> its session id ->
# parkedJobId -> jobId -> the background session's export.
#
# The whole registry is read once a tick into two flat indexes, since bash 3.2 on
# this laptop has no associative arrays. A few dozen one-line files read by bash
# itself, so this costs no forks either.
PARKED_BY_SID=" "   # " <session id>:<parked job id> " for each that has parked one
SID_BY_JOB=" "      # " <job id>:<session id> " for each background session

# One string field out of one line of flat JSON, without a fork. Keys are matched
# with the punctuation in front of them, or "jobId" would find "parkedJobId" -- a
# session would then be read as the parked job of itself. A value with an escaped
# quote in it would come back short, which is why this is only ever used for ids.
JSTR=""
monitor_json_str() {
  local line=$1 k=$2 rest
  JSTR=""
  case $line in
    *",\"$k\":\""*) rest=${line#*",\"$k\":\""} ;;
    *"{\"$k\":\""*) rest=${line#*"{\"$k\":\""} ;;
    *) return 1 ;;
  esac
  JSTR=${rest%%'"'*}
  [ -n "$JSTR" ]
}

# Fills the two indexes. A registry that is not there at all -- another machine's
# monitor directory, an older Claude -- leaves them empty and every pane then
# reads as unparked, which is what it was before this existed.
monitor_read_sessions() {
  local f line sid job
  PARKED_BY_SID=" "; SID_BY_JOB=" "
  [ -d "$SESSION_DIR" ] || return 0
  for f in "$SESSION_DIR"/*.json; do
    [ -f "$f" ] || continue
    # Not `read ... || continue`: these files carry no trailing newline, so read
    # reports failure on the very line it just handed us.
    line=""
    IFS= read -r line < "$f" || true
    [ -n "$line" ] || continue
    monitor_json_str "$line" sessionId || continue
    sid=$JSTR
    monitor_json_str "$line" parkedJobId && PARKED_BY_SID+="$sid:$JSTR "
    monitor_json_str "$line" jobId && SID_BY_JOB+="$JSTR:$sid "
  done
  return 0
}

LOOKUP=""
monitor_index_get() { # value for $2 in index $1, or ""
  local rest
  LOOKUP=""
  case $1 in
    *" $2:"*) rest=${1#*" $2:"}; LOOKUP=${rest%% *} ;;
  esac
}

# Where the session in this pane has parked its work, if it has: the prefix its
# files are under, or "" to stay with the pane's own.
PARKED_BASE=""
monitor_parked_base() {
  local sid=$1 job cand
  PARKED_BASE=""
  [ -n "$sid" ] || return 0
  monitor_index_get "$PARKED_BY_SID" "$sid"; job=$LOOKUP
  [ -n "$job" ] || return 0
  monitor_index_get "$SID_BY_JOB" "$job"; sid=$LOOKUP
  [ -n "$sid" ] || return 0
  cand="$MONITOR_DIR/sess-$sid"
  # Only once it has exported something. A job that has finished, or one on a
  # machine where the exporters are not installed, leaves nothing here -- and the
  # pane's own numbers, old as they are, are then the best there is.
  { [ -r "$cand.state" ] || [ -r "$cand.meta" ]; } && PARKED_BASE=$cand
  return 0
}

# How many subagents the pane's session has in flight: one empty file per agent,
# left in $base.agents by monitor-hook.sh on SubagentStart and removed on
# SubagentStop. A glob, so it costs no forks -- and no arithmetic on our side,
# since the hook has already done the counting by naming the files.
#
# Not aged like the state file. A session that spawns five background agents and
# goes quiet waiting on them stops writing state long before they finish, and
# expiring the count would blank it on exactly the sessions it is there for. What
# guards it instead is the pane: a leftover directory can only be read as this
# session's if Claude is still up in that pane, and monitor_collect drops the
# count for a pane that is not running one.
AGENT_N=0
monitor_count_agents() {
  local f
  AGENT_N=0
  for f in "$1"/*; do
    [ -e "$f" ] || continue
    AGENT_N=$((AGENT_N + 1))
  done
}

# Where an account sits in the table, in ACC_I. Linear, because the table is a
# handful of entries and an index over it would cost more to build than to scan.
ACC_I=-1
monitor_acc_find() {
  local key=$1 i=0 n=${#ACC_KEY[@]}
  ACC_I=-1
  while [ "$i" -lt "$n" ]; do
    [ "${ACC_KEY[$i]}" = "$key" ] && { ACC_I=$i; return 0; }
    i=$((i + 1))
  done
  return 1
}

# The same, adding the account if it is not there yet.
monitor_acc_slot() {
  monitor_acc_find "$1" && return 0
  ACC_I=${#ACC_KEY[@]}
  ACC_KEY+=("$1"); ACC_N+=(0)
  ACC_LIM5+=(""); ACC_LIM7+=("")
  ACC_RST5+=(""); ACC_RST7+=("")
  ACC_TS+=(0); ACC_TAG+=(""); ACC_OFF+=("")
  return 0
}

# Takes the reading just read into the KV_* variables as account $ACC_I's, if it
# beats the one already there. Shared by the live exports and the ledger, so both
# get the same two rules.
#
# The newest write wins, because the limits are account-wide and every session on
# one account reports the same pair -- but each only rewrites its file when its
# own status line runs, so the files disagree by however long ago that was.
#
# A fresh write timestamp is not enough to trust them, though. These numbers come
# from the last API response that session received, so a session sitting idle
# across a window rollover keeps re-exporting the old window's usage with a new
# timestamp on it -- most of the fleet reads that way most of the time. The reset
# epoch is what gives it away: once it is in the past the figure it came with
# describes a window that has since rolled, whatever the timestamp says. Better no
# number than last window's, so it is dropped rather than shown.
#
# Each window is judged by its own epoch, because they roll at completely
# different rates. A reading taken six hours ago has certainly outlived its 5-hour
# window and almost certainly not its weekly one -- and on an account nothing is
# running on any more, that weekly figure is the whole reason to still be looking
# at it. Condemning the pair on the 5-hour epoch would throw it away every time.
monitor_acc_reading() {
  local now=$1 p5="" p7=""
  case $KV_TS in ''|*[!0-9]*) return 1 ;; esac
  [ "$KV_TS" -gt "${ACC_TS[$ACC_I]}" ] || return 1
  [ -n "$KV_LIM5$KV_LIM7" ] && [ "$KV_LIM5" != -1 ] || return 1
  monitor_reset_pending "$KV_RST5" "$now" && p5=1
  monitor_reset_pending "$KV_RST7" "$now" && p7=1
  # Nothing in it describes a window we are still in, so there is nothing to take
  # -- and the timestamp is not taken either, which leaves an older reading that
  # does describe one able to win.
  [ -n "$p5$p7" ] || return 1
  ACC_TS[$ACC_I]=$KV_TS
  monitor_reset_texts "$KV_RST5" "$KV_RST7"
  if [ -n "$p5" ]; then
    ACC_LIM5[$ACC_I]=$KV_LIM5
    ACC_RST5[$ACC_I]=$RST5_OUT
  else
    ACC_LIM5[$ACC_I]=""
    ACC_RST5[$ACC_I]=""
  fi
  if [ -n "$p7" ]; then
    ACC_LIM7[$ACC_I]=$KV_LIM7
    ACC_RST7[$ACC_I]=$RST7_OUT
  else
    ACC_LIM7[$ACC_I]=""
    ACC_RST7[$ACC_I]=""
  fi
  return 0
}

# The accounts the ledger remembers, for the ones with no session left to report
# them. Called after the sessions have been counted, since that count is what
# says which accounts need this -- and the reading is merged for every account it
# holds, live or not: it is the same reading the sessions are exporting, so on a
# live account it either loses to a fresher one or is that fresher one, filed by a
# session that has since gone.
monitor_acc_remembered() {
  local f b now=$MON_NOW cutoff
  [ -d "$ACCT_DIR" ] || return 0
  [ "$now" -gt 0 ] 2>/dev/null || return 0
  cutoff=$((now - ACCT_KEEP))
  for f in "$ACCT_DIR"/*; do
    [ -f "$f" ] || continue
    b=${f##*/}
    # An address and nothing else: a temp file caught mid-rename, or whatever
    # else ends up in the directory, is not one of ours. The same check the
    # status line makes on the way in, because a name is drawn on the screen.
    case $b in
      *@*) ;;
      *) continue ;;
    esac
    case $b in
      *[!A-Za-z0-9@._+-]*) continue ;;
    esac
    KV_LIM5=""; KV_LIM7=""; KV_RST5=""; KV_RST7=""; KV_TS=0
    monitor_read_kv "$f" || continue
    case $KV_TS in ''|*[!0-9]*) continue ;; esac
    [ "$KV_TS" -ge "$cutoff" ] || continue
    monitor_acc_slot "$b"
    monitor_acc_reading "$now" || true
    # Whether this account has a line of its own to earn, rather than a row on
    # the screen already saying where it is. Set after the merge and not before,
    # so an account whose sessions have all gone is still described by the
    # freshest reading any of them left.
    [ "${ACC_N[$ACC_I]}" -eq 0 ] && ACC_OFF[$ACC_I]=1
  done
  return 0
}

# Short labels for the session rows. The address itself is too wide to put on
# every row -- it would take a sixth of an 80-column screen -- so the part in
# front of the @ stands in for it, which is what tells accounts apart in every
# case that is not deliberately adversarial.
#
# Where it does not, because two addresses share a local part, both fall back to
# the front of the whole address. Two that are still the same after that read as
# one account on the rows; the lines under the header spell them out in full, and
# that is the place to look when the tags do not add up.
ACC_TAGW=8
monitor_acc_tags() {
  local i=0 j n=${#ACC_KEY[@]} t
  while [ "$i" -lt "$n" ]; do
    t=${ACC_KEY[$i]%%@*}
    ACC_TAG[$i]=${t:0:$ACC_TAGW}
    i=$((i + 1))
  done
  # Compared after truncation, since that is what ends up on the screen: two
  # addresses that first differ past the eighth character collide here just as
  # much as two that are identical.
  i=0
  while [ "$i" -lt "$n" ]; do
    j=$((i + 1))
    while [ "$j" -lt "$n" ]; do
      if [ -n "${ACC_TAG[$i]}" ] && [ "${ACC_TAG[$i]}" = "${ACC_TAG[$j]}" ]; then
        ACC_TAG[$i]=${ACC_KEY[$i]:0:$ACC_TAGW}
        ACC_TAG[$j]=${ACC_KEY[$j]:0:$ACC_TAGW}
      fi
      j=$((j + 1))
    done
    i=$((i + 1))
  done
}

# Which accounts get a line, and in what order: alphabetical within each half, so
# a line does not jump because a session on some other account came or went.
#
# Left out are the two keys that are not subscriptions to report on -- "api",
# which has no limits by construction, and the unknown account, whose reading
# goes to the header instead -- and any account whose only trace is a meta file a
# dead session left in a pane. An account with nothing live on it is drawn only
# where the ledger remembers it, which is what tells a switched-away account from
# a stale export.
ACC_ORDER=()
ACC_TAGGED=0
monitor_acc_order() {
  local i=0 n=${#ACC_KEY[@]} j k t
  local sk=()   # what each entry sorts by, in step with ACC_ORDER
  ACC_ORDER=(); ACC_SHOWN=0; ACC_LIVE=0; ACC_TAGGED=0
  while [ "$i" -lt "$n" ]; do
    if [ -n "${ACC_KEY[$i]}" ] &&
       { [ "${ACC_N[$i]}" -gt 0 ] || [ -n "${ACC_OFF[$i]:-}" ]; }; then
      # The column on the rows is for telling live sessions apart, so only an
      # account with sessions on it counts toward whether there is one.
      [ "${ACC_N[$i]}" -gt 0 ] && ACC_TAGGED=$((ACC_TAGGED + 1))
      if [ "${ACC_KEY[$i]}" != api ]; then
        [ "${ACC_N[$i]}" -gt 0 ] && ACC_LIVE=$((ACC_LIVE + 1))
        j=${#ACC_ORDER[@]}
        ACC_ORDER+=("$i")
        # Live accounts first and the rest under them, each half alphabetical.
        # The screen is about what is running; what is not is context for it.
        if [ "${ACC_N[$i]}" -gt 0 ]; then
          sk+=("0${ACC_KEY[$i]}")
        else
          sk+=("1${ACC_KEY[$i]}")
        fi
        while [ "$j" -gt 0 ]; do
          k=$((j - 1))
          [[ ${sk[$k]} > ${sk[$j]} ]] || break
          t=${ACC_ORDER[$j]}; ACC_ORDER[$j]=${ACC_ORDER[$k]}; ACC_ORDER[$k]=$t
          t=${sk[$j]}; sk[$j]=${sk[$k]}; sk[$k]=$t
          j=$k
        done
      fi
    fi
    i=$((i + 1))
  done
  ACC_SHOWN=${#ACC_ORDER[@]}
}

# Fills the X_* arrays for every session, and the ACC_* table behind them.
monitor_read_exports() {
  local i n=${#SESSIONS[@]} now base acck subc=0 apic=0 overc=0 allc=0
  local seen_sub="" seen_api="" seen_any=""
  X_STATE=(); X_DETAIL=(); X_CTX=(); X_COST=(); X_COSTF=(); X_AGENTS=()
  X_ACCT=()
  ACC_KEY=(); ACC_N=(); ACC_LIM5=(); ACC_LIM7=(); ACC_RST5=(); ACC_RST7=()
  ACC_TS=(); ACC_TAG=(); ACC_OFF=(); ACC_ORDER=()
  ACC_SHOWN=0; ACC_LIVE=0; ACC_TAGGED=0
  X_LIM5=""; X_LIM7=""; X_RST5=""; X_RST7=""
  X_COST_SUB=""; X_COST_API=""; X_COST_OVER=""; X_COST_ALL=""; X_NOTICE=""
  i=0
  while [ "$i" -lt "$n" ]; do
    X_STATE+=(""); X_DETAIL+=(""); X_CTX+=(""); X_COST+=(""); X_COSTF+=("")
    X_AGENTS+=(0); X_ACCT+=("")
    i=$((i + 1))
  done
  [ "$n" -gt 0 ] && [ -d "$MONITOR_DIR" ] || return 0

  now=$MON_NOW
  [ "$now" -gt 0 ] 2>/dev/null || return 0
  monitor_read_sessions
  i=0
  while [ "$i" -lt "$n" ]; do
    base="$MONITOR_DIR/${SERVER_PID}-${P_PANE[$i]#%}"

    # Which session is in this pane, and whether what it is showing is really
    # somewhere else -- see the parked jobs section. The state file is asked first
    # because it exists from a session's very first event, where the metadata one
    # waits for a status line to render; both carry the id.
    KV_SESSION=""
    monitor_read_kv "$base.state" || true
    [ -n "$KV_SESSION" ] || monitor_read_kv "$base.meta" || true
    monitor_parked_base "$KV_SESSION"
    [ -n "$PARKED_BASE" ] && base=$PARKED_BASE

    monitor_count_agents "$base.agents"
    X_AGENTS[$i]=$AGENT_N

    KV_STATE=""; KV_DETAIL=""; KV_TS=0
    if monitor_read_kv "$base.state" &&
       [ $((now - KV_TS)) -lt "$MONITOR_STALE" ] 2>/dev/null; then
      X_STATE[$i]=$KV_STATE
      X_DETAIL[$i]=$KV_DETAIL
    fi

    # The metadata half is not aged the same way. Its numbers only move when
    # Claude answers, so a quiet session's context and cost stay true for as long
    # as it stays quiet -- expiring them would blank the column on exactly the
    # sessions that have been sitting there longest.
    KV_CTX=""; KV_COST=""; KV_LIM5=""; KV_LIM7=""; KV_TS=0
    KV_RST5=""; KV_RST7=""; KV_SUB=""; KV_OVER=""; KV_ACCT=""
    if monitor_read_kv "$base.meta"; then
      X_CTX[$i]=$KV_CTX
      X_COST[$i]=$KV_COST

      # Which account this reading was taken under, and so which account's
      # windows it describes. An API-billed session is keyed apart from the
      # subscriptions whatever address the config holds, because it is not
      # spending against any of them; see the accounts section.
      case $KV_SUB in
        0) acck=api ;;
        *) acck=$KV_ACCT ;;
      esac
      X_ACCT[$i]=$acck
      monitor_acc_slot "$acck"

      # Whichever reading on this account is newest and still current -- see
      # monitor_acc_reading, which the ledger goes through as well, so a session
      # read here and a file left behind by one that has gone are judged the same
      # way.
      monitor_acc_reading "$now" || true
      # Into whichever column this session is paying from. A session that has not
      # answered yet reports neither, and is left out rather than guessed at.
      case $KV_COST in
        ''|*[!0-9.]*) ;;
        *)
          monitor_cents "$KV_COST"
          # Rounded here rather than in the draw: the draw reruns on every
          # keystroke and the arithmetic would be repeated for nothing.
          printf -v X_COSTF[$i] '$%d.%02d' $((CENTS / 100)) $((CENTS % 100))
          allc=$((allc + CENTS)); seen_any=1
          case $KV_SUB in
            1) subc=$((subc + CENTS)); seen_sub=1 ;;
            0) apic=$((apic + CENTS)); seen_api=1 ;;
          esac
          ;;
      esac
      case $KV_OVER in
        ''|*[!0-9.]*) ;;
        *) monitor_cents "$KV_OVER"; overc=$((overc + CENTS)) ;;
      esac
    fi
    i=$((i + 1))
  done
  # The header's fallback pair: the reading from sessions that did not say which
  # account it came from -- a Claude older than the acct= key, or one whose
  # status line has not run since this was installed. Drawn only when no account
  # identified itself at all, so an installation without any of this keeps the
  # header it had before; where some sessions do name an account, they get lines
  # and this reading is dropped rather than shown as a nameless third window.
  if monitor_acc_find ""; then
    X_LIM5=${ACC_LIM5[$ACC_I]}
    X_LIM7=${ACC_LIM7[$ACC_I]}
    X_RST5=${ACC_RST5[$ACC_I]}
    X_RST7=${ACC_RST7[$ACC_I]}
  fi
  [ "$overc" -gt 0 ] && printf -v X_COST_OVER '%d.%02d' $((overc / 100)) $((overc % 100))
  # Formatted only if something landed there, so an absent column stays absent
  # rather than reading $0.00 -- which would look like a measurement.
  [ -n "$seen_sub" ] && printf -v X_COST_SUB '%d.%02d' $((subc / 100)) $((subc % 100))
  [ -n "$seen_api" ] && printf -v X_COST_API '%d.%02d' $((apic / 100)) $((apic % 100))
  [ -n "$seen_any" ] && printf -v X_COST_ALL '%d.%02d' $((allc / 100)) $((allc % 100))
  return 0
}

# One epoch, formatted, through the cache above -- so this forks only when a
# window actually rolls over, not once per account per tick. An epoch that is not
# one comes back empty rather than as whatever date would make of it.
RST_OUT=""
monitor_reset_text() {
  local e=$1 f=$2 k i=0 n=${#FMTC_K[@]}
  RST_OUT=""
  case $e in ''|0|*[!0-9]*) return 0 ;; esac
  k="$e $f"
  while [ "$i" -lt "$n" ]; do
    [ "${FMTC_K[$i]}" = "$k" ] && { RST_OUT=${FMTC_V[$i]}; return 0; }
    i=$((i + 1))
  done
  # Two entries per account per rollover, so this grows by a handful a day on a
  # monitor left up for one. Dropped wholesale rather than aged: the next tick
  # refills whatever is still current, at the cost of one fork each.
  [ "$n" -gt 32 ] && { FMTC_K=(); FMTC_V=(); }
  monitor_fmt_reset "$e" "$f"
  RST_OUT=$FMT_OUT
  FMTC_K+=("$k"); FMTC_V+=("$RST_OUT")
  return 0
}

# The pair, into RST5_OUT and RST7_OUT. The 5-hour window is shown as a clock
# time and the weekly one as a day, since one is always today and the other
# rarely is.
RST5_OUT=""; RST7_OUT=""
monitor_reset_texts() {
  monitor_reset_text "$1" '%-l:%M%p'; RST5_OUT=$RST_OUT
  monitor_reset_text "$2" '%a %-l%p'; RST7_OUT=$RST_OUT
}

# "1.234" -> CENTS=123. Assigns rather than prints: a $(...) per session to add up
# a column of numbers is a fork per session, which cost more than reading all the
# files put together. Truncates rather than rounds -- this is a running total for
# a header, not an invoice.
CENTS=0
monitor_cents() {
  local v=$1 whole frac
  case $v in
    *.*) whole=${v%%.*}; frac=${v#*.} ;;
    *)   whole=$v; frac=0 ;;
  esac
  frac=${frac}00
  frac=${frac:0:2}
  case $whole in ''|*[!0-9]*) whole=0 ;; esac
  case $frac in ''|*[!0-9]*) frac=0 ;; esac
  CENTS=$((10#$whole * 100 + 10#$frac))
}

# --- spend ledger --------------------------------------------------------------
#
# What claude/statusline.sh files under $MONITOR_DIR/spend: one "<day>.<session>"
# per session per day, holding the cents that session spent on that day. Unlike
# the per-pane exports, these outlive the session that wrote them, which is the
# whole point -- the cost column adds up what is running now, and this adds up
# what has been spent, whether or not anything is still up to show for it.
#
# Today's spend is inside these totals as well, since a live session rewrites its
# file as it goes. So "total" and "today" overlap on purpose: one is the sessions
# on screen, the other the day they are part of.
#
# Each file records how its session was paying as well, so the windows carry the
# same sub/api split as the live line rather than one lump per window.
LEDGER_DIR="$MONITOR_DIR/spend"

# One row per window, in the order they are drawn. Already formatted, like the
# other totals: the draw does no arithmetic.
SPEND_LBL=(today 7d 30d all)
SPEND_ALL=("" "" "" "")
SPEND_SUB=("" "" "" "")
SPEND_API=("" "" "" "")

# Days before today are frozen -- a session past midnight writes to the new day's
# file -- so their sums are computed once and held until the day rolls over,
# leaving each tick with only today's handful of files to read. Indexed 0..2 for
# 7d, 30d and all-time, today excluded from every one of them.
LDG_DAY=""     # the day those sums were computed for
LDG_P_ALL=(0 0 0)
LDG_P_SUB=(0 0 0)
LDG_P_API=(0 0 0)
LDG_CUT7=""    # the oldest day each window includes, blank if date could not say
LDG_CUT30=""
LDG_ANY=""     # whether the ledger holds anything at all; see below

# $1 days back as a local date, BSD spelling first and GNU second -- the same
# order as monitor_fmt_reset, and for the same reason.
DAY_AGO=""
monitor_day_ago() {
  DAY_AGO=$(date -v-"$1"d '+%F' 2>/dev/null) ||
    DAY_AGO=$(date -d "$1 days ago" '+%F' 2>/dev/null) ||
    DAY_AGO=""
}

day_ge() { [ "$1" = "$2" ] || [[ $1 > $2 ]]; }

# The day before an ISO date, in bash alone. The usage view walks the calendar a
# day at a time -- a day the ledger has no file for is a day nothing ran, and is
# drawn as the zero it is -- and a fork per day walked would cost more than the
# whole chart.
DAY_PREV=""
monitor_day_prev() {
  local y=$((10#${1:0:4})) m=$((10#${1:5:2})) d=$((10#${1:8:2}))
  d=$((d - 1))
  if [ "$d" -lt 1 ]; then
    m=$((m - 1))
    [ "$m" -lt 1 ] && { m=12; y=$((y - 1)); }
    case $m in
      1|3|5|7|8|10|12) d=31 ;;
      4|6|9|11)        d=30 ;;
      *) d=28
         if [ $((y % 4)) -eq 0 ] &&
            { [ $((y % 100)) -ne 0 ] || [ $((y % 400)) -eq 0 ]; }; then
           d=29
         fi
         ;;
    esac
  fi
  printf -v DAY_PREV '%04d-%02d-%02d' "$y" "$m" "$d"
}

# "Mon 06 Aug" for an ISO date, and which day of the week it was in DAY_DOW (0 is
# Sunday). Sakamoto's method: a twelve-entry table and some integer division,
# against a fork per column for `date`, on a screen that draws a column per day.
#
# The weekday is what makes the chart read as a calendar rather than as a list --
# a run of quiet Saturdays is only visible if the Saturdays are named.
DOW_NAMES=(Sun Mon Tue Wed Thu Fri Sat)
MON_NAMES=(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
DOW_SHIFT=(0 3 2 5 0 3 5 1 4 6 2 4)
DAY_LABEL=""
DAY_DOW=0
monitor_day_label() {
  local y=$((10#${1:0:4})) m=$((10#${1:5:2})) d=$((10#${1:8:2}))
  # January and February belong to the year before, which is what lets one
  # formula cover the leap years.
  [ "$m" -lt 3 ] && y=$((y - 1))
  DAY_DOW=$(( (y + y / 4 - y / 100 + y / 400 + ${DOW_SHIFT[$((m - 1))]} + d) % 7 ))
  DAY_LABEL="${DOW_NAMES[$DAY_DOW]} ${1:8:2} ${MON_NAMES[$((m - 1))]}"
}

# Cents and payment kind out of one ledger file. Read by bash itself, so a day of
# files costs no forks at all. LDG_SUB is 1 subscription, 0 API-billed, -1 for a
# session that never got far enough to say -- the same three values the status
# line exports, and the third is counted in the total and in neither column.
LDG_CENTS=0
LDG_SUB=-1
monitor_ledger_file() {
  local k v
  LDG_CENTS=0; LDG_SUB=-1
  [ -r "$1" ] || return 1
  while IFS='=' read -r k v; do
    case $k in
      spent) LDG_CENTS=$v ;;
      sub)   LDG_SUB=$v ;;
    esac
  done < "$1"
  case $LDG_CENTS in ''|*[!0-9]*) LDG_CENTS=0 ;; esac
  case $LDG_SUB in 0|1) ;; *) LDG_SUB=-1 ;; esac
  return 0
}

# Adds the file just read into window $1 of the cached past sums.
monitor_ledger_add() {
  LDG_P_ALL[$1]=$((${LDG_P_ALL[$1]} + LDG_CENTS))
  case $LDG_SUB in
    1) LDG_P_SUB[$1]=$((${LDG_P_SUB[$1]} + LDG_CENTS)) ;;
    0) LDG_P_API[$1]=$((${LDG_P_API[$1]} + LDG_CENTS)) ;;
  esac
}

# Sums every day but today, for as long as today lasts.
monitor_ledger_rebuild() {
  local f b d
  LDG_DAY=$MON_DAY
  LDG_P_ALL=(0 0 0); LDG_P_SUB=(0 0 0); LDG_P_API=(0 0 0)
  # The usage view's day-by-day list is filed from this same pass; see the usage
  # history section below for why it rides along here rather than reading the
  # directory a second time.
  LDG_H_DAY=(); LDG_H_ALL=(); LDG_H_SUB=(); LDG_H_API=(); HIST_KEY=""
  monitor_day_ago 6;  LDG_CUT7=$DAY_AGO
  monitor_day_ago 29; LDG_CUT30=$DAY_AGO
  [ -d "$LEDGER_DIR" ] || return 0
  for f in "$LEDGER_DIR"/*; do
    [ -f "$f" ] || continue
    b=${f##*/}
    d=${b%%.*}
    # A name that is not "<iso day>.<something>" is not ours: a temp file caught
    # mid-rename, or whatever else ends up in the directory.
    case $b in "$d") continue ;; esac
    case $d in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) continue ;;
    esac
    LDG_ANY=1
    [ "$d" = "$MON_DAY" ] && continue
    monitor_ledger_file "$f" || continue
    monitor_ledger_add 2
    monitor_hist_file "$d"
    [ -n "$LDG_CUT30" ] && day_ge "$d" "$LDG_CUT30" && monitor_ledger_add 1
    [ -n "$LDG_CUT7" ] && day_ge "$d" "$LDG_CUT7" && monitor_ledger_add 0
  done
  return 0
}

# "$1 cents" -> LDG_FMT="12.34". One place, because the rows below want it a
# dozen times and a $(...) each would be a dozen forks a tick.
LDG_FMT=""
monitor_ledger_fmt() { printf -v LDG_FMT '%d.%02d' $(($1 / 100)) $(($1 % 100)); }

# Today's files every tick, the rest from the cache above, then the four rows.
monitor_read_ledger() {
  local f i t_all=0 t_sub=0 t_api=0 c
  SPEND_ALL=("" "" "" ""); SPEND_SUB=("" "" "" ""); SPEND_API=("" "" "" "")
  LDG_T_ALL=0; LDG_T_SUB=0; LDG_T_API=0
  [ -n "$MON_DAY" ] && [ -d "$LEDGER_DIR" ] || return 0
  [ "$LDG_DAY" = "$MON_DAY" ] || monitor_ledger_rebuild

  for f in "$LEDGER_DIR/$MON_DAY".*; do
    [ -f "$f" ] || continue
    LDG_ANY=1
    monitor_ledger_file "$f" || continue
    t_all=$((t_all + LDG_CENTS))
    case $LDG_SUB in
      1) t_sub=$((t_sub + LDG_CENTS)) ;;
      0) t_api=$((t_api + LDG_CENTS)) ;;
    esac
  done

  # Today, for the usage view: it walks the calendar and the rebuild above stops
  # short of today, since today is still being written.
  LDG_T_ALL=$t_all; LDG_T_SUB=$t_sub; LDG_T_API=$t_api

  # An empty ledger reads as unknown rather than zero, the same way a session
  # that has not reported leaves its cost column blank: nobody has spent nothing
  # today, they have just not installed the exporter yet. Once there is a single
  # file, a quiet day is a real $0.00 and says so.
  [ -n "$LDG_ANY" ] || return 0

  # Row 0 is today alone; the rest are today plus the days behind them, which is
  # why every window is built from the same pair rather than summed twice.
  i=0
  while [ "$i" -lt 4 ]; do
    # 7d and 30d are dropped when date could not work out where they start --
    # better an absent row than one that quietly means something else.
    if { [ "$i" = 1 ] && [ -z "$LDG_CUT7" ]; } ||
       { [ "$i" = 2 ] && [ -z "$LDG_CUT30" ]; }; then
      i=$((i + 1)); continue
    fi
    case $i in
      0) c=0 ;;                 # today: nothing behind it
      *) c=$((i - 1)) ;;        # 7d, 30d, all: cached window i-1
    esac

    if [ "$i" = 0 ]; then
      monitor_ledger_fmt "$t_all"; SPEND_ALL[$i]=$LDG_FMT
      [ "$t_sub" -gt 0 ] && { monitor_ledger_fmt "$t_sub"; SPEND_SUB[$i]=$LDG_FMT; }
      [ "$t_api" -gt 0 ] && { monitor_ledger_fmt "$t_api"; SPEND_API[$i]=$LDG_FMT; }
    else
      monitor_ledger_fmt $((${LDG_P_ALL[$c]} + t_all)); SPEND_ALL[$i]=$LDG_FMT
      if [ $((${LDG_P_SUB[$c]} + t_sub)) -gt 0 ]; then
        monitor_ledger_fmt $((${LDG_P_SUB[$c]} + t_sub)); SPEND_SUB[$i]=$LDG_FMT
      fi
      if [ $((${LDG_P_API[$c]} + t_api)) -gt 0 ]; then
        monitor_ledger_fmt $((${LDG_P_API[$c]} + t_api)); SPEND_API[$i]=$LDG_FMT
      fi
    fi
    i=$((i + 1))
  done
  return 0
}

# --- usage history ------------------------------------------------------------
#
# The same ledger the windows above total, kept day by day instead of summed into
# four figures, so the whole run of it can be drawn: one column per calendar day
# for as far back as the files go. That is the 'u' screen; see monitor_draw_usage.
#
# Calendar, not directory listing: a day with no file is a day nothing ran, and a
# chart that skips those reads as a busier month than it was. So the days between
# the files are walked and drawn as the zeros they are.
#
# The days themselves are filed by monitor_ledger_rebuild, which is already
# reading every file once a day -- a pass of our own would double the only
# expensive read the monitor makes. Its glob expands in name order, so one day's
# files arrive together and each bucket is closed before the next one opens: no
# lookup per file, and no associative array, which bash 3.2 does not have.

# How far back the chart goes. Not a display limit -- the view scrolls -- but a
# floor under the walk: one file with a bad date on it (a clock that came up in
# 1970) would otherwise put fifty thousand empty days between then and now.
HIST_DAYS=${MONITOR_HISTORY_DAYS:-3660}

# Sparse: only the days with files, oldest first, today excluded. The rebuild
# skips today because today is still being written; monitor_read_ledger has it
# fresh every tick and hands it over in LDG_T_*.
LDG_H_DAY=()
LDG_H_ALL=()
LDG_H_SUB=()
LDG_H_API=()
LDG_T_ALL=0
LDG_T_SUB=0
LDG_T_API=0

# Dense: every calendar day from today back to the oldest the ledger knows, gaps
# and all. Newest first -- index 0 is today -- because the walk that builds it
# runs backwards from today, so HIST_DAYS cuts the far end off rather than the
# end anyone is looking at.
HIST_DAY=()
HIST_ALL=()
HIST_SUB=()
HIST_API=()
HIST_MAX=0     # the biggest day, which is what the bars are scaled against
HIST_PEAK=""   # and which day that was
HIST_TOTAL=0   # every day added up, with the split under it
HIST_SUB_ALL=0
HIST_API_ALL=0
HIST_KEY=""    # what the dense list was built from; see monitor_hist_build

# Files one ledger file's cents under its day. Called from the rebuild, once per
# file, with the day already peeled off the name and the file already read.
monitor_hist_file() {
  local d=$1 n=${#LDG_H_DAY[@]}
  # A name can match the rebuild's glob and still not be a date -- "2026-13-45"
  # does -- and one of those would put the calendar walk out of step with the
  # days it is looking for. The windows can afford to count it; a chart with a
  # column per day cannot.
  case ${d:5:2} in 0[1-9]|1[0-2]) ;; *) return 0 ;; esac
  case ${d:8:2} in 0[1-9]|[12][0-9]|3[01]) ;; *) return 0 ;; esac
  if [ "$n" -eq 0 ] || [ "${LDG_H_DAY[$((n - 1))]}" != "$d" ]; then
    LDG_H_DAY+=("$d"); LDG_H_ALL+=(0); LDG_H_SUB+=(0); LDG_H_API+=(0)
    n=$((n + 1))
  fi
  n=$((n - 1))
  LDG_H_ALL[$n]=$((${LDG_H_ALL[$n]} + LDG_CENTS))
  case $LDG_SUB in
    1) LDG_H_SUB[$n]=$((${LDG_H_SUB[$n]} + LDG_CENTS)) ;;
    0) LDG_H_API[$n]=$((${LDG_H_API[$n]} + LDG_CENTS)) ;;
  esac
  return 0
}

# The dense list, out of the sparse days plus today's running total. Rebuilt only
# when one of those has actually moved, so scrolling the chart redraws from what
# is already here -- the same bargain the fleet's cursor makes upstairs.
monitor_hist_build() {
  local key n j d all sub api count
  n=${#LDG_H_DAY[@]}
  key="$MON_DAY:$n:$LDG_T_ALL:$LDG_T_SUB:$LDG_T_API"
  [ "$key" = "$HIST_KEY" ] && return 0
  HIST_KEY=$key
  HIST_DAY=(); HIST_ALL=(); HIST_SUB=(); HIST_API=()
  HIST_MAX=0; HIST_PEAK=""; HIST_TOTAL=0; HIST_SUB_ALL=0; HIST_API_ALL=0
  # No clock, or a ledger with nothing in it at all: the view says so rather than
  # drawing today as a zero, for the same reason the totals stay blank.
  [ -n "$MON_DAY" ] && [ -n "$LDG_ANY" ] || return 0

  # A file dated after today -- a machine whose clock or timezone has moved, or a
  # session writing from the other side of a date line -- is counted in the
  # windows and left off the chart, which ends at today.
  j=$((n - 1))
  while [ "$j" -ge 0 ] && ! day_ge "$MON_DAY" "${LDG_H_DAY[$j]}"; do
    j=$((j - 1))
  done

  d=$MON_DAY
  count=0
  while [ "$count" -lt "$HIST_DAYS" ]; do
    all=0; sub=0; api=0
    if [ "$d" = "$MON_DAY" ]; then
      all=$LDG_T_ALL; sub=$LDG_T_SUB; api=$LDG_T_API
    elif [ "$j" -ge 0 ] && [ "${LDG_H_DAY[$j]}" = "$d" ]; then
      all=${LDG_H_ALL[$j]}; sub=${LDG_H_SUB[$j]}; api=${LDG_H_API[$j]}
      j=$((j - 1))
    fi
    HIST_DAY+=("$d"); HIST_ALL+=("$all"); HIST_SUB+=("$sub"); HIST_API+=("$api")
    HIST_TOTAL=$((HIST_TOTAL + all))
    HIST_SUB_ALL=$((HIST_SUB_ALL + sub))
    HIST_API_ALL=$((HIST_API_ALL + api))
    # Ties go to the later day, which is the one still in view when the chart is
    # pinned to today.
    [ "$all" -gt "$HIST_MAX" ] && { HIST_MAX=$all; HIST_PEAK=$d; }
    count=$((count + 1))
    # Nothing older left to reach: the days behind this one have no files, and
    # rows of zero going back forever are not history.
    [ "$j" -ge 0 ] || break
    monitor_day_prev "$d"; d=$DAY_PREV
  done
  return 0
}

# --- usage view ---------------------------------------------------------------
#
# The second screen, on 'u': the ledger as a chart, dollars up the side and days
# along the bottom. The fleet screen answers what is happening now and carries
# four totals for scale; this one answers where the money went, which is a
# question about days rather than about sessions.
#
# Drawn from the ledger alone -- no tmux, no captures -- so its tick costs a
# directory of small files and nothing else. See monitor_tick.
VIEW=fleet     # which screen is up: "fleet" or "usage"
HIST_OFF=0     # how many of the newest days are scrolled off the right

# Eighths of a row, growing up from the floor of a cell, so the top of a column
# can land between two rows of the screen: at fifty dollars a row, a day rounded
# to the nearest row is fifty dollars wrong.
HIST_RISE=(' ' '▁' '▂' '▃' '▄' '▅' '▆' '▇')

# Those glyphs at the width the columns came out at, built once per draw and used
# by every cell after that. printf pads by bytes, so a run of a multibyte glyph
# cannot be padded into place with %-*s and has to be repeated a glyph at a time.
HIST_FULL=""   # a whole row of one column's bar
HIST_CELL=()   # the eighths, indexed 0..7; 0 is the blank cell
HIST_GAP=" "   # between one column and the next
monitor_hist_glyphs() {
  local bw=$1 i=0 j s
  HIST_FULL=""; HIST_CELL=()
  j=0
  while [ "$j" -lt "$bw" ]; do HIST_FULL="${HIST_FULL}█"; j=$((j + 1)); done
  while [ "$i" -lt 8 ]; do
    s=""; j=0
    while [ "$j" -lt "$bw" ]; do s="$s${HIST_RISE[$i]}"; j=$((j + 1)); done
    HIST_CELL+=("$s")
    i=$((i + 1))
  done
}

# Rounds a figure up the ladder 1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10 times a power
# of ten -- the halves only above ten cents, where they are still whole cents.
# What gets rounded is the step between two gridlines rather than the top of the
# axis, so the labels come out as round money whatever the tallest day was.
#
# The ladder is as fine as it is because the small chart under the fleet has two
# gridlines to work with: a coarser one would round its step so far up that the
# tallest day only reached half the height it had.
HIST_NICE=0
monitor_hist_nice() {
  local v=$1 p=1
  [ "$v" -lt 1 ] && v=1
  while [ $((v / p)) -ge 10 ]; do p=$((p * 10)); done
  if   [ "$v" -le "$p" ];       then HIST_NICE=$p
  elif [ "$p" -ge 10 ] && [ "$v" -le $((3 * p / 2)) ]; then HIST_NICE=$((3 * p / 2))
  elif [ "$v" -le $((2 * p)) ]; then HIST_NICE=$((2 * p))
  elif [ "$p" -ge 10 ] && [ "$v" -le $((5 * p / 2)) ]; then HIST_NICE=$((5 * p / 2))
  elif [ "$v" -le $((3 * p)) ]; then HIST_NICE=$((3 * p))
  elif [ "$v" -le $((4 * p)) ]; then HIST_NICE=$((4 * p))
  elif [ "$v" -le $((5 * p)) ]; then HIST_NICE=$((5 * p))
  elif [ "$v" -le $((6 * p)) ]; then HIST_NICE=$((6 * p))
  elif [ "$v" -le $((8 * p)) ]; then HIST_NICE=$((8 * p))
  else                               HIST_NICE=$((10 * p))
  fi
}

# A gridline's label: whole dollars where the step is whole dollars, which a nice
# step above a dollar always is, and cents below that.
AXIS_FMT=""
monitor_hist_axis_fmt() {
  if [ $(($1 % 100)) -eq 0 ]; then
    printf -v AXIS_FMT '$%d' $(($1 / 100))
  else
    printf -v AXIS_FMT '$%d.%02d' $(($1 / 100)) $(($1 % 100))
  fi
}

# Each visible column, left to right: how many whole rows of bar it has, the
# eighths on top of them, how many of those whole rows are api-coloured (counted
# down from the top) and whether the eighths on top are too.
COL_FULL=()
COL_PART=()
COL_API=()
COL_CAPY=()

# Builds the chart into PLOT_OUT -- the rows of columns, then the floor and the
# dates under it -- for both the screen on 'u' and the small one under the
# fleet's rows. Prints nothing: the callers frame it.
#
#   $1  rows to draw in, at most; rounded down to a whole number of gridlines
#   $2  width to draw in, indent and gutter included
#   $3  the widest a column may be, which is what keeps the small chart small
#   $4  the most days to show, 0 for as many as fit
#   $5  glyphs of indent in front of every line
#
# The days drawn are the newest that fit, less HIST_OFF. PLOT_COLS says how many
# there were, which is what the caller's range and the scroll clamp go by.
PLOT_OUT=""
PLOT_COLS=0
monitor_hist_plot() {
  local rows=$1 width=$2 maxcolw=$3 maxcols=$4 pad=$5
  local n i c r cols colw bw plotw gw ntick step ymax vismax
  local line cur want g f p a lbl day tickx xpos axis="" xlab="" ind=""
  local labelled=() LP_POS=() LP_COL=()
  PLOT_OUT=""; PLOT_COLS=0
  COL_FULL=(); COL_PART=(); COL_API=(); COL_CAPY=()
  n=${#HIST_DAY[@]}
  [ "$n" -gt 0 ] || return 0
  printf -v ind '%*s' "$pad" ''

  # Gridlines, and the rows made a whole multiple of them so that every line
  # falls on a row of the screen rather than between two.
  [ "$rows" -lt 2 ] && rows=2
  if   [ "$rows" -ge 10 ]; then ntick=5
  elif [ "$rows" -ge 8 ];  then ntick=4
  else                          ntick=2
  fi
  rows=$(( (rows / ntick) * ntick ))
  [ "$rows" -lt "$ntick" ] && rows=$ntick
  step=$((rows / ntick))

  # The gutter is sized off the tallest day in the whole history rather than the
  # one on screen, so the chart does not shuffle sideways as it is scrolled.
  vismax=$HIST_MAX
  [ "$vismax" -lt 100 ] && vismax=100
  monitor_hist_nice $((vismax / ntick))
  monitor_hist_axis_fmt $((HIST_NICE * ntick))
  gw=$((${#AXIS_FMT} + 2))

  plotw=$((width - pad - gw))
  [ "$plotw" -lt 4 ] && plotw=4

  # As wide a column as the days allow, so a wide terminal is a wide chart rather
  # than a narrow one with the screen empty beside it -- but no wider than the
  # caller wants, and never under two, which is one glyph of bar and one of gap.
  # At two, a history longer than the screen scrolls instead of shrinking.
  cols=$n
  [ "$maxcols" -gt 0 ] && [ "$cols" -gt "$maxcols" ] && cols=$maxcols
  colw=$((plotw / cols))
  [ "$colw" -gt "$maxcolw" ] && colw=$maxcolw
  [ "$colw" -lt 2 ] && colw=2
  [ "$cols" -gt $((plotw / colw)) ] && cols=$((plotw / colw))
  [ "$cols" -lt 1 ] && cols=1
  bw=$((colw - 1))
  PLOT_COLS=$cols

  # HIST_OFF is clamped here rather than by the keys: how many columns fit is
  # known at the moment of drawing and nowhere else, so scrolling stops at the
  # oldest day instead of running off into empty air.
  [ "$HIST_OFF" -gt $((n - cols)) ] && HIST_OFF=$((n - cols))
  [ "$HIST_OFF" -lt 0 ] && HIST_OFF=0

  # The axis is scaled to the days on screen, and says so in its own labels: a
  # window of quiet days uses the whole height rather than hugging the floor.
  vismax=0
  i=$HIST_OFF
  while [ "$i" -lt $((HIST_OFF + cols)) ]; do
    [ "${HIST_ALL[$i]}" -gt "$vismax" ] && vismax=${HIST_ALL[$i]}
    i=$((i + 1))
  done
  [ "$vismax" -lt 100 ] && vismax=100
  monitor_hist_nice $((vismax / ntick))
  ymax=$((HIST_NICE * ntick))

  # Every column measured once, so the rows below are a lookup and a glyph each.
  i=$((HIST_OFF + cols - 1))     # the oldest visible day is the leftmost column
  while [ "$i" -ge "$HIST_OFF" ]; do
    f=${HIST_ALL[$i]}; a=${HIST_API[$i]}
    if [ "$f" -gt 0 ]; then
      p=$((f * rows * 8 / ymax))
      # A day too small for an eighth still gets one: a chart that draws a
      # hundred-dollar day as nothing is worse than one that draws it as little.
      [ "$p" -eq 0 ] && p=1
    else
      p=0
    fi
    COL_FULL+=($((p / 8)))
    COL_PART+=($((p % 8)))
    # The api share is taken off the top of the column, in whole rows -- a
    # boundary inside a row would want a glyph that is half one color and half
    # the other -- and any api at all is worth a row, so a small real charge is
    # not rounded into the notional part. Cents whose session never said how it
    # was paying ride with the subscription end, which is where the windows put
    # an unknown too.
    r=$((p / 8))
    c=0
    if [ "$a" -gt 0 ] && [ "$f" -gt 0 ]; then
      if [ "$r" -gt 0 ]; then
        c=$((a * r / f))
        [ "$c" -eq 0 ] && c=1
      fi
      COL_API+=("$c"); COL_CAPY+=(1)
    else
      COL_API+=(0); COL_CAPY+=(0)
    fi
    i=$((i - 1))
  done

  # Which columns carry a date under them, and where that date starts. Every ith
  # column, counted from the right so that today always gets one, and i chosen so
  # that two dates cannot touch: a date is five glyphs, and i columns is six or
  # more.
  #
  # A date is centred on its column's tick, except that the rightmost one would
  # hang off the end of the chart -- half of "31/08" is past the last column --
  # so the whole run is shifted left by however much that one overhangs. Shifting
  # them together is what keeps the spacing even: pulling back only the last one
  # would leave it a glyph short of its neighbour, and that neighbour would be
  # dropped for touching it.
  i=$((6 / colw)); [ $((i * colw)) -lt 6 ] && i=$((i + 1))
  tickx=$((bw / 2))          # the tick's glyph within a column
  a=$(((cols - 1) * colw + tickx + 3 - cols * colw))   # the overhang, if any
  [ "$a" -lt 0 ] && a=0
  p=$((cols * colw))         # the leftmost glyph already spoken for
  c=$((cols - 1))
  while [ "$c" -ge 0 ]; do
    f=$((c * colw + tickx - 2 - a))
    if [ "$f" -ge 0 ] && [ $((f + 5)) -le "$p" ]; then
      LP_POS+=("$f"); LP_COL+=("$c"); labelled[$c]=1
      p=$((f - 1))           # a glyph of daylight between one date and the next
    fi
    c=$((c - i))
  done

  monitor_hist_glyphs "$bw"

  r=$((rows - 1))
  while [ "$r" -ge 0 ]; do
    # A gridline every step rows, labelled with the money at the top of it. The
    # rest of the rows carry the axis and nothing else.
    if [ $(((r + 1) % step)) -eq 0 ]; then
      monitor_hist_axis_fmt $(( (r + 1) * ymax / rows ))
      printf -v line '%s%s%*s ┤%s' "$ind" "$C_DIM" $((gw - 2)) "$AXIS_FMT" "$C_RST"
    else
      printf -v line '%s%s%*s │%s' "$ind" "$C_DIM" $((gw - 2)) "" "$C_RST"
    fi

    cur=""
    c=0
    while [ "$c" -lt "$cols" ]; do
      f=${COL_FULL[$c]}; p=${COL_PART[$c]}; a=${COL_API[$c]}
      want=$cur
      if [ "$r" -lt $((f - a)) ]; then
        g=$HIST_FULL; want=$C_CYA
      elif [ "$r" -lt "$f" ]; then
        g=$HIST_FULL; want=$C_YEL
      elif [ "$r" -eq "$f" ] && [ "$p" -gt 0 ]; then
        g=${HIST_CELL[$p]}
        if [ "${COL_CAPY[$c]}" = 1 ]; then want=$C_YEL; else want=$C_CYA; fi
      else
        g=${HIST_CELL[0]}
      fi
      if [ "$want" != "$cur" ]; then line="$line$want"; cur=$want; fi
      line="$line$g$HIST_GAP"
      c=$((c + 1))
    done
    [ -n "$cur" ] && line="$line$C_RST"
    PLOT_OUT+="$line$T_EL"$'\n'
    r=$((r - 1))
  done

  # The floor, with a tick under every column that has a date written under it.
  monitor_hist_axis_fmt 0
  printf -v axis '%s%s%*s └' "$ind" "$C_DIM" $((gw - 2)) "$AXIS_FMT"
  c=0
  while [ "$c" -lt "$cols" ]; do
    p=0
    while [ "$p" -lt "$colw" ]; do
      if [ -n "${labelled[$c]:-}" ] && [ "$p" -eq "$tickx" ]; then
        axis="${axis}┴"
      else
        axis="${axis}─"
      fi
      p=$((p + 1))
    done
    c=$((c + 1))
  done
  axis="$axis$C_RST"
  PLOT_OUT+="$axis$T_EL"$'\n'

  # And the dates themselves, laid down left to right out of the positions picked
  # above -- which were picked from the right, so this walks them backwards.
  xpos=0                     # glyphs of the date line written so far
  c=$((${#LP_POS[@]} - 1))
  while [ "$c" -ge 0 ]; do
    p=${LP_POS[$c]}
    i=$((HIST_OFF + cols - 1 - ${LP_COL[$c]}))
    day=${HIST_DAY[$i]}
    printf -v lbl '%*s' $((p - xpos)) ''
    xlab="$xlab$lbl"
    monitor_day_label "$day"
    # Today is bold -- its column is short for the hour, not for the day -- and a
    # weekend is dim, which is what makes the shape of a week readable.
    case $DAY_DOW in 0|6) lbl=$C_DIM ;; *) lbl="" ;; esac
    [ "$day" = "$MON_DAY" ] && lbl=$C_BOLD
    xlab="$xlab$lbl${day:8:2}/${day:5:2}$C_RST"
    xpos=$((p + 5))
    c=$((c - 1))
  done
  printf -v lbl '%*s' "$((pad + gw))" ''
  PLOT_OUT+="$C_DIM$lbl$xlab$C_RST$T_EL"$'\n'
  return 0
}

# The whole screen on 'u': the chart with as much height and width as there is,
# under a header of the figures it cannot draw.
monitor_draw_usage() {
  local h w n rows hdr="" legend="" tot day first
  read -r h w <<<"$(term_size)"
  monitor_hist_build
  n=${#HIST_DAY[@]}

  # The split is only worth a line when there is a split: one kind of payment is
  # already named by the color of every column on screen.
  if [ "$HIST_SUB_ALL" -gt 0 ] && [ "$HIST_API_ALL" -gt 0 ]; then
    monitor_ledger_fmt "$HIST_SUB_ALL"; legend="  ${C_CYA}█${C_RST} sub ~\$$LDG_FMT"
    monitor_ledger_fmt "$HIST_API_ALL"; legend="$legend   ${C_YEL}█${C_RST} api \$$LDG_FMT"
  fi

  if [ "$n" -eq 0 ]; then
    { printf '%s%s%-*s%s%s\n' "$T_HOME" "${C_REV}${C_BOLD}" "$w" \
        ' USAGE  no history yet' "$C_RST" "$T_EL"
      printf '%s\n' "$T_EL"
      printf '  nothing recorded yet -- see the Claude Code config for the exporter%s\n' "$T_EL"
      printf '%s\n' "$T_EL"
      printf '%s' "$T_ED"
    } 2>/dev/null
    return 0
  fi

  # Seven lines that are not chart -- the header, a blank, the floor, the dates, a
  # blank, the help, and one left spare so the last newline cannot scroll the
  # frame off the screen -- plus the legend when there is one.
  rows=$((h - 7))
  [ -n "$legend" ] && rows=$((rows - 1))
  monitor_hist_plot "$rows" "$w" 10 0 0

  # Days, then the three figures worth having above a chart: what it adds up to,
  # what a day of it costs, and the worst day there was. When the window shows
  # less than the whole history it says which days are on it. ASCII, like the
  # fleet's bar: printf pads this by bytes.
  monitor_ledger_fmt "$HIST_TOTAL"; tot=$LDG_FMT
  printf -v hdr ' USAGE  %d days  total $%s' "$n" "$tot"
  monitor_ledger_fmt $((HIST_TOTAL / n))
  hdr="$hdr  avg \$$LDG_FMT/day"
  if [ -n "$HIST_PEAK" ]; then
    monitor_day_label "$HIST_PEAK"
    monitor_ledger_fmt "$HIST_MAX"
    hdr="$hdr  peak \$$LDG_FMT $DAY_LABEL"
  fi
  if [ "$PLOT_COLS" -lt "$n" ]; then
    first=${HIST_DAY[$((HIST_OFF + PLOT_COLS - 1))]}
    day=${HIST_DAY[$HIST_OFF]}
    hdr="$hdr  showing ${first:8:2}/${first:5:2}-${day:8:2}/${day:5:2}"
  fi

  { printf '%s%s%-*s%s%s\n' "$T_HOME" "${C_REV}${C_BOLD}" "$w" "${hdr:0:$w}" "$C_RST" "$T_EL"
    printf '%s\n' "$T_EL"
    printf '%s' "$PLOT_OUT"
    printf '%s\n' "$T_EL"
    [ -n "$legend" ] && printf '%s%s\n' "$legend" "$T_EL"
    printf '%s  %sh/l%s older/newer   %sj/k%s by week   %su%s sessions   %sr%s refresh   %sq%s back%s%s\n' \
      "$C_DIM" "$C_RST$C_BOLD" "$C_RST$C_DIM" "$C_RST$C_BOLD" "$C_RST$C_DIM" \
      "$C_RST$C_BOLD" "$C_RST$C_DIM" "$C_RST$C_BOLD" "$C_RST$C_DIM" \
      "$C_RST$C_BOLD" "$C_RST$C_DIM" "$C_RST" "$T_EL"
    printf '%s' "$T_ED"
  } 2>/dev/null
}

# Reconciles what the screen says with what Claude's own events say.
#
# Neither source wins outright, because each is blind where the other is not:
#
#   ask    whichever sees it first. The screen usually does -- Notification lags
#          the prompt by about six seconds, a refresh tick is two -- but the hook
#          catches prompts in a pane the classifier cannot read.
#   draft  screen only. No event fires for typing, and nothing in the payload
#          describes the input box.
#   shell  screen only, and final: no Claude, so an old file is just a leftover
#   other  from a session that has since exited.
#   gone
#   busy   the events, when fresh. They know a turn has started before any of it
#   idle   reaches the screen, and they are right about a pane whose title the
#          terminal never set.
monitor_merge() {
  local i=$1 xs=${X_STATE[$i]} xd=${X_DETAIL[$i]}

  [ -n "$xs" ] || return 0
  case $CLS_STATE in
    shell|other|gone) return 0 ;;
  esac

  if [ "$xs" = ask ] && [ "$CLS_STATE" != ask ]; then
    CLS_STATE=ask
    [ -n "$xd" ] && CLS_DETAIL=$xd
    return 0
  fi
  case $CLS_STATE in
    ask|draft) return 0 ;;
  esac
  case $xs in
    busy|idle)
      CLS_STATE=$xs
      # The screen names a turn better than a tool name does -- "Fixing the
      # surface findings…" against "Bash" -- so the event's detail only fills a
      # gap it left.
      if [ -z "$CLS_DETAIL" ] && [ -n "$xd" ]; then CLS_DETAIL=$xd; fi
      ;;
  esac
  # Explicit, because every branch above ends in a test whose result would
  # otherwise become this function's status and read as failure to a caller.
  return 0
}

# Looks for a limit or extra-usage notice at the bottom of the pane just read,
# and keeps the first one found across the fleet for the header. Only the bottom
# few rows, where Claude puts its notices -- the transcript above them is full of
# sentences that would match.
monitor_scan_notice() {
  local j stop
  [ -z "$X_NOTICE" ] || return 0
  stop=$((L_N - 6)); [ "$stop" -lt 0 ] && stop=0
  j=$((L_N - 1))
  while [ "$j" -ge "$stop" ]; do
    if [[ ${LINES[$j]} =~ $LIMIT_NOTICES ]]; then
      monitor_strip "${LINES[$j]}"
      X_NOTICE=$STRIPPED
      return 0
    fi
    j=$((j - 1))
  done
  return 0
}

# --- state ------------------------------------------------------------------

LINES=()   # the visible rows of the pane being classified
L_N=0

# Claude separates the input box's prompt glyph from what you type with a
# non-breaking space, where a dialog's option rows use a plain one. It looks like
# a space on screen and is not one to the shell, so every place that steps over
# the glyph has to strip both -- getting this wrong left a stray byte on the front
# of the draft text and, worse, stopped the dim test below from ever finding the
# escape sequence it looks for.
NBSP=$'\302\240'

# Reads a pane's visible text into LINES, one row per element, no escape
# sequences. Indexing matters: capture-pane emits every row from the top of the
# screen, blanks included, so LINES[cursor_y] is the row the cursor is on.
monitor_read_pane() {
  local line
  LINES=(); L_N=0
  [ -n "${1:-}" ] || return 1
  while IFS= read -r line; do LINES+=("$line"); done \
    < <(tmux capture-pane -p -t "$1" 2>/dev/null)
  L_N=${#LINES[@]}
  [ "$L_N" -gt 0 ]
}

# Trims a row for display: leading whitespace and glyphs off, trailing space off.
STRIPPED=""
monitor_strip() {
  local s=$1
  while [ -n "$s" ]; do
    case ${s:0:1} in [[:alnum:]]) break ;; *) s=${s:1} ;; esac
  done
  while [ -n "$s" ]; do
    case ${s: -1} in [[:space:]]) s=${s%?} ;; *) break ;; esac
  done
  STRIPPED=$s
}

# What a live dialog is asking, read upwards from the row the cursor sits on.
# Taken from the screen rather than from a list of known wordings so that a
# prompt this script has never heard of still says something useful.
ASK_DETAIL=""
monitor_ask_detail() {
  local row=$1 i stop line tail fallback="" loose=""
  ASK_DETAIL=""
  stop=$((row - 14)); [ "$stop" -lt 0 ] && stop=0
  i=$((row - 1))
  while [ "$i" -ge "$stop" ]; do
    monitor_strip "${LINES[$i]}"
    line=$STRIPPED
    if [ -n "$line" ]; then
      case $line in
        *'?')                                 # "Do you want to create foo.txt?"
          # Claude's own questions arrive at the end of a wrapped paragraph, so
          # the line holding the "?" usually starts mid-sentence. Keep the last
          # sentence of it: the column is narrow and the question is the point.
          tail=${line##*'. '}
          case $tail in *'?') line=$tail ;; esac
          ASK_DETAIL=$line
          return 0
          ;;
        *'?'*) [ -n "$loose" ] || loose=$line ;;
      esac
      [ -n "$fallback" ] || fallback=$line    # else the dialog's own title
    fi
    i=$((i - 1))
  done
  ASK_DETAIL=${loose:-$fallback}
}

# Claude's status line, if it is on screen: "✢ Musing… (7s · ↓ 481 tokens)".
# It only shows before the reply starts streaming, so its absence means nothing.
#
# Read from the bottom up and only near the bottom, where the status line lives,
# and only where an ellipsis runs into the timer -- "Cooking… (13s · ". Scanning
# the whole screen for "(<digits>s · " matched transcript text instead: a session
# whose reply happened to quote a regex reported its own detail as
# "SURFACE|AMBIGUOUS|UNSUPPORTED|KEY)|question\(s\) sat". The same match decides
# busy, so the wrong line could also have invented a turn that was not running.
STATUS_DETAIL=""
monitor_status_detail() {
  local i stop line
  STATUS_DETAIL=""
  stop=$((L_N - 20)); [ "$stop" -lt 0 ] && stop=0
  i=$((L_N - 1))
  while [ "$i" -ge "$stop" ]; do
    line=${LINES[$i]}
    # Column 0 or it is not the status line. A tool still running prints the same
    # shape -- a command truncated to an ellipsis, then "(39s · 2 lines)" -- but
    # indented under its ⏺ row, and picking that up named the turn after whatever
    # grep it happened to be running.
    case $line in
      ''|[[:space:]]*) i=$((i - 1)); continue ;;
    esac
    if [[ $line == *'(esc to interrupt'* ]]; then   # pre-2.1 versions
      monitor_strip "${line%%'(esc to interrupt'*}"
      STATUS_DETAIL=$STRIPPED
      return 0
    fi
    # The timer is "(7s · " on a short turn and "(1h 49m 2s · " on a long one, so
    # the whole clock is matched loosely rather than as seconds alone -- which is
    # why a turn running over an hour used to lose its name off this line.
    if [[ $line =~ (.*…)\ \([0-9hms\ ]+·\  ]]; then
      monitor_strip "${BASH_REMATCH[1]}"
      STATUS_DETAIL=$STRIPPED
      return 0
    fi
    i=$((i - 1))
  done
  return 1
}

# The task summary out of a title, "⠂ Fix the parser" -> "Fix the parser".
# "Claude Code" is the placeholder title of a turn too young to have a summary
# yet, so it says nothing worth a column.
TITLE_DETAIL=""
monitor_title_detail() {
  local t=${1:-}
  TITLE_DETAIL=""
  title_is_claude "$t" || return 1
  t=${t#* }
  [ "$t" = 'Claude Code' ] && return 1
  monitor_strip "$t"
  TITLE_DETAIL=$STRIPPED
  [ -n "$TITLE_DETAIL" ]
}

# True when the text on a row is Claude's dim suggestion of what to type next
# rather than something a human typed. One capture of that single row is enough:
# the suggestion is rendered dim, typed text is not.
monitor_row_is_dim() {
  local raw after seq
  raw=$(tmux capture-pane -pe -t "$1" -S "$2" -E "$2" 2>/dev/null) || return 1
  case $raw in *'❯'*) after=${raw#*❯} ;; *) return 1 ;; esac
  after=${after#"$NBSP"}
  after=${after# }
  while [ "${after:0:2}" = "${ESC}[" ]; do
    seq=${after:2}
    case $seq in *m*) seq=${seq%%m*} ;; *) return 1 ;; esac
    case ";$seq;" in *';2;'*) return 0 ;; esac
    after=${after#*m}
  done
  return 1
}

# Footers a blocking dialog keeps on screen. Only consulted when the cursor is
# somewhere unrecognised, as a way of noticing a prompt that does not park it.
DIALOG_FOOTERS='[Ee]sc to (cancel|go back|close)|[Ee]nter to (confirm|approve|select|retry)'
# Wordings Claude asks with. A weak signal by itself -- it writes sentences like
# these in its replies too -- so it only counts alongside a dialog footer.
ASK_WORDS='Do you want|Would you like|Ready to code\?|Is this a project you created'

# monitor_classify <index> -> sets CLS_STATE and CLS_DETAIL from LINES and the
# snapshot. Assigns rather than prints "state|detail": the old packed form had to
# keep the free text last so a draft containing "|" could not shift the fields.
#
#   ask     Claude is waiting on a permission / plan / select prompt (actionable)
#   busy    Claude is generating
#   draft   text sitting in the prompt, unsent  (also actionable)
#   idle    Claude is up with an empty prompt
#   shell   just a shell
#   other   something else running (detail says what)
#   gone    session or pane disappeared
CLS_STATE=""
CLS_DETAIL=""
monitor_classify() {
  local i=$1 cmd=${P_CMD[$i]} cx=${P_CX[$i]} cy=${P_CY[$i]} title=${P_TITLE[$i]}
  local crow lead focus content bottom j stop grow row

  CLS_STATE=gone; CLS_DETAIL=""
  [ -n "${P_PANE[$i]}" ] || return 0
  [ -n "$cmd" ] || return 0

  # Not Claude: rank 300 and up is what the snapshot gives a pane it recognised
  # as Claude, so anything below that is whatever else happens to be running.
  if [ "${P_RANK[$i]}" -lt 300 ]; then
    case $cmd in
      zsh|-zsh|bash|-bash|sh|fish|login) CLS_STATE=shell ;;
      *) CLS_STATE=other; CLS_DETAIL=$cmd ;;
    esac
    return 0
  fi

  # Which widget has the keyboard, straight from where Claude parked the cursor.
  # This is the whole trick. Claude keeps the cursor in the input box at column
  # 0 when it is yours to type in, and moves it onto the selected row of a dialog
  # -- indented, inside the box -- when it is waiting on an answer. So focus, not
  # wording, decides whether a session is blocked.
  #
  # The wording could not: "Do you want ..." also appears in Claude's own replies
  # and in the transcript of prompts already answered, and the old test grepped
  # the whole screen for it *before* checking the spinner. A session that was
  # working, or one whose last reply merely ended in a question, showed up as the
  # loudest row on the monitor.
  # The row the keyboard belongs to is the cursor's own when it carries a prompt
  # glyph, and otherwise the nearest one above it: a draft long enough to wrap
  # leaves the cursor on a continuation row (which read as an empty prompt, so a
  # long draft showed up as idle), and a dialog that opens a text field leaves it
  # below the option it belongs to.
  crow=""; lead=""; focus=other; grow=-1
  j=$cy
  [ "$j" -ge "$L_N" ] && j=$((L_N - 1))
  stop=$((j - 12)); [ "$stop" -lt 0 ] && stop=0
  while [ "$j" -ge "$stop" ]; do
    row=${LINES[$j]}
    row=${row#"${row%%[! ]*}"}
    case $row in '❯'*|'>'*) crow=$row; grow=$j; break ;; esac
    j=$((j - 1))
  done

  if [ -n "$crow" ]; then
    lead=${crow#'❯'}; lead=${lead#'>'}
    # Which of the two that glyph belongs to. The separator is the giveaway: the
    # input box puts a non-breaking space after it, every dialog a plain one.
    # Column position cannot decide it -- a permission prompt indents its rows but
    # the dialog the AskUserQuestion tool puts up does not, so its selected row
    # sits at column 0 looking exactly like an input box, which is how a session
    # sitting on a question came to read as a draft of "1. Yes".
    #
    # Two weaker signals stand behind the separator so that losing it does not
    # turn every settled session into a NEEDS YOU: option rows are numbered, and
    # a dialog keeps the cursor on the glyph while the input box keeps it after
    # the separator.
    case $lead in
      "$NBSP"*) focus=input ;;
      ' '[0-9]*.*) focus=dialog ;;
      *) if [ "$grow" = "$cy" ] && [ "$cx" -le 1 ]; then focus=dialog; else focus=input; fi ;;
    esac
  fi

  # A dialog beats everything else: a pending question matters more than the
  # spinner, and one can be up mid-turn.
  if [ "$focus" = dialog ]; then
    monitor_ask_detail "$grow"
    CLS_STATE=ask; CLS_DETAIL=$ASK_DETAIL
    return 0
  fi

  # Cursor somewhere we do not recognise -- a full-screen view, or a dialog that
  # leaves the cursor alone. Read the bottom of the screen, which is where a live
  # prompt keeps its footer, and never the whole of it.
  if [ "$focus" = other ]; then
    bottom=""
    j=$((L_N - 8)); [ "$j" -lt 0 ] && j=0
    while [ "$j" -lt "$L_N" ]; do
      bottom+="${LINES[$j]}"$'\n'
      j=$((j + 1))
    done
    # A footer is enough on its own; the wording only counts next to an option
    # row, since Claude writes sentences like these in its replies as well.
    if [[ $bottom =~ $DIALOG_FOOTERS ]] ||
       { [[ $bottom =~ $ASK_WORDS ]] && [[ $bottom =~ ❯[[:space:]]*[0-9]+\. ]]; }; then
      monitor_ask_detail "$L_N"
      CLS_STATE=ask; CLS_DETAIL=$ASK_DETAIL
      return 0
    fi
  fi

  # Working. The title is what actually spans the turn: Claude's own footer hint
  # ("esc to interrupt") is gone as of 2.1.x, and the status line only shows
  # before the reply starts streaming. The status line is still read, because it
  # names the turn better than the title's summary does.
  if monitor_status_detail; then
    CLS_STATE=busy; CLS_DETAIL=$STATUS_DETAIL
    return 0
  fi
  if [ "${P_BUSY[$i]}" = 1 ]; then
    CLS_STATE=busy
    monitor_title_detail "$title" && CLS_DETAIL=$TITLE_DETAIL
    return 0
  fi

  # Idle, unless something is typed and unsent -- that one is waiting on a
  # keystroke, so it is worth surfacing.
  content=""
  if [ "$focus" = input ]; then
    # $lead is the row past the glyph, which the focus test above already took
    # off by pattern -- ${crow:1} would have counted characters, and that only
    # works out to one glyph in a UTF-8 locale.
    content=${lead#"$NBSP"}
    content=${content# }
    while [ -n "$content" ]; do
      case ${content: -1} in [[:space:]]) content=${content%?} ;; *) break ;; esac
    done
  fi

  if [ -n "$content" ]; then
    # Text on the prompt row is not proof anyone typed it. Claude fills the empty
    # box with a dim suggestion of what to ask next, which used to read as a
    # draft and made settled sessions look like they were waiting on a keystroke.
    #
    # The cursor settles it for free: typing moves it past the glyph, or off the
    # glyph's row entirely once the text wraps, while a suggestion leaves it
    # sitting at column 2. Only in that last case -- a suggestion, or a draft
    # whose cursor was moved home -- is a second capture worth it, to see whether
    # the text on that row is dim.
    if [ "$grow" != "$cy" ] || [ "$cx" -gt 2 ] ||
       ! monitor_row_is_dim "${P_PANE[$i]}" "$grow"; then
      CLS_STATE=draft; CLS_DETAIL=$content
      return 0
    fi
  fi

  # Nothing pending. The title's summary says what this session was last doing,
  # which beats what used to be here: the footer's "N agents" counter, which
  # reads the same in a session that has never run one.
  CLS_STATE=idle
  monitor_title_detail "$title" && CLS_DETAIL=$TITLE_DETAIL
  return 0
}

# Sets STATE_TEXT (fixed-width, ASCII on purpose: printf pads by bytes, so a
# multibyte glyph would break column alignment) and STATE_COLOR for state $1.
# It assigns rather than prints because the draw runs per row on every keystroke,
# and a $(...) per row is a fork per row. Text and color are separate because the
# highlighted row needs the text with no colour of its own -- an inner reset there
# would end the highlight halfway across the row.
monitor_state_style() {
  case $1 in
    ask)   STATE_TEXT='NEEDS YOU'; STATE_COLOR="${C_BOLD}${C_YEL}" ;;
    busy)  STATE_TEXT='working  '; STATE_COLOR=$C_CYA ;;
    draft) STATE_TEXT='draft    '; STATE_COLOR=$C_YEL ;;
    idle)  STATE_TEXT='idle     '; STATE_COLOR=$C_GRN ;;
    shell) STATE_TEXT='shell    '; STATE_COLOR=$C_DIM ;;
    other) STATE_TEXT='other    '; STATE_COLOR=$C_DIM ;;
    gone)  STATE_TEXT='gone     '; STATE_COLOR=$C_RED ;;
    *)     STATE_TEXT='?        '; STATE_COLOR=$C_DIM ;;
  esac
}

# --- rendering --------------------------------------------------------------

# Names and details are cut with ${x:0:n} rather than by a helper. bash counts
# characters there, not bytes, so Claude's glyphs are not sliced in half -- and it
# forks nothing. This used to pipe every row through perl twice, about 5ms a fork:
# most of a 570ms tick at twenty sessions, all of it paid again on every keypress
# that moved the cursor. (In a non-UTF-8 locale bash counts bytes and a glyph can
# still be cut, which is what the old `cut -c` fallback did anyway.)

term_size() { # -> "rows cols"
  local sz
  sz=$(stty size 2>/dev/null) || sz=""
  case $sz in
    [0-9]*' '[0-9]*) printf '%s' "$sz" ;;
    *) printf '%s %s' "$(tput lines 2>/dev/null || echo 24)" \
                      "$(tput cols  2>/dev/null || echo 80)" ;;
  esac
}

# Width of every column up to and including the cost, which the padding and the
# truncation both have to agree on: 2 + key 1 + 2 + name 23 + 1 + state 9 + 1 +
# agents 3 + 1 + ctx 4 + 1 + cost 8 + 2. Kept in one place because getting it
# wrong by one leaves the highlight bar short of the right edge, which is
# invisible until you look for it.
MON_PREFIX=58

# Where the detail actually starts, which is the same thing plus the account
# column on the screens that have one. The two are separate because the totals
# under the rows hang off the cost column and must not move when a second
# account appears: the account tag sits between the cost and the detail, so
# everything to its left stays where it was.
MON_ACCW=0
MON_DETAIL=$MON_PREFIX

SESSIONS=()
SEL=0          # cursor position in SESSIONS
SEL_NAME=""    # and the session it is on, so it can follow that one as the list moves
STATE_TEXT=""  # set by monitor_state_style
STATE_COLOR=""

# Puts the cursor back on SEL_NAME after the list has been rebuilt. Sessions come
# and go between ticks, and an index alone would slide onto a neighbour.
monitor_sel_sync() {
  local n=${#SESSIONS[@]} i=0
  if [ "$n" -eq 0 ]; then SEL=0; SEL_NAME=""; return; fi
  if [ -n "$SEL_NAME" ]; then
    while [ "$i" -lt "$n" ]; do
      [ "${SESSIONS[$i]}" = "$SEL_NAME" ] && { SEL=$i; return; }
      i=$((i + 1))
    done
  fi
  # Gone, or nothing picked yet: hold the position and adopt whatever is there.
  [ "$SEL" -ge "$n" ] && SEL=$((n - 1))
  [ "$SEL" -lt 0 ] && SEL=0
  SEL_NAME=${SESSIONS[$SEL]}
}

# One totals row -- "total active", then "today", "7d" and the rest -- into
# ROW_OUT, ready to append to the frame. Takes the terminal width rather than
# reading the caller's, since bash would let it and that is exactly the sort of
# thing that breaks quietly when the caller is refactored.
#
# $2 is the word that opens the block, carried by the first row only: the rows
# under it are the same total over a longer reach, so repeating "total" on each
# would be four words of nothing. Every window label is right-aligned to the same
# column whether or not it has that word in front of it, so the labels line up
# and "total" hangs off the left of the first one.
#
# The split goes into fixed-width fields so the rows read as a table instead of
# as four sentences of different lengths. A column with nothing in it is left
# blank rather than zeroed: no api spend and no api sessions look the same from
# here, and neither is worth printing $0.00 for.
ROW_OUT=""
monitor_total_row() {
  local width=$1 mark=$2 lbl=$3 all=$4 sub=$5 api=$6 extra=$7
  local bits sf af ef pad row lead="" text=$lbl
  printf -v sf '%-16s' "${sub:+sub ~\$$sub}"
  printf -v af '%-15s' "${api:+api \$$api}"
  ef=${extra:+extra ~\$$extra}
  bits="  $sf$af$ef"
  while [ -n "$bits" ]; do
    case ${bits: -1} in ' ') bits=${bits%?} ;; *) break ;; esac
  done
  # Cut to what is left of the line, like the detail column above.
  pad=$((width - MON_PREFIX + 2))
  [ ${#bits} -gt "$pad" ] && [ "$pad" -ge 0 ] && bits=${bits:0:$pad}

  # The alignment is worked out here rather than left to a %*s, because the word
  # in front is bold and the label is not: one field cannot hold both, and the
  # escape sequences would be counted as width if it did.
  if [ -n "$mark" ]; then
    text="$mark $lbl"
    lead="${C_BOLD}${mark}${C_RST} "
  fi
  pad=$((MON_PREFIX - 11 - ${#text}))
  [ "$pad" -lt 0 ] && pad=0
  printf -v row '%*s%s%s %s%8s%s%s%s%s' \
    "$pad" '' "$lead" "$lbl" \
    "$C_BOLD" "\$$all" "$C_RST" \
    "$C_DIM" "$bits" "$C_RST"
  ROW_OUT="$row$T_EL"$'\n'
}

# One window of one account -- "  8% to 3:10pm", or "100% FULL to 6:02pm" --
# padded to a fixed width so the two windows line up down the block, and flagged
# when it is exhausted so the caller can color the whole cell without putting an
# escape sequence inside a field printf is padding by bytes.
#
# A window at 100 is FULL, not "nearly there". Tested with -ge rather than =,
# because the figure is not in fact clamped there: readings of 101 have been seen
# in live exports on this machine. The number is printed as it comes, so a window
# past its limit says so rather than being rounded back down to the cap.
ACC_WINW=19
ACC_WIN=""
ACC_WIN_HOT=""
ACC_WIN_KNOWN=""
monitor_acc_window() {
  local lim=$1 rst=$2 t
  ACC_WIN=""; ACC_WIN_HOT=""; ACC_WIN_KNOWN=""
  case $lim in
    ''|-1|*[!0-9]*) printf -v ACC_WIN '%*s' "$ACC_WINW" ''; return 0 ;;
  esac
  ACC_WIN_KNOWN=1
  printf -v t '%3s%%' "$lim"
  if [ "$lim" -ge 100 ] 2>/dev/null; then
    t="$t FULL"
    ACC_WIN_HOT=1
  fi
  [ -n "$rst" ] && t="$t to $rst"
  printf -v ACC_WIN '%-*s' "$ACC_WINW" "$t"
  return 0
}

# One account's line, into ACC_ROW. The address is written out in full here --
# this is the one place on the screen with room for it, and the tags on the rows
# are only readable because this says what they stand for.
#
# The session count is what says whether the line is describing something running
# or something remembered: a live account has at least one by construction, so a
# line reading "0 sess" is an account the fleet has left -- switched away from, or
# whose sessions have all ended -- kept on screen for its windows. The whole line
# is dimmed with it, the address included, so the two kinds do not have to be told
# apart by reading a number.
#
# Built twice, plain and colored, because the escapes make the string longer than
# it looks and a row that overflows the terminal wraps, which shifts every line
# under it and breaks the redraw. Under the width it is drawn in color; over it,
# the plain one is cut to fit. Both come out of the same fields, so they cannot
# drift apart.
ACC_ROW=""
monitor_acc_row() {
  local width=$1 idx=$2 acct sess plain c5 c7 lead tail tailc ca=""
  local w5 h5 k5 w7 h7 k7 p5=5h
  acct=${ACC_KEY[$idx]}
  [ ${#acct} -gt 20 ] && acct=${acct:0:20}
  [ -n "${ACC_OFF[$idx]:-}" ] && ca=$C_DIM
  printf -v sess '%2s sess' "${ACC_N[$idx]}"
  monitor_acc_window "${ACC_LIM5[$idx]}" "${ACC_RST5[$idx]}"
  w5=$ACC_WIN; h5=$ACC_WIN_HOT; k5=$ACC_WIN_KNOWN
  monitor_acc_window "${ACC_LIM7[$idx]}" "${ACC_RST7[$idx]}"
  w7=$ACC_WIN; h7=$ACC_WIN_HOT; k7=$ACC_WIN_KNOWN

  # An account whose only reading has been superseded gets its name and its
  # session count and nothing else -- the line is still worth drawing, since it
  # is how you know the account is there at all, but there is no number to put
  # on it and a blank "5h" would look like one that read zero.
  #
  # The weekly window is last, so an unknown one is dropped outright; the 5-hour
  # one is not, and keeps its width so the weekly stays in its column. Whichever
  # ends the line loses its padding, which is trailing whitespace and nothing
  # else -- the same reason the totals under the rows drop theirs.
  [ -z "$k5" ] && p5='  '
  if [ -n "$k7" ]; then
    while [ -n "$w7" ]; do
      case ${w7: -1} in ' ') w7=${w7%?} ;; *) break ;; esac
    done
  elif [ -n "$k5" ]; then
    while [ -n "$w5" ]; do
      case ${w5: -1} in ' ') w5=${w5%?} ;; *) break ;; esac
    done
  fi

  c5=$C_DIM; c7=$C_DIM
  [ -n "$h5" ] && c5="$C_RED$C_BOLD"
  [ -n "$h7" ] && c7="$C_RED$C_BOLD"
  tail=""; tailc=""
  if [ -n "$k5" ] || [ -n "$k7" ]; then
    tail="  $p5 $w5"
    tailc="  $C_DIM$p5$C_RST $c5$w5$C_RST"
    if [ -n "$k7" ]; then
      tail="$tail  7d $w7"
      tailc="$tailc  ${C_DIM}7d$C_RST $c7$w7$C_RST"
    fi
  fi

  printf -v plain '  %-20s %s%s' "$acct" "$sess" "$tail"
  if [ ${#plain} -gt "$width" ]; then
    ACC_ROW="${plain:0:$width}$T_EL"$'\n'
    return 0
  fi
  printf -v lead '%-20s' "$acct"
  ACC_ROW="  $ca$lead$C_RST $C_DIM$sess$C_RST$tailc$T_EL"$'\n'
  return 0
}

ROW_STATE=()   # per session, same order as SESSIONS
ROW_DETAIL=()
X_ATAG=()      # and the account tag its row will carry, blank for no column
N_CLAUDE=0
N_WORK=0
N_NEED=0

# Polls every session and fills the row arrays. This is the expensive half -- one
# list-panes for the lot, then a capture-pane each, about 20ms apiece -- so it
# runs on the refresh tick and not on every keystroke. Moving the cursor cannot
# change any of it, and redrawing from what is already here is what keeps j and k
# instant.
monitor_collect() {
  local i n
  monitor_clock
  monitor_snapshot
  monitor_sel_sync
  monitor_busy_titles
  monitor_read_exports
  monitor_read_ledger

  ROW_STATE=(); ROW_DETAIL=()
  N_CLAUDE=0; N_WORK=0; N_NEED=0
  n=${#SESSIONS[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    if monitor_read_pane "${P_PANE[$i]}"; then
      monitor_classify "$i"
      monitor_merge "$i"
      monitor_scan_notice
    else
      # The pane went away between the snapshot and the capture.
      CLS_STATE=gone; CLS_DETAIL=""
    fi
    ROW_STATE+=("$CLS_STATE")
    ROW_DETAIL+=("$CLS_DETAIL")
    case $CLS_STATE in
      ask)   N_NEED=$((N_NEED + 1)); N_CLAUDE=$((N_CLAUDE + 1)) ;;
      busy)  N_WORK=$((N_WORK + 1)); N_CLAUDE=$((N_CLAUDE + 1)) ;;
      draft|idle) N_CLAUDE=$((N_CLAUDE + 1)) ;;
      # No Claude in this pane, so anything left in it -- markers, or the account
      # it was signed in to -- is from one that has since gone: killed before
      # SessionEnd, or the whole tmux server with it.
      *) X_AGENTS[$i]=0; X_ACCT[$i]="" ;;
    esac
    # Counted here rather than where the file was read, because only now is it
    # known whether there is still a Claude in the pane. An account whose every
    # session has gone has no line, however recent the export it left behind.
    [ -n "${X_ACCT[$i]}" ] && monitor_acc_find "${X_ACCT[$i]}" &&
      ACC_N[$ACC_I]=$((ACC_N[$ACC_I] + 1))
    i=$((i + 1))
  done

  # The accounts no session is reporting any more, from the ledger that outlives
  # them: read after the count above, because the count is what says which those
  # are.
  monitor_acc_remembered

  # The account column earns its place only once there is more than one account
  # to tell apart. On the ordinary single-account screen every row would carry
  # the same word, so there is no column at all and the detail keeps the space.
  monitor_acc_order
  monitor_acc_tags
  X_ATAG=()
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "$ACC_TAGGED" -ge 2 ] && [ -n "${X_ACCT[$i]}" ] &&
       monitor_acc_find "${X_ACCT[$i]}"; then
      X_ATAG+=("${ACC_TAG[$ACC_I]}")
    else
      X_ATAG+=("")
    fi
    i=$((i + 1))
  done
}

# Whichever screen is up. Both draw from what the last tick collected and neither
# talks to tmux, so a keystroke that only scrolls costs a redraw and nothing else.
monitor_draw() {
  if [ "$VIEW" = usage ]; then monitor_draw_usage; else monitor_draw_fleet; fi
}

# Draws what monitor_collect gathered. Talks to tmux not at all, and builds every
# row with printf -v, so a keystroke that only moves the cursor costs a redraw and
# nothing else.
monitor_draw_fleet() {
  local h w i n state detail maxd pad row out="" acc="" hdr name ctx cost mark agents tagf tail
  # Lines the screen has spent, for the chart at the bottom to see what is left:
  # the header, a blank, a blank and the help, then the account block, then a row
  # per session and per total as they are added.
  local used=4
  [ "$ACC_SHOWN" -gt 0 ] && used=$((used + ACC_SHOWN + 1))
  # Shadowed for the length of the draw, so the small chart is pinned to today
  # and the scroll position of the one on 'u' is left where the user put it.
  local HIST_OFF=0
  read -r h w <<<"$(term_size)"

  # What every column before the detail takes: two spaces, the key, two spaces,
  # the name at 23, a space, the state at 9, a space, the agent count at 3, a
  # space, the context at 4, a space, the cost at 8, two more spaces -- and then
  # the account tag and two more again, on the screens that show one.
  MON_ACCW=0
  [ "$ACC_TAGGED" -ge 2 ] && MON_ACCW=$((ACC_TAGW + 2))
  MON_DETAIL=$((MON_PREFIX + MON_ACCW))
  maxd=$((w - MON_DETAIL))
  [ "$maxd" -lt 12 ] && maxd=12

  n=${#SESSIONS[@]}
  used=$((used + n))
  i=0
  while [ "$i" -lt "$n" ]; do
    name=${SESSIONS[$i]}
    [ ${#name} -gt 23 ] && name=${name:0:23}
    state=${ROW_STATE[$i]}
    detail=${ROW_DETAIL[$i]}
    [ ${#detail} -gt "$maxd" ] && detail=${detail:0:maxd}
    # Context used, from the status line export. Blank -- not "0%" -- for a
    # session that has not answered yet or has no exporter installed, so an empty
    # column reads as "unknown" rather than "plenty of room left".
    ctx='    '
    case ${X_CTX[$i]} in
      ''|-1|*[!0-9]*) ;;
      *) printf -v ctx '%3s%%' "${X_CTX[$i]}" ;;
    esac
    # Blank, again, rather than $0.00 for a session that has not reported --
    # nothing spent and nothing known are different things.
    printf -v cost '%8s' "${X_COSTF[$i]}"
    # Subagents in flight, "5a". Blank at zero: a bare 0 in every row would be
    # three columns of nothing on a machine that never runs one. The suffix is
    # what makes a small number next to the state read as a count of agents
    # rather than as another percentage, and it is ASCII because printf pads this
    # by bytes.
    agents='   '
    [ "${X_AGENTS[$i]:-0}" -gt 0 ] 2>/dev/null &&
      printf -v agents '%3s' "${X_AGENTS[$i]}a"
    # The account tag, where there is a column for one. Padded here and glued to
    # the front of the detail rather than given a field of its own: it is dim
    # like the detail is, so the two share one run of color, and the escapes stay
    # out of anything printf is padding. Blank for a pane with no Claude in it,
    # which leaves the column empty rather than naming an account that has gone.
    tagf=""
    [ "$MON_ACCW" -gt 0 ] &&
      printf -v tagf '%-*s  ' "$ACC_TAGW" "${X_ATAG[$i]}"
    # Which leaves the tag's padding hanging off the end of a row with no detail
    # on it, so the ordinary row drops it. The cursor's row keeps it: there the
    # padding runs to the right edge anyway, and it is measured from the full
    # width of the column.
    tail="$tagf$detail"
    while [ -n "$tail" ]; do
      case ${tail: -1} in ' ') tail=${tail%?} ;; *) break ;; esac
    done
    monitor_state_style "$state"
    if [ "$i" = "$SEL" ]; then
      # The cursor's row goes in reverse video, with no inner resets -- one would
      # end the highlight halfway across -- and padded out so the bar reaches the
      # right edge (tmux erases in the default attribute, so ESC[K cannot do that
      # for us). The mark is kept as well, so the cursor is still visible with
      # colors off; it and the padding live outside every %-*s, so a multibyte
      # glyph cannot skew them.
      pad=$((w - MON_DETAIL - ${#detail}))
      [ "$pad" -lt 0 ] && pad=0
      printf -v row '%s▸ %s  %-23s %s %s %s %s  %s%s%*s%s' \
        "$C_REV" "${KEYS:$i:1}" \
        "$name" "$STATE_TEXT" "$agents" "$ctx" "$cost" \
        "$tagf" "$detail" "$pad" '' "$C_RST"
    else
      # The agent count is the one column here that is not dim. A fleet running
      # under a session is worth seeing from across the room, and it is the same
      # cyan as "working" because that is what it means.
      printf -v row '  %s%s%s  %-23s %s%s%s %s%s%s %s%s %s%s  %s%s%s' \
        "$C_BOLD" "${KEYS:$i:1}" "$C_RST" \
        "$name" \
        "$STATE_COLOR" "$STATE_TEXT" "$C_RST" \
        "$C_CYA" "$agents" "$C_RST" \
        "$C_DIM" "$ctx" "$cost" "$C_RST" \
        "$C_DIM" "$tail" "$C_RST"
    fi
    # T_EL per row here rather than a sed over the whole block: that was one more
    # fork on the path between a keypress and the screen.
    out+="$row$T_EL"$'\n'
    i=$((i + 1))
  done

  # The totals, one row per window, under the column they total. MON_PREFIX - 11
  # lands each label just left of the cost field, so every figure sits directly
  # beneath the per-session costs above it and beneath each other.
  #
  # "active" is the sessions on screen, and is the only row that can carry
  # "extra": overage is worked out from the live exports, which the ledger, being
  # a record of what was spent rather than of how, does not keep. The rest are
  # the ledger's, and count every session that has run in the window whether or
  # not anything is still up to show for it -- so "active" and "today" overlap,
  # and are meant to.
  if [ "$n" -gt 0 ]; then
    # "total" goes on the first row drawn, whichever that turns out to be: with
    # no live cost to report the block opens on "today" instead, and the word
    # belongs to the block rather than to any one window.
    mark=total
    if [ -n "$X_COST_ALL" ]; then
      monitor_total_row "$w" "$mark" active \
        "$X_COST_ALL" "$X_COST_SUB" "$X_COST_API" "$X_COST_OVER"
      out+="$ROW_OUT"
      used=$((used + 1))
      mark=""
    fi
    i=0
    while [ "$i" -lt 4 ]; do
      if [ -n "${SPEND_ALL[$i]}" ]; then
        monitor_total_row "$w" "$mark" "${SPEND_LBL[$i]}" \
          "${SPEND_ALL[$i]}" "${SPEND_SUB[$i]}" "${SPEND_API[$i]}" ""
        out+="$ROW_OUT"
        used=$((used + 1))
        mark=""
      fi
      i=$((i + 1))
    done
  fi

  # And the chart under them, small: four rows of columns, the floor, and the
  # dates. It goes in only when the screen has room to spare -- the fleet is what
  # this screen is for, and a chart that pushed a session off the bottom would be
  # the wrong trade -- and it is always pinned to today, whatever the full-size
  # one on 'u' has been scrolled to.
  #
  # A month of days at two glyphs each, which is about sixty columns however wide
  # the terminal is: enough to see the shape of a month without the chart taking
  # the screen over. 'u' is there for the whole of it.
  if [ "$n" -gt 0 ] && [ $((h - used - 1)) -ge 7 ]; then
    monitor_hist_build
    monitor_hist_plot 4 "$w" 2 30 2
    [ -n "$PLOT_OUT" ] && out+="$T_EL"$'\n'"$PLOT_OUT"
  fi

  # The account block, between the header and the rows: one line per account,
  # with that account's own windows on it -- the ones the fleet is signed in to
  # first, then the ones it has left but whose windows are still running down.
  # Not in the header bar, because there can be more than one of them and the bar
  # is one line; not in a column, because the numbers belong to the account rather
  # than to any session, and a column would repeat each one down every row it
  # owns.
  i=0
  while [ "$i" -lt "$ACC_SHOWN" ]; do
    monitor_acc_row "$w" "${ACC_ORDER[$i]}"
    acc+="$ACC_ROW"
    i=$((i + 1))
  done
  [ -n "$acc" ] && acc+="$T_EL"$'\n'

  if [ "$n" -eq 0 ]; then
    hdr=" MONITOR  no sessions found"
    out="  nothing to monitor yet$T_EL"$'\n'
  else
    printf -v hdr ' MONITOR  %d sessions  %d claude  %d working  %d need you' \
      "$n" "$N_CLAUDE" "$N_WORK" "$N_NEED"
    hdr="$hdr  refresh ${INTERVAL}s"
    # The limits go in the block under the header, not up here -- there can be
    # more than one account's worth of them and this is one line. What is left
    # here is the fallback: a fleet where nothing named an account, which is what
    # a Claude older than the acct= export looks like, keeps the pair it always
    # had in the place it always had it.
    #
    # Kept to ASCII -- printf pads this bar by bytes, so a multibyte glyph would
    # leave the reverse video short of the right edge.
    # A window reading 100 is FULL, not "nearly there": the utilization behind it
    # is clamped, so it cannot climb past that to say how far past it went.
    # Gated on the accounts a session is actually reporting, not on the lines in
    # the block: a remembered account is not this fleet's reading, and hiding the
    # pair behind one would take the header away from an installation whose
    # sessions never name an account at all.
    if [ "$ACC_LIVE" -eq 0 ]; then
      if [ -n "$X_LIM5" ]; then
        hdr="$hdr  5h ${X_LIM5}%"
        [ "$X_LIM5" -ge 100 ] 2>/dev/null && hdr="$hdr FULL"
        [ -n "$X_RST5" ] && hdr="$hdr to $X_RST5"
      fi
      if [ -n "$X_LIM7" ]; then
        hdr="$hdr  7d ${X_LIM7}%"
        [ "$X_LIM7" -ge 100 ] 2>/dev/null && hdr="$hdr FULL"
        [ -n "$X_RST7" ] && hdr="$hdr to $X_RST7"
      fi
    fi
    # Spend is not up here any more; it is on the total line under the rows,
    # beneath the per-session column it adds up.
    [ -n "$X_NOTICE" ] && hdr="$hdr  ** $X_NOTICE"
  fi

  # Redraw in place: home the cursor and erase line by line. A full clear each
  # tick flickers.
  { printf '%s%s%-*s%s%s\n' "$T_HOME" "${C_REV}${C_BOLD}" "$w" "${hdr:0:$w}" "$C_RST" "$T_EL"
    printf '%s\n' "$T_EL"
    printf '%s' "$acc"
    printf '%s' "$out"
    printf '%s\n' "$T_EL"
    printf '%s  %sj/k%s move   %senter%s jump   %s1-9/a-z%s jump directly   %su%s usage   %sr%s refresh   %sq%s back%s%s\n' \
      "$C_DIM" "$C_RST$C_BOLD" "$C_RST$C_DIM" "$C_RST$C_BOLD" "$C_RST$C_DIM" \
      "$C_RST$C_BOLD" "$C_RST$C_DIM" "$C_RST$C_BOLD" "$C_RST$C_DIM" \
      "$C_RST$C_BOLD" "$C_RST$C_DIM" "$C_RST$C_BOLD" "$C_RST$C_DIM" "$C_RST" "$T_EL"
    printf '%s' "$T_ED"
  } 2>/dev/null
}

# --- keys -------------------------------------------------------------------

# The client looking at this session, for the commands below to aim at.
#
# It has to be resolved explicitly: a bare `switch-client` picks an arbitrary
# client when it has no context, which means it can yank a client attached to a
# completely unrelated session. So if we cannot identify the client for our own
# session, we do nothing rather than move someone else's view.
monitor_client() {
  local sess client
  [ -n "${TMUX:-}" ] || return 1
  client=$(tmux display-message -p '#{client_name}' 2>/dev/null)
  if [ -z "$client" ]; then
    sess=$(tmux display-message -p '#{session_name}' 2>/dev/null)
    [ -n "$sess" ] || return 1
    client=$(tmux list-clients -t "$sess" -F '#{client_name}' 2>/dev/null | head -1)
  fi
  [ -n "$client" ] || return 1
  printf '%s' "$client"
}

# Move that client over to a target session.
monitor_switch() {
  local target=$1 client
  client=$(monitor_client) || return 1
  tmux switch-client -c "$client" -t "$target" 2>/dev/null
}

# Leaving the monitor puts the client back where it came from, rather than
# letting it fall out of tmux altogether. Quitting ends the monitor's session,
# and a client attached to a session that gets destroyed detaches
# (detach-on-destroy is on by default) -- so the client is walked to its last
# session first, and only then is the loop allowed to end. With no last session
# to go to (attached straight to the monitor, or it is the only one left) there
# is nothing to do and the old behaviour stands.
monitor_back() {
  local client
  client=$(monitor_client) || return 1
  tmux switch-client -c "$client" -l 2>/dev/null
}

key_index() { # position of $1 in KEYS, or -1
  local i=0 c
  while [ "$i" -lt ${#KEYS} ]; do
    c=${KEYS:$i:1}
    [ "$c" = "$1" ] && { printf '%s' "$i"; return; }
    i=$((i + 1))
  done
  printf -- '-1'
}

# What an escape sequence the monitor has no key for reports back as. It has to be
# something no key is bound to -- so it is ignored, like any other stray key --
# and it has to be non-empty, because empty is what enter reads as: home or page
# up must not jump to a session.
K_NONE=$'\a'

# How long a byte of a key sequence is waited for. bash 4.0 was the first to take
# a fraction here; 3.2 -- what macOS ships as /bin/bash, and what this runs under
# whenever a newer one is not on PATH -- rejects one outright, and the read fails
# instead of waiting. That is what used to make every arrow key quit the monitor:
# the tail of the sequence was never read, so the esc that began it came back on
# its own.
#
# Whole seconds are all 3.2 has, and T_ESC is only ever waited out by an esc
# pressed alone: the rest of a real sequence is already in the buffer by the time
# the esc has been read. So an arrow stays instant there, and only quitting gets
# slower.
#
# T_POLL drains the keys typed while the last tick was drawing, so it must not
# wait at all. 3.2 has no value that does not: -t 0 fails whether or not a key is
# waiting. There the drain is skipped and keys are applied one frame at a time.
if [ "${BASH_VERSINFO[0]:-3}" -ge 4 ]; then
  T_ESC=0.05
  T_POLL=0.001
else
  T_ESC=1
  T_POLL=
fi

# One keypress, waiting $1 seconds for it, with the arrow keys reported as the
# hjkl they stand in for. Without that an arrow would read as a bare esc and quit
# the monitor.
#
# An arrow is esc, then '[' or 'O', then 'A'-'D', with optional parameter bytes
# before the letter. All three forms turn up in practice: 'O' is what a terminal
# sends once application cursor keys mode is on -- tmux switches a pane to it on
# the program's request, and passes the outer terminal's arrows through in
# whichever form the pane is in -- and the parameters carry the modifiers, so
# ctrl-up arrives as "esc [ 1 ; 5 A".
#
# The sequence is read a byte at a time rather than in one two-byte gulp. That is
# what makes the above possible, and it also gives each byte its own 50ms rather
# than sharing one window between them: a keypress whose bytes arrive apart, which
# over a slow link they do, reads as an arrow instead of quitting the monitor.
#
# The timeout is what distinguishes "esc alone" from "esc starting a sequence";
# see T_ESC above for what it is worth on each bash.
monitor_key() {
  local k c t=$1
  IFS= read -rsn1 -t "$t" k || return 1
  [ "$k" = $'\033' ] || { printf '%s' "$k"; return; }

  # Nothing behind the esc, or something that cannot begin a key sequence: the
  # user pressed esc, which closes the monitor.
  IFS= read -rsn1 -t "$T_ESC" c 2>/dev/null || c=""
  case $c in
    '['|'O') ;;
    *) printf '%s' $'\033'; return ;;
  esac

  # The letter that says which key it was comes last, after any parameters; only
  # the letter matters here, so the parameters are read and dropped.
  k=""
  while IFS= read -rsn1 -t "$T_ESC" c 2>/dev/null; do
    case $c in
      [0-9]|';') continue ;;
      *) k=$c; break ;;
    esac
  done
  case $k in
    A) printf 'k' ;;
    B) printf 'j' ;;
    C) printf 'l' ;;
    D) printf 'h' ;;
    *) printf '%s' "$K_NONE" ;;
  esac
}

# `read -s` only silences the keys it reads itself, so anything typed while a tick
# is being drawn is echoed by the terminal -- holding j paints "jjjjj" over the
# monitor. Echo goes off for as long as the monitor is up instead, and the
# terminal is put back exactly as it was on the way out. SAVED_STTY is global on
# purpose: the trap runs after run_monitor's locals are gone.
SAVED_STTY=""

monitor_raw_off() {
  printf '%s%s' "$T_SHOW" "$T_ALT_OFF"
  [ -n "$SAVED_STTY" ] && stty "$SAVED_STTY" 2>/dev/null
  SAVED_STTY=""
}

# A tick for whichever screen is up. The usage chart is drawn from the ledger
# alone, so its tick skips the snapshot and the per-pane captures -- the whole
# cost of a fleet tick -- and reads the day's files instead. Closing the chart
# collects the fleet again before it is drawn, so nothing stale is left on it.
monitor_tick() {
  if [ "$VIEW" = usage ]; then
    monitor_clock
    monitor_read_ledger
  else
    monitor_collect
  fi
}

run_monitor() {
  local key idx n leave moved
  printf '%s%s' "$T_ALT_ON" "$T_HIDE"
  trap 'monitor_raw_off; exit 0' EXIT INT TERM
  if [ -t 0 ]; then
    SAVED_STTY=$(stty -g 2>/dev/null) || SAVED_STTY=""
    stty -echo 2>/dev/null || true
  fi

  monitor_collect
  while :; do
    monitor_draw
    if [ ! -t 0 ]; then
      sleep "$INTERVAL"   # no keyboard (piped/headless): just keep refreshing
      monitor_tick
      continue
    fi

    if key=$(monitor_key "$INTERVAL"); then
      n=${#SESSIONS[@]}
      leave=""
      moved=""
      # Held keys arrive faster than the screen can be drawn, so everything
      # already queued is applied before drawing again. Otherwise the cursor
      # crawls behind the keyboard and keeps moving after the key comes up.
      while :; do
        case $key in
          # One key for both screens: from the chart it goes back to the fleet,
          # from the fleet it closes the monitor. Nothing can strand you on the
          # screen you did not want.
          q|$'\033')
            if [ "$VIEW" = usage ]; then VIEW=fleet; moved=""; else leave=1; fi ;;
          u)
            if [ "$VIEW" = usage ]; then
              VIEW=fleet; moved=""      # empty, so the fleet is collected again
            else
              VIEW=usage; HIST_OFF=0; moved=1
            fi
            ;;
          r) ;;     # nothing to do: the tick below is the refresh
          '') [ "$VIEW" = fleet ] && [ "$n" -gt 0 ] &&
                monitor_switch "${SESSIONS[$SEL]}" ;;
          # The cursor keys, which mean sessions on the fleet and days on the
          # chart. h and l have nothing to do on a list one column wide; on the
          # chart, where time runs left to right, they are the ones that mean
          # anything -- left is older, right is newer -- and j/k step by the week,
          # which is the stride you want when looking for the shape of a month.
          j|k|h|l)
            moved=1
            if [ "$VIEW" = usage ]; then
              case $key in
                h) HIST_OFF=$((HIST_OFF + 1)) ;;
                l) HIST_OFF=$((HIST_OFF - 1)) ;;
                k) HIST_OFF=$((HIST_OFF + 7)) ;;
                j) HIST_OFF=$((HIST_OFF - 7)) ;;
              esac
              # The far end is clamped by the draw, which is the only place that
              # knows how many rows fit; this end needs no such help.
              [ "$HIST_OFF" -lt 0 ] && HIST_OFF=0
            else
              case $key in
                j) [ "$n" -gt 0 ] && { SEL=$(( (SEL + 1) % n )); SEL_NAME=${SESSIONS[$SEL]}; } ;;
                k) [ "$n" -gt 0 ] && { SEL=$(( (SEL - 1 + n) % n )); SEL_NAME=${SESSIONS[$SEL]}; } ;;
              esac
            fi
            ;;
          *)
            if [ "$VIEW" = fleet ]; then
              idx=$(key_index "$key")
              if [ "$idx" -ge 0 ] && [ "$idx" -lt "$n" ]; then
                monitor_switch "${SESSIONS[$idx]}"
              fi
            fi
            ;;
        esac
        [ -n "$leave" ] && break
        [ -n "$T_POLL" ] || break   # no poll on this bash: one key per frame
        key=$(monitor_key "$T_POLL") || break
      done
      [ -n "$leave" ] && break
      # A cursor move or a scroll redraws from what the last tick collected;
      # anything else goes and looks again.
      [ -n "$moved" ] || monitor_tick
    else
      monitor_tick   # the interval ran out: time for a fresh tick
    fi
  done
  # The terminal goes back first so the pane is left clean, then the client is
  # walked back to where it came from -- while this session, and the client's
  # attachment to it, are both still alive.
  monitor_raw_off
  monitor_back
}

open_session() {
  if ! tmux has-session -t "$MON" 2>/dev/null; then
    tmux new-session -d -s "$MON" -n monitor "$(printf '%q --run' "$SELF")" || return 1
    tmux set-option -t "$MON" status-left \
      '#[fg=#1F1F28,bg=#E6C384,bold] monitor #[default]'
    tmux set-option -t "$MON" remain-on-exit off
    tmux set-option -w -t "$MON:monitor" automatic-rename off
  fi
  # Same explicit client resolution as the jump keys: prefix+M arrives via
  # run-shell, where a bare switch-client has to guess the client.
  if [ -n "${TMUX:-}" ]; then
    monitor_switch "$MON"
  else
    tmux attach-session -t "$MON"
  fi
}

# Guarded so the file can be sourced for its functions -- which the tests do, to
# reach the ledger arithmetic without a terminal. Run normally, this is the only
# thing that happens.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case ${1:-} in
    --run)      run_monitor ;;
    ''|--open)  open_session ;;
    *)
      printf 'usage: %s [--open|--run]\n' "$(basename "$0")" >&2
      exit 2
      ;;
  esac
fi
