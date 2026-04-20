#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}#2 — dev sb up${RESET}\n"

header "start supabase"
cd "$WORKTREE_BASE/main"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-up.sh" 2>&1) || true

assert_contains "supabase ready" "Supabase ready" "$OUTPUT"
assert_file_exists "supabase worktree created" "$WORKTREE_BASE/supabase"
assert_file_exists "has config.toml" "$WORKTREE_BASE/supabase/supabase/config.toml"

# Verify detached at origin/main
SUPABASE_HEAD=$(cd "$WORKTREE_BASE/supabase" && git rev-parse HEAD)
ORIGIN_MAIN=$(cd "$TEST_DIR/repo.git" && git rev-parse origin/main)
assert_eq "detached at origin/main" "$ORIGIN_MAIN" "$SUPABASE_HEAD"

header "idempotent re-run"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-up.sh" 2>&1) || true

assert_contains "updates worktree" "Updating supabase worktree" "$OUTPUT"
assert_contains "already running" "already running" "$OUTPUT"

print_results
