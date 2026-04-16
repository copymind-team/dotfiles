#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit tests: dev-supabase.sh${RESET}\n"

# ── No arguments → usage ─────────────────────────────────────────────

header "no arguments prints usage"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}

assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "shows usage" "Usage: dev supabase" "$OUTPUT"
assert_contains "lists up command" "up" "$OUTPUT"
assert_contains "lists down command" "down" "$OUTPUT"
assert_contains "lists status command" "status" "$OUTPUT"
assert_contains "lists migrate command" "migrate" "$OUTPUT"

# ── Unknown subcommand → usage ───────────────────────────────────────

header "unknown subcommand prints usage"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" nonsense 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}

assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "shows usage" "Usage: dev supabase" "$OUTPUT"
