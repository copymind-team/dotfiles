#!/usr/bin/env bash
set -euo pipefail

# Runs all unit tests.
# Usage: ./tests/run-unit.sh [pattern]
# Examples:
#   ./tests/run-unit.sh              # run all
#   ./tests/run-unit.sh env          # run only *env* tests
#   ./tests/run-unit.sh migrate      # run only *migrate* tests

TESTS_DIR="$(cd "$(dirname "$0")/unit" && pwd)"
PATTERN="${1:-}"
TOTAL_PASSED=0
TOTAL_FAILED=0
FAILED_TESTS=()

for test_file in "$TESTS_DIR"/*.test.sh; do
  [ -f "$test_file" ] || continue

  if [ -n "$PATTERN" ] && [[ "$(basename "$test_file")" != *"$PATTERN"* ]]; then
    continue
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "Running: %s\n" "$(basename "$test_file")"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if bash "$test_file"; then
    : # test passed
  else
    FAILED_TESTS+=("$(basename "$test_file")")
  fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
  printf "\033[31m\033[1mFailed test files:\033[0m\n"
  for f in "${FAILED_TESTS[@]}"; do
    printf "  \033[31m✗\033[0m %s\n" "$f"
  done
  exit 1
else
  printf "\033[32m\033[1mAll unit tests passed.\033[0m\n"
fi
