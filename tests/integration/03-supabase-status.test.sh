#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}#3 — dev sb status${RESET}\n"

header "shows status when running"
cd "$WORKTREE_BASE/main"
OUTPUT=$("$SCRIPTS_DIR/dev-supabase-status.sh" 2>&1) || true

# supabase status exits 0 when running — the script would print
# "not running" otherwise
assert_not_contains "not showing 'not running'" "not running" "$OUTPUT"

print_results
