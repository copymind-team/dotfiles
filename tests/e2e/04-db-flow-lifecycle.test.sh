#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}E2E: dev sb flow lifecycle${RESET}\n"

# Entry state (left by 03-db-reset):
#   - Supabase running with edge_runtime enabled
#   - feat-gamma worktree exists
#   - shared supabase worktree has supabase/flows/noop.ts (git-tracked from fixture)
#
# Part 1 (anchor self-heal) exercises the bug that motivated the refactor.
# Part 2 (released-flow guard) exercises the pre-pass validation that prevents
# rewriting a flow's migration once it's on origin/main.
#
# End-to-end `npx pgflow compile` is NOT tested here: Deno inside the
# edge-runtime container can't reliably resolve jsr.io / registry.npmjs.org
# when run under Docker Desktop on macOS without a pre-warmed cache. The
# compile path is covered by pgflow's own test suite; this file focuses on
# the orchestration that surrounds it — anchor handling, rsync, restart,
# and pre-pass guards — which are where this refactor lives.

SHARED_WT="$WORKTREE_BASE/supabase"
PROJECT_ID="test-int"
EDGE_CONTAINER="supabase_edge_runtime_${PROJECT_ID}"
FEAT_WT="$WORKTREE_BASE/feat-gamma"

# ── Pre-flight: confirm edge runtime container actually exists ───────

header "pre-flight — edge runtime container running"
if ! docker inspect "$EDGE_CONTAINER" >/dev/null 2>&1; then
  echo "  ${RED}✗${RESET} edge runtime container '$EDGE_CONTAINER' is not running."
  echo "    This test requires the fixture's config.toml to enable [edge_runtime]."
  # Skip gracefully so the rest of the suite still reports.
  print_results
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════
# Part 1: anchor self-heal
# ══════════════════════════════════════════════════════════════════════

header "baseline — anchored correctly after dev sb up"
assert_docker_mount_contains "edge runtime mounts shared worktree's flows" \
  "$EDGE_CONTAINER" "$SHARED_WT/supabase/flows"

# We call ensure_edge_runtime_anchored directly (rather than via `dev sb flow up`)
# to isolate the anchor-check from the rest of the compile pipeline.
_call_ensure_anchored() {
  local wt="$1"
  (
    source "$SCRIPTS_DIR/dev-supabase-helpers.sh"
    ensure_edge_runtime_anchored "$wt"
  )
}

header "no-op when already anchored correctly"
EXIT_CODE=0
OUTPUT=$(_call_ensure_anchored "$SHARED_WT" 2>&1) || EXIT_CODE=$?
assert_exit_code "exits 0" "0" "$EXIT_CODE"
assert_not_contains "does NOT log re-anchoring" "re-anchoring" "$OUTPUT"

header "induce anchor mismatch — start from feat-gamma"
(cd "$SHARED_WT" && supabase stop --no-backup >/dev/null 2>&1) || true
cd "$FEAT_WT"
supabase start >/dev/null 2>&1

assert_docker_mount_contains "edge runtime now mounts feat-gamma" \
  "$EDGE_CONTAINER" "$FEAT_WT/supabase/flows"
assert_docker_mount_not_contains "edge runtime NOT mounting shared" \
  "$EDGE_CONTAINER" "$SHARED_WT/supabase/flows"

header "ensure_edge_runtime_anchored — auto re-anchor (THE BUG FIX)"
EXIT_CODE=0
OUTPUT=$(_call_ensure_anchored "$SHARED_WT" 2>&1) || EXIT_CODE=$?
assert_exit_code "exits 0" "0" "$EXIT_CODE"
assert_contains "logs re-anchoring" "re-anchoring" "$OUTPUT"
assert_docker_mount_contains "edge runtime back on shared worktree" \
  "$EDGE_CONTAINER" "$SHARED_WT/supabase/flows"

