#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit tests: dev-worktree-migrate.sh${RESET}\n"

# ── No arguments → usage ─────────────────────────────────────────────

header "no arguments prints usage"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-worktree-migrate.sh" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}

assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "shows usage" "Usage:" "$OUTPUT"
assert_contains "lists link subcommand" "link" "$OUTPUT"
assert_contains "lists unlink subcommand" "unlink" "$OUTPUT"
assert_contains "lists apply subcommand" "apply" "$OUTPUT"

# ── link without path → usage ────────────────────────────────────────

header "link without path prints usage"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-worktree-migrate.sh" link 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}

assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "shows usage" "Usage:" "$OUTPUT"

# ── unlink without path → usage ──────────────────────────────────────

header "unlink without path prints usage"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-worktree-migrate.sh" unlink 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}

assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "shows usage" "Usage:" "$OUTPUT"

# ── Source functions for unit testing ─────────────────────────────────
# Extract function definitions from the script using markers.

_extract_fn() {
  local fn_name="$1" script="$2"
  # Extract from 'fn_name() {' to the closing '}' at column 0
  awk "/^${fn_name}\\(\\)/{found=1} found{print} found && /^\\}/{exit}" "$script"
}

eval "$(_extract_fn find_new_migrations "$SCRIPTS_DIR/dev-worktree-migrate.sh")"
eval "$(_extract_fn get_latest_origin_timestamp "$SCRIPTS_DIR/dev-worktree-migrate.sh")"
eval "$(_extract_fn symlink_migrations "$SCRIPTS_DIR/dev-worktree-migrate.sh")"
eval "$(_extract_fn remove_wt_symlinks "$SCRIPTS_DIR/dev-worktree-migrate.sh")"
eval "$(_extract_fn clean_stale_symlinks "$SCRIPTS_DIR/dev-worktree-migrate.sh")"

# ── find_new_migrations ──────────────────────────────────────────────

header "find_new_migrations — detects new file"
setup_tmpdir

# Set up worktree with a migration
WT="$TEST_TMPDIR/feat-a"
SB="$TEST_TMPDIR/supabase"
mkdir -p "$WT/supabase/migrations/app" "$SB/supabase/migrations/app"

echo "CREATE TABLE a;" > "$WT/supabase/migrations/app/20260418000001_a.sql"

RESULT="$(find_new_migrations "$WT" "$SB")"
assert_contains "finds new migration" "20260418000001_a.sql" "$RESULT"

header "find_new_migrations — skips real file (from origin)"
# Add same file as real (non-symlink) in supabase wt
echo "CREATE TABLE a;" > "$SB/supabase/migrations/app/20260418000001_a.sql"

RESULT="$(find_new_migrations "$WT" "$SB")"
assert_eq "no new migrations" "" "$RESULT"

header "find_new_migrations — skips correctly symlinked"
setup_tmpdir

WT="$TEST_TMPDIR/feat-b"
SB="$TEST_TMPDIR/supabase"
mkdir -p "$WT/supabase/migrations/app" "$SB/supabase/migrations/app"

echo "CREATE TABLE b;" > "$WT/supabase/migrations/app/20260418000002_b.sql"
ln -s "$WT/supabase/migrations/app/20260418000002_b.sql" "$SB/supabase/migrations/app/20260418000002_b.sql"

RESULT="$(find_new_migrations "$WT" "$SB")"
assert_eq "already symlinked, nothing new" "" "$RESULT"

header "find_new_migrations — detects wrongly symlinked (different worktree)"
setup_tmpdir

WT_A="$TEST_TMPDIR/feat-a"
WT_B="$TEST_TMPDIR/feat-b"
SB="$TEST_TMPDIR/supabase"
mkdir -p "$WT_A/supabase/migrations/app" "$WT_B/supabase/migrations/app" "$SB/supabase/migrations/app"

echo "CREATE TABLE c;" > "$WT_A/supabase/migrations/app/20260418000003_c.sql"
echo "CREATE TABLE c;" > "$WT_B/supabase/migrations/app/20260418000003_c.sql"
# Symlink points to feat-a
ln -s "$WT_A/supabase/migrations/app/20260418000003_c.sql" "$SB/supabase/migrations/app/20260418000003_c.sql"

# feat-b should see it as new (symlink target is different)
RESULT="$(find_new_migrations "$WT_B" "$SB")"
assert_contains "detects mismatch" "20260418000003_c.sql" "$RESULT"

# ── get_latest_origin_timestamp ──────────────────────────────────────

header "get_latest_origin_timestamp"
setup_tmpdir

SB="$TEST_TMPDIR/supabase"
mkdir -p "$SB/supabase/migrations/app"
echo "sql" > "$SB/supabase/migrations/app/20260101000000_init.sql"
echo "sql" > "$SB/supabase/migrations/app/20260418000001_feature.sql"
# Add a symlink — should be excluded
ln -s "/fake/path.sql" "$SB/supabase/migrations/app/20260501000000_symlink.sql"

RESULT="$(get_latest_origin_timestamp "$SB")"
assert_eq "returns latest real timestamp" "20260418000001" "$RESULT"

header "get_latest_origin_timestamp — empty dir"
setup_tmpdir

