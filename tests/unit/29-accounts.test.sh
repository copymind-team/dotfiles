#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: accounts${RESET}\n"

STATUSLINE="$DOTFILES_DIR/claude/statusline.sh"
MONITOR="$DOTFILES_DIR/tmux/monitor.sh"

# A monitor directory and a config of their own, so the real ~/.claude.json is
# neither read nor written and no real export is touched.
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/accounts-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export CLAUDE_MONITOR_DIR="$ROOT/monitor"
export CLAUDE_SESSION_DIR="$ROOT/sessions"
mkdir -p "$CLAUDE_MONITOR_DIR" "$CLAUDE_SESSION_DIR" "$ROOT/cfg"

NOW="$(date +%s)"
AHEAD=$((NOW + 3600))     # a reset still to come: the reading describes this window
BEHIND=$((NOW - 3600))    # one already past: the reading has been superseded

config() { # write a Claude config holding $1 as the signed-in address
  printf '{"numStartups":3,"oauthAccount":{"accountUuid":"u","emailAddress":"%s","organizationName":"Org"}}\n' \
    "$1" > "$ROOT/cfg/.claude.json"
}

status_tick() { # one render for session $1: cost $2 (default 1.00), 5h $3 (7)
  printf '{"context_window":{"used_percentage":10},"cost":{"total_cost_usd":%s},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":20,"resets_at":%s}},"model":{"display_name":"Test"},"session_id":"%s"}' \
    "${2:-1.00}" "${3:-7}" "$AHEAD" "$AHEAD" "$1" | \
    env CLAUDE_CONFIG_DIR="$ROOT/cfg" TMUX= TMUX_PANE= bash "$STATUSLINE" >/dev/null
}

pane_tick() { # the same, but from inside tmux, so the export is keyed by pane
  printf '{"context_window":{"used_percentage":10},"cost":{"total_cost_usd":%s},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":20,"resets_at":%s}},"model":{"display_name":"Test"},"session_id":"%s"}' \
    "${2:-1.00}" "${3:-7}" "$AHEAD" "$AHEAD" "$1" | \
    env CLAUDE_CONFIG_DIR="$ROOT/cfg" TMUX="/tmp/sock,4242,0" TMUX_PANE="%7" \
      bash "$STATUSLINE" >/dev/null
}
PANE_META="$CLAUDE_MONITOR_DIR/4242-7.meta"

value_of() { # value for key $2 in the key=value file $1, or "none"
  [ -r "$1" ] || { echo none; return; }
  local k v
  while IFS='=' read -r k v; do
    [ "$k" = "$2" ] && { echo "$v"; return; }
  done < "$1"
  echo none
}

# ── what the status line writes down ─────────────────────────────────

header "the export carries the account the reading was taken under"
config alice@example.com
status_tick sess-a
assert_eq "the address out of Claude's own config" \
  "alice@example.com" "$(value_of "$CLAUDE_MONITOR_DIR/sess-sess-a.meta" acct)"

header "the account's own windows are filed where they outlive the session"
# What keeps an account on the monitor after the fleet has switched off it: the
# per-pane export goes with the pane, this does not.
assert_eq "the 5h reading, under the address" \
  "7" "$(value_of "$CLAUDE_MONITOR_DIR/limits/alice@example.com" lim5)"
assert_eq "and the weekly one" \
  "20" "$(value_of "$CLAUDE_MONITOR_DIR/limits/alice@example.com" lim7)"
assert_eq "with the reset it came with" \
  "$AHEAD" "$(value_of "$CLAUDE_MONITOR_DIR/limits/alice@example.com" rst5)"

header "the spend ledger carries it too"
assert_eq "so a day can be split by who paid for it later" \
  "alice@example.com" \
  "$(value_of "$CLAUDE_MONITOR_DIR/spend/$(date +%F).sess-a" acct)"

header "a /login elsewhere does not relabel a session that has not answered since"
# The bug this guards. The config is one global file that `/login` rewrites for
# every session on the machine at once, so a session that merely re-rendered --
# which they do for all sorts of reasons -- used to pick up the new address while
# still reporting the previous account's usage windows underneath it.
config bob@example.com
touch "$ROOT/cfg/.claude.json"      # a later mtime, as a rewrite would leave
status_tick sess-a                  # same cost, same limits: no new reading
assert_eq "the numbers still belong to the old account, and say so" \
  "alice@example.com" "$(value_of "$CLAUDE_MONITOR_DIR/sess-sess-a.meta" acct)"

