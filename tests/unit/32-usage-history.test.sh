#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: usage history${RESET}\n"

MONITOR="$DOTFILES_DIR/tmux/monitor.sh"

# A ledger of its own, so a real ~/.claude/monitor is neither read nor written.
LEDGER_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/usage-history-test.XXXXXX")"
trap 'rm -rf "$LEDGER_ROOT"' EXIT
export CLAUDE_MONITOR_DIR="$LEDGER_ROOT"
SPEND="$LEDGER_ROOT/spend"
mkdir -p "$SPEND"

# Colors on, so the two-tone bars can be told apart; the assertions that read
# text strip them again.
export MONITOR_FORCE_COLOR=1

# Sourced for its functions; the dispatch at the bottom is guarded, so nothing
# runs and no terminal is needed.
# shellcheck disable=SC1090
source "$MONITOR"

plain() { sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g'; }

# Draws the chart into DRAWN (escapes stripped) and DRAWN_RAW (as it went to the
# screen). Not through a command substitution: the draw measures its columns into
# globals as it goes, and a subshell would take those with it.
DRAWN=""
DRAWN_RAW=""
draw_usage() {
  VIEW=usage
  monitor_draw_usage > "$LEDGER_ROOT/drawn"
  DRAWN_RAW="$(cat "$LEDGER_ROOT/drawn")"
  DRAWN="$(plain < "$LEDGER_ROOT/drawn")"
}
blocks() { printf '%s' "$1" | grep -o '█' | wc -l | tr -d ' '; }

# ── the calendar, without a fork ─────────────────────────────────────

header "the day before, in bash alone"
monitor_day_prev 2026-08-31; assert_eq "mid-month" "2026-08-30" "$DAY_PREV"
monitor_day_prev 2026-08-01; assert_eq "over a month boundary" "2026-07-31" "$DAY_PREV"
monitor_day_prev 2026-01-01; assert_eq "over a year boundary" "2025-12-31" "$DAY_PREV"
monitor_day_prev 2026-05-01; assert_eq "a 30-day month behind it" "2026-04-30" "$DAY_PREV"
monitor_day_prev 2024-03-01; assert_eq "a leap year has the 29th" "2024-02-29" "$DAY_PREV"
monitor_day_prev 2023-03-01; assert_eq "an ordinary year does not" "2023-02-28" "$DAY_PREV"
monitor_day_prev 2100-03-01; assert_eq "a century is not a leap year" "2100-02-28" "$DAY_PREV"
monitor_day_prev 2000-03-01; assert_eq "every fourth one is" "2000-02-29" "$DAY_PREV"

header "the label names the weekday"
monitor_day_label 2026-08-31; assert_eq "a Monday" "Mon 31 Aug" "$DAY_LABEL"
monitor_day_label 2026-08-30; assert_eq "the Sunday before it" "Sun 30 Aug" "$DAY_LABEL"
monitor_day_label 2024-02-29; assert_eq "a leap day" "Thu 29 Feb" "$DAY_LABEL"
monitor_day_label 2000-01-01; assert_eq "the turn of the century" "Sat 01 Jan" "$DAY_LABEL"
monitor_day_label 2026-01-04; assert_eq "January, which the formula shifts" "Sun 04 Jan" "$DAY_LABEL"

# ── the days behind the chart ────────────────────────────────────────

seed() { # <day> <file> <cents> <sub>
  printf 'spent=%s\nlast=%s\nsub=%s\nts=1\n' "$3" "$3" "$4" > "$SPEND/$1.$2"
}

# A fortnight with holes in it, read as if today were the 10th of May.
seed 2026-05-01 a 1000 1     # $10, subscription, and the biggest day there is
seed 2026-05-02 b 500 0      # $5, api
seed 2026-05-05 c 300 1      # a day two sessions paid for, one each way
seed 2026-05-05 d 200 0
seed 2026-05-10 e 700 1      # today, still being written
seed 2026-05-12 f 9999 1     # dated after today: a clock that has moved
seed 2026-13-45 g 8888 1     # not a date at all
printf 'junk\n' > "$SPEND/not-a-ledger-file"

MON_DAY=2026-05-10
monitor_read_ledger
monitor_hist_build

header "the chart walks the calendar, not the directory"
assert_eq "every day from the first to today" "10" "${#HIST_DAY[@]}"
assert_eq "today first" "2026-05-10" "${HIST_DAY[0]}"
assert_eq "and the oldest last" "2026-05-01" "${HIST_DAY[9]}"
assert_eq "today's own figure is the live one" "700" "${HIST_ALL[0]}"
assert_eq "a day with no file is a zero" "0" "${HIST_ALL[1]}"
assert_eq "the day two sessions shared" "500" "${HIST_ALL[5]}"
assert_eq "the oldest day" "1000" "${HIST_ALL[9]}"

header "the figures under the header"
assert_eq "every day added up" "2700" "$HIST_TOTAL"
assert_eq "the biggest day" "1000" "$HIST_MAX"
assert_eq "and which day it was" "2026-05-01" "$HIST_PEAK"
assert_eq "the subscription side" "2000" "$HIST_SUB_ALL"
assert_eq "and the billed side" "700" "$HIST_API_ALL"

header "what the chart leaves off"
assert_not_contains "a day dated after today" "2026-05-12" "${HIST_DAY[*]}"
assert_not_contains "a name that is not a date" "2026-13" "${HIST_DAY[*]}"
assert_eq "both are still in the all-time window" "215.87" "${SPEND_ALL[3]}"

header "the walk has a floor under it"
HIST_DAYS=3
HIST_KEY=""
monitor_hist_build
assert_eq "no further back than it is told" "3" "${#HIST_DAY[@]}"
assert_eq "and it is the recent end that is kept" "2026-05-10" "${HIST_DAY[0]}"
HIST_DAYS=3660

header "an empty ledger has no chart, rather than a chart of zeros"
EMPTY="$(mktemp -d "${TMPDIR:-/tmp}/usage-history-empty.XXXXXX")"
mkdir -p "$EMPTY/spend"
(
  export CLAUDE_MONITOR_DIR="$EMPTY"
  # shellcheck disable=SC1090
  source "$MONITOR"
  monitor_clock
  monitor_read_ledger
  monitor_hist_build
  printf '%s\n' "${#HIST_DAY[@]}"
) > "$EMPTY/out"
assert_eq "nothing recorded, nothing drawn" "0" "$(cat "$EMPTY/out")"
rm -rf "$EMPTY"

# ── the axis ─────────────────────────────────────────────────────────

header "a gridline step is rounded to something readable"
monitor_hist_nice 200;  assert_eq "already round" "200" "$HIST_NICE"
monitor_hist_nice 101;  assert_eq "up to one and a half" "150" "$HIST_NICE"
monitor_hist_nice 203;  assert_eq "then two and a half" "250" "$HIST_NICE"
monitor_hist_nice 251;  assert_eq "then three" "300" "$HIST_NICE"
monitor_hist_nice 501;  assert_eq "then six" "600" "$HIST_NICE"
monitor_hist_nice 601;  assert_eq "then eight" "800" "$HIST_NICE"
monitor_hist_nice 801;  assert_eq "then ten" "1000" "$HIST_NICE"
monitor_hist_nice 37;   assert_eq "under a dollar, the same ladder" "40" "$HIST_NICE"
monitor_hist_nice 1;    assert_eq "a cent is already round" "1" "$HIST_NICE"
monitor_hist_nice 0;    assert_eq "and nothing rounds up to a cent" "1" "$HIST_NICE"
monitor_hist_nice 3;    assert_eq "no half cents on the way up" "3" "$HIST_NICE"

header "the labels are money"
monitor_hist_axis_fmt 1000; assert_eq "whole dollars where it can" '$10' "$AXIS_FMT"
monitor_hist_axis_fmt 250;  assert_eq "and cents where it must" '$2.50' "$AXIS_FMT"
monitor_hist_axis_fmt 0;    assert_eq "the floor" '$0' "$AXIS_FMT"

# ── the chart ────────────────────────────────────────────────────────

# A week whose tallest day is a round $10, so the axis comes out at $10 in five
# steps of $2 and every column below is checkable by eye.
rm -f "$SPEND"/*
seed 2026-05-04 a 1000 1     # the tallest day there is, all subscription
seed 2026-05-05 b 500 1      # half the money
seed 2026-05-06 c 500 0      # the same again, but billed
seed 2026-05-07 d 1 1        # a cent: too small for a row, not too small to see
seed 2026-05-09 e 250 1      # today -- and no file at all for the 8th
MON_DAY=2026-05-09
LDG_DAY=""; HIST_KEY=""
monitor_read_ledger
term_size() { printf '22 100'; }
draw_usage

header "dollars up the side, in round steps to the tallest day"
assert_contains "the top of the axis" '\$10 ┤' "$DRAWN"
assert_contains "a gridline every two dollars" '\$8 ┤' "$DRAWN"
assert_contains "the one below it" '\$6 ┤' "$DRAWN"
assert_contains "and the floor, which is where the days hang" '\$0 └' "$DRAWN"

header "every tick on the floor has its date under it"
# The rightmost date has to be pulled back inside the chart -- half of it would
# hang off the end -- and pulling back only that one used to leave its neighbour
# touching it, and the neighbour was dropped for it. The whole run moves instead.
assert_eq "as many dates as ticks" \
  "$(printf '%s\n' "$DRAWN" | grep -o '┴' | wc -l | tr -d ' ')" \
  "$(printf '%s\n' "$DRAWN" | grep -o '[0-9][0-9]/[0-9][0-9]' | wc -l | tr -d ' ')"

header "days along the bottom, written the way a date is read"
assert_contains "today at the right-hand end" "09/05" "$DRAWN"
assert_contains "the tallest day" "04/05" "$DRAWN"
assert_eq "and today is the last of them" "09/05" \
  "$(printf '%s\n' "$DRAWN" | grep -o '[0-9][0-9]/05' | tail -1)"

header "a column is its day measured against that axis"
assert_eq "a column per day, gaps included" "6" "${#COL_FULL[@]}"
assert_eq "the tallest fills the height" "10" "${COL_FULL[0]}"
assert_eq "and needs no eighths on top" "0" "${COL_PART[0]}"
assert_eq "half the money is half the height" "5" "${COL_FULL[1]}"
assert_eq "a day with no file is no column" "0" "${COL_FULL[4]}"
assert_eq "and no eighths either" "0" "${COL_PART[4]}"
assert_eq "today, still being written" "2" "${COL_FULL[5]}"
assert_eq "with the rest of it in eighths" "4" "${COL_PART[5]}"

header "a day too small for a row still gets an eighth of one"
assert_eq "no whole row" "0" "${COL_FULL[3]}"
assert_eq "but not nothing" "1" "${COL_PART[3]}"

header "a day says how it was paid for"
assert_eq "a subscription day is one colour" "0" "${COL_API[0]}"
assert_eq "a billed day is the other" "5" "${COL_API[2]}"
assert_eq "and the eighths on top follow the top of the column" "1" "${COL_CAPY[2]}"
assert_contains "the subscription colour is on the screen" $'\033\[36m' "$DRAWN_RAW"
assert_contains "and the billed one with it" $'\033\[33m' "$DRAWN_RAW"
assert_contains "with a line saying which is which" 'sub ~\$17.51 *. api \$5.00' \
  "$(printf '%s\n' "$DRAWN_RAW" | plain)"

header "the header carries what the chart cannot"
assert_contains "the days it covers" ' USAGE  6 days' "$DRAWN"
assert_contains "the total" 'total \$22.51' "$DRAWN"
assert_contains "the average day" 'avg \$3.75/day' "$DRAWN"
assert_contains "and the worst one, by name" 'peak \$10.00 Mon 04 May' "$DRAWN"
assert_not_contains "with no range, since every day is on screen" "showing" "$DRAWN"

# Four months of it now -- more days than even a wide terminal has columns for.
rm -f "$SPEND"/*

walk_back() { # <day> <days> -> WB
  local d=$1 i=0
  while [ "$i" -lt "$2" ]; do monitor_day_prev "$d"; d=$DAY_PREV; i=$((i + 1)); done
  WB=$d
}

MON_DAY=2026-05-09
D=$MON_DAY
i=0
while [ "$i" -lt 120 ]; do
  seed "$D" s 200 1
  OLDEST=$D
  monitor_day_prev "$D"; D=$DAY_PREV
  i=$((i + 1))
done
seed "$OLDEST" tall 1000 1     # the tallest day is the oldest, so the axis holds still
LDG_DAY=""; HIST_KEY=""
monitor_read_ledger
term_size() { printf '30 120'; }

header "more days than columns: the newest of them, and the range said out loud"
HIST_OFF=0
draw_usage
assert_contains "four months behind it" ' USAGE  120 days' "$DRAWN"
assert_contains "today is the last column" "09/05" "$DRAWN"
walk_back "$MON_DAY" $((${#COL_FULL[@]} - 1))
assert_contains "and the range is the columns it drew" \
  "showing ${WB:8:2}/${WB:5:2}-09/05" "$DRAWN"
assert_not_contains "the days before that are off the left" \
  "${OLDEST:8:2}/${OLDEST:5:2}" "$DRAWN"

header "scrolling moves the window and stops at the oldest day"
HIST_OFF=10
draw_usage
walk_back "$MON_DAY" 10; NEWEST=$WB
walk_back "$MON_DAY" $((10 + ${#COL_FULL[@]} - 1))
assert_contains "wound back a week and a half" \
  "showing ${WB:8:2}/${WB:5:2}-${NEWEST:8:2}/${NEWEST:5:2}" "$DRAWN"
assert_not_contains "today is off the right" "09/05" "$DRAWN"
HIST_OFF=999
draw_usage
assert_contains "wound back past the start it stops on the oldest day" \
  "showing ${OLDEST:8:2}/${OLDEST:5:2}-" "$DRAWN"
assert_eq "and the clamp says how far that was" \
  "$((120 - ${#COL_FULL[@]}))" "$HIST_OFF"

header "an empty history says so instead of drawing an empty chart"
EMPTY="$(mktemp -d "${TMPDIR:-/tmp}/usage-history-blank.XXXXXX")"
mkdir -p "$EMPTY/spend"
DRAWN="$(
  export CLAUDE_MONITOR_DIR="$EMPTY"
  # shellcheck disable=SC1090
  source "$MONITOR"
  term_size() { printf '12 80'; }
  monitor_clock
  monitor_read_ledger
  VIEW=usage monitor_draw_usage
)"
DRAWN="$(printf '%s\n' "$DRAWN" | plain)"
rm -rf "$EMPTY"
assert_contains "the header admits it" " USAGE  no history yet" "$DRAWN"
assert_contains "and the screen says where it comes from" "nothing recorded yet" "$DRAWN"

# ── the keys ─────────────────────────────────────────────────────────

header "'u' belongs to the chart, not to a session"
assert_not_contains "it is not a jump key" "u" "$KEYS"
assert_eq "which leaves 28 of them" "28" "${#KEYS}"

# ── the small chart under the fleet ──────────────────────────────────

draw_fleet() {
  VIEW=fleet
  monitor_draw_fleet > "$LEDGER_ROOT/fleet"
  DRAWN="$(plain < "$LEDGER_ROOT/fleet")"
}

# A week of days again, and a fleet of one session to hang them under.
rm -f "$SPEND"/*
seed 2026-05-04 a 1000 1
seed 2026-05-05 b 500 1
seed 2026-05-09 e 250 1
MON_DAY=2026-05-09
LDG_DAY=""; HIST_KEY=""
monitor_read_ledger
SESSIONS=(alpha); ROW_STATE=(idle); ROW_DETAIL=(""); X_CTX=(10); X_COSTF=('$1.00')
X_COST_ALL=1.00; X_COST_SUB="" ; X_COST_API=1.00; X_COST_OVER=""
term_size() { printf '30 100'; }

header "the fleet screen carries the chart under its totals"
draw_fleet
assert_contains "the sessions it is there for" "alpha" "$DRAWN"
assert_contains "the totals under them" ' all *\$17.50' "$DRAWN"
assert_contains "the floor of a chart under those" '\$0 └' "$DRAWN"
assert_contains "with today's date written on it" "09/05" "$DRAWN"
assert_contains "and the key to the full-size one" "u usage" "$DRAWN"

header "the small chart names every tick too"
assert_eq "as many dates as ticks" \
  "$(printf '%s\n' "$DRAWN" | grep -o '┴' | wc -l | tr -d ' ')" \
  "$(printf '%s\n' "$DRAWN" | grep -o '[0-9][0-9]/[0-9][0-9]' | wc -l | tr -d ' ')"

header "and it is small"
assert_eq "four rows and a floor" "5" \
  "$(printf '%s\n' "$DRAWN" | grep -c '[┤│└]')"
assert_eq "and one line of dates under that" "1" \
  "$(printf '%s\n' "$DRAWN" | grep -c '^ *[0-9][0-9]/[0-9][0-9]')"

header "it is pinned to today, whatever the full-size chart is scrolled to"
HIST_OFF=4
draw_fleet
assert_contains "today is on it all the same" "09/05" "$DRAWN"
assert_eq "and the scroll position is left where it was" "4" "$HIST_OFF"
HIST_OFF=0

header "a screen with no room for it keeps the sessions instead"
term_size() { printf '16 100'; }
draw_fleet
assert_eq "no chart at all" "0" "$(printf '%s\n' "$DRAWN" | grep -c '[┤└]')"
assert_contains "the sessions are still there" "alpha" "$DRAWN"
assert_contains "and so are the totals" ' all *\$17.50' "$DRAWN"

header "and neither screen draws one before there is anything to draw"
EMPTY="$(mktemp -d "${TMPDIR:-/tmp}/usage-history-fleet.XXXXXX")"
mkdir -p "$EMPTY/spend"
DRAWN="$(
  export CLAUDE_MONITOR_DIR="$EMPTY"
  # shellcheck disable=SC1090
  source "$MONITOR"
  term_size() { printf '30 100'; }
  monitor_clock
  monitor_read_ledger
  SESSIONS=(alpha); ROW_STATE=(idle); ROW_DETAIL=(""); X_CTX=(10); X_COSTF=""
  VIEW=fleet monitor_draw_fleet
)"
DRAWN="$(printf '%s\n' "$DRAWN" | plain)"
rm -rf "$EMPTY"
assert_eq "an empty ledger draws no axis" "0" "$(printf '%s\n' "$DRAWN" | grep -c '[┤└]')"
assert_contains "just the fleet" "alpha" "$DRAWN"

print_results
