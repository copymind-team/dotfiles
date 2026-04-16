#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit tests: dev-worktree-supabase.sh${RESET}\n"

# ── Non-bare repo → error ────────────────────────────────────────────

header "non-bare repo check"
setup_tmpdir

cd "$TEST_TMPDIR"
git init -q test-repo
cd test-repo
git config user.email "test@test.com"
git config user.name "Test"
touch file && git add file && git commit -q -m "init"

OUTPUT=$(bash "$SCRIPTS_DIR/dev-worktree-supabase.sh" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}

assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "bare repo error" "bare" "$OUTPUT"