header "a session that has answered since the switch relabels itself"
status_tick sess-a 2.00
assert_eq "new cost, so a new reading to attribute" \
  "bob@example.com" "$(value_of "$CLAUDE_MONITOR_DIR/sess-sess-a.meta" acct)"

header "a moved window counts as a new reading too"
# Usage can move on a turn too cheap to shift the cost, so the limits are watched
# in their own right rather than left to the cost to stand in for.
config carol@example.com
touch "$ROOT/cfg/.claude.json"
status_tick sess-a 2.00 9
assert_eq "same cost, higher 5h" \
  "carol@example.com" "$(value_of "$CLAUDE_MONITOR_DIR/sess-sess-a.meta" acct)"

header "the address is cached, so the config is not parsed on every render"
# It is a 120KB document and this runs on every assistant message. The cache is
# keyed off the config's own mtime, which is what a login or a switch changes.
CACHE="$CLAUDE_MONITOR_DIR/accounts/${ROOT//\//_}_cfg_.claude.json"
assert_eq "the cache holds the current address" \
  "carol@example.com" "$(value_of "$CACHE" acct)"
# Proved by making the two disagree: the cache is what comes out, so the config
# was not touched.
printf 'acct=fromcache@example.com\n' > "$CACHE"
status_tick sess-a 3.00
assert_eq "an unchanged config is read from the cache, not re-parsed" \
  "fromcache@example.com" "$(value_of "$CLAUDE_MONITOR_DIR/sess-sess-a.meta" acct)"
config carol@example.com
touch "$ROOT/cfg/.claude.json"      # newer than the cache again

header "a pane's next session does not inherit the last one's account"
# The export is keyed by tmux server pid and pane, so the first render of a new
# session in a reused pane compares itself against the previous occupant's
# reading. Same numbers here, deliberately: only the id says it is a different
# session, and that has to be enough on its own.
config dave@example.com
touch "$ROOT/cfg/.claude.json"
pane_tick sess-first 4.00 11
assert_eq "the pane's first session" \
  "dave@example.com" "$(value_of "$PANE_META" acct)"
config erin@example.com
touch "$ROOT/cfg/.claude.json"
pane_tick sess-second 4.00 11         # identical reading, different session
assert_eq "a new session in that pane is read afresh" \
  "erin@example.com" "$(value_of "$PANE_META" acct)"
assert_eq "and the export names the new session" \
  "sess-second" "$(value_of "$PANE_META" session)"

header "a config with no account in it exports nothing rather than a guess"
printf '{"numStartups":3}\n' > "$ROOT/cfg/.claude.json"
status_tick sess-c
assert_eq "an API-key login has no address here" \
  "" "$(value_of "$CLAUDE_MONITOR_DIR/sess-sess-c.meta" acct)"

header "an unreadable config costs the export nothing else"
rm -f "$ROOT/cfg/.claude.json"
status_tick sess-d
assert_eq "no address" "" "$(value_of "$CLAUDE_MONITOR_DIR/sess-sess-d.meta" acct)"
assert_eq "and the numbers are still there" \
  "10" "$(value_of "$CLAUDE_MONITOR_DIR/sess-sess-d.meta" ctx)"
assert_eq "including the limits" \
  "7" "$(value_of "$CLAUDE_MONITOR_DIR/sess-sess-d.meta" lim5)"

# ── what the monitor makes of it ─────────────────────────────────────

# Sourced for its functions; the dispatch at the bottom is guarded, so nothing
# runs and no terminal is needed. Colors are forced on, since the monitor turns
# them off when stdout is not a terminal and one of the assertions below is about
# what gets colored; the rows are compared with the escapes stripped or in full,
# so nothing else minds.
export MONITOR_FORCE_COLOR=1
# shellcheck disable=SC1090
source "$MONITOR"

