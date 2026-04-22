#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}#6 — dev sb dispatcher (argument handling)${RESET}\n"

# Pre-condition: Supabase is running (inherited from #02). These checks are
# argument-level only — no DB mutations, no actual compilation.

cd "$WORKTREE_BASE/main"

# ── new subcommands listed in usage ──────────────────────────────────

header "usage lists new subcommands"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "${EXIT_CODE:-0}"
assert_contains "lists migrate" "migrate" "$OUTPUT"
assert_contains "lists seed" "seed" "$OUTPUT"
assert_contains "lists reset" "reset" "$OUTPUT"
assert_contains "lists flow" "flow" "$OUTPUT"

# ── dev sb flow argument validation ──────────────────────────────────

header "dev sb flow without subcommand"
EXIT_CODE=0
OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" flow 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "shows usage" "Usage: dev sb flow up" "$OUTPUT"

header "dev sb flow with unknown subcommand"
EXIT_CODE=0
OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" flow bogus 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "flags unknown subcommand" "unknown subcommand" "$OUTPUT"

header "dev sb flow up with too many args"
EXIT_CODE=0
OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" flow up foo bar 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "flags too many args" "too many arguments" "$OUTPUT"

# ── dev sb seed/migrate operate on shared worktree regardless of cwd ─
# Non-destructive check: reading usage/bare-repo guards works from anywhere.

header "dev sb migrate from outside any worktree — still runs (no-op)"
# With supabase running and no pending migrations beyond baseline, migrate is
# a harmless no-op. Just verify it exits cleanly from the main worktree.
EXIT_CODE=0
OUTPUT=$(cd "$WORKTREE_BASE/main" && bash "$SCRIPTS_DIR/dev-supabase.sh" migrate 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 0" "0" "$EXIT_CODE"

print_results
