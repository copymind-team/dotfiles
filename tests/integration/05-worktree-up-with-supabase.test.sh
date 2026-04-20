#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}#5 — dev wt up (Supabase running — auto-inject)${RESET}\n"

header "dev wt up feat-beta"
cd "$WORKTREE_BASE/main"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-up.sh" feat-beta 2>&1) || true

assert_file_exists "worktree created" "$WORKTREE_BASE/feat-beta"
assert "branch exists" git -C "$TEST_DIR/repo.git" show-ref --verify --quiet "refs/heads/feat-beta"

# Port increment
REGISTRY="$WORKTREE_BASE/.worktree-ports"
BETA_PORT=$(grep "^feat-beta	" "$REGISTRY" | awk -F'\t' '{print $2}')
assert "feat-beta port allocated" test -n "$BETA_PORT"

ENTRY_COUNT=$(grep -cv '^#' "$REGISTRY")
assert_eq "registry has 3 entries" "3" "$ENTRY_COUNT"

# Auto-injected (Supabase is running)
assert_contains "injected env vars" "Injecting Supabase env vars" "$OUTPUT"
assert_not_contains "no sb up hint" "dev sb up" "$OUTPUT"
assert_not_contains "no wt env hint" "dev wt env" "$OUTPUT"

ENV_LOCAL=$(cat "$WORKTREE_BASE/feat-beta/.env.local")
assert_contains "SUPABASE_URL injected" "NEXT_PUBLIC_SUPABASE_URL=" "$ENV_LOCAL"

header "worktree info"
cd "$WORKTREE_BASE/feat-beta"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-info.sh" 2>&1) || true

assert_contains "shows Worktree Info" "Worktree Info" "$OUTPUT"
assert_contains "shows branch" "feat-beta" "$OUTPUT"
assert_contains "shows port" "$BETA_PORT" "$OUTPUT"
assert_contains "lists all worktrees" "All Worktrees" "$OUTPUT"

print_results