# The addresses the half above signed in and out of are still on file, and this
# half is about what the monitor makes of a fleet it describes itself. Cleared so
# the two fixtures do not mix; the accounts kept across a switch have a section of
# their own at the end, which puts back what it needs.
rm -rf "$CLAUDE_MONITOR_DIR/limits"

limits_file() { # remember account $1 at 5h $2, 7d $3, resetting $4, written $5
  mkdir -p "$CLAUDE_MONITOR_DIR/limits"
  printf 'lim5=%s\nlim7=%s\nrst5=%s\nrst7=%s\nacct=%s\nts=%s\n' \
    "$2" "$3" "$4" "$AHEAD" "$1" "${5:-$NOW}" > "$CLAUDE_MONITOR_DIR/limits/$1"
}

meta() { # pane, lim5, lim7, sub, acct, rst5
  printf 'ctx=30\ncost=1.00\nover=0.00\nlim5=%s\nlim7=%s\nrst5=%s\nrst7=%s\nsub=%s\nacct=%s\nmodel=Opus\nsession=s-%s\nts=%s\n' \
    "$2" "$3" "$6" "$AHEAD" "$4" "$5" "$1" "$NOW" \
    > "$CLAUDE_MONITOR_DIR/9-$1.meta"
}

# Everything monitor_collect would do between reading the exports and drawing,
# minus the half that needs a live tmux to classify a pane.
settle() {
  local i=0
  monitor_clock
  monitor_read_exports
  while [ "$i" -lt "${#SESSIONS[@]}" ]; do
    [ -n "${X_ACCT[$i]}" ] && monitor_acc_find "${X_ACCT[$i]}" &&
      ACC_N[$ACC_I]=$((ACC_N[$ACC_I] + 1))
    i=$((i + 1))
  done
  monitor_acc_remembered
  monitor_acc_order
  monitor_acc_tags
}

limits_of() { # "lim5 lim7" held for account $1, or "none"
  monitor_acc_find "$1" || { echo none; return; }
  echo "${ACC_LIM5[$ACC_I]} ${ACC_LIM7[$ACC_I]}"
}

SERVER_PID=9

header "each account keeps its own pair of windows"
SESSIONS=(one two three); P_PANE=(%1 %2 %3)
meta 1 8  46 1 os@pailab.co  "$AHEAD"
meta 2 8  46 1 os@pailab.co  "$AHEAD"
meta 3 91 12 1 work@acme.com "$AHEAD"
settle
assert_eq "the first account's" "8 46" "$(limits_of os@pailab.co)"
assert_eq "the second account's" "91 12" "$(limits_of work@acme.com)"
assert_eq "both get a line" "2" "$ACC_SHOWN"
assert_eq "and the sessions are counted per account" "2" \
  "$(monitor_acc_find os@pailab.co && echo "${ACC_N[$ACC_I]}")"

header "the newest reading wins, but only against its own account"
# The whole point of the split. Written last and highest, so a single newest-wins
# rule over the fleet would put 99 on both lines.
printf 'ctx=30\ncost=1.00\nlim5=99\nlim7=99\nrst5=%s\nrst7=%s\nsub=1\nacct=work@acme.com\nsession=s-3\nts=%s\n' \
  "$AHEAD" "$AHEAD" "$((NOW + 10))" > "$CLAUDE_MONITOR_DIR/9-3.meta"
settle
assert_eq "the account that answered moves" "99 99" "$(limits_of work@acme.com)"
assert_eq "the one that did not is untouched" "8 46" "$(limits_of os@pailab.co)"

header "a reading from the account you just left is not shown as the current one"
# What /login switching looks like from here: pane 1 has answered since the
# switch and pane 2 has not, so its numbers describe an account that is no
# longer signed in. They belong to that account's line, not to this one.
SESSIONS=(one two); P_PANE=(%1 %2)
rm -f "$CLAUDE_MONITOR_DIR/9-3.meta"
meta 1 3  5  1 new@example.com "$AHEAD"
meta 2 97 88 1 old@example.com "$AHEAD"
settle
assert_eq "the account in front of you" "3 5" "$(limits_of new@example.com)"
assert_eq "and the one behind it, said so" "97 88" "$(limits_of old@example.com)"

