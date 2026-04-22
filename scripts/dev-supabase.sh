#!/usr/bin/env bash
set -euo pipefail

# Manage shared local Supabase instance (one per repo, shared across worktrees).
# Usage: dev supabase <up|down|status|link|unlink|sync|migrate|seed|reset|flow>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

case "${1:-}" in
  up)
    shift
    exec "$SCRIPT_DIR/dev-supabase-up.sh" "$@"
    ;;
  down)
    shift
    exec "$SCRIPT_DIR/dev-supabase-down.sh" "$@"
    ;;
  status)
    shift
    exec "$SCRIPT_DIR/dev-supabase-status.sh" "$@"
    ;;
  link)
    shift
    exec "$SCRIPT_DIR/dev-supabase-link.sh" "$@"
    ;;
  unlink)
    shift
    exec "$SCRIPT_DIR/dev-supabase-unlink.sh" "$@"
    ;;
  sync)
    shift
    exec "$SCRIPT_DIR/dev-supabase-sync.sh" "$@"
    ;;
  migrate)
    shift
    exec "$SCRIPT_DIR/dev-supabase-migrate.sh" "$@"
    ;;
  seed)
    shift
    exec "$SCRIPT_DIR/dev-supabase-seed.sh" "$@"
    ;;
  reset)
    shift
    exec "$SCRIPT_DIR/dev-supabase-reset.sh" "$@"
    ;;
  flow)
    shift
    exec "$SCRIPT_DIR/dev-supabase-flow.sh" "$@"
    ;;
  *)
    echo "Usage: dev supabase <up|down|status|link|unlink|sync|migrate|seed|reset|flow>" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  up              Create supabase worktree and start Supabase" >&2
    echo "  down [--force]  Stop shared Supabase instance" >&2
    echo "  status          Show Supabase status" >&2
    echo "  link            Symlink current worktree's migrations and apply" >&2
    echo "  unlink          Remove current worktree's migration symlinks" >&2
    echo "  sync [--reset]  Fetch origin/main, update supabase worktree, clean stale symlinks" >&2
    echo "  migrate         Apply pending migrations in the shared worktree" >&2
    echo "  seed            Apply pending seeds (skips users.sql)" >&2
    echo "  reset           Full reset: db reset + migrate + seeds + functions serve" >&2
    echo "  flow [slug]     Compile + apply pgflow flows from invoking worktree" >&2
    exit 1
    ;;
esac
