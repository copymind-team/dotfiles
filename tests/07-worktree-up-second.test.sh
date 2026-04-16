#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

echo ""
printf "${BOLD}07 — dev wt up (second worktree)${RESET}\n"

# ── Create feat-beta ──────────────────────────────────────────────────

header "dev wt up feat-beta"
cd "$TEST_DIR/main"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-up.sh" feat-beta 2>&1) || true

assert_file_exists "worktree directory created" "$TEST_DIR/feat-beta"
assert "branch exists" git -C "$TEST_DIR/repo.git" show-ref --verify --quiet "refs/heads/feat-beta"

# ── Port increment ───────────────────────────────────────────────────

header "port allocation"
REGISTRY="$TEST_DIR/.worktree-ports"

BETA_PORT=$(grep "^feat-beta	" "$REGISTRY" | awk -F'\t' '{print $2}')
assert_eq "feat-beta port is 13002" "13002" "$BETA_PORT"

# Count entries (excluding header)
ENTRY_COUNT=$(grep -cv '^#' "$REGISTRY")
assert_eq "registry has 3 entries" "3" "$ENTRY_COUNT"

# ── Both worktrees exist ─────────────────────────────────────────────

header "both worktrees coexist"
assert_file_exists "feat-alpha still exists" "$TEST_DIR/feat-alpha"
assert_file_exists "feat-beta exists" "$TEST_DIR/feat-beta"

WT_LIST=$(cd "$TEST_DIR/repo.git" && git worktree list)
assert_contains "alpha in worktree list" "feat-alpha" "$WT_LIST"
assert_contains "beta in worktree list" "feat-beta" "$WT_LIST"

print_results