header "an API-billed session is kept off the subscription lines"
SESSIONS=(one two); P_PANE=(%1 %2)
meta 1 8  46 1 os@pailab.co "$AHEAD"
meta 2 -1 -1 0 os@pailab.co 0
settle
assert_eq "only the subscription gets a line" "1" "$ACC_SHOWN"
assert_eq "the api session is not counted on it" "1" \
  "$(monitor_acc_find os@pailab.co && echo "${ACC_N[$ACC_I]}")"
assert_eq "it is keyed apart" "api" "${X_ACCT[1]}"

header "a superseded window loses its number; the one beside it keeps its own"
# The two windows roll at completely different rates, so they are judged apart: a
# reading from six hours ago has outlived its 5-hour window and not its weekly
# one, and the weekly figure is the one worth keeping.
SESSIONS=(one); P_PANE=(%1)
meta 1 8 46 1 os@pailab.co "$BEHIND"
settle
assert_eq "the line is still drawn" "1" "$ACC_SHOWN"
assert_eq "the rolled window is blank, the weekly one is not" \
  " 46" "$(limits_of os@pailab.co)"

header "a reading with nothing current left in it is not taken at all"
SESSIONS=(one); P_PANE=(%1)
printf 'ctx=30\ncost=1.00\nlim5=8\nlim7=46\nrst5=%s\nrst7=%s\nsub=1\nacct=os@pailab.co\nsession=s-1\nts=%s\n' \
  "$BEHIND" "$BEHIND" "$NOW" > "$CLAUDE_MONITOR_DIR/9-1.meta"
settle
assert_eq "the line is still drawn" "1" "$ACC_SHOWN"
assert_eq "with nothing on it" " " "$(limits_of os@pailab.co)"

header "a fleet that named no account falls back to the old single pair"
SESSIONS=(one two); P_PANE=(%1 %2)
meta 1 8 46 1 "" "$AHEAD"
meta 2 8 46 1 "" "$AHEAD"
settle
assert_eq "no account lines" "0" "$ACC_SHOWN"
assert_eq "the header's 5h" "8" "$X_LIM5"
assert_eq "the header's 7d" "46" "$X_LIM7"

# ── the tags on the rows ─────────────────────────────────────────────

header "tags are the part in front of the @"
SESSIONS=(one two); P_PANE=(%1 %2)
meta 1 8  46 1 os@pailab.co  "$AHEAD"
meta 2 91 12 1 work@acme.com "$AHEAD"
settle
assert_eq "the first" "os" "$(monitor_acc_find os@pailab.co && echo "${ACC_TAG[$ACC_I]}")"
assert_eq "the second" "work" "$(monitor_acc_find work@acme.com && echo "${ACC_TAG[$ACC_I]}")"
assert_eq "and there is a column for them" "2" "$ACC_TAGGED"

header "two accounts sharing one local part are widened, not merged"
SESSIONS=(one two); P_PANE=(%1 %2)
meta 1 8  46 1 dev@acme.com   "$AHEAD"
meta 2 91 12 1 dev@pailab.co  "$AHEAD"
settle
assert_eq "the first" "dev@acme" "$(monitor_acc_find dev@acme.com && echo "${ACC_TAG[$ACC_I]}")"
assert_eq "the second" "dev@pail" "$(monitor_acc_find dev@pailab.co && echo "${ACC_TAG[$ACC_I]}")"

header "one account is no column at all"
SESSIONS=(one two); P_PANE=(%1 %2)
meta 1 8 46 1 os@pailab.co "$AHEAD"
meta 2 8 46 1 os@pailab.co "$AHEAD"
settle
assert_eq "nothing to tell apart" "1" "$ACC_TAGGED"

# ── the account lines themselves ─────────────────────────────────────

header "the lines are alphabetical, so one does not jump when another appears"
SESSIONS=(one two three); P_PANE=(%1 %2 %3)
meta 1 8  46 1 zeta@example.com  "$AHEAD"
meta 2 91 12 1 alpha@example.com "$AHEAD"
meta 3 30 30 1 mid@example.com   "$AHEAD"
settle
ORDER=""
for idx in "${ACC_ORDER[@]}"; do ORDER="$ORDER ${ACC_KEY[$idx]}"; done
assert_eq "sorted by address" \
  " alpha@example.com mid@example.com zeta@example.com" "$ORDER"

