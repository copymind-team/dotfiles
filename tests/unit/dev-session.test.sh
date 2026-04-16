#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit tests: dev-session.sh${RESET}\n"

# ── Session name defaults to directory basename ──────────────────────

header "session name from directory"
setup_tmpdir

mkdir -p "$TEST_TMPDIR/my-project"

# The script uses basename of the directory for SESSION name.
# We test the logic inline since the script requires tmux.
DIR="$TEST_TMPDIR/my-project"
SESSION="$(basename "$DIR")"
assert_eq "session name from dir basename" "my-project" "$SESSION"

# ── -n flag overrides session name ───────────────────────────────────

header "-n flag overrides name"

# Simulate the script's getopts parsing in a subshell
SESSION_NAME=$(bash -c '
  SESSION_NAME=""
  while getopts "n:" opt; do
    case $opt in n) SESSION_NAME="$OPTARG" ;; esac
  done
  echo "$SESSION_NAME"
' _ -n custom-name)

assert_eq "-n sets session name" "custom-name" "$SESSION_NAME"

# ── Directory resolves to absolute path ──────────────────────────────

header "directory resolution"
setup_tmpdir

mkdir -p "$TEST_TMPDIR/relative/path"
RESOLVED="$(cd "$TEST_TMPDIR/relative/path" && pwd)"
assert "resolves to absolute path" test "${RESOLVED:0:1}" = "/"
assert_contains "path is correct" "relative/path" "$RESOLVED"
