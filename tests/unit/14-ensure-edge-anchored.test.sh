#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: ensure_edge_runtime_anchored${RESET}\n"

setup_tmpdir
STUB_BIN="$TEST_TMPDIR/bin"
DOCKER_STATE="$TEST_TMPDIR/docker.state"
SUPABASE_LOG="$TEST_TMPDIR/supabase.log"
mkdir -p "$STUB_BIN"

# `docker` stub driven by $DOCKER_STATE:
#   - first line: "MISSING", "ANCHORED_SHARED", or "ANCHORED_OTHER"
#   - second line: expected shared path (anchor target)
#   - third line: non-shared path (wrong anchor)
cat > "$STUB_BIN/docker" <<STUB
#!/usr/bin/env bash
STATE_FILE="$DOCKER_STATE"
state=\$(sed -n '1p' "\$STATE_FILE")
shared_path=\$(sed -n '2p' "\$STATE_FILE")
wrong_path=\$(sed -n '3p' "\$STATE_FILE")

if [ "\$1" = "inspect" ]; then
  # args: inspect <container> [--format <fmt>]
  if [ "\$state" = "MISSING" ]; then
    exit 1
  fi
  # Look for --format — emit Destinations when asked
  for a in "\$@"; do
    if [ "\$a" = "--format" ]; then
      if [ "\$state" = "ANCHORED_SHARED" ]; then
        echo "\$shared_path/supabase/flows/index.ts"
        echo "\$shared_path/supabase/flows/noop.ts"
      else
        echo "\$wrong_path/supabase/flows/index.ts"
      fi
      exit 0
    fi
  done
  # No --format — just success (means "container exists")
  echo "[{}]"
  exit 0
fi
exit 0
STUB
chmod +x "$STUB_BIN/docker"

cat > "$STUB_BIN/supabase" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$SUPABASE_LOG"
exit 0
STUB
chmod +x "$STUB_BIN/supabase"

# `curl` — always reports control plane ready
cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_BIN/curl"

PATH="$STUB_BIN:$PATH"
export PATH

source "$SCRIPTS_DIR/dev-supabase-helpers.sh"

SHARED_WT="$TEST_TMPDIR/shared-wt"
OTHER_WT="$TEST_TMPDIR/feat-wt"
mkdir -p "$SHARED_WT/supabase"
mkdir -p "$OTHER_WT/supabase"
cat > "$SHARED_WT/supabase/config.toml" <<TOML
project_id = "anchor-test"
[api]
port = 54621
[db]
port = 54622
TOML

# ── correctly anchored — no-op ───────────────────────────────────────
header "no-op when anchored to shared"
: > "$SUPABASE_LOG"
printf "ANCHORED_SHARED\n%s\n%s\n" "$SHARED_WT" "$OTHER_WT" > "$DOCKER_STATE"

ensure_edge_runtime_anchored "$SHARED_WT" >/dev/null

assert_not_contains "supabase stop NOT called" "stop" "$(cat "$SUPABASE_LOG")"
assert_not_contains "supabase start NOT called" "start" "$(cat "$SUPABASE_LOG")"

# ── wrong anchor — restart fires ─────────────────────────────────────
header "restarts stack when anchored to different worktree"
: > "$SUPABASE_LOG"
printf "ANCHORED_OTHER\n%s\n%s\n" "$SHARED_WT" "$OTHER_WT" > "$DOCKER_STATE"

OUTPUT=$(ensure_edge_runtime_anchored "$SHARED_WT" 2>&1)

assert_contains "logs re-anchoring" "re-anchoring" "$OUTPUT"
assert_contains "supabase stop called" "stop" "$(cat "$SUPABASE_LOG")"
assert_contains "supabase start called" "start" "$(cat "$SUPABASE_LOG")"

# ── container missing — start fires ──────────────────────────────────
header "starts stack when container missing"
: > "$SUPABASE_LOG"
printf "MISSING\n%s\n%s\n" "$SHARED_WT" "$OTHER_WT" > "$DOCKER_STATE"

OUTPUT=$(ensure_edge_runtime_anchored "$SHARED_WT" 2>&1)

assert_contains "logs container missing" "not found" "$OUTPUT"
assert_contains "supabase start called" "start" "$(cat "$SUPABASE_LOG")"

print_results
