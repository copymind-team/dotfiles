#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit tests: dev-worktree-env.sh${RESET}\n"

# Source the functions from the script without running the main body.
# We extract and eval just the function definitions.
_source_functions() {
  eval "$(sed -n '/^upsert_env()/,/^}/p' "$SCRIPTS_DIR/dev-worktree-env.sh")"
  eval "$(sed -n '/^classify_supabase_var()/,/^}/p' "$SCRIPTS_DIR/dev-worktree-env.sh")"
  eval "$(sed -n '/^discover_supabase_vars()/,/^}/p' "$SCRIPTS_DIR/dev-worktree-env.sh")"
}
_source_functions

# ── upsert_env ────────────────────────────────────────────────────────

header "upsert_env — insert new key"
setup_tmpdir

ENV="$TEST_TMPDIR/.env.local"
echo "EXISTING_KEY=old_value" > "$ENV"

upsert_env "$ENV" "NEW_KEY" "new_value"
assert_contains "new key appended" "NEW_KEY=new_value" "$(cat "$ENV")"
assert_contains "existing key untouched" "EXISTING_KEY=old_value" "$(cat "$ENV")"

header "upsert_env — update existing key"
upsert_env "$ENV" "EXISTING_KEY" "updated_value"
assert_contains "key updated" "EXISTING_KEY=updated_value" "$(cat "$ENV")"
assert_not_contains "old value gone" "old_value" "$(cat "$ENV")"

header "upsert_env — insert into empty file"
setup_tmpdir
ENV="$TEST_TMPDIR/.env.local"
touch "$ENV"

upsert_env "$ENV" "FIRST_KEY" "first_value"
assert_contains "key written to empty file" "FIRST_KEY=first_value" "$(cat "$ENV")"

header "upsert_env — no double newlines"
setup_tmpdir
ENV="$TEST_TMPDIR/.env.local"
printf "KEY1=val1" > "$ENV"  # no trailing newline

upsert_env "$ENV" "KEY2" "val2"
upsert_env "$ENV" "KEY3" "val3"

# Check no blank lines between entries
BLANK_LINES=$(grep -c '^$' "$ENV" || true)
assert_eq "no blank lines" "0" "$BLANK_LINES"

# ── classify_supabase_var ─────────────────────────────────────────────

header "classify_supabase_var"

assert_eq "NEXT_PUBLIC_SUPABASE_URL → API_URL" \
  "API_URL" "$(classify_supabase_var "NEXT_PUBLIC_SUPABASE_URL")"

assert_eq "NEXT_PUBLIC_SUPABASE_ANON_KEY → ANON_KEY" \
  "ANON_KEY" "$(classify_supabase_var "NEXT_PUBLIC_SUPABASE_ANON_KEY")"

assert_eq "SUPABASE_SERVICE_ROLE_KEY → SERVICE_ROLE_KEY" \
  "SERVICE_ROLE_KEY" "$(classify_supabase_var "SUPABASE_SERVICE_ROLE_KEY")"

assert_eq "DATABASE_URL → DB_URL" \
  "DB_URL" "$(classify_supabase_var "DATABASE_URL")"

assert_eq "JWT_SECRET → JWT_SECRET" \
  "JWT_SECRET" "$(classify_supabase_var "JWT_SECRET")"

assert_eq "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY → PUBLISHABLE_KEY" \
  "PUBLISHABLE_KEY" "$(classify_supabase_var "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY")"

assert_eq "SUPABASE_SECRET_KEY → SECRET_KEY" \
  "SECRET_KEY" "$(classify_supabase_var "SUPABASE_SECRET_KEY")"

assert_eq "unmapped var returns empty" \
  "" "$(classify_supabase_var "SOME_OTHER_VAR")"

assert_eq "partial match returns empty" \
  "" "$(classify_supabase_var "MY_URL")"

# ── discover_supabase_vars ────────────────────────────────────────────

header "discover_supabase_vars"
setup_tmpdir

WORKTREE="$TEST_TMPDIR/worktree"
mkdir -p "$WORKTREE/src/lib"
ENV="$WORKTREE/.env.local"

# Source code with Supabase env vars
cat > "$WORKTREE/src/lib/config.ts" << 'TS'
const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const other = process.env.NODE_ENV;
TS

# .env.local with additional vars
cat > "$ENV" << 'ENV'
NEXT_PUBLIC_SUPABASE_URL=http://localhost:54321
DATABASE_URL=postgresql://localhost/db
UNRELATED_VAR=foo
ENV

VARS="$(discover_supabase_vars "$WORKTREE" "$ENV")"

assert_contains "finds SUPABASE_URL from source" "NEXT_PUBLIC_SUPABASE_URL" "$VARS"
assert_contains "finds SUPABASE_ANON_KEY from source" "NEXT_PUBLIC_SUPABASE_ANON_KEY" "$VARS"
assert_contains "finds DATABASE_URL from .env" "DATABASE_URL" "$VARS"
assert_not_contains "excludes NODE_ENV" "NODE_ENV" "$VARS"
assert_not_contains "excludes UNRELATED_VAR" "UNRELATED_VAR" "$VARS"

header "discover_supabase_vars — deduplication"
# Add duplicate references
cat >> "$WORKTREE/src/lib/config.ts" << 'TS'
const url2 = process.env.NEXT_PUBLIC_SUPABASE_URL;
TS

VARS="$(discover_supabase_vars "$WORKTREE" "$ENV")"
COUNT=$(echo "$VARS" | grep -c "NEXT_PUBLIC_SUPABASE_URL")
assert_eq "SUPABASE_URL appears once" "1" "$COUNT"
