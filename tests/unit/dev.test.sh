#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit tests: dev.sh${RESET}\n"

# ── No arguments → usage ─────────────────────────────────────────────

header "no arguments prints usage"
OUTPUT=$(bash "$SCRIPTS_DIR/dev.sh" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}

assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "shows usage" "Usage: dev" "$OUTPUT"
assert_contains "lists session command" "session" "$OUTPUT"
assert_contains "lists supabase command" "supabase" "$OUTPUT"
assert_contains "lists worktree command" "worktree" "$OUTPUT"

# ── Unknown command → usage ──────────────────────────────────────────

header "unknown command prints usage"
OUTPUT=$(bash "$SCRIPTS_DIR/dev.sh" nonsense 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}

assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "shows usage" "Usage: dev" "$OUTPUT"
