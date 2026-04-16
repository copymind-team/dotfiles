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

# ── Temp dir management ───────────────────────────────────────────────

TEST_TMPDIR=""

setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d "/tmp/dotfiles-test-$$-XXXXXX")"
  # Resolve symlinks (macOS /tmp → /private/tmp) so realpath comparisons work
  TEST_TMPDIR="$(cd "$TEST_TMPDIR" && pwd -P)"
}

# ── Summary ───────────────────────────────────────────────────────────

print_results() {
  echo ""
  printf "${BOLD}Results: ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}\n" "$PASSED" "$FAILED"
  if [ "$FAILED" -gt 0 ]; then
    exit 1
  fi
}

# Auto-cleanup and print results on exit
_test_cleanup() {
  if [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ]; then
    rm -rf "$TEST_TMPDIR"
  fi
  print_results
}
trap _test_cleanup EXIT
