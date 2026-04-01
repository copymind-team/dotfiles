#!/usr/bin/env bash
set -euo pipefail

# Wrapper for git worktree scripts.
# Usage: dev worktree up <branch-name>
#        dev worktree down <branch-name>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

case "${1:-}" in
  up)
    shift
    exec "$SCRIPT_DIR/dev-worktree-up.sh" "$@"
    ;;
  down)
    shift
    exec "$SCRIPT_DIR/dev-worktree-down.sh" "$@"
    ;;
  *)
    echo "Usage: dev worktree <up|down> <branch-name>" >&2
    exit 1
    ;;
esac