header "an exhausted window says FULL and is drawn hot"
monitor_acc_window 100 "6:02PM"
assert_contains "the word" "FULL" "$ACC_WIN"
assert_eq "and the flag the caller colors on" "1" "$ACC_WIN_HOT"
monitor_acc_window 46 "6:02PM"
assert_not_contains "not at 46" "FULL" "$ACC_WIN"
assert_eq "nor the flag" "" "$ACC_WIN_HOT"
monitor_acc_window -1 ""
assert_eq "and an unknown window is blank, not zero" "" "$(echo "$ACC_WIN" | tr -d ' ')"

# ── accounts the fleet has left ──────────────────────────────────────

header "an account with nothing live on it keeps its line and its windows"
# The whole point: you switch away because a window is full, and full is exactly
# what you need to keep seeing -- along with when it comes back.
SESSIONS=(one); P_PANE=(%1)
rm -f "$CLAUDE_MONITOR_DIR"/9-*.meta
meta 1 3 5 1 new@example.com "$AHEAD"
limits_file old@example.com 97 88 "$AHEAD"
settle
assert_eq "both accounts get a line" "2" "$ACC_SHOWN"
assert_eq "the one that is running" "3 5" "$(limits_of new@example.com)"
assert_eq "and the one that is not, out of the ledger" "97 88" "$(limits_of old@example.com)"
assert_eq "with no sessions counted on it" "0" \
  "$(monitor_acc_find old@example.com && echo "${ACC_N[$ACC_I]}")"
assert_eq "the live one is not marked as left" "" \
  "$(monitor_acc_find new@example.com && echo "${ACC_OFF[$ACC_I]}")"
assert_eq "the other one is" "1" \
  "$(monitor_acc_find old@example.com && echo "${ACC_OFF[$ACC_I]}")"

