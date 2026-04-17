#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

echo ""
printf "${BOLD}10 — Post-cleanup sanity${RESET}\n"

# ── Hub is clean ─────────────────────────────────────────────────────

header "dev sb migrate from main — post-cleanup"
cd "$TEST_DIR/main"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-link.sh" 2>&1) || true

assert_contains "no new migrations" "No new migrations in main" "$OUTPUT"
assert_contains "DB up to date" "up to date" "$OUTPUT"

# ── No stale symlinks ────────────────────────────────────────────────

header "hub state verification"
assert_symlink_count "zero symlinks in hub" "0" "$TEST_DIR/supabase/supabase/migrations"

# Real files from origin/main should exist
assert_file_exists "init migration exists" "$TEST_DIR/supabase/supabase/migrations/app/20260101000000_init.sql"
assert_file_exists "merged migration exists" "$TEST_DIR/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"
assert_not_symlink "init is real file" "$TEST_DIR/supabase/supabase/migrations/app/20260101000000_init.sql"
assert_not_symlink "merged is real file" "$TEST_DIR/supabase/supabase/migrations/app/20260418000001_test_alpha.sql"

# DB should have init + merged migration
assert "init version in DB" db_version_exists "20260101000000"
assert "merged version in DB" db_version_exists "20260418000001"

print_results