# ══════════════════════════════════════════════════════════════════════
# Part 2: released-flow guard (pre-pass validation)
# ══════════════════════════════════════════════════════════════════════

SLUG="mirror"
MIG_TS="20260501000000"
MIG_BASENAME="${MIG_TS}_create_${SLUG}_flow.sql"

# ── Setup: add flow source + a hand-crafted migration to feat-gamma ──
# We bypass real pgflow compilation by pre-placing the migration file the
# compile step would have produced. The released-flow guard checks for a
# matching migration basename on origin/main, independent of the compile.

header "setup — add mirror flow + hand-crafted migration in feat-gamma"
cat > "$FEAT_WT/supabase/flows/mirror.ts" <<'TS'
import { Flow } from "@pgflow/dsl";

export const Mirror = new Flow<{ value: string }>({
  slug: "mirror",
}).step({ slug: "reflect" }, (input) => ({ value: input.run.value }));
TS
cat > "$FEAT_WT/supabase/flows/index.ts" <<'TS'
export { Noop } from "./noop.ts";
export { Mirror } from "./mirror.ts";
TS

mkdir -p "$FEAT_WT/supabase/migrations/jobs"
cat > "$FEAT_WT/supabase/migrations/jobs/${MIG_BASENAME}" <<SQL
SELECT pgflow.create_flow('${SLUG}', max_attempts => 3, base_delay => 1);
SELECT pgflow.add_step('${SLUG}', 'reflect');
SQL

# Make the source file NEWER than the migration so the mtime-skip branch
# doesn't short-circuit. The released-flow guard runs only when recompile
# is needed (source newer than migration).
touch "$FEAT_WT/supabase/flows/mirror.ts"

assert_file_exists "mirror source file" "$FEAT_WT/supabase/flows/mirror.ts"
assert_file_exists "pre-placed migration" "$FEAT_WT/supabase/migrations/jobs/${MIG_BASENAME}"

# ── Merge the migration to origin/main — flow becomes "released" ─────

header "merge mirror migration to origin/main"
cd "$WORKTREE_BASE/main"
mkdir -p supabase/migrations/jobs supabase/flows
cp "$FEAT_WT/supabase/migrations/jobs/${MIG_BASENAME}" supabase/migrations/jobs/
cp "$FEAT_WT/supabase/flows/mirror.ts" supabase/flows/mirror.ts
cat > supabase/flows/index.ts <<'TS'
export { Noop } from "./noop.ts";
export { Mirror } from "./mirror.ts";
TS
git add supabase/migrations/jobs/"${MIG_BASENAME}" supabase/flows/mirror.ts supabase/flows/index.ts
git commit -q -m "release mirror flow"
git push -q origin main

# ── dev sb flow up mirror from feat-gamma — guard fires ──────────────

header "dev sb flow up mirror from feat-gamma — released-flow guard fires"
cd "$FEAT_WT"
EXIT_CODE=0
OUTPUT=$(bash "$SCRIPTS_DIR/dev-supabase.sh" flow up "$SLUG" 2>&1) || EXIT_CODE=$?
if [ "$EXIT_CODE" != "1" ]; then
  printf "${DIM}flow up output (expected non-zero):${RESET}\n%s\n" "$OUTPUT" >&2
fi
assert_exit_code "exits 1 (released-flow guard)" "1" "$EXIT_CODE"
assert_contains "flags released-flow state" "released on origin/main" "$OUTPUT"
assert_contains "points at versioning guide" "version-flows" "$OUTPUT"

# Shared wt flows must be restored after the guard-triggered abort
assert_file_exists "shared wt still has noop.ts" "$SHARED_WT/supabase/flows/noop.ts"
assert_file_not_exists "shared wt has no mirror.ts (trap restored)" "$SHARED_WT/supabase/flows/mirror.ts"

# ── Return to main for later cleanup ─────────────────────────────────

cd "$WORKTREE_BASE/main"

print_results