header "the live accounts come first, then the ones the fleet has left"
# So a line does not jump between the halves as sessions come and go, and the
# accounts something is actually running on stay at the top.
SESSIONS=(one); P_PANE=(%1)
rm -f "$CLAUDE_MONITOR_DIR"/limits/*
meta 1 3 5 1 zeta@example.com "$AHEAD"
limits_file alpha@example.com 10 10 "$AHEAD"
limits_file omega@example.com 20 20 "$AHEAD"
settle
ORDER=""
for idx in "${ACC_ORDER[@]}"; do ORDER="$ORDER ${ACC_KEY[$idx]}"; done
assert_eq "the running one, then the rest alphabetically" \
  " zeta@example.com alpha@example.com omega@example.com" "$ORDER"
rm -f "$CLAUDE_MONITOR_DIR/limits/alpha@example.com" \
      "$CLAUDE_MONITOR_DIR/limits/omega@example.com"

header "a session's own reading still beats the one on file"
# The ledger holds whatever was filed last, which on a live account is the same
# reading a session is exporting -- so it goes through the same newest-wins rule
# rather than around it.
SESSIONS=(one); P_PANE=(%1)
rm -f "$CLAUDE_MONITOR_DIR"/9-*.meta "$CLAUDE_MONITOR_DIR"/limits/*
meta 1 42 44 1 os@pailab.co "$AHEAD"
limits_file os@pailab.co 8 9 "$AHEAD" "$((NOW - 60))"
settle
assert_eq "the newer reading wins" "42 44" "$(limits_of os@pailab.co)"
assert_eq "and the account is live, not remembered" "" \
  "$(monitor_acc_find os@pailab.co && echo "${ACC_OFF[$ACC_I]}")"

header "a ledger reading newer than every session's is the one shown"
# What a /login looks like on the account you moved to: the session that answered
# has since gone, and its reading is the only current one there is.
limits_file os@pailab.co 61 62 "$AHEAD" "$((NOW + 60))"
settle
assert_eq "the ledger's" "61 62" "$(limits_of os@pailab.co)"

header "an account left hours ago keeps the weekly window it was left on"
# The case this is all for. Six hours after the switch the 5-hour figure describes
# a window that has rolled, and the weekly one -- the reason you switched -- does
# not.
SESSIONS=(); P_PANE=()
rm -f "$CLAUDE_MONITOR_DIR"/9-*.meta "$CLAUDE_MONITOR_DIR"/limits/*
limits_file old@example.com 97 88 "$BEHIND"
settle
assert_eq "the line is still drawn" "1" "$ACC_SHOWN"
assert_eq "the 5h is gone and the 7d is not" " 88" "$(limits_of old@example.com)"

header "an account not used for a week and a day is not kept"
rm -f "$CLAUDE_MONITOR_DIR"/limits/*
limits_file stale@example.com 97 88 "$AHEAD" "$((NOW - 8 * 86400 - 60))"
settle
assert_eq "no line for it" "0" "$ACC_SHOWN"
limits_file fresh@example.com 97 88 "$AHEAD" "$((NOW - 6 * 86400))"
settle
assert_eq "one still inside the window keeps its own" "1" "$ACC_SHOWN"

header "a remembered account does not put an account column on the rows"
# The column is there to tell one session's account from another's, and a
# remembered account has no sessions to tell apart.
SESSIONS=(one); P_PANE=(%1)
rm -f "$CLAUDE_MONITOR_DIR"/limits/*
meta 1 3 5 1 new@example.com "$AHEAD"
limits_file old@example.com 97 88 "$AHEAD"
settle
assert_eq "two lines in the block" "2" "$ACC_SHOWN"
assert_eq "but one account on the rows" "1" "$ACC_TAGGED"

header "a remembered account does not take the header's own pair away"
# The fallback is for a fleet whose sessions name no account at all. A line from
# the ledger is not one of those sessions answering, so it must not stand in for
# them.
SESSIONS=(one); P_PANE=(%1)
meta 1 8 46 1 "" "$AHEAD"
settle
assert_eq "the remembered account still has its line" "1" "$ACC_SHOWN"
assert_eq "and no live account to replace the header" "0" "$ACC_LIVE"
assert_eq "so the header keeps its 5h" "8" "$X_LIM5"
assert_eq "and its 7d" "46" "$X_LIM7"

header "whatever else is in the directory is not read as an account"
rm -f "$CLAUDE_MONITOR_DIR"/limits/*
printf 'lim5=1\nlim7=1\nrst5=%s\nrst7=%s\nts=%s\n' "$AHEAD" "$AHEAD" "$NOW" \
  > "$CLAUDE_MONITOR_DIR/limits/.tmp.4242"
settle
assert_eq "a temp file caught mid-rename is not a line" "0" "$ACC_SHOWN"
rm -f "$CLAUDE_MONITOR_DIR/limits/.tmp.4242"

header "a remembered line says 0 sess, and is drawn dim"
SESSIONS=(); P_PANE=()
rm -f "$CLAUDE_MONITOR_DIR"/9-*.meta "$CLAUDE_MONITOR_DIR"/limits/*
limits_file old@example.com 97 88 "$AHEAD"
settle
monitor_acc_row 90 "${ACC_ORDER[0]}"
assert_contains "the count that marks it" "0 sess" "$ACC_ROW"
assert_eq "the address is dimmed with the rest of the line" \
  "  $C_DIM" "${ACC_ROW%%old@*}"
assert_contains "and the window it was left on is still there" "97%" "$ACC_ROW"

header "a live account's address is not dimmed"
SESSIONS=(one); P_PANE=(%1)
meta 1 3 5 1 new@example.com "$AHEAD"
settle
monitor_acc_row 90 "${ACC_ORDER[0]}"
assert_eq "nothing between the indent and the name" \
  "  " "${ACC_ROW%%new@*}"

header "the line is cut to the terminal rather than wrapped"
# A wrapped line shifts every row under it, which breaks the redraw-in-place.
SESSIONS=(one); P_PANE=(%1)
meta 1 100 91 1 averyveryverylongaddress@example.com "$AHEAD"
settle
monitor_acc_row 40 "${ACC_ORDER[0]}"
PLAIN="$(printf '%s' "$ACC_ROW" | sed -e $'s/\033\\[[0-9;]*[A-Za-z]//g' -e 's/$//' | head -1)"
assert_eq "no longer than the width given" "40" "${#PLAIN}"

print_results