SB="$TEST_TMPDIR/supabase"
mkdir -p "$SB/supabase/migrations/app"

RESULT="$(get_latest_origin_timestamp "$SB")"
assert_eq "returns empty for no files" "" "$RESULT"

# ── symlink_migrations ───────────────────────────────────────────────

header "symlink_migrations — creates symlinks"
setup_tmpdir

WT="$TEST_TMPDIR/feat-a"
SB="$TEST_TMPDIR/supabase"
mkdir -p "$WT/supabase/migrations/app" "$SB/supabase/migrations/app"

echo "CREATE TABLE x;" > "$WT/supabase/migrations/app/20260418000001_x.sql"

OUTPUT=$(symlink_migrations "$WT" "supabase/migrations/app/20260418000001_x.sql" "$SB")
assert_symlink "symlink created" "$SB/supabase/migrations/app/20260418000001_x.sql"
assert_contains "reports count" "Symlinked 1" "$OUTPUT"

# Verify target
TARGET=$(readlink "$SB/supabase/migrations/app/20260418000001_x.sql")
assert_eq "symlink target correct" "$WT/supabase/migrations/app/20260418000001_x.sql" "$TARGET"

header "symlink_migrations — skips existing correct symlink"
OUTPUT=$(symlink_migrations "$WT" "supabase/migrations/app/20260418000001_x.sql" "$SB")
assert_eq "no output for existing symlink" "" "$OUTPUT"

# ── remove_wt_symlinks ───────────────────────────────────────────────

header "remove_wt_symlinks"
setup_tmpdir

WT_A="$TEST_TMPDIR/feat-a"
WT_B="$TEST_TMPDIR/feat-b"
SB="$TEST_TMPDIR/supabase"
mkdir -p "$WT_A/supabase/migrations/app" "$WT_B/supabase/migrations/app" "$SB/supabase/migrations/app"

echo "sql" > "$WT_A/supabase/migrations/app/20260418000001_a.sql"
echo "sql" > "$WT_A/supabase/migrations/app/20260418000002_a2.sql"
echo "sql" > "$WT_B/supabase/migrations/app/20260418000003_b.sql"
echo "sql" > "$SB/supabase/migrations/app/20260101000000_init.sql"

ln -s "$WT_A/supabase/migrations/app/20260418000001_a.sql" "$SB/supabase/migrations/app/20260418000001_a.sql"
ln -s "$WT_A/supabase/migrations/app/20260418000002_a2.sql" "$SB/supabase/migrations/app/20260418000002_a2.sql"
ln -s "$WT_B/supabase/migrations/app/20260418000003_b.sql" "$SB/supabase/migrations/app/20260418000003_b.sql"

OUTPUT=$(remove_wt_symlinks "$WT_A" "$SB")

assert_contains "reports 2 removed" "Removed 2" "$OUTPUT"
assert_file_not_exists "a.sql removed" "$SB/supabase/migrations/app/20260418000001_a.sql"
assert_file_not_exists "a2.sql removed" "$SB/supabase/migrations/app/20260418000002_a2.sql"
assert_symlink "b.sql still intact" "$SB/supabase/migrations/app/20260418000003_b.sql"
assert_file_exists "init.sql untouched" "$SB/supabase/migrations/app/20260101000000_init.sql"

# ── clean_stale_symlinks ─────────────────────────────────────────────

header "clean_stale_symlinks — removes broken symlinks"
setup_tmpdir

WT="$TEST_TMPDIR/feat-a"
SB="$TEST_TMPDIR/supabase"
mkdir -p "$WT/supabase/migrations/app" "$SB/supabase/migrations/app"

echo "sql" > "$WT/supabase/migrations/app/20260418000001_exists.sql"
ln -s "$WT/supabase/migrations/app/20260418000001_exists.sql" "$SB/supabase/migrations/app/20260418000001_exists.sql"
ln -s "$WT/supabase/migrations/app/20260418000002_deleted.sql" "$SB/supabase/migrations/app/20260418000002_deleted.sql"

OUTPUT=$(clean_stale_symlinks "$WT" "$SB")

assert_contains "reports 1 stale removed" "Removed 1 stale" "$OUTPUT"
assert_symlink "valid symlink untouched" "$SB/supabase/migrations/app/20260418000001_exists.sql"
assert_file_not_exists "stale symlink removed" "$SB/supabase/migrations/app/20260418000002_deleted.sql"

header "clean_stale_symlinks — ignores other worktree's broken symlinks"
setup_tmpdir

WT_A="$TEST_TMPDIR/feat-a"
WT_B="$TEST_TMPDIR/feat-b"
SB="$TEST_TMPDIR/supabase"
mkdir -p "$WT_A/supabase/migrations/app" "$WT_B/supabase/migrations/app" "$SB/supabase/migrations/app"

# Broken symlink from feat-b
ln -s "$WT_B/supabase/migrations/app/20260418000003_gone.sql" "$SB/supabase/migrations/app/20260418000003_gone.sql"

OUTPUT=$(clean_stale_symlinks "$WT_A" "$SB")

# Should not touch feat-b's symlinks
assert_eq "no output for other worktree" "" "$OUTPUT"
assert "broken feat-b symlink untouched" test -L "$SB/supabase/migrations/app/20260418000003_gone.sql"
