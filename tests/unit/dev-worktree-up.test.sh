#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit tests: dev-worktree-up.sh${RESET}\n"

# ── No arguments → usage ─────────────────────────────────────────────

header "no arguments prints usage"
OUTPUT=$(bash "$SCRIPTS_DIR/dev-worktree-up.sh" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}

assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "shows error" "branch name is required" "$OUTPUT"
assert_contains "shows usage" "Usage: dev worktree up" "$OUTPUT"
assert_contains "shows example" "Example:" "$OUTPUT"

# ── Name sanitization ────────────────────────────────────────────────

header "name sanitization"

sanitize() {
  echo "$1" | tr '/' '-' | tr -cd 'a-zA-Z0-9_.-'
}

assert_eq "slashes become dashes" "feat-new-chat" "$(sanitize "feat/new-chat")"
assert_eq "nested slashes" "feat-team-new-chat" "$(sanitize "feat/team/new-chat")"
assert_eq "plain name unchanged" "my-branch" "$(sanitize "my-branch")"
assert_eq "special chars stripped" "featbranch" "$(sanitize "feat@branch!")"
assert_eq "dots preserved" "v1.2.3" "$(sanitize "v1.2.3")"
assert_eq "underscores preserved" "feat_thing" "$(sanitize "feat_thing")"

# ── Port allocation logic ────────────────────────────────────────────

header "port allocation"
setup_tmpdir

REGISTRY="$TEST_TMPDIR/.worktree-ports"
printf "# worktree\tport\tcreated\n" > "$REGISTRY"
printf "main\t13000\t2026-01-01\n" >> "$REGISTRY"

# Simulate allocating next port
MAX_PORT=$(grep -v '^#' "$REGISTRY" | awk -F'\t' '{print $2}' | sort -n | tail -1)
NEW_PORT=$((MAX_PORT + 1))
assert_eq "next port after 13000" "13001" "$NEW_PORT"

# Add another entry and allocate again
printf "feat-a\t13001\t2026-01-02\n" >> "$REGISTRY"
MAX_PORT=$(grep -v '^#' "$REGISTRY" | awk -F'\t' '{print $2}' | sort -n | tail -1)
NEW_PORT=$((MAX_PORT + 1))
assert_eq "next port after 13001" "13002" "$NEW_PORT"

# Port overflow check (base + 100)
BASE_PORT=13000
assert "port within range" test "$NEW_PORT" -lt $((BASE_PORT + 100))

# Simulate overflow
printf "feat-overflow\t13099\t2026-01-03\n" >> "$REGISTRY"
MAX_PORT=$(grep -v '^#' "$REGISTRY" | awk -F'\t' '{print $2}' | sort -n | tail -1)
NEW_PORT=$((MAX_PORT + 1))
assert "port overflow detected" test "$NEW_PORT" -ge $((BASE_PORT + 100))

# ── Registry format ──────────────────────────────────────────────────

header "registry format"
setup_tmpdir

REGISTRY="$TEST_TMPDIR/.worktree-ports"
printf "# worktree\tport\tcreated\n" > "$REGISTRY"
printf "main\t13000\t2026-01-01\n" >> "$REGISTRY"
printf "feat-a\t13001\t2026-01-02\n" >> "$REGISTRY"

# Check existing entry detection
assert "detects existing entry" grep -q "^feat-a	" "$REGISTRY"
MISSING=$(grep -c "^feat-b	" "$REGISTRY" || true)
assert_eq "does not detect missing entry" "0" "$MISSING"

# ── Non-bare repo → error ────────────────────────────────────────────

header "non-bare repo check"
setup_tmpdir

cd "$TEST_TMPDIR"
git init -q test-repo
cd test-repo
git config user.email "test@test.com"
git config user.name "Test"
touch file && git add file && git commit -q -m "init"

OUTPUT=$(bash "$SCRIPTS_DIR/dev-worktree-up.sh" test-branch 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}

assert_exit_code "exits with 1" "1" "$EXIT_CODE"
assert_contains "bare repo error" "bare" "$OUTPUT"
