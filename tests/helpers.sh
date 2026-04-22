#!/usr/bin/env bash
# Shared test helpers for unit and e2e tests.
# Source this file at the top of each test script.

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$DOTFILES_DIR/scripts"

# ── Colors ────────────────────────────────────────────────────────────
RED='\033[31m'
GREEN='\033[32m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

PASSED=0
FAILED=0
CURRENT_TEST=""

# ── Assertions ────────────────────────────────────────────────────────

header() {
  echo ""
  printf "${BOLD}── %s ──${RESET}\n" "$1"
  CURRENT_TEST="$1"
}

assert() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}✓${RESET} %s\n" "$label"
  else
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s\n" "$label"
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}✓${RESET} %s\n" "$label"
  else
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s — expected: '%s', got: '%s'\n" "$label" "$expected" "$actual"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}✓${RESET} %s\n" "$label"
  else
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s — expected to contain: '%s'\n" "$label" "$needle"
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s — should not contain: '%s'\n" "$label" "$needle"
  else
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}✓${RESET} %s\n" "$label"
  fi
}

assert_exit_code() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}✓${RESET} %s (exit %s)\n" "$label" "$actual"
  else
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s — expected exit %s, got %s\n" "$label" "$expected" "$actual"
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  if [ -e "$path" ]; then
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}✓${RESET} %s\n" "$label"
  else
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s — not found: %s\n" "$label" "$path"
  fi
}

assert_file_not_exists() {
  local label="$1" path="$2"
  if [ ! -e "$path" ]; then
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}✓${RESET} %s\n" "$label"
  else
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s — should not exist: %s\n" "$label" "$path"
  fi
}

assert_symlink() {
  local label="$1" path="$2"
  if [ -L "$path" ]; then
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}✓${RESET} %s\n" "$label"
  else
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s — not a symlink: %s\n" "$label" "$path"
  fi
}

assert_not_symlink() {
  local label="$1" path="$2"
  if [ ! -L "$path" ]; then
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}✓${RESET} %s\n" "$label"
  else
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s — should not be a symlink: %s\n" "$label" "$path"
  fi
}

# ── Symlink helpers ───────────────────────────────────────────────────

assert_symlink_count() {
  local label="$1" expected="$2" dir="$3"
  local actual
  actual=$(find "$dir" -type l 2>/dev/null | wc -l | tr -d ' ')
  if [ "$actual" = "$expected" ]; then
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}✓${RESET} %s (count: %s)\n" "$label" "$actual"
  else
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s — expected %s, got %s\n" "$label" "$expected" "$actual"
  fi
}

# ── Database helpers ─────────────────────────────────────────────────
# Require TEST_DB_CONTAINER to be set (e.g., "supabase_db_test-int")

db_query() {
  docker exec -e PGPASSWORD=postgres "${TEST_DB_CONTAINER:-supabase_db_test-int}" \
    psql -U supabase_admin -d postgres -tAc "$1" 2>/dev/null
}

db_version_exists() {
  local version="$1"
  local count
  count=$(db_query "SELECT count(*) FROM supabase_migrations.schema_migrations WHERE version = '$version';")
  [ "$count" = "1" ]
}

db_version_not_exists() {
  local version="$1"
  local count
  count=$(db_query "SELECT count(*) FROM supabase_migrations.schema_migrations WHERE version = '$version';")
  [ "$count" = "0" ]
}

db_table_exists() {
  local table="$1"
  local count
  count=$(db_query "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '$table';")
  [ "$count" = "1" ]
}

db_seed_exists() {
  local name="$1"
  local count
  count=$(db_query "SELECT count(*) FROM supabase_seeds.applied_seeds WHERE name = '$name';")
  [ "$count" = "1" ]
}

db_count() {
  local table="$1"
  db_query "SELECT count(*) FROM public.\"$table\";"
}

assert_docker_mount_contains() {
  local label="$1" container="$2" needle="$3"
  local mounts
  mounts=$(docker inspect "$container" --format '{{range .Mounts}}{{.Destination}}
{{end}}' 2>/dev/null || true)
  if echo "$mounts" | grep -qF "$needle"; then
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}✓${RESET} %s\n" "$label"
  else
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s — mounts did not contain: '%s'\n" "$label" "$needle"
  fi
}

assert_docker_mount_not_contains() {
  local label="$1" container="$2" needle="$3"
  local mounts
  mounts=$(docker inspect "$container" --format '{{range .Mounts}}{{.Destination}}
{{end}}' 2>/dev/null || true)
  if echo "$mounts" | grep -qF "$needle"; then
    FAILED=$((FAILED + 1))
    printf "  ${RED}✗${RESET} %s — mounts unexpectedly contained: '%s'\n" "$label" "$needle"
  else
    PASSED=$((PASSED + 1))
    printf "  ${GREEN}✓${RESET} %s\n" "$label"
  fi
}

# ── File mtime helpers ────────────────────────────────────────────────

# Set a file's mtime to a fixed date in the distant past. Use this when a
# test compares mtimes (e.g., `source -nt migration`) and needs the result to
# be deterministic on 1-second-resolution filesystems (CI ext4/tmpfs), where
# two sequential writes can otherwise share the same second and make `-nt`
# ambiguous. A subsequent `touch` (or fresh file) is then guaranteed newer.
backdate() {
  touch -t 202001010000 "$1"
}

# ── Temp dir management ───────────────────────────────────────────────

TEST_TMPDIR=""

setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d "/tmp/dotfiles-test-$$-XXXXXX")"
  # Resolve symlinks (macOS /tmp → /private/tmp) so realpath comparisons work
  TEST_TMPDIR="$(cd "$TEST_TMPDIR" && pwd -P)"
}

# ── Summary ───────────────────────────────────────────────────────────

print_results() {
  # When run from the runner, write stats to a file for aggregation
  if [ "${RUN_FROM_RUNNER:-}" = "1" ] && [ -n "${STATS_FILE:-}" ]; then
    echo "$PASSED $FAILED" >> "$STATS_FILE"
  fi
  echo ""
  printf "${BOLD}Results: ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}\n" "$PASSED" "$FAILED"
  if [ "$FAILED" -gt 0 ]; then
    exit 1
  fi
}

# Auto-cleanup and print results on exit.
# When run from the runner (RUN_FROM_RUNNER=1), skip auto-trap — the runner handles reporting.
_test_cleanup() {
  if [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ]; then
    rm -rf "$TEST_TMPDIR"
  fi
  print_results
}
if [ "${RUN_FROM_RUNNER:-}" != "1" ]; then
  trap _test_cleanup EXIT
fi
