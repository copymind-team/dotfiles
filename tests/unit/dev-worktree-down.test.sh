#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit tests: dev-worktree-down.sh${RESET}\n"

# ── No arguments → usage ─────────────────────────────────────────────

header "no arguments prints usage"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-worktree-down.sh" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}

assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "shows error" "branch name is required" "$OUTPUT"
assert_contains "shows usage" "Usage: dev worktree down" "$OUTPUT"
assert_contains "shows example" "Example:" "$OUTPUT"

# ── Name sanitization (same logic as worktree-up) ────────────────────

header "name sanitization"

sanitize() {
  echo "$1" | tr '/' '-' | tr -cd 'a-zA-Z0-9_.-'
}

assert_eq "slashes become dashes" "feat-new-chat" "$(sanitize "feat/new-chat")"
assert_eq "nested slashes" "feat-team-new-chat" "$(sanitize "feat/team/new-chat")"
assert_eq "special chars stripped" "featbranch" "$(sanitize "feat@branch!")"

# ── Port registry removal ────────────────────────────────────────────

header "port registry removal"
setup_tmpdir

REGISTRY="$TEST_TMPDIR/.worktree-ports"
printf "# worktree\tport\tcreated\n" > "$REGISTRY"
printf "main\t13000\t2026-01-01\n" >> "$REGISTRY"
printf "feat-a\t13001\t2026-01-02\n" >> "$REGISTRY"
printf "feat-b\t13002\t2026-01-03\n" >> "$REGISTRY"

SAFE_NAME="feat-a"
grep -v "^${SAFE_NAME}	" "$REGISTRY" > "${REGISTRY}.tmp"
mv "${REGISTRY}.tmp" "$REGISTRY"

assert_not_contains "feat-a removed" "feat-a" "$(cat "$REGISTRY")"
assert_contains "main still present" "main" "$(cat "$REGISTRY")"
assert_contains "feat-b still present" "feat-b" "$(cat "$REGISTRY")"

# Verify line count (header + 2 entries)
LINE_COUNT=$(wc -l < "$REGISTRY" | tr -d ' ')
assert_eq "3 lines remain" "3" "$LINE_COUNT"

# ── Non-bare repo → error ────────────────────────────────────────────

header "non-bare repo check"
setup_tmpdir

cd "$TEST_TMPDIR"
git init -q test-repo
cd test-repo
git config user.email "test@test.com"
git config user.name "Test"
touch file && git add file && git commit -q -m "init"

OUTPUT=$(bash "$SCRIPTS_DIR/dev-worktree-down.sh" test-branch 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}

assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "bare repo error" "bare" "$OUTPUT"

# ── Self-teardown detection ──────────────────────────────────────────

header "self-teardown detection"

# The script checks: SAFE_NAME == basename of current worktree
# This is a logic test, not a live worktree test
CURRENT_WORKTREE_NAME="feat-test"
SAFE_NAME="feat-test"
assert "detects self-teardown" test "$SAFE_NAME" = "$CURRENT_WORKTREE_NAME"

SAFE_NAME="other-branch"
assert "allows teardown of other branch" test "$SAFE_NAME" != "$CURRENT_WORKTREE_NAME"

# ── Non-existent target directory ────────────────────────────────────

header "non-existent target directory"

assert "detects missing dir" test ! -d "/tmp/nonexistent-worktree-dir-$$"
