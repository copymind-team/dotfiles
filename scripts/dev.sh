#!/usr/bin/env bash
set -euo pipefail

# dev CLI — unified entry point for development tools.
# Usage: dev <command> [args]
#
# Commands:
#   session, s [dir]           Create a tmux dev session
#   worktree up, wt up <branch>   Create a git worktree with Docker isolation
#   worktree down, wt down <branch>   Tear down a git worktree

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

case "${1:-}" in
  s|session)
    shift
    exec "$SCRIPT_DIR/dev-session.sh" "$@"
    ;;
  wt|worktree)
    shift
    exec "$SCRIPT_DIR/dev-worktree.sh" "$@"
    ;;
  *)
    echo "Usage: dev <command> [args]" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  session, s [dir]             Create a tmux dev session" >&2
    echo "  worktree up, wt up <branch>  Create a git worktree with Docker isolation" >&2
    echo "  worktree down, wt down <branch>  Tear down a git worktree" >&2
    exit 1
    ;;
esac
