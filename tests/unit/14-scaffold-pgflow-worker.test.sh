#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: scaffold_pgflow_worker${RESET}\n"

setup_tmpdir

# Shadow `supabase` on PATH so sourcing dev-supabase-helpers.sh doesn't abort.
STUB_BIN="$TEST_TMPDIR/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/supabase" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_BIN/supabase"
PATH="$STUB_BIN:$PATH"
export PATH

source "$SCRIPTS_DIR/dev-supabase-helpers.sh"

_make_flow_wt() {
  local wt="$1" kebab="$2" export_name="$3" dep_version="${4:-}"
  mkdir -p "$wt/supabase/flows"
  cat > "$wt/supabase/flows/${kebab}.ts" <<TS
import { Flow } from "@pgflow/dsl";

export const ${export_name} = new Flow<{ value: string }>({
  slug: "placeholder",
}).step({ slug: "noop" }, (input) => ({ value: input.run.value }));
TS
  if [ -n "$dep_version" ]; then
    cat > "$wt/package.json" <<JSON
{
  "name": "test-wt",
  "dependencies": {
    "@pgflow/dsl": "${dep_version}",
    "@pgflow/edge-worker": "${dep_version}"
  }
}
JSON
  fi
}

# ── happy path: both files rendered, substitutions correct ───────────
header "renders index.ts + deno.json from templates with package.json version"
WT="$TEST_TMPDIR/wt-happy"
_make_flow_wt "$WT" "twin-sleep" "TwinSleep" "^0.15.2"

OUTPUT=$(scaffold_pgflow_worker "$WT" "twinSleep" 2>&1)

WORKER_DIR="$WT/supabase/functions/twin-sleep-worker"
assert_file_exists "worker dir created" "$WORKER_DIR"
assert_file_exists "index.ts written" "$WORKER_DIR/index.ts"
assert_file_exists "deno.json written" "$WORKER_DIR/deno.json"
assert_contains "index.ts imports EdgeWorker" "from \"@pgflow/edge-worker\"" "$(cat "$WORKER_DIR/index.ts")"
assert_contains "index.ts uses real export name" "import { TwinSleep }" "$(cat "$WORKER_DIR/index.ts")"
assert_contains "index.ts imports from kebab path" "../../flows/twin-sleep.ts" "$(cat "$WORKER_DIR/index.ts")"
assert_contains "index.ts starts worker with export" "EdgeWorker.start(TwinSleep)" "$(cat "$WORKER_DIR/index.ts")"
assert_contains "deno.json uses version from package.json" "@pgflow/dsl@0.15.2" "$(cat "$WORKER_DIR/deno.json")"
assert_contains "log reports version" "pgflow@0.15.2" "$OUTPUT"

# ── version fallback when package.json is missing ───────────────────
header "falls back to 0.14.1 when package.json absent"
WT="$TEST_TMPDIR/wt-no-pkg"
_make_flow_wt "$WT" "build-facts-map" "BuildFactsMap"

scaffold_pgflow_worker "$WT" "buildFactsMap" >/dev/null 2>&1

assert_contains "deno.json uses fallback version" "@pgflow/edge-worker@0.14.1" \
  "$(cat "$WT/supabase/functions/build-facts-map-worker/deno.json")"

# ── export-name fallback when no 'export const … = new Flow' found ──
header "falls back to PascalCase slug when no matching export"
WT="$TEST_TMPDIR/wt-noexport"
mkdir -p "$WT/supabase/flows"
# Flow file without the expected pattern — e.g. renamed export
cat > "$WT/supabase/flows/mystery.ts" <<'TS'
import { Flow } from "@pgflow/dsl";
const Internal = new Flow<{}>({ slug: "mystery" });
export { Internal as Default };
TS

OUTPUT=$(scaffold_pgflow_worker "$WT" "mystery" 2>&1)

assert_contains "warns about fallback" "falling back to Mystery" "$OUTPUT"
assert_contains "index.ts imports PascalCase-derived name" "import { Mystery }" \
  "$(cat "$WT/supabase/functions/mystery-worker/index.ts")"

# ── idempotent: existing worker dir left untouched ──────────────────
header "skips when worker dir already exists"
WT="$TEST_TMPDIR/wt-exists"
_make_flow_wt "$WT" "noop" "Noop" "0.14.1"

# Pre-create a worker dir with sentinel content
mkdir -p "$WT/supabase/functions/noop-worker"
echo "// user-customized" > "$WT/supabase/functions/noop-worker/index.ts"

OUTPUT=$(scaffold_pgflow_worker "$WT" "noop" 2>&1)

assert_eq "scaffold is silent on skip" "" "$OUTPUT"
assert_eq "user file untouched" "// user-customized" \
  "$(cat "$WT/supabase/functions/noop-worker/index.ts")"
assert_file_not_exists "deno.json not created" "$WT/supabase/functions/noop-worker/deno.json"

# ── warn + skip when flow source file is missing ────────────────────
header "warns and skips when flow source absent"
WT="$TEST_TMPDIR/wt-no-source"
mkdir -p "$WT/supabase/flows"

OUTPUT=$(scaffold_pgflow_worker "$WT" "ghost" 2>&1)

assert_contains "warns about missing source" "ghost.ts missing" "$OUTPUT"
assert_file_not_exists "no worker dir created" "$WT/supabase/functions/ghost-worker"

print_results
