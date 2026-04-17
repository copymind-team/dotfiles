#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}#3 — dev sb status${RESET}\n"

header "shows status when running"
cd "$TEST_DIR/main"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-status.sh" 2>&1) || true

assert_contains "shows service info" "service_role" "$OUTPUT"

print_results
