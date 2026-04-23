#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}#7 — dev wt port (override from registry)${RESET}\n"

MAIN_DIR="$WORKTREE_BASE/main"
OVERRIDE="$MAIN_DIR/docker-compose.override.yml"
REGISTRY="$WORKTREE_BASE/.worktree-ports"

header "regenerates override from registry"
rm -f "$OVERRIDE"
(cd "$MAIN_DIR" && "$SCRIPTS_DIR/dev-worktree-port.sh") >/dev/null
assert_file_exists "override.yml regenerated" "$OVERRIDE"
assert_contains "override maps main's port" "13000:3000" "$(cat "$OVERRIDE")"
assert_contains "override sets container_name" "container_name:" "$(cat "$OVERRIDE")"

header "idempotent"
FIRST_HASH=$(shasum "$OVERRIDE" | awk '{print $1}')
(cd "$MAIN_DIR" && "$SCRIPTS_DIR/dev-worktree-port.sh") >/dev/null
SECOND_HASH=$(shasum "$OVERRIDE" | awk '{print $1}')
assert_eq "re-running produces identical file" "$FIRST_HASH" "$SECOND_HASH"

header "fails when worktree has no registry entry"
# Temporarily hide main's registry entry.
cp "$REGISTRY" "$REGISTRY.bak"
grep -v '^main	' "$REGISTRY.bak" > "$REGISTRY"
set +e
OUTPUT=$(cd "$MAIN_DIR" && "$SCRIPTS_DIR/dev-worktree-port.sh" 2>&1)
EXIT_CODE=$?
set -e
mv "$REGISTRY.bak" "$REGISTRY"
assert_exit_code "exits non-zero" "1" "$EXIT_CODE"
assert_contains "mentions missing entry" "No entry" "$OUTPUT"

header "fails when registry file is missing"
mv "$REGISTRY" "$REGISTRY.bak"
set +e
OUTPUT=$(cd "$MAIN_DIR" && "$SCRIPTS_DIR/dev-worktree-port.sh" 2>&1)
EXIT_CODE=$?
set -e
mv "$REGISTRY.bak" "$REGISTRY"
assert_exit_code "exits non-zero" "1" "$EXIT_CODE"
assert_contains "mentions registry not found" "Port registry not found" "$OUTPUT"

# Restore main's override so later reruns of the suite see consistent state.
(cd "$MAIN_DIR" && "$SCRIPTS_DIR/dev-worktree-port.sh") >/dev/null

print_results
