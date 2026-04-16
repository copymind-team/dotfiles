#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

echo ""
printf "${BOLD}09 — dev wt down (teardown)${RESET}\n"

# ── Teardown feat-beta ───────────────────────────────────────────────

header "dev wt down feat-beta"
cd "$TEST_DIR/main"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-down.sh" feat-beta 2>&1) || true

assert_contains "removed 1 symlink" "Removed 1 symlink" "$OUTPUT"
assert_contains "repairing migration history" "Repairing migration history" "$OUTPUT"
assert_contains "DB row deleted" "DELETE 1" "$OUTPUT"

assert_file_not_exists "feat-beta directory gone" "$TEST_DIR/feat-beta"
assert_file_not_exists "beta symlink gone" "$TEST_DIR/supabase/supabase/migrations/app/20260418000003_test_beta.sql"

# feat-alpha's symlink should still exist
assert_symlink "alpha symlink intact" "$TEST_DIR/supabase/supabase/migrations/app/20260418000002_test_alpha_2.sql"
assert_symlink_count "1 symlink remains" "1" "$TEST_DIR/supabase/supabase/migrations"

# Branch deleted
BRANCH_EXISTS=$(git -C "$TEST_DIR/repo.git" branch --list feat-beta)
assert_eq "branch feat-beta deleted" "" "$BRANCH_EXISTS"

# Registry cleaned
REGISTRY="$TEST_DIR/.worktree-ports"
assert_not_contains "feat-beta removed from registry" "feat-beta" "$(cat "$REGISTRY")"
assert_contains "main still in registry" "main" "$(cat "$REGISTRY")"
assert_contains "feat-alpha still in registry" "feat-alpha" "$(cat "$REGISTRY")"

# DB state
assert "beta version removed from DB" db_version_not_exists "20260418000003"
assert "alpha versions still in DB" db_version_exists "20260418000002"

assert_not_contains "no migration errors" "Remote migration versions not found" "$OUTPUT"

# ── Teardown feat-alpha ──────────────────────────────────────────────

header "dev wt down feat-alpha"
cd "$TEST_DIR/main"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-down.sh" feat-alpha 2>&1) || true

assert_contains "removed 1 symlink" "Removed 1 symlink" "$OUTPUT"
assert_contains "DB row deleted" "DELETE 1" "$OUTPUT"

assert_file_not_exists "feat-alpha directory gone" "$TEST_DIR/feat-alpha"

# Merged migration (real file from origin/main) should still exist
assert "merged migration still real file" test -f "$TEST_DIR/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"
assert "merged migration not a symlink" test ! -L "$TEST_DIR/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"

assert_file_not_exists "alpha symlink 2 gone" "$TEST_DIR/supabase/supabase/migrations/app/20260418000002_test_alpha_2.sql"
assert_symlink_count "no symlinks remain" "0" "$TEST_DIR/supabase/supabase/migrations"

# Merged version stays in DB, unmerged version removed
assert "merged version 1 still in DB" db_version_exists "20260418000001"
assert "version 2 removed from DB" db_version_not_exists "20260418000002"

# Branch deleted
BRANCH_EXISTS=$(git -C "$TEST_DIR/repo.git" branch --list feat-alpha)
assert_eq "branch feat-alpha deleted" "" "$BRANCH_EXISTS"

assert_not_contains "no migration errors" "Remote migration versions not found" "$OUTPUT"

print_results
