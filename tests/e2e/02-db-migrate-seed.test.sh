#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}E2E: dev sb migrate + seed${RESET}\n"

# Entry state (left by 01-migration-lifecycle):
#   - main worktree exists, no feature worktrees
#   - Supabase running, versions 20260101000000 + 20260418000001 applied
#   - shared supabase worktree has both migration files as real files

SHARED_WT="$WORKTREE_BASE/supabase"

# ── migrate — no-op when up to date ──────────────────────────────────

header "dev sb migrate — no-op when up to date"
cd "$WORKTREE_BASE/main"
EXIT_CODE=0
OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" migrate 2>&1) || EXIT_CODE=$?
assert_exit_code "exits 0" "0" "$EXIT_CODE"
assert "baseline still in DB" db_version_exists "20260101000000"

# ── migrate — applies a new migration dropped into the shared worktree ──

header "dev sb migrate — applies a file written to shared worktree"
cat > "$SHARED_WT/supabase/migrations/app/20260420000000_migrate_test.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS public._migrate_test (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
SQL

# Run from a feature worktree to exercise shared-worktree resolution from non-shared cwd.
# `repo.git` at $TEST_DIR/repo.git IS the bare repo; use any existing worktree
# to run `git worktree add`.
(cd "$WORKTREE_BASE/main" && git worktree add "$WORKTREE_BASE/feat-gamma" --detach origin/main)
cd "$WORKTREE_BASE/feat-gamma"
EXIT_CODE=0
OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" migrate 2>&1) || EXIT_CODE=$?
assert_exit_code "exits 0" "0" "$EXIT_CODE"
assert "new version recorded" db_version_exists "20260420000000"
assert "table exists" db_table_exists "_migrate_test"

# ── seed — registry created + first apply ────────────────────────────

header "dev sb seed — first run creates registry and applies"
# Ensure supabase/seeds/ exists — git doesn't track empty dirs, so the shared
# wt won't have one even though the fixture's init repo did.
mkdir -p "$SHARED_WT/supabase/seeds"
cat > "$SHARED_WT/supabase/seeds/001_sample.sql" <<'SQL'
INSERT INTO public._test_init DEFAULT VALUES;
SQL

EXIT_CODE=0
OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" seed 2>&1) || EXIT_CODE=$?
assert_exit_code "exits 0" "0" "$EXIT_CODE"
assert_contains "reports 1 applied" "1 applied" "$OUTPUT"
assert "registry contains 001_sample" db_seed_exists "001_sample.sql"
assert_eq "1 row in _test_init" "1" "$(db_count _test_init)"

# ── seed — idempotent re-run ─────────────────────────────────────────

header "dev sb seed — idempotent"
EXIT_CODE=0
OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" seed 2>&1) || EXIT_CODE=$?
assert_exit_code "exits 0" "0" "$EXIT_CODE"
assert_contains "reports 0 applied" "0 applied" "$OUTPUT"
assert_eq "still 1 row in _test_init" "1" "$(db_count _test_init)"

# ── seed — users.sql is skipped (poison detection) ───────────────────

header "dev sb seed — users.sql is skipped (poison)"
cat > "$SHARED_WT/supabase/seeds/users.sql" <<'SQL'
SELECT 1/0;
SQL
EXIT_CODE=0
OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" seed 2>&1) || EXIT_CODE=$?
assert_exit_code "exits 0 (poison not run)" "0" "$EXIT_CODE"
OUTPUT_NOT_IN_REGISTRY=$(db_query "SELECT count(*) FROM supabase_seeds.applied_seeds WHERE name = 'users.sql';")
assert_eq "users.sql not in registry" "0" "$OUTPUT_NOT_IN_REGISTRY"
rm "$SHARED_WT/supabase/seeds/users.sql"

# ── seed — modified existing seed is NOT re-applied ──────────────────

header "dev sb seed — modified seed NOT re-applied"
cat > "$SHARED_WT/supabase/seeds/001_sample.sql" <<'SQL'
INSERT INTO public._test_init DEFAULT VALUES;
INSERT INTO public._test_init DEFAULT VALUES;
SQL
EXIT_CODE=0
OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" seed 2>&1) || EXIT_CODE=$?
assert_exit_code "exits 0" "0" "$EXIT_CODE"
assert_contains "reports 0 applied" "0 applied" "$OUTPUT"
assert_eq "still 1 row (edit ignored)" "1" "$(db_count _test_init)"

# ── seed — renamed seed IS treated as new ────────────────────────────

header "dev sb seed — renamed seed IS applied"
mv "$SHARED_WT/supabase/seeds/001_sample.sql" "$SHARED_WT/supabase/seeds/002_sample.sql"
EXIT_CODE=0
OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" seed 2>&1) || EXIT_CODE=$?
assert_exit_code "exits 0" "0" "$EXIT_CODE"
assert_contains "reports 1 applied" "1 applied" "$OUTPUT"
assert "registry contains 002_sample" db_seed_exists "002_sample.sql"
assert "registry STILL contains 001_sample" db_seed_exists "001_sample.sql"
assert_eq "rows increased by 2 (the renamed seed inserts 2)" "3" "$(db_count _test_init)"

# ── migrate — bails cleanly when Supabase is down ────────────────────

header "dev sb migrate — bails when Supabase down"
cd "$WORKTREE_BASE/main"
# Plain `supabase stop` (without --no-backup) dumps DB state so the restart
# below restores it — preserves the seed state for subsequent e2e tests.
(cd "$SHARED_WT" && supabase stop >/dev/null 2>&1) || true
EXIT_CODE=0
OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" migrate 2>&1) || EXIT_CODE=$?
assert_exit_code "exits != 0" "1" "$EXIT_CODE"
assert_contains "mentions dev sb up" "dev sb up" "$OUTPUT"

# Restart Supabase so subsequent e2e tests have a running stack.
(cd "$SHARED_WT" && supabase start >/dev/null 2>&1)

print_results
