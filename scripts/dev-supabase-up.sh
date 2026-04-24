#!/usr/bin/env bash
set -euo pipefail

# Create supabase worktree and start Supabase.
# Usage: dev sb up

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/dev-supabase-helpers.sh"

require_bare_repo

supabase_wt="$(resolve_supabase_wt)"

ensure_fetch_refspec

echo "Fetching origin..."
git fetch origin

# Create or update supabase worktree
if [ -d "$supabase_wt" ]; then
  echo "Updating supabase worktree to origin/main..."
  (cd "$supabase_wt" && git checkout -f origin/main) 2>&1 | grep -v "^HEAD is now at" || true
else
  echo "Creating supabase worktree..."
  git worktree add "$supabase_wt" --detach origin/main
fi

# Start Supabase if not running
if supabase_is_running; then
  echo "Supabase already running."
else
  echo "Starting Supabase..."
  echo "(First run pulls ~10 Docker images and may take a few minutes)"
  (cd "$supabase_wt" && supabase start)
fi

# Apply origin/main migrations
apply_migrations "$supabase_wt"

# Inject env vars
echo "Injecting Supabase env vars..."
(cd "$supabase_wt" && "$SCRIPT_DIR/dev-worktree-env.sh")

# Start edge functions runtime — pgflow's ensure_workers cron needs it up to
# dispatch flow tasks to the worker endpoints. config.toml commits to
# [edge_runtime] enabled = true project-wide, so no need to check.
project_id="$(get_project_id "$supabase_wt")"
if docker ps --filter "name=supabase_edge_runtime_${project_id}" --format "{{.Names}}" 2>/dev/null | grep -q .; then
  echo "Edge functions already running."
else
  echo "Starting edge functions..."
  (cd "$supabase_wt" && supabase functions serve) </dev/null >/dev/null 2>&1 &
  disown
fi

echo ""
echo "=== Supabase ready ==="
echo "  Worktree: $supabase_wt"
echo "  Branch:   origin/main (detached)"
echo ""
echo "To sync after rebase: dev sb sync"
