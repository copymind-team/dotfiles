#!/usr/bin/env bash
set -euo pipefail

# Remove current worktree's symlinks from the hub and repair DB migration history.
# Usage: dev sb unlink

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/dev-supabase-helpers.sh"

require_bare_repo

current_wt="$(git rev-parse --show-toplevel)"
unlink_worktree_migrations "$current_wt"
