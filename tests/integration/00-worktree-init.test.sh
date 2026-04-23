#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}#0 — dev wt init (bootstrap)${RESET}\n"

header "dev wt init from fresh bare clone"
cd "$TEST_DIR/repo.git"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-init.sh" 2>&1) || true

assert_file_exists "main worktree created" "$WORKTREE_BASE/main"
assert_file_exists "worktree has docker-compose.yml" "$WORKTREE_BASE/main/docker-compose.yml"
assert_file_exists "worktree has supabase config" "$WORKTREE_BASE/main/supabase/config.toml"
assert_file_exists "port registry created" "$WORKTREE_BASE/.worktree-ports"

REGISTRY_CONTENT=$(cat "$WORKTREE_BASE/.worktree-ports")
assert_contains "registry has main entry" "main" "$REGISTRY_CONTENT"
assert_contains "registry has base port" "13000" "$REGISTRY_CONTENT"

# Override file is generated from the registry, same as sibling worktrees.
assert_file_exists "main override.yml exists" "$WORKTREE_BASE/main/docker-compose.override.yml"
OVERRIDE_CONTENT=$(cat "$WORKTREE_BASE/main/docker-compose.override.yml")
assert_contains "main override maps base port" "13000:3000" "$OVERRIDE_CONTENT"

assert_contains "prints next steps" "dev wt up" "$OUTPUT"

header "rejects re-init when worktree already exists"
cd "$TEST_DIR/repo.git"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-init.sh" 2>&1) || EXIT_CODE=$?
assert_exit_code "exits with 1" "1" "${EXIT_CODE:-0}"
assert_contains "mentions already exists" "already" "$OUTPUT"

# Stop any leftover Supabase containers from previous test runs
(cd "$WORKTREE_BASE/main" && supabase stop --no-backup 2>/dev/null) || true

print_results
