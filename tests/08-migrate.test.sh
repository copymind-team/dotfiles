#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

echo ""
printf "${BOLD}08 — Migration lifecycle${RESET}\n"

# ── No new migrations initially ──────────────────────────────────────

header "no new migrations"
cd "$TEST_DIR/feat-alpha"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-migrate.sh" apply 2>&1) || true

assert_contains "reports no new" "No new migrations in feat-alpha" "$OUTPUT"
assert_symlink_count "no symlinks in hub" "0" "$TEST_DIR/supabase/supabase/migrations"

# ── Add migration to feat-alpha ──────────────────────────────────────

header "new migration — symlink + apply"
cd "$TEST_DIR/feat-alpha"

cat > supabase/migrations/app/20260418000001_test_alpha.sql << 'SQL'
CREATE TABLE IF NOT EXISTS public.test_alpha (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz DEFAULT now()
);
SQL

OUTPUT=$("$SCRIPTS_DIR/dev-worktree-migrate.sh" apply 2>&1) || true

assert_contains "found new migrations" "Found new migrations in feat-alpha" "$OUTPUT"
assert_contains "symlinked 1" "Symlinked 1 migration" "$OUTPUT"
assert_contains "applying migration" "Applying migration 20260418000001" "$OUTPUT"
assert_symlink "symlink created" "$TEST_DIR/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"
assert "table created in DB" db_table_exists "test_alpha"

# ── Idempotent re-run ────────────────────────────────────────────────

header "idempotent re-run"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-migrate.sh" apply 2>&1) || true

assert_contains "no new on re-run" "No new migrations in feat-alpha" "$OUTPUT"
assert_not_contains "no symlinking" "Symlinked" "$OUTPUT"

# ── Second migration in same worktree ────────────────────────────────

header "second migration"
cd "$TEST_DIR/feat-alpha"

cat > supabase/migrations/app/20260418000002_test_alpha_2.sql << 'SQL'
CREATE TABLE IF NOT EXISTS public.test_alpha_2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid()
);
SQL

OUTPUT=$("$SCRIPTS_DIR/dev-worktree-migrate.sh" apply 2>&1) || true

assert_contains "symlinked only 1" "Symlinked 1 migration" "$OUTPUT"
assert_symlink "first symlink still exists" "$TEST_DIR/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"
assert_symlink "second symlink created" "$TEST_DIR/supabase/supabase/migrations/app/20260418000002_test_alpha_2.sql"
assert_symlink_count "2 symlinks total" "2" "$TEST_DIR/supabase/supabase/migrations"
assert "second table created" db_table_exists "test_alpha_2"

# ── Multi-worktree: feat-beta migration ──────────────────────────────

header "multi-worktree — feat-beta migration"
cd "$TEST_DIR/feat-beta"

cat > supabase/migrations/app/20260418000003_test_beta.sql << 'SQL'
CREATE TABLE IF NOT EXISTS public.test_beta (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid()
);
SQL

OUTPUT=$("$SCRIPTS_DIR/dev-worktree-migrate.sh" apply 2>&1) || true

assert_contains "symlinked beta" "Symlinked 1 migration" "$OUTPUT"
assert_symlink_count "3 symlinks total" "3" "$TEST_DIR/supabase/supabase/migrations"
assert "beta table created" db_table_exists "test_beta"

# Verify symlinks point to correct worktrees
ALPHA_COUNT=$(find "$TEST_DIR/supabase/supabase/migrations" -type l -exec readlink {} \; | grep -c "feat-alpha" || true)
BETA_COUNT=$(find "$TEST_DIR/supabase/supabase/migrations" -type l -exec readlink {} \; | grep -c "feat-beta" || true)
assert_eq "2 symlinks → feat-alpha" "2" "$ALPHA_COUNT"
assert_eq "1 symlink → feat-beta" "1" "$BETA_COUNT"

# ── Timestamp conflict ───────────────────────────────────────────────

header "timestamp conflict detection"
cd "$TEST_DIR/feat-beta"

cat > supabase/migrations/app/20250101000001_test_outdated.sql << 'SQL'
CREATE TABLE IF NOT EXISTS public.test_outdated (id uuid PRIMARY KEY);
SQL

OUTPUT=$("$SCRIPTS_DIR/dev-worktree-migrate.sh" apply 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}

assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "reports outdated timestamps" "outdated timestamps" "$OUTPUT"
assert_contains "shows fix instruction" "Fix: rebase feat-beta" "$OUTPUT"
assert_file_not_exists "outdated NOT symlinked" "$TEST_DIR/supabase/supabase/migrations/app/20250101000001_test_outdated.sql"
assert_symlink_count "still 3 symlinks" "3" "$TEST_DIR/supabase/supabase/migrations"

rm "$TEST_DIR/feat-beta/supabase/migrations/app/20250101000001_test_outdated.sql"

# ── Merge to main — symlink replaced by real file ────────────────────

header "merge to main — symlink replaced"
cd "$TEST_DIR/main"

mkdir -p supabase/migrations/app
cp "$TEST_DIR/feat-alpha/supabase/migrations/app/20260418000001_test_alpha.sql" \
   supabase/migrations/app/20260418000001_test_alpha.sql
git add supabase/migrations/app/20260418000001_test_alpha.sql
git commit -q -m "merge test-alpha migration"
git push -q origin main

assert_symlink "symlink exists before refresh" "$TEST_DIR/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"

cd "$TEST_DIR/feat-alpha"
OUTPUT=$("$SCRIPTS_DIR/dev-worktree-migrate.sh" apply 2>&1) || true

assert "merged migration is a real file" test -f "$TEST_DIR/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"
assert "merged migration is NOT a symlink" test ! -L "$TEST_DIR/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"
assert_symlink "unmerged migration still symlinked" "$TEST_DIR/supabase/supabase/migrations/app/20260418000002_test_alpha_2.sql"
assert_contains "no new after merge" "No new migrations in feat-alpha" "$OUTPUT"
assert_symlink_count "2 symlinks remain" "2" "$TEST_DIR/supabase/supabase/migrations"
assert "merged version still in DB" db_version_exists "20260418000001"
assert "unmerged version still in DB" db_version_exists "20260418000002"

print_results
