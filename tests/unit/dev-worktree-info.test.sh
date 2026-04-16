#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit tests: dev-worktree-info.sh${RESET}\n"

# ── Non-bare repo → error ────────────────────────────────────────────

header "non-bare repo check"
setup_tmpdir

cd "$TEST_TMPDIR"
git init -q test-repo
cd test-repo
git config user.email "test@test.com"
git config user.name "Test"
touch file && git add file && git commit -q -m "init"

OUTPUT=$(bash "$SCRIPTS_DIR/dev-worktree-info.sh" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}

assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "bare repo error" "bare" "$OUTPUT"

# ── Registry parsing ─────────────────────────────────────────────────

header "registry parsing"
setup_tmpdir

REGISTRY="$TEST_TMPDIR/.worktree-ports"
printf "# worktree\tport\tcreated\n" > "$REGISTRY"
printf "main\t13000\t2026-01-01\n" >> "$REGISTRY"
printf "feat-chat\t13001\t2026-04-15\n" >> "$REGISTRY"

# Simulate parsing like the info script does
WORKTREE_NAME="feat-chat"
ENTRY=$(grep "^${WORKTREE_NAME}	" "$REGISTRY" 2>/dev/null || true)
PORT=$(echo "$ENTRY" | awk -F'\t' '{print $2}')
CREATED=$(echo "$ENTRY" | awk -F'\t' '{print $3}')

assert_eq "port parsed correctly" "13001" "$PORT"
assert_eq "date parsed correctly" "2026-04-15" "$CREATED"

# Non-existent entry
WORKTREE_NAME="nonexistent"
ENTRY=$(grep "^${WORKTREE_NAME}	" "$REGISTRY" 2>/dev/null || true)
assert_eq "missing entry is empty" "" "$ENTRY"
