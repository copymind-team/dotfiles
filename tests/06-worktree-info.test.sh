#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

echo ""
printf "${BOLD}06 — dev wt info${RESET}\n"

# ── Run info from feat-alpha ─────────────────────────────────────────

header "worktree info display"
cd "$TEST_DIR/feat-alpha"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-info.sh" 2>&1) || true

assert_contains "shows Worktree Info header" "Worktree Info" "$OUTPUT"
assert_contains "shows correct path" "$TEST_DIR/feat-alpha" "$OUTPUT"
assert_contains "shows branch name" "feat-alpha" "$OUTPUT"
assert_contains "shows port 13001" "13001" "$OUTPUT"

# ── All Worktrees section ────────────────────────────────────────────

header "all worktrees listing"
assert_contains "shows All Worktrees" "All Worktrees" "$OUTPUT"
assert_contains "lists main" "main" "$OUTPUT"
assert_contains "lists feat-alpha" "feat-alpha" "$OUTPUT"
assert_contains "marks current worktree" "current" "$OUTPUT"

print_results
